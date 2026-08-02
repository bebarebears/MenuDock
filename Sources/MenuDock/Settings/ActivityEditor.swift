import SwiftUI

/// Editor for an Activity item: what it measures, how each metric is drawn, and how often.
///
/// The preview at the top is not a mock-up. It calls the same
/// ``ActivityRenderer/image(for:readings:height:tint:appearance:)`` the menu bar calls, with the
/// same live readings, at the same point size — so what the user is tuning is literally the thing
/// that ships to the bar. That matters more here than in the other editors: an Activity item is
/// the only kind whose width the user does not choose, and the only way to make automatic sizing
/// feel like a feature rather than a surprise is to show the width changing as gauges are added.
struct ActivityEditor: View {
    let environment: AppEnvironment
    @Binding var entry: ActivityEntry
    /// The item's colour, for the preview and for the tint control. Lives on the item rather than
    /// on the entry — see ``DockItem/tint``.
    @Binding var tint: IconTint?
    /// The item's height in the menu bar, so the preview matches the real thing rather than
    /// being drawn at some convenient size.
    let height: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionBox("Preview") {
                ActivityPreview(environment: environment, entry: entry, tint: tint, height: height)
            }

            SectionBox("Name", help: "Shown in the tooltip and at the top of the item's menu.") {
                TextField("Activity", text: $entry.name)
                    .textFieldStyle(.roundedBorder)
            }

            SectionBox("Metrics") {
                GaugeList(entry: $entry)
            }

            SectionBox(
                "Colour",
                help: """
                    Applies to every gauge set to “Menu bar”. Gauges set to “By load” pick their \
                    own colour from the reading instead.
                    """
            ) {
                TintPicker(tint: $tint)
            }

            SectionBox("Menu") {
                HelpRow("""
                    Shown when you click the item, so you can see what is using the CPU without \
                    opening Activity Monitor. Reading it costs one system call per running \
                    process, so unlike everything else here it is measured only while the menu \
                    is open — never in the background.
                    """) {
                    Toggle("List the busiest processes", isOn: $entry.showsTopProcesses)
                }
            }

            SectionBox(
                "Updates",
                help: """
                    Every interval here is cheap — a reading costs well under a millisecond. \
                    Sampling stops entirely when the menu bar is hidden or the screen is locked, \
                    and the interval doubles in Low Power Mode.
                    """
            ) {
                Picker("Refresh", selection: $entry.interval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
    }
}

// MARK: - Preview

private struct ActivityPreview: View {
    let environment: AppEnvironment
    let entry: ActivityEntry
    let tint: IconTint?
    let height: Double

    var body: some View {
        // Reading `generation` is what subscribes this view to the sample clock: the monitor
        // bumps it once per completed sample and SwiftUI redraws from it. Nothing else here is
        // observable, which is deliberate — see ``MetricsMonitor``.
        let _ = environment.metrics.generation
        let image = ActivityRenderer.image(for: entry, readings: readings, height: height,
                                           tint: tint)

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                strip(image)
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

    /// A strip carrying a coloured gauge is not a template, so it must be shown as-is; one that
    /// is still a template gets tinted here exactly as ``GlyphLayer`` tints it in the menu bar.
    @ViewBuilder
    private func strip(_ image: NSImage) -> some View {
        if image.isTemplate {
            Image(nsImage: image)
                .renderingMode(.template)
                .foregroundStyle(tint.previewStyle)
        } else {
            Image(nsImage: image)
                .renderingMode(.original)
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

/// The metric list, and the controls for whichever one is selected.
///
/// ## Why the controls are below the list rather than in the row
///
/// A gauge carries four settings, and an earlier version put all four in the row as popups. It
/// fitted, barely, and it read as a spreadsheet: four unlabelled controls repeated down the page,
/// none of them wide enough to say what it was for. Selecting a row and editing it underneath
/// gives each control a label and room to explain itself — the colour section in particular has a
/// sentence to say about thresholds that could never have gone in a row — and it matches the
/// shape of the window it sits in, where the sidebar selects and the pane edits.
///
/// The list keeps the +/− footer and the drag-to-reorder of the folder and group lists, because
/// those parts genuinely are the same gesture.
private struct GaugeList: View {
    @Binding var entry: ActivityEntry

    @State private var selection: ActivityGauge.ID?
    @State private var isShowingMetricPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach($entry.gauges) { $gauge in
                    row(gauge)
                        .tag(gauge.id)
                }
                .onMove { source, destination in
                    entry.gauges.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.bordered)
            .frame(height: 132)
            .overlay {
                if entry.gauges.isEmpty {
                    Text("No metrics yet — use +")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Button {
                    isShowingMetricPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a metric")
                .popover(isPresented: $isShowingMetricPicker, arrowEdge: .bottom) {
                    MetricPicker(used: entry.requiredMetrics) { metric in
                        isShowingMetricPicker = false
                        add(metric)
                    }
                }

                Button {
                    entry.gauges.removeAll { $0.id == selection }
                    selection = entry.gauges.first?.id
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

            if let index = selectedIndex {
                Divider().padding(.vertical, 2)
                GaugeInspector(gauge: $entry.gauges[index])
            }
        }
        // Landing on an empty inspector when there is something to edit is a wasted click.
        .onAppear {
            if selection == nil { selection = entry.gauges.first?.id }
        }
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return entry.gauges.firstIndex { $0.id == selection }
    }

    /// One row: what it measures, and a one-line summary of how. The summary is what makes the
    /// list readable at a glance — without it, five rows of metric names say nothing about which
    /// is the graph and which the number.
    private func row(_ gauge: ActivityGauge) -> some View {
        HStack(spacing: 9) {
            Image(systemName: gauge.metric.symbolName)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(gauge.metric.displayName)
                .lineLimit(1)

            Spacer(minLength: 8)

            if gauge.coloring == .byLoad {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(Color(nsColor: GaugeSeverity.low.color))
                    .help("Coloured by load")
            }

            Text(summary(gauge))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }

    private func summary(_ gauge: ActivityGauge) -> String {
        var parts = [gauge.style.displayName]
        if let caption = gauge.label.text(for: gauge.metric) { parts.append("“\(caption)”") }
        return parts.joined(separator: " · ")
    }

    /// Adds a gauge for the chosen metric, in the style that metric reads best as.
    private func add(_ metric: ActivityMetric) {
        let gauge = ActivityGauge(metric: metric,
                                  style: ActivityGauge.defaultStyle(for: metric),
                                  label: .short)
        entry.gauges.append(gauge)
        selection = gauge.id
    }
}

// MARK: - Gauge inspector

/// Style, caption and colour for one gauge.
private struct GaugeInspector: View {
    @Binding var gauge: ActivityGauge

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Draw as") {
                Picker("", selection: $gauge.style) {
                    ForEach(GaugeStyle.allCases) { style in
                        Label(style.displayName, systemImage: style.symbolName)
                            .labelStyle(.iconOnly)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 172)
                .help("Graph, bar, ring or number")
            }

            LabeledContent("Caption") {
                Picker("", selection: $gauge.label) {
                    ForEach(GaugeLabel.allCases) { label in
                        Text(label.displayName).tag(label)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 172)
                .help("The text drawn before this gauge")
            }

            LabeledContent("Colour") {
                Picker("", selection: $gauge.coloring) {
                    ForEach(GaugeColoring.allCases) { coloring in
                        Text(coloring.displayName).tag(coloring)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 172)
            }

            colourNote
        }
        .padding(.leading, 2)
    }

    /// Says what the setting will actually do, in the metric's own units.
    ///
    /// Worth the space because the thresholds are per metric and there is no other way to find
    /// them out: 50% is where CPU turns amber and 20% is where battery does, and a user cannot be
    /// expected to infer either. See ``ActivityMetric/thresholds``.
    @ViewBuilder
    private var colourNote: some View {
        switch gauge.coloring {
        case .monochrome:
            Label(GaugeColoring.monochrome.summary, systemImage: "circle.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .byLoad:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(GaugeSeverity.allCases, id: \.self) { severity in
                        Circle()
                            .fill(Color(nsColor: severity.color))
                            .frame(width: 8, height: 8)
                            .help(severity.displayName)
                    }
                }
                Text(gauge.metric.thresholdSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
