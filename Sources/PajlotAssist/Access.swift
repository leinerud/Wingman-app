import SwiftUI
import AppKit

/// Folder access for the sandboxed app. macOS only lets a sandboxed app read folders the user has chosen,
/// so we ask once, remember the choice (a security-scoped bookmark) and reuse it on every launch.
/// Outside the sandbox (e.g. a plain `swift build`) every folder is already readable and nothing is asked.
extension Notification.Name { static let accessChanged = Notification.Name("PajlotAccessChanged") }

enum Access {
    /// The real home folder. Inside the sandbox `NSHomeDirectory()` points at the app's private container instead.
    static let realHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    private static let copilotKey = "access.copilotBookmark"
    private static let projectsKey = "access.projectBookmarks"
    nonisolated(unsafe) private static var open: [URL] = []

    static var copilotPath: String { realHome + "/.copilot" }

    static func canRead(_ path: String) -> Bool { FileManager.default.isReadableFile(atPath: path) }
    static var hasCopilotAccess: Bool { canRead(copilotPath + "/session-state") }

    /// Re-opens every folder the user chose in earlier launches.
    static func restore() {
        var keys = [copilotKey]
        keys.append(contentsOf: (UserDefaults.standard.array(forKey: projectsKey) as? [String]) ?? [])
        for k in keys {
            guard let data = UserDefaults.standard.data(forKey: k) else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() { open.append(url) }
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope) { UserDefaults.standard.set(fresh, forKey: k) }
        }
    }

    private static func remember(_ url: URL, key: String) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope) else { return }
        UserDefaults.standard.set(data, forKey: key)
        if url.startAccessingSecurityScopedResource() { open.append(url) }
    }

    private static func panel(message: String, prompt: String, start: URL, hidden: Bool) -> URL? {
        let p = NSOpenPanel()
        p.message = message
        p.prompt = prompt
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = hidden
        p.directoryURL = start
        NSApp.activate()
        return p.runModal() == .OK ? p.url : nil
    }

    /// Asks the user to pick the `.copilot` folder. Returns true once it can be read.
    @MainActor @discardableResult
    static func requestCopilotFolder() -> Bool {
        guard let url = panel(message: "Choose the “.copilot” folder in your home folder. Pajlot Assist only reads it to show your sessions.",
                              prompt: "Allow", start: URL(fileURLWithPath: copilotPath), hidden: true) else { return hasCopilotAccess }
        guard url.lastPathComponent == ".copilot" else {
            let a = NSAlert()
            a.messageText = "That isn't the .copilot folder"
            a.informativeText = "Look for “.copilot” in your home folder. Press ⌘⇧. in the file picker to show hidden folders."
            a.runModal()
            return requestCopilotFolder()
        }
        remember(url, key: copilotKey)
        NotificationCenter.default.post(name: .accessChanged, object: nil)
        return hasCopilotAccess
    }

    /// Asks the user to allow a project folder (or a parent such as ~/Developer, which covers every project inside it).
    @MainActor @discardableResult
    static func requestProjectFolder(for path: String) -> Bool {
        let start = URL(fileURLWithPath: path)
        guard let url = panel(message: "Allow Pajlot Assist to read this project so it can show what changed. Pick a parent folder to cover all your projects at once.",
                              prompt: "Allow", start: start, hidden: false) else { return canRead(path) }
        let key = "access.project." + url.path
        remember(url, key: key)
        var keys = (UserDefaults.standard.array(forKey: projectsKey) as? [String]) ?? []
        if !keys.contains(key) { keys.append(key); UserDefaults.standard.set(keys, forKey: projectsKey) }
        return canRead(path)
    }
}
