import AppKit
import ApplicationServices
import OSLog
import Security

/// Whether macOS currently trusts MenuDock to synthesise a keystroke — and, when it does not,
/// *which kind* of "no" this is.
///
/// ## The failure this exists to name
///
/// macOS pins an Accessibility grant to the exact copy of the app it was given to. For an app
/// signed with a certificate that means the certificate; for an **ad-hoc** signed one — which
/// MenuDock is, so that it builds with no developer account — it means the binary's `cdhash`.
/// Every rebuild produces a new hash, so every rebuild silently invalidates the grant.
///
/// What the user sees is the worst possible version of that: the switch beside MenuDock in
/// Privacy & Security › Accessibility is still **on**, and `AXIsProcessTrusted()` still returns
/// **false**. `tccd` says so in as many words —
///
/// ```
/// SecStaticCodeCheckValidity() ... status: -67050   // code failed to satisfy code requirement
/// Failed to match existing code requirement for subject com.bebarebears.MenuDock
///                                            and service kTCCServiceAccessibility
/// ```
///
/// — but nothing in the UI does, so the feature reads as broken rather than as unpermitted. Worse,
/// the usual remedy is a no-op: `AXIsProcessTrustedWithOptions` raises no prompt once a row for the
/// app exists, whether or not that row still matches. The switch has to be turned *off and on
/// again*, or the entry removed with **–** and re-added, before macOS will re-record the
/// requirement against the current build.
///
/// So this class records the signature a grant was seen under. On a later launch, a `false` from
/// `AXIsProcessTrusted()` beside a *different* recorded signature is not a user who never granted
/// anything — it is this exact bug, and it can be said out loud instead of guessed at.
///
/// ## Why it polls
///
/// There is no notification for a TCC change. Every app that shows a live permission state polls,
/// and this one only does so while something is watching — the Settings pane being open, in
/// practice — so an idle MenuDock runs no timer for it at all.
@Observable
@MainActor
final class AccessibilityPermission {

    /// Whether macOS will let MenuDock press ⌘V in another app, as of the last check.
    private(set) var isTrusted: Bool

    /// Why auto-paste is unavailable, when it is.
    enum Denial: Equatable {
        /// Never granted, or granted and then switched off. The system prompt is worth raising.
        case notGranted
        /// Granted to an earlier build of MenuDock. The row in System Settings looks enabled and
        /// does nothing; it has to be removed and re-added. No prompt will appear for this.
        case grantedToAnotherBuild
    }

    var denial: Denial? {
        guard !isTrusted else { return nil }
        // Both halves of the comparison have to be known. A missing *current* signature — an
        // unsigned build, or a bundle the Security framework cannot read — is not evidence that
        // the grant belongs to another build, and claiming it is would send the user off to
        // remove a working entry.
        guard let granted = grantedSignature,
              let current = Self.signature,
              granted != current
        else { return .notGranted }
        return .grantedToAnotherBuild
    }

    // MARK: Stored state

    /// The code signature MenuDock was last *seen* trusted under.
    ///
    /// `UserDefaults` rather than `config.json`: that file is the user's settings, small enough to
    /// read and hand-edit, and this is neither settings nor interesting to a human. It is a fact
    /// about a macOS permission, and it belongs with the other facts of that kind.
    @ObservationIgnored private var grantedSignature: String? {
        get { UserDefaults.standard.string(forKey: Self.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    private static let defaultsKey = "AccessibilityGrantedSignature"

    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    @ObservationIgnored private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MenuDock",
        category: "Accessibility"
    )

    init() {
        isTrusted = AXIsProcessTrusted()
        recordIfTrusted()

        if case .grantedToAnotherBuild = denial {
            log.error("""
                Accessibility was granted to a different build of MenuDock (\
                \(self.grantedSignature ?? "unknown", privacy: .public) vs \
                \(Self.signature ?? "unknown", privacy: .public)), so macOS is refusing it now. \
                The entry in Privacy & Security › Accessibility looks enabled but no longer \
                matches: remove MenuDock with – and add it again.
                """)
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    // MARK: - Checking

    /// Re-reads the live trust state. Cheap, and deliberately never cached across a call: the user
    /// can revoke Accessibility while the app is running, and a stale `true` would turn auto-paste
    /// into a dead keystroke with no explanation.
    @discardableResult
    func refresh() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
        recordIfTrusted()
        return trusted
    }

    /// Remembers the build a grant was seen under, so a later refusal can be explained rather than
    /// guessed at. Only ever written while trusted, which is the one moment it is known to be true.
    private func recordIfTrusted() {
        guard isTrusted, let signature = Self.signature, grantedSignature != signature else {
            return
        }
        grantedSignature = signature
    }

    // MARK: - Watching

    /// Starts polling while a view is on screen showing the permission state. Balanced by
    /// ``stopWatching()``; nested callers are counted, so two open windows do not fight over one
    /// timer.
    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }

        // One second. This is a human walking to System Settings and back, not a UI animation.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Coming back from System Settings is the moment the answer most often changes, and
        // waiting up to a second to notice makes granting the permission feel like it failed.
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
    }

    func stopWatching() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: - Asking

    /// Asks macOS to show its "allow MenuDock to control this computer" prompt.
    ///
    /// Returns whether a prompt could plausibly appear. It cannot when the app already has a row in
    /// the Accessibility list — including the stale row this class exists to detect — and calling
    /// it anyway is a silent no-op, which is exactly how a user ends up believing they granted a
    /// permission that is not in force.
    @discardableResult
    func requestPrompt() -> Bool {
        guard denial != .grantedToAnotherBuild else { return false }
        // The key is spelled out rather than read from `kAXTrustedCheckOptionPrompt`, which is a
        // mutable global and therefore not readable from concurrent code under Swift 6. Its value
        // is this string and has been since the API shipped.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return true
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Identity

    /// The `cdhash` of the copy of MenuDock on disk — the value macOS pins an Accessibility grant
    /// to, and the one `tccd` compares against when deciding whether the grant still applies.
    ///
    /// Read from the bundle rather than the running process because that is what `tccd` evaluates:
    /// its log lines say `static code ... at /Applications/MenuDock.app`.
    private static let signature: String? = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }

        return hash.map { String(format: "%02x", $0) }.joined()
    }()
}
