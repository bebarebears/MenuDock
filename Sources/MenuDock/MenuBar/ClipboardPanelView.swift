import SwiftUI

/// State shared between the panel's AppKit shell and its SwiftUI contents.
///
/// The shell owns keyboard handling — it has to, because ⌘⇧V cycling has to work while a text
/// field holds focus — and the view owns presentation. This is the seam: the shell moves
/// ``selection`` and the view scrolls to it, the view edits ``query`` and the shell re-measures.
@MainActor
@Observable
final class ClipboardPanelModel {
    let history: ClipboardHistoryStore

    var title: String = "Clipboard"
    var query: String = ""

    /// Index into ``results``. Kept valid by every mutation here, so no view has to bounds-check.
    var selection: Int = 0

    /// True while the recall shortcut's modifiers are still held. The view uses it to explain
    /// what releasing them will do, which is the only way that gesture is discoverable.
    var isCycling: Bool = false

    var onChoose: (ClipboardItem) -> Void = { _ in }
    var onDelete: (ClipboardItem) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Fired when the number of visible rows changes, so the panel can resize to fit them.
    var onLayoutChange: () -> Void = {}

    init(history: ClipboardHistoryStore) {
        self.history = history
    }

    /// The rows currently on show.
    ///
    /// Matching runs over the stored preview rather than the full payload: the preview is already
    /// whitespace-collapsed and capped, so filtering a thousand-item history is a thousand short
    /// string searches instead of a thousand file reads.
    var results: [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history.items }
        return history.items.filter {
            $0.preview.localizedCaseInsensitiveContains(trimmed)
                || $0.sourceAppName?.localizedCaseInsensitiveContains(trimmed) == true
        }
    }

    var selectedItem: ClipboardItem? {
        let results = results
        guard results.indices.contains(selection) else { return nil }
        return results[selection]
    }

    /// Moves the selection, wrapping at both ends.
    ///
    /// Wrapping matters for the hold-to-cycle gesture specifically: the user is tapping V without
    /// looking at a counter, and a selection that silently sticks at the bottom means the taps
    /// stop doing anything with no indication why.
    func move(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = ((selection + offset) % count + count) % count
    }

    func clampSelection() {
        let count = results.count
        guard count > 0 else {
            selection = 0
            return
        }
        selection = min(max(selection, 0), count - 1)
    }
}

/// The dropdown itself.
///
/// Sized and positioned by ``ClipboardPanelController``; everything here assumes it is being
/// drawn inside a borderless panel with a vibrant backdrop already in place.
struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel

    @FocusState private var isSearchFocused: Bool

    static let rowHeight: CGFloat = 52
    static let searchHeight: CGFloat = 40
    static let footerHeight: CGFloat = 26
    /// Most rows shown before the list starts scrolling.
    static let maximumVisibleRows = 7

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.6)
            content
            Divider().opacity(0.6)
            footer
        }
        .background(.clear)
        .onAppear { isSearchFocused = true }
        .onChange(of: model.query) { _, _ in
            model.clampSelection()
            model.onLayoutChange()
        }
        .onChange(of: model.history.items.count) { _, _ in
            model.clampSelection()
            model.onLayoutChange()
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Search \(model.title.lowercased())", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.searchHeight)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        let results = model.results
        if results.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            ClipboardRow(
                                model: model,
                                item: item,
                                index: index,
                                isSelected: index == model.selection
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                }
                // Keeps the cycled-to row on screen. Driven from `selection` rather than from the
                // keystroke, so it works the same whether the selection moved by arrow key, by a
                // ⌘⇧V tap, or because the list was re-filtered underneath it.
                .onChange(of: model.selection) { _, _ in
                    guard let item = model.selectedItem else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: model.history.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(model.history.items.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.history.items.isEmpty {
                Text("Copy something and it will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 22)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isCycling {
                // Shown only while the modifiers are down, because this is the one moment the
                // instruction is both relevant and impossible to guess. Escape is listed beside
                // them because releasing now commits — without a stated way out, a user who
                // opened the list only to look has no idea how to not paste.
                hint("tap V", "next")
                hint("release", "paste")
                hint("esc", "cancel")
            } else {
                hint("↩", "paste")
                hint("⌘⌫", "delete")
                hint("esc", "close")
            }
            Spacer(minLength: 0)
            Text(countLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
    }

    private var countLabel: String {
        let shown = model.results.count
        let total = model.history.items.count
        if shown == total { return total == 1 ? "1 item" : "\(total) items" }
        return "\(shown) of \(total)"
    }

    private func hint(_ key: String, _ meaning: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(meaning)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Row

private struct ClipboardRow: View {
    let model: ClipboardPanelModel
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            model.onChoose(item)
        } label: {
            HStack(spacing: 9) {
                thumbnail

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.preview.isEmpty ? item.typeDescription : item.preview)
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text(subtitle)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                }

                Spacer(minLength: 4)

                // The first nine rows advertise their own shortcut. A row that tells you how to
                // reach it without the arrow keys is worth more than a tidier layout.
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(.white.opacity(0.7))
                                         : AnyShapeStyle(.tertiary))
                        .opacity(isSelected || isHovered ? 1 : 0)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: ClipboardPanelView.rowHeight - 2)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Color.accentColor)
                          : AnyShapeStyle(isHovered ? Color.primary.opacity(0.07) : Color.clear))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            // Hover moves the selection, so the keyboard and the mouse never disagree about which
            // row Return will paste.
            if hovering { model.selection = index }
        }
        .contextMenu {
            Button("Paste") { model.onChoose(item) }
            Divider()
            Button("Delete", role: .destructive) { model.onDelete(item) }
        }
        .accessibilityLabel(item.preview.isEmpty ? item.typeDescription : item.preview)
        .accessibilityValue(subtitle)
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.white.opacity(0.18))
                                 : AnyShapeStyle(.quaternary))

            if let image = model.history.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(1.5)
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
        }
        .frame(width: 32, height: 32)
    }

    private var subtitle: String {
        var parts = [item.typeDescription]
        if let source = item.sourceAppName, !source.isEmpty { parts.append(source) }
        parts.append(Self.age(of: item.capturedAt))
        return parts.joined(separator: " · ")
    }

    /// Compact age, written by hand rather than with `RelativeFormatStyle`.
    ///
    /// The system style produces "2 minutes ago", which at this font size wraps the subtitle onto
    /// a line that does not exist — and its output width changes with every unit boundary, so the
    /// row's layout would shift as history aged.
    private static func age(of date: Date) -> String {
        let seconds = max(Date().timeIntervalSince(date), 0)
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
