import SwiftUI

extension Optional where Wrapped == IconTint {
    /// How a template preview should be filled: the tint if there is one, and otherwise the
    /// `.primary` that stands in for whatever the menu bar would have used.
    ///
    /// Shared by the icon well and the Activity strip preview so the two cannot disagree about
    /// what "no tint" looks like. Lives here rather than on ``IconTint`` because nothing under
    /// `Model/` imports SwiftUI, and this is not the place to start.
    var previewStyle: AnyShapeStyle {
        map { AnyShapeStyle(Color(nsColor: $0.color)) } ?? AnyShapeStyle(.primary)
    }
}

/// The tint control shared by every item editor: a row of swatches, a custom colour, and a way
/// back to the default.
///
/// The palette comes first and the system colour well second, in that order on purpose. A free
/// colour picker offered as the primary control invites exactly the colours that do not work in a
/// menu bar — pure yellow, near-black, anything at the extremes of luminance — and the user only
/// finds out after looking up at the bar. The ten offered here are pre-checked against both
/// appearances (see ``IconTint/palette``), so the fast path is also the one that looks right.
struct TintPicker: View {
    @Binding var tint: IconTint?
    /// Shown under the swatches. Differs between an icon and an Activity strip, which is the one
    /// thing about this control that is not the same everywhere it appears.
    var note: String

    private let swatch: Double = 22

    /// Reads the current tint and writes a new one, with no `@State` mirror in between.
    ///
    /// The mirror is the obvious way to build this and it is subtly wrong: a `@State` colour
    /// seeded from the tint in `onAppear` counts as a *change*, which fires `onChange`, which
    /// writes the colour back — round-tripped through `NSColor` and sRGB conversion. The value
    /// that comes back is a few floating-point ulps from the palette entry it started as, so the
    /// item silently stops matching any swatch and the selection ring disappears the moment the
    /// pane is reopened. A computed binding has no initial write to go wrong.
    private var customColour: Binding<Color> {
        Binding(
            get: { tint.map { Color(nsColor: $0.color) } ?? .accentColor },
            set: { tint = IconTint(NSColor($0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                defaultSwatch

                Divider().frame(height: swatch - 4)

                ForEach(IconTint.palette) { named in
                    swatchButton(named)
                }

                Divider().frame(height: swatch - 4)

                ColorPicker("Custom colour", selection: customColour, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: swatch + 22)
                    .help("Choose any colour")
            }

            if !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The "no tint" option, drawn as the menu bar's own foreground colour rather than as an
    /// empty slot — because that is what it is, and an empty slot reads as "none of the above".
    private var defaultSwatch: some View {
        Button {
            tint = nil
        } label: {
            ZStack {
                Circle().fill(.primary)
                selectionRing(isSelected: tint == nil)
            }
            .frame(width: swatch, height: swatch)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Follow the menu bar")
        .accessibilityLabel("Default colour")
    }

    private func swatchButton(_ named: IconTint.Named) -> some View {
        Button {
            tint = named.tint
        } label: {
            ZStack {
                Circle().fill(Color(nsColor: named.tint.color))
                selectionRing(isSelected: tint == named.tint)
            }
            .frame(width: swatch, height: swatch)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(named.name)
        .accessibilityLabel(named.name)
    }

    /// A ring *outside* the swatch rather than a checkmark inside it: at 22pt a glyph on a
    /// saturated fill is unreadable, and half these colours are dark enough that a white tick
    /// disappears while the other half swallow a black one.
    @ViewBuilder
    private func selectionRing(isSelected: Bool) -> some View {
        if isSelected {
            Circle()
                .strokeBorder(.primary, lineWidth: 1.5)
                .padding(-3)
        }
    }
}
