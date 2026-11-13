import Foundation

/// What the app hands to the desktop widget. The widget is sandboxed and can't read ~/.copilot,
/// so the app writes this small summary into a shared App Group folder instead.
struct WidgetSnapshot: Codable, Equatable {
    struct Session: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let repo: String
        let status: String          // SessionStatus raw value
        let activity: String
        let question: String?
        let done: Int
        let total: Int
        let updatedAt: Date
        var pinned: Bool? = nil
    }
    var sessions: [Session] = []
    var savedAt = Date.distantPast

    static let appGroup = "RD223D229Z.se.humblebee.PajlotAssist"
    static let widgetKind = "PajlotSessions"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snap
    }

    /// Writes the snapshot; returns false when there is no shared folder (e.g. an unsigned SwiftPM build).
    @discardableResult
    func save() -> Bool {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

/// Taps on the desktop widget's buttons. The widget can't touch the app's data, so it leaves a note
/// in the shared folder and the app picks it up within a few seconds.
struct WidgetActions: Codable, Equatable {
    var togglePin: [String] = []

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup)?
            .appendingPathComponent("widget-actions.json")
    }

    static func enqueueTogglePin(_ id: String) {
        guard let url = fileURL else { return }
        var cur = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(WidgetActions.self, from: $0) } ?? WidgetActions()
        cur.togglePin.append(id)
        if let data = try? JSONEncoder().encode(cur) { try? data.write(to: url, options: .atomic) }
    }

    /// Returns and clears whatever the widget has queued.
    static func drain() -> WidgetActions {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let cur = try? JSONDecoder().decode(WidgetActions.self, from: data), cur != WidgetActions() else { return WidgetActions() }
        try? FileManager.default.removeItem(at: url)
        return cur
    }
}

extension WidgetSnapshot {
    /// Flips the pin flag right in the saved summary so the widget updates instantly, before the app has seen the tap.
    static func togglePinInSnapshot(_ id: String) {
        var snap = load()
        guard let i = snap.sessions.firstIndex(where: { $0.id == id }) else { return }
        snap.sessions[i].pinned = !(snap.sessions[i].pinned ?? false)
        snap.save()
    }
}
