import SwiftUI

/// The list of metrics an Activity item can show, presented all at once.
///
/// ## Why this replaced a walk through the list
///
/// The + button used to add "the first metric not already shown" and leave the user to change it
/// with a popup in the row. That is a reasonable thing to build and a poor thing to use: adding
/// GPU meant pressing + to get Power, opening a popup, and finding GPU in it — and the *set* of
/// what was available was never visible anywhere. A user who did not already know MenuDock could
/// show disk write had no way to find out except by cycling through until it appeared.
///
/// Showing every metric at once fixes the discovery problem outright, and it is the only
/// presentation where "what can this thing measure?" has an answer you can read. The rows carry a
/// symbol and a line of description for the same reason: "Power" is not self-explanatory, and the
/// difference between "Memory" and "Disk Free" is worth one sentence each.
///
/// Deliberately the same shape as ``AddItemPopup`` — material card, symbol, title, detail line,
/// accent-filled hover, a check on what is already taken. Two menus that do the same job in the
/// same app should not be two things to learn.
struct MetricPicker: View {
    /// Metrics already in this item. Shown but not choosable — hiding them would make the menu
    /// change shape between openings and leave a user wondering where CPU went.
    var used: Set<ActivityMetric>
    var onChoose: (ActivityMetric) -> Void

    @State private var hovered: ActivityMetric?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(ActivityMetric.allCases) { metric in
                row(metric)
            }
        }
        .padding(6)
        .frame(width: 292)
    }

    private func row(_ metric: ActivityMetric) -> some View {
        let isUsed = used.contains(metric)

        return ChoiceRow(
            symbolName: metric.symbolName,
            title: metric.displayName,
            detail: isUsed ? "Already shown" : metric.summary,
            isTaken: isUsed,
            // A disabled row must not highlight: an accent-filled row that does nothing on click
            // reads as a bug rather than as a limit.
            isHighlighted: hovered == metric && !isUsed,
            action: { onChoose(metric) }
        )
        .onHover { isInside in
            hovered = isInside ? metric : (hovered == metric ? nil : hovered)
        }
    }
}
