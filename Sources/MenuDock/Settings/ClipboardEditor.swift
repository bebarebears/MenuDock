import SwiftUI

/// Editor for the Clipboard item: what it keeps, for how long, and how it is recalled.
///
/// The icon well is deliberately *not* here — it sits in ``ItemDetailView`` alongside the app,
/// group and folder wells, because a Clipboard item is an ordinary icon like those and picks from
/// the same library. That is the difference between this and the Activity editor, whose item
/// draws itself from live data and so has no artwork to choose.
struct ClipboardEditor: View {
    let environment: AppEnvironment
    @Binding var entry: ClipboardEntry

    @State private var isConfirmingClear = false

    private var history: ClipboardHistoryStore { environment.clipboard.history }
    private var permission: AccessibilityPermission { environment.clipboard.permission }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionBox("Name") {
                TextField("Clipboard", text: $entry.name)
                    .textFieldStyle(.roundedBorder)
                Text("Shown in the tooltip and at the top of the dropdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SectionBox("History") {
                historySettings
            }

            SectionBox("What to Record") {
                captureSettings
            }

            SectionBox("Recall") {
                recallSettings
            }
        }
        // macOS posts nothing when a permission changes, so the live state is polled — but only
        // while this pane is on screen, which is the only place it is shown. Without it the note
        // below would be a snapshot from whenever SwiftUI last happened to re-render, and the user
        // who has just granted the permission would come back to a pane still telling them to.
        .onAppear { permission.startWatching() }
        .onDisappear { permission.stopWatching() }
    }

    // MARK: - History

    @ViewBuilder
    private var historySettings: some View {
        Picker("Keep items for", selection: $entry.retention) {
            ForEach(ClipboardRetention.allCases) { retention in
                Text(retention.displayName).tag(retention)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)

        HStack(spacing: 8) {
            Text("Keep at most")
            // A stepper rather than a slider: this is a number the user reasons about ("about a
            // day's worth"), not a continuum they scrub through, and the slider's precision would
            // be spent on the difference between 347 and 348.
            TextField(
                "",
                value: Binding(
                    get: { entry.maxItems },
                    set: { entry.maxItems = min(max($0, ClipboardEntry.maxItemsRange.lowerBound),
                                                ClipboardEntry.maxItemsRange.upperBound) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            Stepper("", value: $entry.maxItems, in: ClipboardEntry.maxItemsRange, step: 25)
                .labelsHidden()
            Text("items")
        }

        Text("""
            Both limits apply — whichever runs out first. Items are stored in \
            ~/Library/Application Support/MenuDock/Clipboard, and copied *files* are recorded by \
            path, never duplicated.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider().padding(.vertical, 2)

        HStack {
            Text(storageSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear History…") { isConfirmingClear = true }
                .controlSize(.small)
                .disabled(history.items.isEmpty)
        }
        .confirmationDialog(
            history.items.count == 1
                ? "Delete the 1 item in your clipboard history?"
                : "Delete all \(history.items.count) items in your clipboard history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. The Clipboard item stays in your menu bar and carries "
                 + "on recording.")
        }
    }

    private var storageSummary: String {
        let count = history.items.count
        guard count > 0 else { return "Nothing stored yet." }
        let size = ByteCountFormatStyle(style: .file).format(Int64(history.totalByteCount))
        return count == 1 ? "1 item · \(size)" : "\(count) items · \(size)"
    }

    // MARK: - Capture

    @ViewBuilder
    private var captureSettings: some View {
        Toggle("Text", isOn: $entry.capturesText)
        Toggle("Images", isOn: $entry.capturesImages)
        Toggle("Files", isOn: $entry.capturesFiles)

        if !entry.capturesAnything {
            Label(
                "Nothing will be recorded. Your existing history is kept and stays searchable.",
                systemImage: "pause.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Divider().padding(.vertical, 2)

        Toggle("Skip items apps mark as confidential", isOn: $entry.ignoresConfidential)
        Text("""
            Password managers flag what they copy so clipboard tools ignore it. Leave this on \
            unless you have a specific reason not to — MenuDock cannot tell a password from any \
            other text on its own.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Recall

    @ViewBuilder
    private var recallSettings: some View {
        Toggle("Open the history with \(GlobalHotKey.recallDisplayName)", isOn: $entry.hotkeyEnabled)

        if entry.hotkeyEnabled {
            if environment.clipboard.hotKeyUnavailable {
                Label(
                    "\(GlobalHotKey.recallDisplayName) is already taken by another app, so the "
                        + "shortcut is not active. Clicking the menu bar icon still works.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("""
                    Let go and it pastes: a plain tap gives you the newest item, and holding ⌘⇧ \
                    while tapping V walks further down the list — the same gesture as ⌘-Tab. \
                    Escape cancels without pasting. To browse without committing to anything, \
                    click the menu bar icon instead; that leaves the list open.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Divider().padding(.vertical, 2)

        Toggle("Paste straight into the app I was using", isOn: $entry.pastesAutomatically)
        accessibilityNote
    }

    /// The permission story, stated plainly and only when it is actually load-bearing.
    ///
    /// The two refusals are shown differently on purpose. "Never granted" is a normal state with an
    /// obvious next step. "Granted to an earlier build" is a **trap**: the switch in System
    /// Settings is on, the *Grant Permission* button is a silent no-op because macOS only prompts
    /// when it has no row for the app at all, and the only thing that works is removing the entry
    /// and adding it back. A user has no way to deduce any of that, so it is spelled out.
    @ViewBuilder
    private var accessibilityNote: some View {
        if entry.pastesAutomatically, let denial = permission.denial {
            VStack(alignment: .leading, spacing: 6) {
                if denial == .grantedToAnotherBuild {
                    Label(
                        "MenuDock's Accessibility permission was granted to an earlier build and "
                            + "no longer applies — macOS ties it to the exact copy of the app. The "
                            + "switch still looks on. Remove MenuDock from the list with – and add "
                            + "it back with +, or switch it off and on again.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("""
                        macOS needs Accessibility permission before one app can press ⌘V in \
                        another. Without it, choosing an item still copies it and returns you to \
                        your app — you press ⌘V yourself.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    // *Grant Permission* is offered only when it can actually do something. Once
                    // macOS has a row for MenuDock — including the stale one above — it raises no
                    // prompt, and a button that visibly does nothing is worse than no button. In
                    // that case System Settings is the only remedy, so it stops being the quiet
                    // link beside a primary action and becomes the action.
                    if denial == .notGranted {
                        Button("Grant Permission…") { permission.requestPrompt() }
                            .controlSize(.small)

                        Button("Open System Settings") { permission.openSystemSettings() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    } else {
                        Button("Open System Settings…") { permission.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            }
        } else {
            Text(entry.pastesAutomatically
                 ? "Choosing an item returns you to the app you were in and pastes it."
                 : "Choosing an item copies it and returns you to the app you were in. Press ⌘V "
                   + "to paste.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
