import SwiftUI

/// SwiftUI bridging for the store.
///
/// `configuration` is deliberately `private(set)` so every mutation goes through
/// `update(_:)` and gets persisted. These bindings preserve that guarantee while still
/// letting views use ordinary `TextField($binding)` syntax.
extension ConfigurationStore {

    func binding<Value>(_ keyPath: WritableKeyPath<Configuration, Value>) -> Binding<Value> {
        Binding(
            get: { self.configuration[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Binds a single item **by identity**, not by index.
    ///
    /// An index-based binding is a crash waiting to happen here: the sidebar can delete or
    /// reorder items while a detail view holds a binding to position 3. Looking up by `id` on
    /// every access means a stale binding degrades to a harmless no-op instead of an
    /// out-of-bounds trap.
    func itemBinding(id: DockItem.ID, fallback: DockItem) -> Binding<DockItem> {
        Binding(
            get: { self.item(id: id) ?? fallback },
            set: { updated in
                guard self.item(id: id) != nil else { return }
                self.replace(updated)
            }
        )
    }
}

extension DockItem {
    /// Read/write view onto the wrapped `AppEntry`, so detail views can bind straight to
    /// fields without unwrapping the `kind` enum at every callsite.
    var appEntry: AppEntry? {
        get {
            if case .application(let entry) = kind { return entry }
            return nil
        }
        set {
            guard let newValue else { return }
            kind = .application(newValue)
        }
    }

    var groupEntry: GroupEntry? {
        get {
            if case .group(let group) = kind { return group }
            return nil
        }
        set {
            guard let newValue else { return }
            kind = .group(newValue)
        }
    }

    var folderEntry: FolderEntry? {
        get {
            if case .folder(let folder) = kind { return folder }
            return nil
        }
        set {
            guard let newValue else { return }
            kind = .folder(newValue)
        }
    }

    var activityEntry: ActivityEntry? {
        get {
            if case .activity(let activity) = kind { return activity }
            return nil
        }
        set {
            guard let newValue else { return }
            kind = .activity(newValue)
        }
    }
}
