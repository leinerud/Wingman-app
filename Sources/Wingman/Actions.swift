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

    /// Opens the Copilot session that works in `folder`, or just the app when no session matches.
    /// Handing the app the folder itself doesn't work: it treats it as a link and shows "Link not found".
    static func openCopilot(workspace folder: String?, branch: String? = nil) {
        if let id = sessionID(forWorkspace: folder, branch: branch) { openSession(id: id) } else { openCopilot() }
    }

    /// The newest session whose workspace.yaml has `cwd: <folder>`, or failing that `branch: <branch>`.
    static func sessionID(forWorkspace folder: String?, branch: String? = nil) -> String? {
        let dir = Access.copilotPath + "/session-state"
        let fm = FileManager.default
        let target = folder.map { ($0 as NSString).standardizingPath }
        var best: (id: String, date: Date)?, byBranch: (id: String, date: Date)?
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let file = dir + "/" + name + "/workspace.yaml"
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            func value(_ key: String) -> String? {
                text.split(separator: "\n").first { $0.hasPrefix(key + ":") }
                    .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            }
            let date = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date ?? .distantPast
            if let target, let cwd = value("cwd"), (cwd as NSString).standardizingPath == target {
                if date > (best?.date ?? .distantPast) { best = (name, date) }
            } else if let branch, value("branch") == branch {
                if date > (byBranch?.date ?? .distantPast) { byBranch = (name, date) }
            }
        }
        return (best ?? byBranch)?.id
    }

    static func showInFinder(_ s: CopilotSession) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
    }
    static func openInEditor(_ s: CopilotSession) {
        let dir = URL(fileURLWithPath: s.cwd)
        if let vsc = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([dir], withApplicationAt: vsc, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(dir) }
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
