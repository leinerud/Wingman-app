import SwiftUI
import AppKit

// "What's in it": what has been done on a branch, in plain words. Everything here only READS git and Copilot's data.

struct BranchDetails {
    struct Change: Identifiable { let id = UUID(); let title: String; let date: Date? }
    struct File: Identifiable { let id = UUID(); let kind: String; let path: String }
    struct Session: Identifiable { let id = UUID(); let title: String; let date: Date?; let closed: Bool }

    var changes: [Change] = []          // saved changes (commits) that main doesn't have yet
    var latest: [Change] = []           // when everything is already in main: the branch's last changes
    var moreChanges = 0
    var files: [File] = []              // files that differ from main
    var moreFiles = 0
    var added = 0, removed = 0          // lines
    var unsaved: [File] = []            // edits not saved as a version yet
    var moreUnsaved = 0
    var sessions: [Session] = []        // Copilot sessions and workspaces on this branch
    var prs: [Int] = []
    var readGit = false                 // false when the branch isn't on this Mac or git can't run

    var isEmpty: Bool { changes.isEmpty && latest.isEmpty && files.isEmpty && unsaved.isEmpty && sessions.isEmpty }
}

enum BranchDetailsLoader {
    nonisolated static func load(_ row: BranchRow) -> BranchDetails {
        var d = BranchDetails()
        d.prs = row.prs

        if row.existsLocally == true, let folder = row.folder, FileManager.default.fileExists(atPath: folder),
           Git.run(["--version"], cwd: folder) != nil {
            d.readGit = true
            let ref = "refs/heads/" + row.name
            let fmt = "--format=%s%x1f%ct"
            func changes(_ args: [String]) -> [BranchDetails.Change] {
                (Git.run(["log", "--no-merges", fmt] + args, cwd: folder) ?? "").split(separator: "\n").map { line in
                    let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                    return .init(title: p.first ?? "", date: p.count > 1 ? TimeInterval(p[1]).map { Date(timeIntervalSince1970: $0) } : nil)
                }
            }
            if let base = row.defaultName, !row.isDefault {
                let all = changes([base + ".." + ref])
                d.changes = Array(all.prefix(12)); d.moreChanges = max(0, all.count - 12)
                // Merged: show what it last did. A new branch with nothing saved yet would only list main's own changes.
                if all.isEmpty && (row.merged == true || row.remoteGone) { d.latest = changes(["--max-count=3", ref]) }
                // Files compared with where the branch started from main.
                let lines = (Git.run(["diff", "--name-status", "--no-renames", base + "..." + ref], cwd: folder) ?? "").split(separator: "\n")
                d.files = lines.prefix(15).compactMap(file); d.moreFiles = max(0, lines.count - 15)
                for line in (Git.run(["diff", "--numstat", base + "..." + ref], cwd: folder) ?? "").split(separator: "\n") {
                    let p = line.split(separator: "\t")
                    if p.count >= 2 { d.added += Int(p[0]) ?? 0; d.removed += Int(p[1]) ?? 0 }
                }
            } else {
                d.latest = changes(["--max-count=5", ref])
            }
            if row.isCurrent {
                let lines = (Git.run(["status", "--porcelain", "--untracked-files=normal"], cwd: folder) ?? "").split(separator: "\n")
                d.unsaved = lines.prefix(12).compactMap { l in
                    let s = String(l); guard s.count > 3 else { return nil }
                    let code = s.prefix(2).trimmingCharacters(in: .whitespaces)
                    return .init(kind: code == "??" ? "new" : code.contains("D") ? "removed" : code.contains("A") ? "added" : "changed",
                                 path: String(s.dropFirst(3)))
                }
                d.moreUnsaved = max(0, lines.count - 12)
            }
        }

        d.sessions = sessions(repo: row.repo, branch: row.name)
        return d
    }

    private nonisolated static func file(_ line: Substring) -> BranchDetails.File? {
        let p = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard p.count == 2 else { return nil }
        let kind = switch p[0].prefix(1) { case "A": "added"; case "D": "removed"; default: "changed" }
        return .init(kind: kind, path: p[1])
    }

    /// Sessions from Copilot's session list and workspaces from the Copilot app, newest first, without duplicates.
    private nonisolated static func sessions(repo: String, branch: String) -> [BranchDetails.Session] {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = DateFormatter(); plain.dateFormat = "yyyy-MM-dd HH:mm:ss"; plain.timeZone = TimeZone(identifier: "UTC")
        func date(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) ?? plain.date(from: $0) } }
        let repoFilter = repo.contains("/") ? " AND (repository IS NULL OR repository = \(q(repo)))" : ""

        var out: [BranchDetails.Session] = []
        for r in SQLiteReader.rows(path: Access.copilotPath + "/data.db", sql: """
            SELECT w.name AS title, w.updated_at AS updated, w.archived_at AS archived
            FROM workspaces w LEFT JOIN workspace_checkout_bindings b ON b.workspace_id = w.id
            WHERE w.branch = \(q(branch))\(repo.contains("/") ? " AND (b.repo_full_name IS NULL OR b.repo_full_name = \(q(repo)))" : "")
            """) {
            if let t = r["title"], !t.isEmpty { out.append(.init(title: t, date: date(r["updated"]), closed: r["archived"] != nil)) }
        }
        for r in SQLiteReader.rows(path: Access.copilotPath + "/session-store.db",
                                   sql: "SELECT summary, updated_at FROM sessions WHERE branch = \(q(branch))\(repoFilter)") {
            if let t = cleanTitle(r["summary"]) { out.append(.init(title: t, date: date(r["updated_at"]), closed: false)) }
        }
        var seen = Set<String>()
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .filter { seen.insert($0.title.lowercased()).inserted && $0.title != "New session" }
            .prefix(8).map { $0 }
    }

    private nonisolated static func cleanTitle(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        for prefix in ["The user asked: ", "The user wants ", "The user’s request was: ", "The user's request was: ", "The user "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)); break
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' ")).replacingOccurrences(of: "\n", with: " ")
        return t.count > 120 ? String(t.prefix(120)) + "…" : t
    }
}

/// The expanded "What's in it" part of a branch row.
struct BranchDetailsPanel: View {
    let row: BranchRow
    @State private var details: BranchDetails?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = details {
                if d.isEmpty && !d.readGit {
                    Text("This branch isn't on your Mac, and no Copilot session is linked to it.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if !d.changes.isEmpty {
                    section("Saved changes not in main yet", count: d.changes.count + d.moreChanges, symbol: "clock.arrow.circlepath") {
                        ForEach(d.changes) { changeLine($0) }
                        more(d.moreChanges, "change")
                    }
                } else if d.readGit && d.latest.isEmpty && !row.isDefault {
                    Label("No saved changes of its own yet", systemImage: "circle.dashed")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                } else if !d.latest.isEmpty {
                    section(row.isDefault ? "Latest changes" : "Already in main. Its last changes were", count: nil, symbol: "checkmark.circle") {
                        ForEach(d.latest) { changeLine($0) }
                    }
                }
                if !d.files.isEmpty {
                    section("Files changed compared with main", count: d.files.count + d.moreFiles, symbol: "doc.on.doc",
                            trailing: d.added + d.removed > 0 ? "+\(d.added) −\(d.removed) lines" : nil) {
                        ForEach(d.files) { fileLine($0) }
                        more(d.moreFiles, "file")
                    }
                }
                if !d.unsaved.isEmpty {
                    section("Unsaved on your Mac", count: d.unsaved.count + d.moreUnsaved, symbol: "pencil", tint: Palette.attention) {
                        ForEach(d.unsaved) { fileLine($0) }
                        more(d.moreUnsaved, "file")
                    }
                }
                if !d.sessions.isEmpty {
                    section("Copilot sessions on this branch", count: d.sessions.count, symbol: "sparkles") {
                        ForEach(d.sessions) { s in
                            HStack(spacing: 6) {
                                Text(s.title).lineLimit(1).truncationMode(.tail)
                                if s.closed { Text("closed").font(.system(size: 10)).foregroundStyle(.tertiary) }
                                Spacer(minLength: 6)
                                if let date = s.date { Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated)).foregroundStyle(.tertiary).fixedSize() }
                            }
                        }
                    }
                }
                if !d.readGit, row.existsLocally != false {
                    Text("Allow the project folder to see saved changes and files.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.well.opacity(0.55)))
        .task(id: row.id) {
            let r = row
            details = await Task.detached(priority: .userInitiated) { BranchDetailsLoader.load(r) }.value
        }
    }

    private func section<C: View>(_ title: String, count: Int?, symbol: String, tint: Color = .secondary, trailing: String? = nil,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let count { Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary) }
                Spacer(minLength: 6)
                if let trailing { Text(trailing).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary) }
            }
            VStack(alignment: .leading, spacing: 3) { content() }
                .font(.system(size: 11.5))
                .padding(.leading, 15)
        }
    }

    private func changeLine(_ c: BranchDetails.Change) -> some View {
        HStack(spacing: 6) {
            Text(c.title).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            Spacer(minLength: 6)
            if let d = c.date { Text(d, format: .relative(presentation: .named, unitsStyle: .abbreviated)).foregroundStyle(.tertiary).fixedSize() }
        }
    }

    private func fileLine(_ f: BranchDetails.File) -> some View {
        let tint: Color = f.kind == "removed" ? Palette.attention : f.kind == "added" || f.kind == "new" ? Palette.ready : .secondary
        let name = (f.path as NSString).lastPathComponent
        let dir = (f.path as NSString).deletingLastPathComponent
        return HStack(spacing: 6) {
            Text(f.kind).font(.system(size: 10, weight: .medium)).foregroundStyle(tint).frame(width: 52, alignment: .leading)
            Text(name).lineLimit(1)
            if !dir.isEmpty { Text(dir).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
            Spacer(minLength: 0)
        }
        .help(f.path)
    }

    @ViewBuilder private func more(_ n: Int, _ noun: String) -> some View {
        if n > 0 { Text("and \(n) more \(n == 1 ? noun : noun + "s")").foregroundStyle(.tertiary) }
    }
}
