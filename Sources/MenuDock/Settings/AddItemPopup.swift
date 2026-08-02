import SwiftUI

/// What the + button can add.
enum AddItemChoice: String, CaseIterable, Identifiable {
    case app
    case folder
    case group
    case activity
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "Add App"
        case .folder: "Add Folder"
        case .group: "Add Group"
        case .activity: "Add Activity"
        case .clipboard: "Add Clipboard"
        }
    }

    var detail: String {
        switch self {
        case .app: "One click launches it"
        case .folder: "Opens in Finder"
        case .group: "Several apps, one icon"
        case .activity: "Live CPU, memory, network"
        case .clipboard: "Everything you copy, recallable"
        }
    }

    var symbolName: String {
        switch self {
        case .app: "square.grid.2x2"
        case .folder: "folder"
        case .group: "rectangle.stack"
        case .activity: "waveform.path.ecg"
        case .clipboard: "doc.on.clipboard"
        }
    }

    /// The kind this choice would create, for the choices that create one outright.
    ///
    /// Only the singleton kinds have one, and only so the popup can ask the configuration
    /// whether it already holds one — the others open a picker and cannot be answered in advance.
    var singletonKind: DockItem.Kind? {
        switch self {
        case .app, .folder, .group: nil
        case .activity: .activity(ActivityEntry())
        case .clipboard: .clipboard(ClipboardEntry())
        }
    }

    /// Replaces ``detail`` on a row that cannot be chosen, so the row explains itself instead of
    /// being greyed out for no stated reason.
    static let alreadyAddedDetail = "Already in your menu bar"
}

/// The + button's menu, drawn **inside** the settings window.
///
/// ## Why this is not a `Menu`
///
/// A SwiftUI `Menu` (or any `NSMenu`) is its own window, and AppKit positions it below its
/// anchor with no regard for the window it came from. Anchored to a button on the bottom edge of
/// a settings window, that puts the menu on the desktop *outside* the window — floating in
/// space, clipped by nothing, and visually detached from the app it belongs to.
///
/// This is a plain SwiftUI overlay instead, so it is laid out by the window that owns it and
/// opens upward from the button. The cost is that keyboard handling and dismissal have to be
/// written by hand; the gain is a popup that always sits inside its own window.
struct AddItemPopup: View {
    /// Choices already in the menu bar. Shown, but not choosable — hiding them instead would
    /// make the menu's contents change shape between openings, and leave a user who wonders where
    /// "Add Clipboard" went with nothing to read.
    var unavailable: Set<AddItemChoice> = []
    var onChoose: (AddItemChoice) -> Void
    var onDismiss: () -> Void

    @State private var hovered: AddItemChoice?
    @State private var escapeMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(AddItemChoice.allCases) { choice in
                row(choice)
            }
        }
        .padding(5)
        .frame(width: 214)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.separator.opacity(0.7), lineWidth: 1)
        }
        // Escape closes it, matching every other menu on the system.
        //
        // A hidden `Button(...).keyboardShortcut(.cancelAction)` is the tidy-looking way to do
        // this and it is wrong: inside an `NSHostingController` that promotes Escape to the
        // window's cancel action, so pressing it closed the entire settings window. A local key
        // monitor that *swallows* the event keeps Escape scoped to this popup.
        .onAppear {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated { onDismiss() }
                return nil
            }
        }
        .onDisappear {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add to menu bar")
    }

    private func row(_ choice: AddItemChoice) -> some View {
        let isDisabled = unavailable.contains(choice)

        return ChoiceRow(
            symbolName: choice.symbolName,
            title: choice.title,
            detail: isDisabled ? AddItemChoice.alreadyAddedDetail : choice.detail,
            isTaken: isDisabled,
            // A disabled row must not highlight on hover: an accent-filled row that does nothing
            // when clicked reads as a bug rather than as a limit.
            isHighlighted: hovered == choice && !isDisabled,
            action: { onChoose(choice) }
        )
        .help(isDisabled ? "\(choice.title.dropFirst(4)) can only be added once." : "")
        .onHover { isInside in
            hovered = isInside ? choice : (hovered == choice ? nil : hovered)
        }
    }
}

// MARK: - Shared row

/// One row of a MenuDock-drawn popup: symbol, title, a line of detail, and a tick on anything
/// already taken.
///
/// Shared by ``AddItemPopup`` and ``MetricPicker`` rather than written twice, because the two are
/// meant to be the same control applied to different lists — a user who has learned that a ticked,
/// dimmed row means "you already have one" has learned it for both. Two copies would keep that
/// promise only until one of them was next edited.
struct ChoiceRow: View {
    let symbolName: String
    let title: String
    let detail: String
    /// Dims the row and adds a checkmark. Also disables it — a taken choice is shown rather than
    /// hidden, so the list does not change shape between openings.
    let isTaken: Bool
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 12.5))
                    .frame(width: 19)
                    .foregroundStyle(isHighlighted ? .white : .secondary)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isHighlighted ? .white.opacity(0.75) : .secondary)
                }

                Spacer(minLength: 0)

                if isTaken {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isHighlighted ? .white : .primary)
            .opacity(isTaken ? 0.45 : 1)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isTaken)
    }
}
