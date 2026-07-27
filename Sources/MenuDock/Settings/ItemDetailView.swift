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
                }
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
                    app: entry.app
                )
            }

            SectionBox("Name") {
                TextField(
                    entry.app.name,
                    text: Binding(
                        get: { entryBinding.wrappedValue.customTitle ?? "" },
                        set: { entryBinding.wrappedValue.customTitle = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                Text("Shown in tooltips and group menus. Leave empty to use the app's own name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    app: nil
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

// MARK: - Layout helper

/// Titled block matching the rhythm of native macOS settings panes.
private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
