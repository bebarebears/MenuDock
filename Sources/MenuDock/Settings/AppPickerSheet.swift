import SwiftUI

/// Searchable list of installed applications.
///
/// Backed by ``InstalledAppsIndex`` rather than `NSOpenPanel` so apps can be filtered by
/// name and added several at a time — dragging in eight apps one panel at a time is the kind
/// of friction that makes a launcher feel worse than the Dock it replaces. The panel is still
/// available via "Browse…" for apps outside the scanned locations.
struct AppPickerSheet: View {
    let environment: AppEnvironment
    var onSelect: ([AppReference]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Set<AppReference.ID> = []

    private var results: [AppReference] {
        environment.installedApps.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 460, height: 480)
        .onAppear {
            if environment.installedApps.applications.isEmpty {
                environment.installedApps.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search applications", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
    }

    private var list: some View {
        List(results, selection: $selection) { app in
            HStack(spacing: 8) {
                Image(nsImage: icon(for: app))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(app.name)
                Spacer()
                if environment.running.isRunning(app.bundleIdentifier) {
                    Circle().fill(.secondary).frame(width: 5, height: 5)
                }
            }
            .tag(app.id)
            .contentShape(.rect)
            // Double-click is the expected shortcut for "add this one and close".
            .onTapGesture(count: 2) {
                onSelect([app])
                dismiss()
            }
        }
        .listStyle(.inset)
        .overlay {
            if environment.installedApps.isScanning && results.isEmpty {
                ProgressView().controlSize(.small)
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Browse…", action: browse)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                let chosen = results.filter { selection.contains($0.id) }
                if !chosen.isEmpty { onSelect(chosen) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty)
        }
        .padding(10)
    }

    private func icon(for app: AppReference) -> NSImage {
        guard let url = app.resolvedURL else {
            return NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil)
                ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }
        let references = panel.urls.compactMap(AppReference.init(applicationURL:))
        if !references.isEmpty { onSelect(references) }
        dismiss()
    }
}
