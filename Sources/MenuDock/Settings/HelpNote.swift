import SwiftUI

/// A `?` that reveals an explanation on click.
///
/// ## Why the prose moved behind a button
///
/// Several settings here genuinely need a paragraph to explain — what the auto-hide rule does,
/// why a hotkey behaves like ⌘-Tab, where the clipboard is stored. Printed inline, those
/// paragraphs were the *majority* of every pane: a grey wall between one control and the next
/// that a returning user reads exactly never, and that pushes the control they came for below
/// the fold.
///
/// A `?` inverts that cost. The explanation is one click away the first time and invisible every
/// time after, so the pane is a list of controls again — which is what a settings window is
/// supposed to look like.
///
/// It is deliberately **not** a tooltip. `.help()` needs a hover the user has no reason to try,
/// gives no affordance that anything is there, and cannot be reached from the keyboard. A button
/// says "there is more here" just by existing.
///
/// ## What stays visible
///
/// Only static explanation belongs in here. Anything that reports *state* — a permission that is
/// missing, a warning that nothing is being recorded, the figures behind an auto-hide decision —
/// stays on the pane, because a user cannot click a button they have no reason to suspect is
/// relevant.
struct HelpNote: View {
    private let text: String

    @State private var isShowing = false
    @State private var isHovering = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(isShowing || isHovering ? AnyShapeStyle(.primary)
                                                         : AnyShapeStyle(.tertiary))
                // A hit area larger than the glyph: 12.5pt of circle is a small target, and the
                // padding costs nothing because the layout frame stays the glyph's own size.
                .contentShape(.rect.inset(by: -5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("More information")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(width: 270, alignment: .leading)
                .padding(14)
        }
    }
}

/// A section heading with a `?` beside it.
///
/// The `Form`-shaped counterpart to ``SectionBox``'s `help:` parameter. A `Form` row lays its
/// control out edge to edge — label left, switch hard right — and wrapping one in ``HelpRow``
/// collapses that to hug its text, so the switch stops lining up with every other switch on the
/// pane. Attaching the explanation to the section heading instead leaves the rows alone.
struct HelpLabel: View {
    private let title: String
    private let help: String

    init(_ title: String, help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            HelpNote(help)
        }
    }
}

/// A control with a `?` beside it, aligned as one row.
///
/// `.fixedSize()` on the content is what keeps the two together: without it the control is handed
/// the pane's full width and the `?` lands somewhere off to the right, disowned by the thing it
/// explains. That is also why this is wrong inside a `Form` — see ``HelpLabel``.
struct HelpRow<Content: View>: View {
    private let help: String
    private let content: Content

    init(_ help: String, @ViewBuilder content: () -> Content) {
        self.help = help
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            content
                .fixedSize()
            HelpNote(help)
        }
    }
}
