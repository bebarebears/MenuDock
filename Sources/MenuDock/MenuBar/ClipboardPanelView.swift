import AppKit
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

    /// Index into ``results``. Every write goes through the methods below, which is what keeps it
    /// in bounds and keeps ``selectedID`` in agreement with it.
    private(set) var selection: Int = 0

    /// The item ``selection`` currently points at.
    ///
    /// Held so a history that changes underneath the panel keeps the selection on the same *item*
    /// rather than the same row number. A capture landing while the panel is open inserts at the
    /// top and pushes every row down one, so an index alone would quietly come to mean a different
    /// item — and Return would paste something the user had never pointed at.
    private(set) var selectedID: ClipboardItem.ID?

    /// Bumped whenever the selection moves for a reason the list should scroll to follow.
    ///
    /// The list scrolls in response to *this*, never to ``selection`` on its own — which is the
    /// whole of the fix for a list that used to creep under a cursor that was not moving. See
    /// ``hover(over:)``.
    private(set) var scrollTick: Int = 0

    /// True while the recall shortcut's modifiers are still held. The view uses it to explain
    /// what releasing them will do, which is the only way that gesture is discoverable.
    var isCycling: Bool = false

    /// Bumped once per presentation, so the view can put the keyboard back in the search field.
    ///
    /// The panel is built once and reused — ordered out and back in — so `onAppear` fires exactly
    /// once in the life of the app. Focusing the search field there meant it was focused the first
    /// time the panel was ever opened and never again: every open after that landed on a window
    /// whose first responder was whatever had been left behind, and typing went nowhere. Which is
    /// how a search field can look completely fine and simply not work.
    private(set) var presentation: Int = 0

    /// Where the pointer was when it last selected a row, so hovers that arrive because the *list*
    /// moved can be told apart from hovers the user meant. See ``hover(over:)``.
    private var lastHoverLocation: NSPoint = .zero

    var onChoose: (ClipboardItem) -> Void = { _ in }
    var onDelete: (ClipboardItem) -> Void = { _ in }
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

    // MARK: - Moving the selection

    /// Resets everything a fresh presentation should start from.
    ///
    /// The pointer's position is recorded here as well, and that is deliberate: the panel drops out
    /// of the menu bar, often straight under a cursor that has not moved a pixel. Treating that
    /// as a hover would hand row three to a user who pressed a shortcut expecting row one.
    func prepare(title: String, cycling: Bool) {
        self.title = title
        query = ""
        isCycling = cycling
        lastHoverLocation = NSEvent.mouseLocation
        select(0, scroll: true)
        presentation &+= 1
    }

    /// Moves the selection, wrapping at both ends.
    ///
    /// Wrapping matters for the hold-to-cycle gesture specifically: the user is tapping V without
    /// looking at a counter, and a selection that silently sticks at the bottom means the taps
    /// stop doing anything with no indication why.
    func move(by offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        select(((selection + offset) % count + count) % count, scroll: true)
    }

    /// Selects a row the pointer has moved onto.
    ///
    /// Guarded on the pointer having *actually moved*, because SwiftUI fires `onHover` whenever a
    /// row arrives under the cursor — and rows arrive under a perfectly still cursor all the time:
    /// while the wheel scrolls, while the arrow keys scroll, while typing re-filters the list.
    /// Left ungated it meant a cursor resting anywhere over the list silently overruled the
    /// keyboard, so arrowing down scrolled the list and the selection immediately snapped back to
    /// whatever row had slid under the mouse.
    ///
    /// It is ignored outright during a cycle. A hold-to-cycle gesture is the keyboard's, and where
    /// the user happens to have left the pointer is not a vote.
    func hover(over index: Int) {
        guard !isCycling else { return }
        let location = NSEvent.mouseLocation
        guard location != lastHoverLocation else { return }
        lastHoverLocation = location
        guard results.indices.contains(index) else { return }
        // Deliberately does not scroll. Hovering to select and selecting to scroll formed a loop
        // with the mouse inside it — the hovered row was centred, centring slid a *different* row
        // under the stationary cursor, that row selected itself, and the list crawled on its own
        // until it hit an end. Now the wheel and the scrollbar are the only things a mouse can
        // scroll this list with.
        select(index, scroll: false)
    }

    /// A new query means a new list, and the top match is what it should land on.
    ///
    /// Clamping the old index instead — which is what this used to do — left a user who typed a
    /// search with the selection on the *last* match, or on whatever row the clamp happened to
    /// produce, so the obvious follow-up of typing a few letters and pressing Return pasted the
    /// wrong thing.
    func queryChanged() {
        select(0, scroll: true)
    }

    /// Re-finds the selected item after the history itself has changed.
    func itemsChanged() {
        let results = results
        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) {
            select(index, scroll: false)
        } else {
            select(min(selection, max(results.count - 1, 0)), scroll: false)
        }
    }

    /// The single place ``selection`` is written.
    private func select(_ index: Int, scroll: Bool) {
        let results = results
        let clamped = results.isEmpty ? 0 : min(max(index, 0), results.count - 1)
        selection = clamped
        selectedID = results.indices.contains(clamped) ? results[clamped].id : nil
        if scroll { scrollTick &+= 1 }
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
    /// Height of the hint strip shown *only* during a hold-to-cycle. See ``hintBar``.
    static let hintBarHeight: CGFloat = 26
    /// Most rows shown before the list starts scrolling.
    static let maximumVisibleRows = 7

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().opacity(0.6)
            content
            if model.isCycling {
                Divider().opacity(0.6)
                hintBar
            }
        }
        .background(.clear)
        .onAppear { isSearchFocused = true }
        // And again on every open after the first — see ``ClipboardPanelModel/presentation``.
        .onChange(of: model.presentation) { _, _ in isSearchFocused = true }
        .onChange(of: model.query) { _, _ in
            model.queryChanged()
            model.onLayoutChange()
        }
        .onChange(of: model.history.items.count) { _, _ in
            model.itemsChanged()
            model.onLayoutChange()
        }
        .onChange(of: model.isCycling) { _, _ in
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
                // Keeps a *keyboard-moved* row on screen — an arrow key, a ⌘⇧V tap, a new search
                // landing on its top match. Driven from `scrollTick` rather than from `selection`
                // so that the one thing which must never scroll the list, the mouse passing over
                // it, cannot: see ``ClipboardPanelModel/hover(over:)``.
                .onChange(of: model.scrollTick) { _, _ in
                    guard let item = model.selectedItem else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        // No anchor, so this scrolls the minimum needed to bring the row into
                        // view. Centring every selection instead made a single arrow key shove
                        // the whole list half a panel, which reads as the list moving on its own.
                        proxy.scrollTo(item.id)
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

    // MARK: - Hints

    /// Shown only while the modifiers are down.
    ///
    /// There used to be a permanent strip here spelling out Return, ⌘⌫ and Escape next to a running
    /// item count. It was noise: those are the three keys every list on the platform already uses,
    /// the count answers a question nobody asked, and a dropdown meant to be read in a second spent
    /// a fifth of its height on a legend. The hold-to-cycle gesture is the one thing here that is
    /// genuinely unguessable — and the one moment it is worth saying is while the user is mid-hold.
    private var hintBar: some View {
        HStack(spacing: 10) {
            hint("tap V", "next")
            hint("release", "paste")
            // Listed beside them because releasing commits — without a stated way out, a user who
            // opened the list only to look has no idea how to *not* paste.
            hint("esc", "cancel")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.hintBarHeight)
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
            // row Return will paste — but only when the pointer is the thing that moved.
            if hovering { model.hover(over: index) }
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
