import SwiftUI
import AppKit
import Sparkle

/// Keeps Wingman up to date with Sparkle, the same way as Markd and NotchPet: it checks
/// leinerud.se/wingman/appcast.xml once a day (SUFeedURL and SUEnableAutomaticChecks in Info.plist) and when you
/// choose Check for Updates… (in the app menu or Settings).
///
/// With "Update automatically" on (the default, SUAutomaticallyUpdate), a new version downloads quietly and
/// installs when you quit. Wingman hardly ever quits, so it installs and reopens as soon as you're away: the screen
/// locks or sleeps, or nothing's been touched for ten minutes. Until then the footer and the app menu offer
/// Restart to Update. With it off, a daily check doesn't throw a window in your face: the footer says an update
/// is available, and clicking it shows what's new.
///
/// Wingman is sandboxed, so Sparkle installs through its installer service (SUEnableInstallerLauncherService,
/// plus the mach-lookup exceptions in the entitlements). Scripts/direct.sh signs it and the update itself.
///
/// For testing an update end to end: `-WingmanUpdateFeed <url>` reads another appcast, checks right away and
/// installs as soon as the update is downloaded.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    /// A downloaded version that installs as soon as you're away.
    @Published private(set) var readyVersion: String?
    /// A newer version found by the daily check while automatic updates are off.
    @Published private(set) var pendingVersion: String?
    @Published var automaticallyUpdates = false {
        didSet {
            if let u = controller?.updater, u.automaticallyDownloadsUpdates != automaticallyUpdates {
                u.automaticallyDownloadsUpdates = automaticallyUpdates
            }
        }
    }
    private var installNow: (() -> Void)?
    private var awayTimer: Timer?
    static let awayFor: TimeInterval = 10 * 60

    /// The version waiting for you, either way.
    var waitingVersion: String? { readyVersion ?? pendingVersion }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    private nonisolated static var testFeed: String? { UserDefaults.standard.string(forKey: "WingmanUpdateFeed") }

    /// Called once at launch. Demo mode (screenshots) never looks for updates.
    func start() {
        guard controller == nil, !Demo.isOn else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        automaticallyUpdates = c.updater.automaticallyDownloadsUpdates
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(away), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(away), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(away), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        if Self.testFeed != nil { c.updater.checkForUpdatesInBackground() }
    }

    /// Restart into a downloaded update, or check (and show what's found).
    func checkNow() {
        if let installNow {
            self.installNow = nil
            installNow()
            return
        }
        NSApp.activate()   // a menu bar app: bring Sparkle's window to the front
        controller?.checkForUpdates(nil)
    }

    @objc private func away() {
        guard let installNow else { return }
        self.installNow = nil
        awayTimer?.invalidate()
        installNow()   // installs and reopens Wingman; back before you are
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { Self.testFeed }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            readyVersion = version
            installNow = immediateInstallationBlock
            if Self.testFeed != nil { away(); return }
            awayTimer?.invalidate()
            awayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                    if idle > Self.awayFor { Updates.shared.away() }
                }
            }
        }
        return true
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString, userInitiated = state.userInitiated
        MainActor.assumeIsolated { if !userInitiated { pendingVersion = version } }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingVersion = nil }
    }
}

/// Wingman › Check for Updates…, right below About Wingman. Becomes Restart to Update once one is downloaded.
struct UpdateCommands: Commands {
    @ObservedObject private var updates = Updates.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updates.readyVersion.map { "Restart to Update to \($0)" } ?? "Check for Updates…") {
                updates.checkNow()
            }
            .disabled(updates.readyVersion == nil && !updates.canCheck)
        }
    }
}

/// In the footer of the panel and the main window, only while an update is waiting.
struct UpdateBadge: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        if let v = updates.waitingVersion {
            Button { updates.checkNow() } label: {
                Label(updates.readyVersion != nil ? "Restart to update" : "Update to \(v)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(updates.readyVersion != nil
                  ? "Wingman \(v) is downloaded. Restart now, or it installs by itself next time you're away."
                  : "Wingman \(v) is available. Click to see what's new and install it.")
        }
    }
}

/// The Updates section in Settings.
struct UpdateSettings: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Update automatically", isOn: $updates.automaticallyUpdates)
            Text("New versions download quietly and install while you're away from your Mac.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                Button(updates.readyVersion.map { "Restart to Update to \($0)" } ?? "Check for Updates…") { updates.checkNow() }
                    .disabled(updates.readyVersion == nil && !updates.canCheck)
                Text("You have Wingman \(updates.currentVersion).").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}
