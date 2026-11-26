import SwiftUI
import AppKit
import Combine

@main
struct WingmanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // With -WingmanDemo YES it shows made-up sessions instead of yours (Demo.swift), for screenshots.
    @StateObject private var store = Demo.isOn ? SessionStore(preview: Demo.sessions) : SessionStore()
    @AppStorage(Prefs.menuBar) private var showInMenuBar = true

    var body: some Scene {
        // The main window: Sessions and Branches, switched at the top. Opens from the Dock or the menu bar panel.
        // It opens at launch only for Dock users who are past the welcome screen.
        Window("Wingman", id: MainWindow.id) {
            MainWindowView().environmentObject(store).registersWindowOpener()
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 720, height: 640)
        .defaultPosition(.topTrailing)
        .defaultLaunchBehavior(Prefs.hasSeenWelcome && Prefs.showInDock ? .presented : .suppressed)
        .commands {
            UpdateCommands()
            CommandGroup(after: .help) {
                SendFeedbackMenuItem()
            }
        }

        // Send Feedback…: written here and sent straight to leinerud.se.
        Window("Send Feedback", id: Feedback.windowID) {
            FeedbackView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        // First-launch splash: pick Dock and/or menu bar, and learn about the widget.
        Window("Welcome to Wingman", id: WelcomeView.windowID) {
            WelcomeView().registersWindowOpener()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultLaunchBehavior(Prefs.hasSeenWelcome ? .suppressed : .presented)

        // "Review": what a session changed on screen, token check, timeline and live preview.
        WindowGroup("Review", id: InspectorWindowID.id, for: String.self) { $sessionID in
            InspectorWindow(sessionID: sessionID ?? "").environmentObject(store).onAppear { Demo.fitWindows() }
        }
        .defaultSize(width: 780, height: 640)

        Settings {
            SettingsView()
        }

        // The same settings as a regular window. SwiftUI's openSettings() often does nothing when called from the
        // menu bar panel while the app has no Dock icon, so the gear button opens this one instead.
        Window("Wingman Settings", id: SettingsWindowID.id) {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra(isInserted: $showInMenuBar) {
            PopoverView().environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

enum InspectorWindowID { static let id = "inspector" }

/// Help › Send Feedback… (a view, so it can reach openWindow).
private struct SendFeedbackMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Send Feedback…") { Feedback.show(openWindow) }
    }
}

enum SettingsWindowID { static let id = "settings" }

/// The main window: Sessions and Branches, switched with a segmented control at the top.
struct MainWindowView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Sessions", branches = "Branches"
        var id: Self { self }
    }
    @AppStorage(MainWindow.tabKey) private var tab: Tab = .sessions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch tab {
            case .sessions: PopoverView(resizable: true, showBranches: { tab = .branches })
            case .branches: BranchesWindow()
            }
        }
        .navigationTitle(tab.rawValue)
        .onAppear {
            Demo.fitWindows()
            if let id = Demo.reviewSession { openWindow(id: InspectorWindowID.id, value: id) }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            // A native toolbar control, so it picks up the system look (Liquid Glass on macOS 26). Pinned to the
            // leading edge: a centred item moves when the Branches tab adds its search and buttons on the right.
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Switch between your sessions and the branches they used")
            }
        }
    }
}

enum MainWindow {
    static let id = "main"
    static let tabKey = "main.tab"
    /// Set by whichever SwiftUI view is alive, so AppKit callbacks (Dock clicks) can open the window.
    @MainActor static var open: (() -> Void)?
}

private struct WindowOpenerRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            MainWindow.open = { open(id: MainWindow.id); NSApp.activate() }
            // For screenshots and testing: open Send Feedback at launch (`-WingmanFeedback YES`).
            if UserDefaults.standard.bool(forKey: "WingmanFeedback") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Feedback.show(open) }
            }
        }
    }
}

extension View {
    func registersWindowOpener() -> some View { modifier(WindowOpenerRegistration()) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        Prefs.applyDockPolicy()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Updates.shared.start() }
    }
    /// Clicking the Dock icon (or the desktop widget) brings the window back if it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { MainWindow.open?() } }
        return true
    }
    /// Closing the window keeps the app running (in the menu bar and/or Dock).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarLabel: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var animator = MenuBarIconAnimator()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var mode: MenuBarIconMode {
        if store.needsInputCount > 0 { return .needsInput }
        if store.sessions.contains(where: { $0.status == .working }) { return .working }
        if store.doneAt != nil { return .done }
        return .idle
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: animator.image)
            if store.activeCount > 0 { Text("\(store.activeCount)") }
        }
        .help(store.activeCount == 0 ? "Wingman: nothing running" : "Wingman: \(store.activeCount) \(store.activeCount == 1 ? "session" : "sessions") active")
        .onAppear { animator.set(mode) }
        .registersWindowOpener()
        .onChange(of: mode) { _, new in animator.set(new) }
        .onReceive(timer) { _ in
            if let d = store.doneAt, Date().timeIntervalSince(d) > 120 { store.doneAt = nil }
        }
    }
}
