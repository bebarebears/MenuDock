import SwiftUI

/// Browsable grid of the 48 built-in icons.
///
/// Animated icons **preview live in the grid**. A still frame of "Breathe" and a still frame of
/// "Pulse" look nearly identical, so a static gallery would force the user to pick blind, apply,
/// look at the menu bar, and come back. `TimelineView` drives the previews from the same phase
/// function the status items use, so what animates here is exactly what animates up there.
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

    private func section(_ category: BuiltinIcon.Category, _ icons: [BuiltinIcon]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(category.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(icons) { icon in
                    IconGalleryCell(
                        icon: icon,
                        isSelected: spec.builtinID == icon.id,
                        isAnimating: environment.animator.isAnimating
                    ) {
                        spec = .builtin(id: icon.id)
                        environment.icons.invalidateCache()
                    }
                }
            }
        }
    }
}

/// One tappable icon in the gallery.
private struct IconGalleryCell: View {
    let icon: BuiltinIcon
    let isSelected: Bool
    let isAnimating: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.09))

                if icon.isAnimated && isAnimating {
                    // Redraws only while this gallery is on screen, and only for animated cells.
                    TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
                        glyph(phase: BuiltinIconCatalog.phase(
                            for: icon,
                            at: context.date.timeIntervalSinceReferenceDate
                        ))
                    }
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
        Image(nsImage: BuiltinIconCatalog.image(icon: icon, size: 20, phase: phase))
            .renderingMode(.template)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}
