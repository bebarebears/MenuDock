import AppKit

/// Carries a menu item's behaviour as a closure.
///
/// Menus here are rebuilt from live model state every time they open, so classic
/// target/action plumbing would mean a selector switchboard and a `representedObject` cast at
/// every callsite. Closures keep each entry's behaviour written next to its title.
///
/// This is a companion object rather than an `NSMenuItem` subclass on purpose: `NSMenuItem`'s
/// designated initialisers are `nonisolated`, so under the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` any subclass would have to be `nonisolated`
/// too — which would in turn force every menu handler to be `@Sendable`, even though menus
/// only ever run on the main thread.
final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func fire() {
        handler()
    }
}

extension NSMenu {
    /// Appends an item that runs `handler` when chosen.
    @discardableResult
    func addAction(
        _ title: String,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        image: NSImage? = nil,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let target = MenuActionTarget(handler: handler)
        let item = NSMenuItem(
            title: title,
            action: #selector(MenuActionTarget.fire),
            keyEquivalent: keyEquivalent
        )
        item.target = target
        // `NSMenuItem.target` is a weak reference, so the target would deallocate the moment
        // this function returns. `representedObject` is strong and unused here, so it is the
        // natural place to anchor the closure's lifetime to the item's.
        item.representedObject = target
        item.keyEquivalentModifierMask = modifiers
        item.image = image
        addItem(item)
        return item
    }

    /// Non-interactive title row, used as a menu header.
    func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        addItem(item)
    }

    /// Adds a disabled explanatory row, for empty states.
    func addPlaceholder(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}

extension NSMenuItem {
    /// Marks this item as the Option-key variant of the item directly above it.
    @discardableResult
    func asAlternate() -> Self {
        isAlternate = true
        keyEquivalentModifierMask = .option
        return self
    }
}
