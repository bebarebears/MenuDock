import SwiftUI

/// What the + button can add.
enum AddItemChoice: String, CaseIterable, Identifiable {
    case app
    case folder
    case group
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: "Add App"
        case .folder: "Add Folder"
        case .group: "Add Group"
        case .activity: "Add Activity"
        }
    }

    var detail: String {
        switch self {
        case .app: "One click launches it"
        case .folder: "Opens in Finder"
        case .group: "Several apps, one icon"
        case .activity: "Live CPU, memory, network"
        }
    }

    var symbolName: String {
        switch self {
        case .app: "square.grid.2x2"
        case .folder: "folder"
        case .group: "rectangle.stack"
        case .activity: "waveform.path.ecg"
        }
    }
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
        Button {
            onChoose(choice)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: choice.symbolName)
                    .font(.system(size: 12.5))
                    .frame(width: 18)
                    .foregroundStyle(hovered == choice ? .white : .secondary)

                VStack(alignment: .leading, spacing: 0) {
                    Text(choice.title)
                        .font(.system(size: 13))
                    Text(choice.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(hovered == choice ? .white.opacity(0.75) : .secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(hovered == choice ? .white : .primary)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovered == choice ? Color.accentColor : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            hovered = isInside ? choice : (hovered == choice ? nil : hovered)
        }
    }
}
