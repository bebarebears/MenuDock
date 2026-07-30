import SwiftUI

/// Browsable grid of the built-in icons.
///
/// Animated icons **preview live in the grid**. A still frame of "Breathe" and a still frame of
/// "Pulse" look nearly identical, so a static gallery would force the user to pick blind, apply,
/// look at the menu bar, and come back. `TimelineView` drives the previews from the same phase
/// function the status items use, so what animates here is exactly what animates up there.
///
/// ## One clock for the whole grid
///
/// Each animated cell used to own a `TimelineView` and render a fresh bitmap per tick. With a
/// couple of dozen animated glyphs in the catalogue that is dozens of timers and hundreds of
/// rasterisations a second — the settings window becoming more expensive than the menu bar it
/// configures. Now a single timeline wraps the grid and every cell reads a cached frame, so
/// opening this pane costs one timer and no drawing at all after the first loop.
struct IconGalleryView: View {
    let environment: AppEnvironment
    @Binding var spec: IconSpec

    @State private var query = ""
    @State private var category: BuiltinIcon.Category?

    /// Flexible rather than fixed columns so the grid fills the detail pane at any window
    /// width instead of leaving a ragged gap on the right.
    private let columns = [GridItem(.adaptive(minimum: 34, maximum: 34), spacing: 6, alignment: .leading)]

    private var results: [BuiltinIcon] {
        let matches = BuiltinIconCatalog.search(query)
        guard let category, query.isEmpty else { return matches }
        return matches.filter { $0.category == category }
    }

    private var groupedResults: [(BuiltinIcon.Category, [BuiltinIcon])] {
        BuiltinIcon.Category.allCases.compactMap { category in
            let icons = results.filter { $0.category == category }
            return icons.isEmpty ? nil : (category, icons)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterBar

            if results.isEmpty {
                Text("No icons match “\(query)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groupedResults, id: \.0) { category, icons in
                            section(category, icons)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 232)
            }

            if let reason = environment.animator.suppressionReason,
               results.contains(where: \.isAnimated) {
                Label(reason, systemImage: "pause.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pieces

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search icons", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)

            Picker("", selection: $category) {
                Text("All Categories").tag(BuiltinIcon.Category?.none)
                Divider()
                ForEach(BuiltinIcon.Category.allCases) { category in
                    Label(category.rawValue, systemImage: category.symbolName)
                        .tag(BuiltinIcon.Category?.some(category))
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .disabled(!query.isEmpty)
        }
    }

    @ViewBuilder
    private func section(_ category: BuiltinIcon.Category, _ icons: [BuiltinIcon]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            // Only the animated section is driven by a clock, and only one clock drives it. The
            // static sections are rebuilt on user input alone, as they should be.
            if category == .animated, environment.animator.isAnimating {
                TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
                    grid(icons, at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                grid(icons, at: nil)
            }
        }
    }

    private func grid(_ icons: [BuiltinIcon], at time: TimeInterval?) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(icons) { icon in
                IconGalleryCell(
                    icon: icon,
                    isSelected: spec.builtinID == icon.id,
                    time: time
                ) {
                    spec = .builtin(id: icon.id)
                    environment.icons.invalidateCache()
                }
            }
        }
    }
}

/// One tappable icon in the gallery.
private struct IconGalleryCell: View {
    let icon: BuiltinIcon
    let isSelected: Bool
    /// Clock reading to animate from, or `nil` to draw the rest frame.
    let time: TimeInterval?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.09))

                if icon.isAnimated, let time {
                    glyph(phase: BuiltinIconCatalog.phase(for: icon, at: time))
                } else {
                    glyph(phase: 0)
                }

                if icon.isAnimated {
                    // A corner pip distinguishes animated entries even when motion is
                    // suppressed by Reduce Motion.
                    Circle()
                        .fill(isSelected ? Color.white : Color.accentColor)
                        .frame(width: 4, height: 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                        .padding(3)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .help(icon.isAnimated ? "\(icon.name) (animated)" : icon.name)
        .accessibilityLabel(icon.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func glyph(phase: Double) -> some View {
        Image(nsImage: BuiltinIconCatalog.frame(
            icon: icon,
            size: 20,
            index: BuiltinIconCatalog.frameIndex(for: phase)
        ))
        .renderingMode(.template)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}
