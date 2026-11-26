import SwiftUI
import AppKit

/// Safe, non-destructive actions. Nothing here writes to Copilot's data.
enum SessionActions {
    static func openCopilot() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.githubapp") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    /// Opens one session in the GitHub Copilot app through its deep link (ghapp://sessions/<id>).
    static func openSession(id: String) {
        guard let url = URL(string: "ghapp://sessions/" + id) else { return openCopilot() }
        NSWorkspace.shared.open(url)
    }

    /// Opens the Copilot session for a branch (and/or its workspace folder), or just the app when none matches.
    /// Handing the app the folder itself doesn't work: it treats it as a link and shows "Link not found".
    static func openCopilot(workspace folder: String?, branch: String? = nil, repo: String? = nil) {
        if let id = sessionID(forWorkspace: folder, branch: branch, repo: repo) { openSession(id: id) } else { openCopilot() }
    }

    /// The session to open for a branch. A folder only counts together with the branch: the main checkout of a
    /// project is shared by many sessions, so matching on it alone opens an unrelated one.
    /// Looks in the Copilot app's own workspace list first (it also knows archived workspaces), then in the
    /// session folders. Active workspaces win over archived ones, then the most recent.
    static func sessionID(forWorkspace folder: String?, branch: String? = nil, repo: String? = nil) -> String? {
        let target = folder.map { ($0 as NSString).standardizingPath }
        func folderMatches(_ path: String?) -> Bool {
            guard let target, let path else { return false }
            return (path as NSString).standardizingPath == target
        }

        // 1. The app's own list: workspaces, the branch each is on and where it is checked out.
        struct Candidate { let id: String; let exact: Bool; let archived: Bool; let updated: String }
        var found: [Candidate] = []
        for r in SQLiteReader.rows(path: Access.copilotPath + "/data.db", sql: """
            SELECT w.session_id AS sid, w.branch AS branch, w.archived_at AS archived, w.updated_at AS updated,
                   b.checkout_path AS path, b.checkout_kind AS kind, b.repo_full_name AS repo
            FROM workspaces w LEFT JOIN workspace_checkout_bindings b ON b.workspace_id = w.id
            WHERE w.session_id IS NOT NULL AND w.session_id <> ''
            """) {
            guard let sid = r["sid"] else { continue }
            let sameBranch = branch.map { r["branch"] == $0 } ?? false
            let sameRepo = repo.map { r["repo"] == nil || r["repo"] == $0 } ?? true
            // A worktree belongs to one workspace, so its folder identifies it; an in-place checkout doesn't.
            let ownFolder = r["kind"] == "worktree" && folderMatches(r["path"])
            guard sameRepo, sameBranch || (branch == nil && ownFolder) else { continue }
            found.append(Candidate(id: sid, exact: ownFolder, archived: r["archived"] != nil, updated: r["updated"] ?? ""))
        }
        if let best = found.max(by: { a, b in
            if a.exact != b.exact { return !a.exact }
            if a.archived != b.archived { return a.archived }
            return a.updated < b.updated
        }) { return best.id }

        // 2. Copilot's session folders (workspace.yaml), with the same rule.
        let dir = Access.copilotPath + "/session-state"
        let fm = FileManager.default
        var best: (id: String, exact: Bool, date: Date)?
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let file = dir + "/" + name + "/workspace.yaml"
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            func value(_ key: String) -> String? {
                text.split(separator: "\n").first { $0.hasPrefix(key + ":") }
                    .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            }
            let sameBranch = branch.map { value("branch") == $0 } ?? false
            let sameRepo = repo.map { value("repository") == nil || value("repository") == $0 } ?? true
            let sameFolder = folderMatches(value("cwd"))
            guard sameRepo, sameBranch || (branch == nil && sameFolder) else { continue }
            let date = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date ?? .distantPast
            let exact = sameBranch && sameFolder
            if best == nil || (exact && !best!.exact) || (exact == best!.exact && date > best!.date) { best = (name, exact, date) }
        }
        return best?.id
    }

    static func showInFinder(_ s: CopilotSession) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
    }
    static func githubURL(_ s: CopilotSession, path: String) -> URL? {
        guard let repo = s.repository else { return nil }
        return URL(string: "https://github.com/\(repo)\(path)")
    }
    static func openBranch(_ s: CopilotSession) {
        guard let b = s.branch?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = githubURL(s, path: "/tree/\(b)") else { return }
        Links.open(url)
    }
    static func openPullRequests(_ s: CopilotSession) {
        guard let b = s.branch?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = githubURL(s, path: "/pulls?q=is%3Apr+head%3A\(b)") else { return }
        Links.open(url)
    }
    static func copyID(_ s: CopilotSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.id, forType: .string)
    }
}

/// Send Feedback… opens FeedbackView (FeedbackWindow.swift). When it can't send, it offers the form on
/// leinerud.se instead, opened with the Wingman and macOS versions filled in.
enum Feedback {
    static let windowID = "feedback"

    /// Opens the feedback window and brings Wingman forward (it may have no Dock icon).
    @MainActor static func show(_ openWindow: OpenWindowAction) {
        openWindow(id: windowID)
        NSApp.activate()
    }

    static func openInBrowser() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var url = URLComponents(string: "https://leinerud.se/wingman/feedback/")!
        url.queryItems = [
            URLQueryItem(name: "v", value: version),
            URLQueryItem(name: "os", value: "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"),
        ]
        if let link = url.url { Links.open(link) }
    }
}
