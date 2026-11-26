import SwiftUI
import AppKit

/// A colour label you can put on a session, like Finder tags.
enum TagColor: String, CaseIterable, Codable {
    case none, red, orange, yellow, green, blue, purple, pink

    var label: String { self == .none ? "No colour" : rawValue.capitalized }
    var color: Color? {
        switch self {
        case .none: nil
        case .red: Color(red: 0.93, green: 0.33, blue: 0.31)
        case .orange: Color(red: 0.96, green: 0.58, blue: 0.20)
        case .yellow: Color(red: 0.94, green: 0.76, blue: 0.18)
        case .green: Color(red: 0.27, green: 0.74, blue: 0.40)
        case .blue: Color(red: 0.27, green: 0.55, blue: 0.95)
        case .purple: Color(red: 0.62, green: 0.40, blue: 0.90)
        case .pink: Color(red: 0.93, green: 0.40, blue: 0.64)
        }
    }
}

struct SessionMeta: Codable, Equatable {
    var name: String?
    var pinned = false
    var tag: TagColor = .none
    var isEmpty: Bool { (name ?? "").isEmpty && !pinned && tag == .none }
}

/// Your own names, pins and colour tags for sessions. Stored on this Mac only, never in Copilot's files.
@MainActor
final class MetaStore: ObservableObject {
    static let shared = MetaStore()
    private let key = "sessionMeta.v1"
    @Published private(set) var meta: [String: SessionMeta] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let m = try? JSONDecoder().decode([String: SessionMeta].self, from: data) { meta = m }
    }

    func meta(_ id: String) -> SessionMeta { meta[id] ?? SessionMeta() }

    private func update(_ id: String, _ change: (inout SessionMeta) -> Void) {
        var m = meta(id)
        change(&m)
        meta[id] = m.isEmpty ? nil : m
        if let data = try? JSONEncoder().encode(meta) { UserDefaults.standard.set(data, forKey: key) }
    }

    func rename(_ id: String, to name: String?) {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.name = (t?.isEmpty ?? true) ? nil : t }
    }
    func togglePin(_ id: String) {
        update(id) { $0.pinned.toggle() }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }
    func setTag(_ id: String, _ tag: TagColor) { update(id) { $0.tag = tag } }

    /// Puts your names, pins and tags on top of what Copilot reported.
    func apply(to s: CopilotSession) -> CopilotSession {
        var out = s
        let m = meta(s.id)
        if let n = m.name { out.generatedTitle = s.title; out.title = n }
        out.pinned = m.pinned
        out.tag = m.tag
        return out
    }
}
