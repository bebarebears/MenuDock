import AppKit
import OSLog
import UniformTypeIdentifiers

/// Owns the custom icon files on disk and the in-memory render cache.
///
/// Two rules drive the design:
///
/// 1. **Copy in, never reference.** A user drags an SVG out of `~/Downloads`, then empties
///    the folder a week later. Storing a path would silently break their menu bar, so the
///    file is copied into `~/Library/Application Support/MenuDock/Icons/` under a generated
///    name and the config only ever stores that name.
/// 2. **Cache the rendered result, not the source.** Rendering (decode → fit → analyse →
///    template) is the expensive part and the input only changes when the user edits the
///    item, so the cache is keyed on everything that affects output.
@Observable
final class IconLibrary {
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
                                                 category: "IconLibrary")
    @ObservationIgnored private var renderCache: [CacheKey: NSImage] = [:]

    /// Formats we accept on drop. SVG first — it is the only one that stays sharp at every
    /// menu bar height and scale factor.
    static let acceptedTypes: [UTType] = [.svg, .png, .pdf, .jpeg, .tiff, .icns, .heic]

    private struct CacheKey: Hashable {
        let spec: IconSpec
        let bundleIdentifier: String?
        let size: Double
        let running: Bool
        let showsIndicator: Bool
        /// Quantised animation frame. Always 0 for static icons, so they occupy one entry.
        let frame: Int
    }

    static var iconsDirectory: URL {
        ConfigurationStore.supportDirectory.appending(path: "Icons", directoryHint: .isDirectory)
    }

    init(directory: URL = IconLibrary.iconsDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(forFileName fileName: String) -> URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    // MARK: - Importing

    /// Copies a user-supplied image into the library and returns the generated file name,
    /// or `nil` if the file is not a decodable image.
    ///
    /// The extension is preserved so `NSImage` picks the right decoder — in particular SVG,
    /// which `NSImage` only recognises from its UTI/extension.
    func importImage(from source: URL) -> String? {
        let needsAccess = source.startAccessingSecurityScopedResource()
        defer { if needsAccess { source.stopAccessingSecurityScopedResource() } }

        guard NSImage(contentsOf: source) != nil else {
            log.error("Rejected \(source.lastPathComponent): not a decodable image")
            return nil
        }

        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = url(forFileName: fileName)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return fileName
        } catch {
            log.error("Failed to import \(source.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Where unreferenced icons are moved instead of being deleted.
    var unusedDirectory: URL {
        directory.appending(path: "Unused", directoryHint: .isDirectory)
    }

    /// Moves library files no longer referenced by any item into `Icons/Unused/`.
    ///
    /// ## This never deletes, on purpose
    ///
    /// It used to call `removeItem`, and that destroyed real user artwork: a configuration that
    /// failed to decode loaded as *empty*, so on the next reconcile every icon in the library
    /// looked unreferenced and was deleted — permanently, with the config file itself still sitting
    /// safe in a `.corrupt-*` backup beside it. Two individually reasonable behaviours combined
    /// into irreversible data loss.
    ///
    /// The caller now also refuses to prune after a failed load (see ``ConfigurationStore/didFailToLoad``),
    /// but that alone would be a fix for one trigger rather than for the hazard. Artwork the user
    /// supplied is not ours to delete, so the destructive operation is simply gone: orphans are
    /// set aside where they can be recovered, and the directory stays small enough that nothing
    /// needs reaping.
    func pruneOrphans(keeping referenced: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let orphans = contents.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
                return false
            }
            return !referenced.contains(url.lastPathComponent)
        }
        guard !orphans.isEmpty else { return }

        do {
            try FileManager.default.createDirectory(at: unusedDirectory, withIntermediateDirectories: true)
        } catch {
            log.error("Could not create Unused directory; leaving orphans in place: \(error.localizedDescription)")
            return
        }

        for file in orphans {
            let destination = unusedDirectory.appending(path: file.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: file, to: destination)
            } catch {
                log.error("Could not set aside \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Restores a previously set-aside icon, so re-selecting an icon the user removed does not
    /// require them to find the original file again.
    @discardableResult
    func restoreFromUnused(fileName: String) -> Bool {
        let source = unusedDirectory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        try? FileManager.default.moveItem(at: source, to: url(forFileName: fileName))
        return true
    }

    // MARK: - Rendering

    /// Returns the menu-bar-ready image for a spec, using the cache when possible.
    ///
    /// - Parameters:
    ///   - app: the app whose bundle icon to use for `.appIcon`, and whose running state
    ///     drives the indicator dot.
    ///   - size: the size to draw at, unless the spec carries its own override.
    ///   - running: whether to draw the running indicator.
    ///   - phase: animation position, 0…1. Ignored for static icons.
    func image(
        for spec: IconSpec,
        app: AppReference?,
        size: Double,
        running: Bool = false,
        showsIndicator: Bool = false,
        phase: Double = 0
    ) -> NSImage {
        // Custom artwork may override the global size. Resolved here rather than at each call
        // site so every surface — menu bar, settings list, previews — agrees on one answer.
        let size = min(max(spec.customPointSize ?? size, IconRenderer.minimumIconSize),
                       IconRenderer.maximumIconSize)

        let frame = Int((phase * Double(BuiltinIconCatalog.frameCount)).rounded())
        let key = CacheKey(spec: spec,
                           bundleIdentifier: app?.bundleIdentifier,
                           size: size,
                           running: running,
                           showsIndicator: showsIndicator,
                           frame: frame)
        if let cached = renderCache[key] { return cached }

        let rendered: NSImage
        if case .builtin(let id) = spec, let icon = BuiltinIconCatalog.icon(id: id) {
            // Built-ins skip the NSImage pipeline entirely — they are drawn straight into the
            // final rect, so no resampling ever touches them.
            rendered = IconRenderer.menuBarImage(
                builtin: icon,
                size: size,
                showsRunningDot: showsIndicator && running,
                phase: phase
            )
        } else {
            rendered = IconRenderer.menuBarImage(
                from: sourceImage(for: spec, app: app),
                spec: spec,
                size: size,
                showsRunningDot: showsIndicator && running
            )
        }

        renderCache[key] = rendered
        return rendered
    }

    /// The built-in glyph behind a spec, if it is one.
    func builtinIcon(for spec: IconSpec) -> BuiltinIcon? {
        guard case .builtin(let id) = spec else { return nil }
        return BuiltinIconCatalog.icon(id: id)
    }

    /// The unprocessed image behind a spec, before fitting or template analysis.
    func sourceImage(for spec: IconSpec, app: AppReference?) -> NSImage? {
        switch spec {
        case .appIcon:
            guard let url = app?.resolvedURL else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)

        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image

        case .builtin(let id):
            guard let icon = BuiltinIconCatalog.icon(id: id) else { return nil }
            return BuiltinIconCatalog.image(icon: icon, size: 64)

        case .custom(let fileName, _, _):
            return NSImage(contentsOf: url(forFileName: fileName))
        }
    }

    /// Drops every cached render. Called when the system appearance changes, when the
    /// configuration changes, or when preferences alter icon size.
    func invalidateCache() {
        renderCache.removeAll(keepingCapacity: true)
    }
}
