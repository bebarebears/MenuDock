import SwiftUI

/// Editor for whichever entry is selected in the sidebar.
struct ItemDetailView: View {
    let environment: AppEnvironment
    @Binding var item: DockItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch item.kind {
                case .application:
                    applicationEditor
                case .group:
                    groupEditor
                case .folder:
                    folderEditor
                case .activity:
                    activityEditor
                case .clipboard:
                    clipboardEditor
                }

                // Shared by every kind, and below the kind-specific parts because they answer a
                // different question: everything above is *what this item is*, and this is *when
                // you see it*.
                Divider()
                ProfileMembershipSection(environment: environment, item: $item)
                PrioritySection(environment: environment, item: $item)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Application

    @ViewBuilder
    private var applicationEditor: some View {
        if let entry = item.appEntry {
            let entryBinding = Binding<AppEntry>(
                get: { item.appEntry ?? entry },
                set: { item.appEntry = $0 }
            )

            SectionBox("Icon") {
                IconEditor(
                    environment: environment,
                    spec: entryBinding.icon,
                    size: $item.iconSize,
                    tint: $item.tint,
                    app: entry.app
                )
            }

            SectionBox(
                "Name",
                help: "Shown in tooltips and group menus. Leave it empty to use the app's own name."
            ) {
                TextField(
                    entry.app.name,
                    text: Binding(
                        get: { entryBinding.wrappedValue.customTitle ?? "" },
                        set: { entryBinding.wrappedValue.customTitle = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            SectionBox("Application") {
                ApplicationSummary(environment: environment, app: entry.app)
            }
        }
    }

    // MARK: - Group

    @ViewBuilder
    private var groupEditor: some View {
        if let group = item.groupEntry {
            let groupBinding = Binding<GroupEntry>(
                get: { item.groupEntry ?? group },
                set: { item.groupEntry = $0 }
            )

            SectionBox("Icon") {
                IconEditor(
                    environment: environment,
                    spec: groupBinding.icon,
                    size: $item.iconSize,
                    tint: $item.tint,
                    app: nil,
                    defaultBuiltinID: "grid"
                )
            }

            SectionBox("Name") {
                TextField("Group name", text: groupBinding.name)
                    .textFieldStyle(.roundedBorder)
            }

            SectionBox("Apps in this Group") {
                GroupMemberList(environment: environment, group: groupBinding)
            }
        }
    }

    // MARK: - Folder

    @ViewBuilder
    private var folderEditor: some View {
        if let folder = item.folderEntry {
            let folderBinding = Binding<FolderEntry>(
                get: { item.folderEntry ?? folder },
                set: { item.folderEntry = $0 }
            )

            SectionBox("Icon") {
                IconEditor(
                    environment: environment,
                    spec: folderBinding.icon,
                    size: $item.iconSize,
                    tint: $item.tint,
                    app: nil,
                    defaultBuiltinID: "folder"
                )
            }

            SectionBox(
                "Name",
                help: "Shown in the tooltip. Leave it as the folder's own name if you like."
            ) {
                TextField(folder.folders.count == 1 ? folder.folders[0].name : "Folder item name",
                          text: folderBinding.name)
                    .textFieldStyle(.roundedBorder)
            }

            SectionBox("Folders to Open") {
                FolderList(environment: environment, entry: folderBinding)
            }
        }
    }

    // MARK: - Clipboard

    /// Unlike Activity, this one has an icon well: a Clipboard item is an ordinary menu bar icon
    /// and picks from the same library as everything else. Only what sits *below* the well is
    /// particular to it, which is why that part lives in ``ClipboardEditor``.
    @ViewBuilder
    private var clipboardEditor: some View {
        if let clipboard = item.clipboardEntry {
            let clipboardBinding = Binding<ClipboardEntry>(
                get: { item.clipboardEntry ?? clipboard },
                set: { item.clipboardEntry = $0 }
            )

            SectionBox("Icon") {
                IconEditor(
                    environment: environment,
                    spec: clipboardBinding.icon,
                    size: $item.iconSize,
                    tint: $item.tint,
                    app: nil,
                    defaultBuiltinID: "clipboard"
                )
            }

            ClipboardEditor(environment: environment, entry: clipboardBinding)
        }
    }

    // MARK: - Activity

    /// Unlike the other three, this editor has no icon well: an Activity item draws itself from
    /// live data, so there is no artwork to choose. The size knob those wells carry moves here,
    /// where it controls the *height* of the gauge strip — the width being the one thing the
    /// user does not set.
    @ViewBuilder
    private var activityEditor: some View {
        if let activity = item.activity {
            let activityBinding = Binding<ActivityEntry>(
                get: { item.activity ?? activity },
                set: { item.activityEntry = $0 }
            )

            ActivityEditor(
                environment: environment,
                entry: activityBinding,
                tint: $item.tint,
                height: item.resolvedIconSize(
                    default: environment.store.configuration.preferences.iconSize
                )
            )

            SectionBox(
                "Height",
                help: "Everything scales with this — graphs, bars, and the size of the numbers."
            ) {
                HStack {
                    Slider(
                        value: Binding(
                            get: {
                                item.iconSize
                                    ?? environment.store.configuration.preferences.iconSize
                            },
                            set: { item.iconSize = $0 }
                        ),
                        in: 12...IconRenderer.maximumIconSize,
                        step: 1
                    )
                    .frame(width: 200)

                    Text("\(Int(item.resolvedIconSize(default: environment.store.configuration.preferences.iconSize))) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)

                    if item.iconSize != nil {
                        Button("Reset") { item.iconSize = nil }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Folder list

/// Editor for the folders behind one menu bar icon.
///
/// Mirrors ``GroupMemberList`` deliberately — the two are the same gesture applied to different
/// things, and making them look and behave differently would be a needless second thing to learn.
private struct FolderList: View {
    let environment: AppEnvironment
    @Binding var entry: FolderEntry

    @State private var selection: FolderReference.ID?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(entry.folders) { folder in
                    row(folder)
                        .tag(folder.id)
                }
                .onMove { source, destination in
                    entry.folders.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.bordered)
            .frame(height: 150)
            .overlay {
                if entry.folders.isEmpty {
                    Text("Drag folders here, or use +")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let added = urls.compactMap(FolderReference.init(folderURL:))
                guard !added.isEmpty else { return false }
                entry.folders.append(contentsOf: added)
                adoptSingleFolderName()
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                Button(action: choose) {
                    Image(systemName: "plus")
                }
                .help("Choose folders to add")

                Button {
                    entry.folders.removeAll { $0.id == selection }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected folder")

                Spacer()

                if let selection, let folder = entry.folders.first(where: { $0.id == selection }) {
                    Button("Show in Finder") { AppLauncher.revealFolder(folder) }
                        .controlSize(.small)
                }
            }

            if entry.folders.count > 1 {
                Divider().padding(.vertical, 2)
                Toggle("Open every folder on click", isOn: $entry.opensAllAtOnce)
                Text(entry.opensAllAtOnce
                        ? "Clicking the icon opens all \(entry.folders.count) folders in Finder."
                        : "Clicking the icon lists the folders so you can pick one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.folders.count == 1 {
                Text("Clicking the icon opens this folder in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ folder: FolderReference) -> some View {
        let exists = folder.resolvedURL != nil
        return HStack(spacing: 8) {
            Image(nsImage: finderIcon(folder))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(folder.name)
                    .lineLimit(1)
                Text(folder.displayPath)
                    .font(.caption)
                    .foregroundStyle(exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !exists {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This folder could not be found. It may be on a volume that is not mounted.")
            }
        }
        .padding(.vertical, 1)
    }

    private func finderIcon(_ folder: FolderReference) -> NSImage {
        if let url = folder.resolvedURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "questionmark.folder", accessibilityDescription: nil)
            ?? NSImage()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to open from the menu bar."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap(FolderReference.init(folderURL:))
        guard !added.isEmpty else { return }
        entry.folders.append(contentsOf: added)
        adoptSingleFolderName()
    }

    /// "Folders" is a placeholder, not a name. The moment an item points at exactly one folder,
    /// that folder's own name is the better answer.
    private func adoptSingleFolderName() {
        guard entry.folders.count == 1 else { return }
        let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Folders" {
            entry.name = entry.folders[0].name
        }
    }
}

// MARK: - Group members

private struct GroupMemberList: View {
    let environment: AppEnvironment
    @Binding var group: GroupEntry

    @State private var isShowingPicker = false
    @State private var selection: AppEntry.ID?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(group.members) { member in
                    HStack(spacing: 8) {
                        Image(nsImage: environment.icons.image(
                            for: member.icon, app: member.app, size: 18
                        ))
                        .frame(width: 18, height: 18)
                        Text(member.displayTitle)
                        Spacer()
                        if environment.running.isRunning(member.app.bundleIdentifier) {
                            Circle().fill(.secondary).frame(width: 5, height: 5)
                        }
                    }
                    .tag(member.id)
                }
                .onMove { source, destination in
                    group.members.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.bordered)
            .frame(height: 180)
            .overlay {
                if group.members.isEmpty {
                    Text("Drag apps here, or use +")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let added = urls
                    .filter { $0.pathExtension == "app" }
                    .compactMap(AppReference.init(applicationURL:))
                guard !added.isEmpty else { return false }
                group.members.append(contentsOf: added.map { AppEntry(app: $0) })
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                Button {
                    isShowingPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add apps to this group")

                Button {
                    group.members.removeAll { $0.id == selection }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected app")

                Spacer()

                Text("Apps appear in this order in the dropdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isShowingPicker) {
            AppPickerSheet(environment: environment) { references in
                group.members.append(contentsOf: references.map { AppEntry(app: $0) })
            }
        }
    }
}

// MARK: - Application summary

private struct ApplicationSummary: View {
    let environment: AppEnvironment
    let app: AppReference

    var body: some View {
        let resolved = app.resolvedURL
        let isRunning = environment.running.isRunning(app.bundleIdentifier)

        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Bundle ID") {
                Text(app.bundleIdentifier)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Location") {
                Text(resolved?.path ?? "Not found")
                    .font(.caption)
                    .foregroundStyle(resolved == nil ? .red : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent("Status") {
                Label(
                    isRunning ? "Running" : "Not running",
                    systemImage: isRunning ? "circle.fill" : "circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if resolved == nil {
                Label(
                    "This app could not be found. Reinstall it, or remove this entry.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Profiles

/// Which profiles show this item.
///
/// Absent entirely until the user has created a profile. Profiles are a feature you opt into, and
/// a permanently empty section headed "Profiles" would be a question mark in every item's editor
/// for the large majority of people who never make one.
private struct ProfileMembershipSection: View {
    let environment: AppEnvironment
    @Binding var item: DockItem

    private var profiles: [Profile] { environment.store.configuration.profiles }

    var body: some View {
        if !profiles.isEmpty {
            SectionBox("Profiles") {
                ForEach(profiles) { profile in
                    Toggle(isOn: binding(for: profile)) {
                        Label(profile.effectiveName, systemImage: profile.symbolName)
                    }
                }

                Text(item.profileIDs == nil
                        ? "Shown in every profile."
                        : "Shown only in the profiles ticked above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Goes through the store rather than mutating the binding directly, because switching one
    /// profile off has to know about all of them — an item's membership starts as "all", and the
    /// first removal is what turns that into an explicit list. See ``DockItem/setMembership(_:ofProfile:allProfiles:)``.
    private func binding(for profile: Profile) -> Binding<Bool> {
        Binding(
            get: { item.isMember(ofProfile: profile.id) },
            set: { environment.store.setMembership($0, ofItem: item.id, inProfile: profile.id) }
        )
    }
}

// MARK: - Priority

/// How readily this item gives up its slot when the bar is crowded.
///
/// Shown whether or not auto-hiding is switched on, but with a different footnote: setting a
/// priority in advance is a reasonable thing to do before the situation that needs it, and a
/// control that appears only once you have flipped a switch in a different tab is a control
/// nobody finds.
private struct PrioritySection: View {
    let environment: AppEnvironment
    @Binding var item: DockItem

    var body: some View {
        SectionBox(
            "When the menu bar is full",
            help: """
                The menu bar cannot scroll, and items that do not fit are not clipped — they are \
                simply not drawn, starting from the left. This is how you choose which ones go \
                first. Switch the rule on in General.
                """
        ) {
            Picker("", selection: $item.priority) {
                ForEach(ItemPriority.allCases) { priority in
                    Label(priority.displayName, systemImage: priority.symbolName)
                        .tag(priority)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            // The summary is *state* — it says what the current selection does — so it stays on
            // the pane. The "switch it on first" line is too, and it is the reason a user would
            // otherwise think this control was broken.
            Text(item.priority.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !environment.store.configuration.preferences.autoHideWhenCrowded {
                Label("Not active yet — switch on hiding in General.",
                      systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Layout helper

/// Titled block matching the rhythm of native macOS settings panes.
///
/// Not `private`, because ``ActivityEditor`` lives in its own file and must produce the same
/// vertical rhythm as the editors here — the two are shown in the same pane.
///
/// `help` puts a ``HelpNote`` beside the heading, which is where an explanation of the *whole*
/// section belongs. An explanation of one control goes beside that control instead — see
/// ``HelpRow``.
struct SectionBox<Content: View>: View {
    let title: String
    let help: String?
    @ViewBuilder let content: Content

    init(_ title: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                if let help {
                    HelpNote(help)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
