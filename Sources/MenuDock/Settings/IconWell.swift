import SwiftUI
import UniformTypeIdentifiers

/// Where a menu bar icon's artwork comes from.
///
/// File-scope rather than nested in ``IconEditor`` purely for readability — see the note at
/// the `Picker` in `sourcePicker` for the Swift 6.3 IRGen crash this type was caught up in,
/// and its actual cause.
enum IconSourceKind: String, CaseIterable, Identifiable {
    case builtin = "Built-in"
    case appIcon = "App Icon"
    case custom = "Custom"
    var id: String { rawValue }
}

/// The complete icon editor: live preview, source selector, and whichever picker that source
/// needs.
///
/// The preview well doubles as the drop target for custom artwork, so the two most common
/// gestures — "pick one of yours" and "drop in one of mine" — are the same control.
struct IconEditor: View {
    let environment: AppEnvironment
    @Binding var spec: IconSpec
    /// This item's size override, or `nil` while it follows the global preference.
    @Binding var size: Double?
    /// `nil` for groups and folders, which have no single application to borrow an icon from.
    let app: AppReference?
    /// Which built-in glyph to fall back to when the user switches to the built-in source.
    let defaultBuiltinID: String

    init(
        environment: AppEnvironment,
        spec: Binding<IconSpec>,
        size: Binding<Double?>,
        app: AppReference?,
        defaultBuiltinID: String = "globe"
    ) {
        self.environment = environment
        self._spec = spec
        self._size = size
        self.app = app
        self.defaultBuiltinID = defaultBuiltinID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                IconWell(environment: environment, spec: $spec, app: app)
                VStack(alignment: .leading, spacing: 8) {
                    sourcePicker
                    IconSourceNote(environment: environment, spec: spec, app: app)
                }
                Spacer(minLength: 0)
            }

            switch source {
            case .builtin:
                IconGalleryView(environment: environment, spec: $spec)
            case .custom:
                customControls
            case .appIcon:
                EmptyView()
            }

            // Size applies to every source, not just custom artwork: a built-in glyph or an
            // app's own icon is just as likely to want to sit a point or two larger than its
            // neighbours, and the whole appeal of a per-item knob is that it works everywhere.
            Divider().padding(.vertical, 2)
            sizeControls
        }
    }

    // MARK: - Source

    private var source: IconSourceKind {
        switch spec {
        case .appIcon: .appIcon
        case .custom: .custom
        // `.symbol` is the legacy SF Symbol case, kept for configs written before the built-in
        // catalogue existed. It groups with the built-ins so those users still land somewhere
        // sensible instead of on an empty pane.
        case .builtin, .symbol: .builtin
        }
    }

    private var availableSources: [IconSourceKind] {
        app == nil ? [.builtin, .custom] : IconSourceKind.allCases
    }

    /// Groups and folders lose the "App Icon" segment, so their picker is narrower.
    private var sourcePickerWidth: Double {
        app == nil ? 190 : 260
    }

    private var sourcePicker: some View {
        // `set: { apply($0) }` rather than `set: apply`: passing the method reference directly
        // makes the compiler synthesise a reabstraction thunk carrying the binding's implicit
        // isolated-actor parameter, which crashes IRGen in Swift 6.3 under
        // `SWIFT_APPROACHABLE_CONCURRENCY`. Wrapping it in a closure emits normally.
        Picker("", selection: Binding(get: { source }, set: { apply($0) })) {
            ForEach(availableSources) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: sourcePickerWidth)
    }

    /// Switching source picks a sensible default rather than clearing the icon, so the preview
    /// never goes blank mid-edit.
    private func apply(_ newSource: IconSourceKind) {
        guard newSource != source else { return }
        switch newSource {
        case .appIcon:
            spec = .appIcon
        case .builtin:
            spec = .builtin(id: defaultBuiltinID)
        case .custom:
            // Nothing to select yet — the well becomes the call to action.
            spec = .custom(fileName: "", rendering: .auto, pointSize: nil)
        }
        environment.icons.invalidateCache()
    }

    // MARK: - Custom artwork

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Choose Image…", action: chooseImage)
                if spec.customFileName?.isEmpty == false {
                    Button("Remove") {
                        spec = app == nil ? .builtin(id: defaultBuiltinID) : .appIcon
                        environment.icons.invalidateCache()
                    }
                }
                Text("or drop an SVG / PNG on the well")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .custom(let fileName, let rendering, _) = spec, !fileName.isEmpty {
                Picker("Appearance", selection: Binding(
                    get: { rendering },
                    set: { spec = .custom(fileName: fileName, rendering: $0, pointSize: nil)
                           environment.icons.invalidateCache() }
                )) {
                    ForEach(IconSpec.RenderingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 2)
            }
        }
    }

    // MARK: - Per-item size

    private var defaultSize: Double {
        environment.store.configuration.preferences.iconSize
    }

    /// A size slider for this item alone, plus a preview at the size it actually claims.
    ///
    /// The preview is not decoration. A size control with no true-size readout is unusable —
    /// judging 16pt against 19pt from an 88pt well is impossible, so without it the only way
    /// to evaluate a change is to look up at the menu bar and back down again. Two real system
    /// items sit alongside for scale.
    private var sizeControls: some View {
        let effective = size ?? defaultSize

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Size")
                Slider(
                    value: Binding(
                        get: { effective },
                        set: {
                            size = $0.rounded()
                            environment.icons.invalidateCache(includingAnimationFrames: true)
                        }
                    ),
                    in: IconRenderer.minimumIconSize...IconRenderer.maximumIconSize,
                    step: 1
                )
                .frame(width: 170)

                Text(size == nil ? "\(Int(effective)) pt (default)" : "\(Int(effective)) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)

                if size != nil {
                    Button("Use Default") {
                        size = nil
                        environment.icons.invalidateCache(includingAnimationFrames: true)
                    }
                    .controlSize(.small)
                }
            }

            actualSizePreview(effective)
        }
    }

    private func actualSizePreview(_ effective: Double) -> some View {
        HStack(spacing: 4) {
            Text("Actual size")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)

            Image(nsImage: environment.icons.image(for: spec, app: app, size: effective))
            ForEach(["wifi", "battery.75percent"], id: \.self) { name in
                Image(systemName: name)
                    .font(.system(size: defaultSize * 0.72))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NSStatusBar.system.thickness)
        .background(.bar, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = IconLibrary.acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url,
              let fileName = environment.icons.importImage(from: url) else { return }
        spec = .custom(fileName: fileName, rendering: .auto, pointSize: nil)
        environment.icons.invalidateCache()
    }
}

// MARK: - Preview well

/// Shows the icon exactly as the menu bar will render it, and accepts dropped artwork.
struct IconWell: View {
    let environment: AppEnvironment
    @Binding var spec: IconSpec
    let app: AppReference?

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.4))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1,
                                       dash: isTargeted ? [] : [4, 3])
                )
            preview
        }
        .frame(width: 88, height: 88)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { isTargeted = $0 }
        .accessibilityLabel("Icon preview. Drop an image here to replace it.")
    }

    /// Animated built-ins preview in motion here too — this well is often the only thing on
    /// screen when the user is deciding, and a frozen frame tells them nothing.
    @ViewBuilder
    private var preview: some View {
        if let icon = environment.icons.builtinIcon(for: spec),
           icon.isAnimated, environment.animator.isAnimating {
            TimelineView(.periodic(from: .now, by: 1.0 / 12.0)) { context in
                // Frames come from the shared cache, so this well costs a lookup per tick
                // rather than rasterising a fresh 48pt bitmap twelve times a second.
                Image(nsImage: BuiltinIconCatalog.frame(
                    icon: icon,
                    size: 48,
                    index: BuiltinIconCatalog.frameIndex(
                        for: BuiltinIconCatalog.phase(
                            for: icon,
                            at: context.date.timeIntervalSinceReferenceDate
                        )
                    )
                ))
                .renderingMode(.template)
                .foregroundStyle(.primary)
            }
        } else {
            // Always 48pt: this well shows *what* the artwork is, at a size it picks itself.
            // How big it will be in the menu bar is the job of the actual-size strip.
            Image(nsImage: environment.icons.image(for: spec, app: app, size: 48))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .foregroundStyle(.primary)
        }
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: isSupportedImage),
              let fileName = environment.icons.importImage(from: url) else { return false }
        spec = .custom(fileName: fileName, rendering: .auto, pointSize: nil)
        environment.icons.invalidateCache()
        return true
    }

    private func isSupportedImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return IconLibrary.acceptedTypes.contains { type.conforms(to: $0) }
    }
}

// MARK: - Explanation

/// States in words what the current icon setting will actually do — particularly what
/// Automatic decided about a custom image, which is otherwise invisible until you look up
/// at the menu bar and find your logo has turned into a silhouette.
private struct IconSourceNote: View {
    let environment: AppEnvironment
    let spec: IconSpec
    let app: AppReference?

    var body: some View {
        switch spec {
        case .appIcon:
            note("Using the application's own icon.", "app.badge")

        case .symbol(let name):
            note("SF Symbol “\(name)”. Tints with Light/Dark mode.", "circle.lefthalf.filled")

        case .builtin(let id):
            if let icon = BuiltinIconCatalog.icon(id: id) {
                note(icon.isAnimated
                        ? "\(icon.name) — animated, tints with Light/Dark mode."
                        : "\(icon.name) — tints with Light/Dark mode.",
                     icon.isAnimated ? "sparkles" : "circle.lefthalf.filled")
            } else {
                warning("This icon is no longer available.")
            }

        case .custom(let fileName, let rendering, _):
            if fileName.isEmpty {
                note("Choose or drop an image to use.", "square.and.arrow.down")
            } else if let source = environment.icons.sourceImage(for: spec, app: app) {
                switch rendering {
                case .auto:
                    let analysis = IconRenderer.automaticDecision(for: source)
                    note(analysis.isMonochrome
                            ? "Detected monochrome — tints with Light/Dark mode."
                            : "Detected colour artwork — original colours preserved.",
                         analysis.isMonochrome ? "circle.lefthalf.filled" : "paintpalette")
                case .template:
                    note("Forced monochrome — colour is discarded.", "circle.lefthalf.filled")
                case .original:
                    note("Drawn as-is — will not adapt to Light/Dark mode.", "paintpalette")
                }
            } else {
                warning("Image file is missing.")
            }
        }
    }

    private func note(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}
