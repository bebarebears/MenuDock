import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let environment: AppEnvironment

    var body: some View {
        TabView {
            MenuBarItemsView(environment: environment)
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            GeneralSettingsView(environment: environment)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 720, minHeight: 440)
    }
}

// MARK: - Items

/// The main editor: an ordered list of menu bar entries on the left, the selected entry's
/// settings on the right. Adding an app is a drag onto the list; changing its icon is a drag
/// onto the icon well.
struct MenuBarItemsView: View {
    let environment: AppEnvironment

    @State private var selection: DockItem.ID?
    @State private var isShowingAppPicker = false
    @State private var isShowingAddMenu = false
    @State private var isTargeted = false

    private var store: ConfigurationStore { environment.store }

    var body: some View {
        VStack(spacing: 0) {
            if store.didFailToLoad, let quarantined = store.quarantinedConfigurationURL {
                recoveryBanner(quarantined)
            }
            HSplitView {
                sidebar
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
                detail
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $isShowingAppPicker) {
            AppPickerSheet(environment: environment) { references in
                store.update { configuration in
                    configuration.items.append(contentsOf: references.map(DockItem.init(app:)))
                }
                selection = store.configuration.items.last?.id
            }
        }
        // Landing on an empty detail pane when there are items to edit is a wasted click.
        .onAppear {
            if selection == nil { selection = store.configuration.items.first?.id }
        }
    }

    /// Silence would be the worst outcome here: the user sees an empty menu bar and assumes
    /// their setup is gone, when it is sitting intact in a file next door.
    private func recoveryBanner(_ quarantined: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Your previous settings could not be read.")
                    .font(.callout.weight(.medium))
                Text("They have been preserved and nothing was deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show File") {
                NSWorkspace.shared.activateFileViewerSelecting([quarantined])
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !store.configuration.profiles.isEmpty {
                ProfileBar(environment: environment)
                Divider()
            }
            List(selection: $selection) {
                ForEach(store.configuration.items) { item in
                    ItemRow(environment: environment, item: item)
                        .tag(item.id)
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.inset)
            .overlay {
                if store.configuration.items.isEmpty {
                    emptyState
                }
            }
            // Dropping an app or folder anywhere on the list adds it — the fastest path from
            // Finder to menu bar, and the one users try first.
            .dropDestination(for: URL.self) { urls, _ in
                addDroppedItems(urls)
            } isTargeted: { targeted in
                isTargeted = targeted
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isTargeted ? 1 : 0)
                    .allowsHitTesting(false)
                    .padding(2)
            }

            Divider()
            footer
        }
        // The popup is an overlay on the sidebar rather than an attachment to the + button, so
        // it is laid out — and clipped — by this window instead of escaping onto the desktop.
        .overlay(alignment: .bottomLeading) {
            if isShowingAddMenu {
                ZStack(alignment: .bottomLeading) {
                    // Click-anywhere-else to dismiss, the one behaviour a real menu gives free.
                    Rectangle()
                        .fill(.black.opacity(0.001))
                        .onTapGesture { isShowingAddMenu = false }

                    AddItemPopup(
                        unavailable: unavailableChoices,
                        onChoose: { choice in
                            isShowingAddMenu = false
                            add(choice)
                        },
                        onDismiss: { isShowingAddMenu = false }
                    )
                    .padding(.leading, 5)
                    .padding(.bottom, 33)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.85), value: isShowingAddMenu)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Drag apps or folders here")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("or use the + button below")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                isShowingAddMenu.toggle()
            } label: {
                Image(systemName: "plus")
                    .rotationEffect(.degrees(isShowingAddMenu ? 45 : 0))
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
            .help("Add an app, folder, or group")
            .accessibilityLabel("Add to menu bar")

            Button {
                if let selection { store.remove(id: selection) }
                selection = nil
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
            .disabled(selection == nil)
            .help("Remove the selected item")

            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(.bar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let item = store.item(id: selection) {
            ItemDetailView(
                environment: environment,
                item: store.itemBinding(id: selection, fallback: item)
            )
            .id(selection)
        } else {
            ContentUnavailableView(
                "No Item Selected",
                systemImage: "menubar.rectangle",
                description: Text("Select an entry to change its icon, name, or apps.")
            )
        }
    }

    // MARK: Actions

    /// The choices the configuration already holds one of. Recomputed on every render, so
    /// removing the Clipboard item re-enables its row without the popup having to be told.
    private var unavailableChoices: Set<AddItemChoice> {
        Set(AddItemChoice.allCases.filter { choice in
            guard let kind = choice.singletonKind else { return false }
            return store.configuration.contains(singletonLike: kind)
        })
    }

    private func add(_ choice: AddItemChoice) {
        switch choice {
        case .app:
            isShowingAppPicker = true
        case .folder:
            chooseFolders()
        case .group:
            store.addGroup()
            selection = store.configuration.items.last?.id
        case .activity:
            // Selecting by the returned id rather than by "the last item" — the store declines to
            // add a second, and taking the last item regardless would silently move the selection
            // to whatever happens to sit at the end of the list.
            if let id = store.addActivity() { selection = id }
        case .clipboard:
            if let id = store.addClipboard() { selection = id }
        }
    }

    /// Folders are picked with `NSOpenPanel` rather than a MenuDock-drawn browser: it is the
    /// panel every Mac user already knows, and it comes with sidebar favourites, iCloud Drive,
    /// and network volumes that would take a month to reimplement badly.
    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to open from the menu bar."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        store.addFolders(at: panel.urls)
        selection = store.configuration.items.last?.id
    }

    /// Accepts both app bundles and plain folders from one drop, since the user dragging things
    /// out of a Finder window has no reason to sort them first.
    private func addDroppedItems(_ urls: [URL]) -> Bool {
        let before = store.configuration.items.count

        for url in urls where url.pathExtension == "app" {
            store.addApplication(at: url)
        }
        // `addFolders` rejects anything that is not a directory, so a file dropped alongside is
        // discarded rather than becoming a broken entry.
        store.addFolders(at: urls.filter { $0.pathExtension != "app" })

        guard store.configuration.items.count > before else { return false }
        selection = store.configuration.items.last?.id
        return true
    }
}

// MARK: - Profile bar

/// The active-profile switcher, above the item list.
///
/// Sits here rather than in the General tab because this is the list it filters, and a control
/// that changes what a list contains belongs beside the list. It appears only once a profile
/// exists — see ``ProfileMembershipSection`` for the same reasoning applied to the item editor.
private struct ProfileBar: View {
    let environment: AppEnvironment

    private var store: ConfigurationStore { environment.store }

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { store.configuration.activeProfileID },
                set: { store.activateProfile($0) }
            )) {
                Label("All Items", systemImage: "square.stack.3d.up.fill")
                    .tag(Profile.ID?.none)
                Divider()
                ForEach(store.configuration.profiles) { profile in
                    Label(profile.effectiveName, systemImage: profile.symbolName)
                        .tag(Profile.ID?.some(profile.id))
                }
            }
            .labelsHidden()

            let hidden = store.configuration.itemsHiddenByProfile
            if hidden > 0 {
                Text("\(hidden) hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Items not in this profile stay in the list, dimmed.")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Sidebar row

private struct ItemRow: View {
    let environment: AppEnvironment
    let item: DockItem

    /// Whether this item is on the menu bar right now, given the active profile and auto-hiding.
    ///
    /// A hidden item stays in the list, dimmed, rather than disappearing from it. The list is
    /// where the whole setup is edited, and a profile that removed items from *the editor* as
    /// well as from the bar would leave the user no way to put them back.
    private var isShowing: Bool {
        item.isMember(ofProfile: environment.store.configuration.activeProfileID)
            && !environment.space.hiddenItemIDs.contains(item.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            // Drawn at this item's own size, in a slot wide enough for the largest one allowed,
            // so a resized icon looks resized here too and the rows still line up.
            Image(nsImage: environment.icons.image(
                for: item.icon,
                app: item.referencedApps.first,
                size: item.resolvedIconSize(
                    default: environment.store.configuration.preferences.iconSize
                ),
                tint: item.tint
            ))
            .frame(width: IconRenderer.maximumIconSize, height: IconRenderer.maximumIconSize)

            Text(item.displayTitle)
                .lineLimit(1)

            Spacer(minLength: 4)

            if !isShowing {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(item.isMember(ofProfile: environment.store.configuration.activeProfileID)
                            ? "Hidden — the menu bar has run out of room"
                            : "Not in the active profile")
            }

            switch item.kind {
            case .group:
                countBadge(item.referencedApps.count)
            case .folder(let entry):
                if entry.folders.count == 1 {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(entry.folders[0].displayPath)
                } else {
                    countBadge(entry.folders.count)
                }
            case .application(let entry):
                if environment.running.isRunning(entry.app.bundleIdentifier) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .help("Running")
                }
            case .activity(let entry):
                countBadge(entry.gauges.count)
            case .clipboard:
                countBadge(environment.clipboard.history.items.count)
            }
        }
        .padding(.vertical, 2)
        .opacity(isShowing ? 1 : 0.45)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let environment: AppEnvironment

    @State private var launchAtLogin = LoginItem.isEnabled

    private var store: ConfigurationStore { environment.store }

    var body: some View {
        Form {
            Section {
                Toggle("Launch MenuDock at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if !LoginItem.setEnabled(newValue) {
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if LoginItem.requiresUserApproval {
                    HStack {
                        Text("Approval is required in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open…") { LoginItem.openLoginItemsSettings() }
                            .buttonStyle(.link)
                    }
                }
            }

            Section("Appearance") {
                Toggle(
                    "Show a dot beneath running apps",
                    isOn: store.binding(\.preferences.showRunningIndicator)
                )

                Toggle(
                    "Animate built-in icons",
                    isOn: store.binding(\.preferences.animateIcons)
                )
                .disabled(environment.animator.reduceMotionEnabled)

                if environment.animator.reduceMotionEnabled {
                    Text("Animation is off because Reduce Motion is enabled in System Settings › Accessibility › Display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if environment.animator.isThrottled {
                    // Said out loud, because a halved frame rate that appears unannounced reads
                    // as the app being janky rather than as the app being considerate.
                    Label(
                        "Running at half frame rate while Low Power Mode is on.",
                        systemImage: "battery.25percent"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                LabeledContent("Icon size") {
                    HStack {
                        // Upper bound comes from the menu bar's actual height rather than a
                        // constant, so the slider cannot offer sizes that would be clamped
                        // back down on the way to the screen.
                        Slider(
                            value: store.binding(\.preferences.iconSize),
                            in: 14...IconRenderer.maximumIconSize,
                            step: 1
                        )
                        .frame(width: 180)
                        Text("\(Int(store.configuration.preferences.iconSize)) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle(
                    "Hide items when the menu bar runs out of room",
                    isOn: store.binding(\.preferences.autoHideWhenCrowded)
                )

                if store.configuration.preferences.autoHideWhenCrowded {
                    SpaceVerdictLine(environment: environment)
                }
            } header: {
                HelpLabel("Menu Bar Space", help: """
                    A 14" MacBook has roughly a third the usable menu bar of a large display once \
                    the notch and the app menus have taken their share, so a setup that fits \
                    docked may not fit undocked. With this on, MenuDock drops its lowest-priority \
                    items rather than letting macOS silently clip whichever happens to be \
                    leftmost. Each item's priority is set in its own pane.
                    """)
            }

            Section {
                ProfileEditor(environment: environment)
            } header: {
                HelpLabel("Profiles", help: """
                    A profile is a named subset of your menu bar — “Work”, “Personal”, \
                    “Presenting”. Items belong to as many as you like, and switching profiles \
                    shows and hides them without changing anything else about them.

                    A new profile starts with every item in it. Remove what you do not want from \
                    each item's own pane.
                    """)
            }

            Section {
                LabeledContent("Configuration") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ConfigurationStore.configurationURL]
                        )
                    }
                    .buttonStyle(.link)
                }
            } footer: {
                Text("Settings and custom icons are stored in ~/Library/Application Support/MenuDock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Icon size changes have to invalidate every cached render, since size is part of
        // the cache key but the status items are not otherwise told to redraw.
        .onChange(of: store.configuration.preferences.iconSize) { _, _ in
            environment.icons.invalidateCache(includingAnimationFrames: true)
        }
    }
}

// MARK: - Space verdict

/// What the last auto-hide evaluation concluded, in words.
///
/// A feature that removes things from the menu bar has to be able to say what it did and why. The
/// figures are the ones the decision was actually made on — see ``MenuBarSpaceMonitor`` — so if
/// they look wrong the user has something concrete to disbelieve rather than a vanished icon.
private struct SpaceVerdictLine: View {
    let environment: AppEnvironment

    var body: some View {
        // The verdict is recomputed on screen changes and edits, not on a timer, so this reads
        // whatever the last reconcile concluded.
        if let verdict = environment.space.lastVerdict {
            if verdict.isOverBudgetRegardless {
                Label(
                    """
                    Even the items marked “Always show” do not fit — \(points(verdict.wanted)) \
                    wanted, \(points(verdict.available)) available. macOS will clip one of them.
                    """,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if verdict.hiddenCount > 0 {
                Label(
                    """
                    \(verdict.hiddenCount == 1 ? "1 item is" : "\(verdict.hiddenCount) items are") \
                    hidden to fit \(points(verdict.wanted)) of items into \
                    \(points(verdict.available)).
                    """,
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(
                    "Everything fits — \(points(verdict.wanted)) of \(points(verdict.available)) used.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func points(_ value: Double) -> String {
        "\(Int(value.rounded())) pt"
    }
}

// MARK: - Profiles

/// Create, rename, re-symbol and delete profiles.
///
/// The section heading carries a `?`, because a list with a + button under a heading saying
/// "Profiles" tells a first-time reader nothing about what a profile *is* in this app — and the
/// answer here ("a subset of your items", not "a separate menu bar") is not the one they would
/// guess.
private struct ProfileEditor: View {
    let environment: AppEnvironment

    @State private var selection: Profile.ID?

    private var store: ConfigurationStore { environment.store }
    private var profiles: [Profile] { store.configuration.profiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profiles.isEmpty {
                Text("No profiles yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(selection: $selection) {
                    ForEach(profiles) { profile in
                        row(profile)
                            .tag(profile.id)
                    }
                }
                .listStyle(.bordered)
                .frame(height: 116)
            }

            HStack(spacing: 8) {
                Button {
                    selection = store.addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a profile")

                Button {
                    if let selection { store.removeProfile(id: selection) }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Delete the selected profile")

                Spacer()
            }
        }
    }

    private func row(_ profile: Profile) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Profile.symbolChoices, id: \.self) { symbol in
                    Button {
                        store.setProfileSymbol(id: profile.id, to: symbol)
                    } label: {
                        Label(symbol, systemImage: symbol)
                    }
                }
            } label: {
                Image(systemName: profile.symbolName)
                    .frame(width: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose an icon")

            TextField("Profile name", text: Binding(
                get: { profile.name },
                set: { store.renameProfile(id: profile.id, to: $0) }
            ))
            .textFieldStyle(.plain)

            if store.configuration.activeProfileID == profile.id {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Switch") { store.activateProfile(profile.id) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 1)
    }
}
