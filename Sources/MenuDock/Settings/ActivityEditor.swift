import SwiftUI

/// Editor for an Activity item: what it measures, how each metric is drawn, and how often.
///
/// The preview at the top is not a mock-up. It calls the same
/// ``ActivityRenderer/image(for:readings:height:)`` the menu bar calls, with the same live
/// readings, at the same point size — so what the user is tuning is literally the thing that
/// ships to the bar. That matters more here than in the other editors: an Activity item is the
/// only kind whose width the user does not choose, and the only way to make automatic sizing
/// feel like a feature rather than a surprise is to show the width changing as gauges are added.
struct ActivityEditor: View {
    let environment: AppEnvironment
    @Binding var entry: ActivityEntry
    /// The item's height in the menu bar, so the preview matches the real thing rather than
    /// being drawn at some convenient size.
    let height: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionBox("Preview") {
                ActivityPreview(environment: environment, entry: entry, height: height)
            }

            SectionBox("Name") {
                TextField("Activity", text: $entry.name)
                    .textFieldStyle(.roundedBorder)
                Text("Shown in the tooltip and at the top of the item's menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SectionBox("Metrics") {
                GaugeList(entry: $entry)
            }

            SectionBox("Updates") {
                Picker("Refresh", selection: $entry.interval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text("""
                    Reading the system costs well under a millisecond, so every setting here is \
                    cheap. Sampling stops entirely when the menu bar is hidden, when the screen \
                    is locked or asleep, and the interval doubles in Low Power Mode.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview

private struct ActivityPreview: View {
    let environment: AppEnvironment
    let entry: ActivityEntry
    let height: Double

    var body: some View {
        // Reading `generation` is what subscribes this view to the sample clock: the monitor
        // bumps it once per completed sample and SwiftUI redraws from it. Nothing else here is
        // observable, which is deliberate — see ``MetricsMonitor``.
        let _ = environment.metrics.generation
        let image = ActivityRenderer.image(for: entry, readings: readings, height: height)

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                Image(nsImage: image)
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
            }
            .frame(height: max(height + 14, 34))
            .frame(maxWidth: .infinity)

            HStack(spacing: 6) {
                Text("\(Int(image.size.width.rounded())) × \(Int(height)) pt in the menu bar")
                if entry.gauges.isEmpty {
                    Text("· add a metric below")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var readings: [ActivityMetric: ActivityRenderer.Reading] {
        var result: [ActivityMetric: ActivityRenderer.Reading] = [:]
        for metric in entry.requiredMetrics {
            result[metric] = ActivityRenderer.Reading(
                current: environment.metrics.latest(for: metric),
                series: environment.metrics.series(for: metric)
            )
        }
        return result
    }
}

// MARK: - Gauge list

/// Mirrors ``GroupMemberList`` and the folder list deliberately: same list, same +/− footer, same
/// reorder gesture. A third arrangement of the same idea would be a third thing to learn.
private struct GaugeList: View {
    @Binding var entry: ActivityEntry

    @State private var selection: ActivityGauge.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach($entry.gauges) { $gauge in
                    row($gauge)
                        .tag(gauge.id)
                }
                .onMove { source, destination in
                    entry.gauges.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.bordered)
            .frame(height: 168)
            .overlay {
                if entry.gauges.isEmpty {
                    Text("No metrics yet — use +")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .help("Add a metric")

                Button {
                    entry.gauges.removeAll { $0.id == selection }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("Remove the selected metric")

                Spacer()

                Text("Gauges appear left to right in this order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ gauge: Binding<ActivityGauge>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: gauge.metric) {
                ForEach(ActivityMetric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Picker("", selection: gauge.style) {
                ForEach(GaugeStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .labelsHidden()
            .frame(width: 90)

            Picker("", selection: gauge.label) {
                ForEach(GaugeLabel.allCases) { label in
                    Text(label.displayName).tag(label)
                }
            }
            .labelsHidden()
            .frame(width: 80)
            .help("The caption drawn before this gauge")

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    /// Adds a gauge for a metric not already shown, so repeatedly pressing + walks through the
    /// metrics rather than stacking up CPU gauges the user has to re-pick every time.
    private func add() {
        let used = entry.requiredMetrics
        let metric = ActivityMetric.allCases.first { !used.contains($0) } ?? .cpu
        // A percentage has a fixed 0–100 range that a graph reads well against; a rate or a
        // wattage does not, and its actual figure is the useful part.
        let gauge = ActivityGauge(metric: metric,
                                  style: metric.unit == .percentage ? .graph : .number,
                                  label: .short)
        entry.gauges.append(gauge)
        selection = gauge.id
    }
}
