import Foundation
import AppKit
import SwiftUI

/// Made-up sessions, branches and changes for screenshots of the app, so they never show anyone's real work.
/// Turn it on with a launch argument: `open Wingman.app --args -WingmanDemo YES`. Nothing is read from disk then.
enum Demo {
    nonisolated static var isOn: Bool { UserDefaults.standard.bool(forKey: "WingmanDemo") }

    private nonisolated static func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
    private nonisolated static func todo(_ id: String, _ title: String, _ state: TodoItem.State) -> TodoItem {
        TodoItem(id: id, title: title, detail: "", state: state)
    }

    /// Gives the app's windows the same 16:10 size as the other screenshots on leinerud.se (2000 x 1250 at 2x).
    @MainActor static func fitWindows() {
        guard isOn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) && w.styleMask.contains(.resizable) {
                w.setFrame(NSRect(x: 80, y: 80, width: 1000, height: 625), display: true)
            }
        }
    }

    /// -WingmanDemoDetails <branch> opens that branch's "What's in it"; -WingmanDemoReview <session id> opens its Review.
    nonisolated static func opensDetails(_ branch: String) -> Bool {
        isOn && UserDefaults.standard.string(forKey: "WingmanDemoDetails") == branch
    }
    static var reviewSession: String? { isOn ? UserDefaults.standard.string(forKey: "WingmanDemoReview") : nil }
    /// -WingmanDemoReviewTab Tokens (or Timeline) opens Review on that tab.
    static var reviewTab: String? { isOn ? UserDefaults.standard.string(forKey: "WingmanDemoReviewTab") : nil }

    /// -WingmanDemoPanel YES shows the menu bar panel with its icon above it, in a transparent window titled
    /// "Demo panel" to capture. The real status item can't be relied on: macOS may hide it behind the notch.
    @MainActor private static var panelWindow: NSWindow?
    @MainActor static func openPanel(_ store: SessionStore) {
        guard isOn, UserDefaults.standard.bool(forKey: "WingmanDemoPanel"), panelWindow == nil else { return }
        let view = DemoPanelShot().environmentObject(store)
        let w = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 500, height: 700), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.title = "Demo panel"
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        w.setContentSize(w.contentView!.fittingSize)
        w.orderFrontRegardless()
        panelWindow = w
    }

    // MARK: Sessions

    static var sessions: [CopilotSession] {
        [
            CopilotSession(
                id: "demo-0001-checkout", title: "Redesign the checkout summary", cwd: "/Users/demo/Projects/lumen-shop",
                repository: "northwind-studio/lumen-shop", branch: "checkout-summary", updatedAt: ago(0.3), status: .needsInput,
                activity: "Waiting for your answer",
                lastMessage: "The summary card now uses the new surface colour and 16 pt spacing.",
                question: "Should the discount line be green, like the brand accent, or stay neutral grey?",
                todos: [todo("1", "Match the Figma layout", .done), todo("2", "Use spacing tokens", .done),
                        todo("3", "Style the discount line", .in_progress), todo("4", "Check dark mode", .pending)],
                pinned: true, tag: .purple),
            CopilotSession(
                id: "demo-0002-tokens", title: "Move button colours to design tokens", cwd: "/Users/demo/Projects/pebble-ui",
                repository: "northwind-studio/pebble-ui", branch: "button-tokens", updatedAt: ago(1), status: .working,
                activity: "Updating Button.tsx",
                lastMessage: "Replacing hard-coded colours in the primary and ghost buttons.",
                question: nil,
                todos: [todo("1", "Find hard-coded colours", .done), todo("2", "Add colour tokens", .done),
                        todo("3", "Update the buttons", .in_progress), todo("4", "Update the docs", .pending),
                        todo("5", "Run the visual tests", .pending)],
                tag: .blue),
            CopilotSession(
                id: "demo-0003-onboarding", title: "Friendlier onboarding copy", cwd: "/Users/demo/Projects/tandem-app",
                repository: "northwind-studio/tandem-app", branch: "onboarding-copy", updatedAt: ago(4), status: .working,
                activity: "Rewriting the welcome screen",
                lastMessage: "Shortened the three intro cards to one sentence each.",
                question: nil,
                todos: [todo("1", "Rewrite the welcome screen", .in_progress), todo("2", "Rewrite the empty states", .pending),
                        todo("3", "Check text length on small phones", .pending)]),
            CopilotSession(
                id: "demo-0004-darkmode", title: "Dark mode for the settings page", cwd: "/Users/demo/Projects/lumen-shop",
                repository: "northwind-studio/lumen-shop", branch: "settings-dark-mode", updatedAt: ago(38), status: .idle,
                activity: "Finished", lastMessage: "Settings now follow the system appearance. Opened pull request #214.",
                question: nil,
                todos: [todo("1", "Add dark colours", .done), todo("2", "Fix the toggle contrast", .done),
                        todo("3", "Open a pull request", .done)],
                tag: .green),
            CopilotSession(
                id: "demo-0005-icons", title: "Swap the icon set to rounded", cwd: "/Users/demo/Projects/pebble-ui",
                repository: "northwind-studio/pebble-ui", branch: "rounded-icons", updatedAt: ago(60 * 26), status: .stopped,
                activity: "Closed", lastMessage: "All 48 icons now use the rounded set.", question: nil,
                todos: [todo("1", "Replace the icons", .done), todo("2", "Update the icon page", .done)]),
        ]
    }

    // MARK: Review

    nonisolated static func inspect(cwd: String) -> InspectorData {
        var d = InspectorData()
        d.branch = cwd.hasSuffix("pebble-ui") ? "button-tokens" : "checkout-summary"
        d.dirtyFiles = 4
        d.hasTokenFile = true
        d.changes = [
            ScreenChange(name: "Checkout", kind: .screen, files: ["src/pages/Checkout.tsx"], added: 42, removed: 18,
                         changes: [DesignChange(kind: .colour, label: "Background", before: "#FFFFFF", after: "#F6F5F2"),
                                   DesignChange(kind: .number, label: "Padding", before: "12", after: "16"),
                                   DesignChange(kind: .text, label: "Heading", before: "Order summary", after: "Your order")],
                         isNew: false, isDeleted: false),
            ScreenChange(name: "Summary card", kind: .component, files: ["src/components/SummaryCard.tsx"], added: 64, removed: 0,
                         changes: [DesignChange(kind: .added, label: "New component", before: nil, after: "SummaryCard")],
                         isNew: true, isDeleted: false),
            ScreenChange(name: "Discount line", kind: .style, files: ["src/styles/checkout.css"], added: 9, removed: 5,
                         changes: [DesignChange(kind: .colour, label: "Text colour", before: "#333333", after: "#1F7A4D"),
                                   DesignChange(kind: .number, label: "Text size", before: "12", after: "13")],
                         isNew: false, isDeleted: false),
            ScreenChange(name: "Checkout copy", kind: .content, files: ["src/content/checkout.md"], added: 6, removed: 6,
                         changes: [DesignChange(kind: .text, label: "Button", before: "Proceed to payment", after: "Pay now")],
                         isNew: false, isDeleted: false),
        ]
        d.findings = [
            TokenFinding(kind: .colour, file: "src/styles/checkout.css", line: 41, value: "#1F7A4D",
                         message: "This green isn't in your colour tokens.", suggestion: "--color-success (#1E7A4C)"),
            TokenFinding(kind: .spacing, file: "src/components/SummaryCard.tsx", line: 18, value: "14px",
                         message: "14 isn't on the 4-point grid.", suggestion: "16px (--space-4)"),
        ]
        d.commits = [
            CommitEntry(sha: "a1c9e07f2b", date: ago(25), subject: "Use spacing tokens in the summary card"),
            CommitEntry(sha: "9be310d4c1", date: ago(70), subject: "Match the checkout layout to Figma"),
            CommitEntry(sha: "47d02aa9e3", date: ago(60 * 20), subject: "Add the summary card component"),
        ]
        return d
    }

    // MARK: Branches

    nonisolated static var repos: [RepoBranches] {
        func row(_ repo: String, _ name: String, sessions: Int = 1, hours: Double, ahead: Int? = 0, merged: Bool = false,
                 dirty: Int = 0, current: Bool = false, active: Bool = false, gone: Bool = false, onGitHub: Bool? = true,
                 prs: [Int] = [], topic: String? = nil, commits: Int = 0, copilot: CopilotWorkspace? = .active) -> BranchRow {
            var r = BranchRow(repo: repo, name: name)
            r.sessions = sessions; r.lastActive = ago(hours * 60); r.existsLocally = true; r.isCurrent = current
            r.upstream = onGitHub == true ? "origin/\(name)" : nil; r.track = gone ? "gone" : nil
            r.dirty = dirty; r.defaultName = "origin/main"; r.ahead = ahead; r.merged = merged
            r.sessionActive = active; r.onGitHub = onGitHub; r.prs = prs; r.topic = topic; r.commits = commits
            r.copilot = copilot; r.folder = "/Users/demo/Projects/" + (repo.split(separator: "/").last.map(String.init) ?? repo)
            return r
        }
        let shop = "northwind-studio/lumen-shop", ui = "northwind-studio/pebble-ui", app = "northwind-studio/tandem-app"
        return [
            RepoBranches(name: shop, folders: ["/Users/demo/Projects/lumen-shop"], branches: [
                row(shop, "main", sessions: 2, hours: 30, current: false),
                row(shop, "checkout-summary", sessions: 2, hours: 0.1, ahead: 3, dirty: 4, current: true, active: true,
                    topic: "Redesign the checkout summary", commits: 3),
                row(shop, "settings-dark-mode", hours: 0.7, ahead: 5, prs: [214], topic: "Dark mode for the settings page", commits: 5),
                row(shop, "product-card-hover", hours: 60, merged: true, gone: true, prs: [198],
                    topic: "Softer hover on product cards", commits: 2, copilot: .closed),
                row(shop, "try-new-header", hours: 200, ahead: 2, onGitHub: false, topic: "Try a sticky header", commits: 2,
                    copilot: .closed),
            ], needsAccess: false, basicLocal: false),
            RepoBranches(name: ui, folders: ["/Users/demo/Projects/pebble-ui"], branches: [
                row(ui, "main", hours: 26),
                row(ui, "button-tokens", hours: 0.02, ahead: 2, dirty: 3, current: true, active: true,
                    topic: "Move button colours to design tokens", commits: 2),
                row(ui, "rounded-icons", hours: 26, merged: true, prs: [87], topic: "Swap the icon set to rounded", commits: 4,
                    copilot: .closed),
            ], needsAccess: false, basicLocal: false),
            RepoBranches(name: app, folders: ["/Users/demo/Projects/tandem-app"], branches: [
                row(app, "main", hours: 90),
                row(app, "onboarding-copy", hours: 0.07, ahead: 1, current: true, active: true,
                    topic: "Friendlier onboarding copy", commits: 1),
            ], needsAccess: false, basicLocal: false),
        ]
    }

    nonisolated static func details(_ row: BranchRow) -> BranchDetails {
        var d = BranchDetails()
        d.readGit = true
        d.prs = row.prs
        let f = { (k: String, p: String) in BranchDetails.File(kind: k, path: p) }
        switch row.name {
        case "checkout-summary":
            d.changes = [.init(title: "Use spacing tokens in the summary card", date: ago(25)),
                         .init(title: "Match the checkout layout to Figma", date: ago(70)),
                         .init(title: "feat: add SummaryCard component", date: ago(60 * 20))]
            d.files = [f("M", "src/pages/Checkout.tsx"), f("A", "src/components/SummaryCard.tsx"),
                       f("M", "src/styles/checkout.css"), f("M", "src/content/checkout.md")]
            d.added = 121; d.removed = 29
            d.unsaved = [f("M", "src/styles/checkout.css"), f("M", "src/components/SummaryCard.tsx")]
            d.sessions = [.init(title: "Redesign the checkout summary", date: ago(0.3), closed: false),
                          .init(title: "Fix the total alignment on mobile", date: ago(60 * 22), closed: true)]
        case "settings-dark-mode":
            d.changes = [.init(title: "fix: toggle contrast in dark mode", date: ago(45)),
                         .init(title: "Add dark colours for settings", date: ago(90))]
            d.files = [f("M", "src/pages/Settings.tsx"), f("M", "src/styles/theme.css"), f("M", "src/components/Toggle.tsx")]
            d.added = 58; d.removed = 12
            d.sessions = [.init(title: "Dark mode for the settings page", date: ago(38), closed: false)]
        default:
            d.latest = [.init(title: row.topic ?? "Update styles", date: row.lastActive)]
            d.files = [f("M", "src/styles/theme.css")]
            d.added = 14; d.removed = 6
            if let t = row.topic { d.sessions = [.init(title: t, date: row.lastActive, closed: row.copilot == .closed)] }
        }
        return d
    }
}


/// What -WingmanDemoPanel captures: the menu bar icon, highlighted as when it's clicked, and the panel below it.
/// The top 24 points are left clear so compose.py can draw the menu bar behind the icon.
private struct DemoPanelShot: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 3) {
                Image(nsImage: MenuBarIcon.image(MenuBarIcon.pose(for: .needsInput, at: 10), description: "Wingman"))
                    .renderingMode(.template)
                if store.activeCount > 0 { Text("\(store.activeCount)").font(.system(size: 13, weight: .medium)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.22)))
            .frame(height: 24)
            .padding(.trailing, 150)
            PopoverView()
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }
}
