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
            // Dropping an app bundle anywhere on the list adds it — the fastest path from
            // Finder to menu bar, and the one users try first.
            .dropDestination(for: URL.self) { urls, _ in
                addApplications(urls)
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
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("Drag apps here")
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
            Menu {
                Button("Add App…") { isShowingAppPicker = true }
                Button("Add Group") {
                    store.addGroup()
                    selection = store.configuration.items.last?.id
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Add an app or group")

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

    private func addApplications(_ urls: [URL]) -> Bool {
        let bundles = urls.filter { $0.pathExtension == "app" }
        guard !bundles.isEmpty else { return false }
        for url in bundles {
            store.addApplication(at: url)
        }
        selection = store.configuration.items.last?.id
        return true
    }
}

// MARK: - Sidebar row

private struct ItemRow: View {
    let environment: AppEnvironment
    let item: DockItem

    var body: some View {
        HStack(spacing: 8) {
            // Drawn at the configured size, in a slot wide enough for the largest one allowed,
            // so a resized custom icon looks resized here too and the rows still line up.
            Image(nsImage: environment.icons.image(
                for: item.icon,
                app: item.referencedApps.first,
                size: environment.store.configuration.preferences.iconSize
            ))
            .frame(width: IconRenderer.maximumIconSize, height: IconRenderer.maximumIconSize)

            Text(item.displayTitle)
                .lineLimit(1)

            Spacer(minLength: 4)

            if item.isGroup {
                Text("\(item.referencedApps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            } else if let app = item.referencedApps.first,
                      environment.running.isRunning(app.bundleIdentifier) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 5, height: 5)
                    .help("Running")
            }
        }
        .padding(.vertical, 2)
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
            environment.icons.invalidateCache()
        }
    }
}
