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
        guard let url = panel(message: "Select the “.copilot” folder in your home folder and click Allow. Pajlot Assist only reads it to show your sessions.",
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

// MARK: - Guide shown in the welcome screen and wherever access is missing

/// Explains, step by step, how to let the app read Copilot's session folder.
struct CopilotAccessGuide: View {
    var compact = false
    var onChange: () -> Void = {}
    @State private var granted = Access.hasCopilotAccess
    @State private var missing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if granted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ready)
                    Text("Connected. Your sessions show up automatically.").font(.system(size: 12.5, weight: .medium))
                }
            } else {
                Text("Your Copilot sessions are stored in a hidden folder called “.copilot”. macOS asks you to approve access once. Pajlot Assist only reads it and never changes anything.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Click “Choose .copilot folder…”")
                    step(2, "In the window, open your home folder (the one with your name) and select “.copilot”")
                    step(3, "Click “Allow”")
                }
                Text("Can't see it? Hidden folders are shown here, or press ⌘⇧. to toggle them.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                if missing {
                    Text("There is no .copilot folder on this Mac yet. Start a chat in the GitHub app first, then try again.")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                }
                Button("Choose .copilot folder…") {
                    missing = !FileManager.default.fileExists(atPath: Access.copilotPath)
                    if missing { return }
                    Access.requestCopilotFolder()
                    granted = Access.hasCopilotAccess
                    onChange()
                }
                .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: true))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessChanged)) { _ in granted = Access.hasCopilotAccess }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent)
                .frame(width: 17, height: 17).background(Circle().fill(Palette.accent.opacity(0.14)))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
