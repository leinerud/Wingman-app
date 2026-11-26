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
        if Demo.isOn { return Demo.details(row) }
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

// MARK: - Plain language

/// Turns developer wording into something a designer can read at a glance.
enum PlainWords {
    /// "feat(ux): add prototype links" -> "Add prototype links"; "chore(deps): bump x" -> "Updated dependencies".
    static func change(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        var type = ""
        if let colon = t.firstIndex(of: ":"), t.distance(from: t.startIndex, to: colon) <= 24 {
            let head = t[..<colon]
            if head.range(of: #"^[a-zA-Z]+(\([^)]*\))?!?$"#, options: .regularExpression) != nil {
                type = String(head.prefix { $0.isLetter }).lowercased()
                t = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        if type == "chore" && (raw.contains("(deps") || t.lowercased().hasPrefix("bump")) { return "Updated libraries the project uses" }
        if type == "revert" || t.lowercased().hasPrefix("revert") {
            t = t.replacingOccurrences(of: #"^[Rr]evert:?\s*"?"#, with: "", options: .regularExpression)
            return "Undid: " + t.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        if t.lowercased().hasPrefix("merge ") { return "Brought in changes from another branch" }
        t = t.replacingOccurrences(of: #"\s*\(#\d+\)$"#, with: "", options: .regularExpression)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    enum Area: Int, CaseIterable {
        case pages, components, layouts, styles, images, text, tests, setup, code
        var title: String {
            switch self {
            case .pages: "Pages and screens"; case .components: "Components"; case .layouts: "Layouts"
            case .styles: "Styles and tokens"; case .images: "Images and assets"; case .text: "Text and docs"
            case .tests: "Tests"; case .setup: "Project setup"; case .code: "Other code"
            }
        }
        var symbol: String {
            switch self {
            case .pages: "rectangle.on.rectangle"; case .components: "square.on.square"; case .layouts: "rectangle.3.group"
            case .styles: "paintpalette"; case .images: "photo"; case .text: "text.alignleft"
            case .tests: "checkmark.seal"; case .setup: "gearshape"; case .code: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    static func area(_ path: String) -> Area {
        let p = "/" + path.lowercased()
        let name = (p as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if name.contains(".test.") || name.contains(".spec.") || p.contains("/__tests__/") || p.contains("/tests/") { return .tests }
        if ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "woff", "woff2", "ttf", "otf", "mp4", "pdf"].contains(ext) { return .images }
        if ["css", "scss", "sass", "less"].contains(ext) || p.contains("token") || p.contains("/theme") || p.contains("/styles/") { return .styles }
        if ["md", "mdx", "txt"].contains(ext) || p.contains("/content/") || p.contains("/docs/") { return .text }
        if p.contains("/pages/") || p.contains("/screens/") || p.contains("/views/") || p.contains("/routes/") || p.contains("/app/") { return .pages }
        if p.contains("/components/") || p.contains("/ui/") { return .components }
        if p.contains("/layouts/") || p.contains("/layout/") { return .layouts }
        if ["json", "yml", "yaml", "lock", "toml", "env", "plist", "xcconfig"].contains(ext) || name.hasPrefix(".") || name.contains("config") { return .setup }
        return .code
    }

    /// "src/pages/AiToolsGuide.tsx" -> "Ai Tools Guide"; "src/components/index.ts" -> "Components (index)".
    static func name(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        var base = file
        while !(base as NSString).pathExtension.isEmpty { base = (base as NSString).deletingPathExtension }
        if ["index", "skill", "readme"].contains(base.lowercased()) {
            let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !folder.isEmpty { return words(folder) + " (" + base.lowercased() + ")" }
        }
        return words(base)
    }

    private static func words(_ s: String) -> String {
        var out = ""
        var prev: Character?
        for c in s {
            if c == "-" || c == "_" || c == "." { out.append(" "); prev = " "; continue }
            if let p = prev, c.isUppercase, p.isLowercase || p.isNumber { out.append(" ") }
            out.append(c); prev = c
        }
        let t = out.split(separator: " ").joined(separator: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    static func size(files: Int, lines: Int) -> String {
        let kind = lines == 0 ? (files <= 3 ? "Small" : "Medium") : lines < 60 ? "Small" : lines < 400 ? "Medium" : "Large"
        let filePart = files == 1 ? "1 file" : "\(files) files"
        return lines > 0 ? "\(kind) change · \(filePart) · about \(lines) lines" : "\(kind) change · \(filePart)"
    }
}

/// The expanded "What's in it" part of a branch row, in plain language with the technical list one click away.
struct BranchDetailsPanel: View {
    let row: BranchRow
    @State private var details: BranchDetails?
    @State private var showTechnical = false

    /// The work counts as being in main when git or GitHub says so, even if a squash merge hides the exact versions.
    private var inMain: Bool { row.merged == true || row.remoteGone }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let d = details {
                if d.isEmpty && !d.readGit {
                    Text("This branch isn't on your Mac, and no Copilot chat is linked to it.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                status(d)
                whatItDid(d)
                touched(d.files, title: "What it touched", trailing: d.files.isEmpty ? nil : PlainWords.size(files: d.files.count + d.moreFiles, lines: d.added + d.removed))
                if !d.unsaved.isEmpty {
                    touched(d.unsaved, title: "Edited on your Mac, not saved yet", trailing: "\(d.unsaved.count + d.moreUnsaved) files", tint: Palette.attention)
                }
                chats(d)
                if !d.changes.isEmpty || !d.latest.isEmpty || !d.files.isEmpty || !d.unsaved.isEmpty { technical(d) }
                if !d.readGit, row.existsLocally != false {
                    Text("Allow the project folder to see what changed.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Looking…").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.well.opacity(0.55)))
        .task(id: row.id) {
            let r = row
            details = await Task.detached(priority: .userInitiated) { BranchDetailsLoader.load(r) }.value
        }
    }

    // MARK: Parts

    /// One line that says where the work stands.
    @ViewBuilder private func status(_ d: BranchDetails) -> some View {
        let n = d.changes.count + d.moreChanges
        let (text, symbol, tint): (String, String, Color) =
            row.isDefault ? ("This is the main version itself.", "star", Palette.muted)
            : inMain ? ("This work is in main.", "checkmark.circle.fill", Palette.ready)
            : n > 0 ? (n == 1 ? "1 saved change that isn't in main yet." : "\(n) saved changes that aren't in main yet.", "clock", Palette.working)
            : d.readGit ? ("Nothing saved on this branch yet.", "circle.dashed", Palette.muted)
            : ("", "", .clear)
        if !text.isEmpty {
            Label { Text(text).font(.system(size: 12.5, weight: .semibold)) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
        }
    }

    /// The saved changes as plain sentences; falls back to what the Copilot chats were about.
    @ViewBuilder private func whatItDid(_ d: BranchDetails) -> some View {
        let source = d.changes.isEmpty ? d.latest : d.changes
        var seen = Set<String>()
        let lines = source.map { PlainWords.change($0.title) }.filter { seen.insert($0.lowercased()).inserted }
        if !lines.isEmpty {
            block(row.isDefault ? "Latest changes" : "What it did") {
                ForEach(Array(lines.prefix(5).enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        Text(l).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if lines.count > 5 { Text("and \(lines.count - 5) more").foregroundStyle(.tertiary) }
            }
        }
    }

    /// Files grouped by what they are for a designer: pages, components, styles and so on.
    @ViewBuilder private func touched(_ files: [BranchDetails.File], title: String, trailing: String?, tint: Color = .secondary) -> some View {
        if !files.isEmpty {
            let groups = Dictionary(grouping: files) { PlainWords.area($0.path) }
            block(title, trailing: trailing, tint: tint) {
                ForEach(PlainWords.Area.allCases.filter { groups[$0] != nil }, id: \.rawValue) { area in
                    let items = groups[area] ?? []
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(area.title, systemImage: area.symbol)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)
                        Text(names(items)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func names(_ files: [BranchDetails.File]) -> AttributedString {
        var out = AttributedString()
        for (i, f) in files.prefix(6).enumerated() {
            if i > 0 { out += AttributedString(", ") }
            out += AttributedString(PlainWords.name(f.path))
            if f.kind == "added" || f.kind == "new" || f.kind == "removed" {
                var tag = AttributedString(f.kind == "removed" ? " (removed)" : " (new)")
                tag.foregroundColor = f.kind == "removed" ? Palette.attention : Palette.ready
                out += tag
            }
        }
        if files.count > 6 {
            var more = AttributedString(" and \(files.count - 6) more")
            more.foregroundColor = .secondary
            out += more
        }
        return out
    }

    @ViewBuilder private func chats(_ d: BranchDetails) -> some View {
        if !d.sessions.isEmpty {
            block(d.sessions.count == 1 ? "Worked on in 1 Copilot chat" : "Worked on in \(d.sessions.count) Copilot chats") {
                ForEach(d.sessions) { s in
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(PlainWords.change(s.title)).lineLimit(1).truncationMode(.tail)
                        if s.closed { Text("closed").font(.system(size: 10)).foregroundStyle(.tertiary) }
                        Spacer(minLength: 6)
                        if let date = s.date { Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated)).foregroundStyle(.tertiary).fixedSize() }
                    }
                }
            }
        }
    }

    /// The original lists (version messages and file paths), for when you need the exact details.
    private func technical(_ d: BranchDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.2)) { showTechnical.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(showTechnical ? 90 : 0))
                    Text("Show files and versions")
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("The exact saved versions and file paths, as git lists them")
            if showTechnical {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(d.changes.isEmpty ? d.latest : d.changes) { c in
                        HStack(spacing: 6) {
                            Text(c.title).lineLimit(1).textSelection(.enabled)
                            Spacer(minLength: 6)
                            if let date = c.date { Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated)).foregroundStyle(.tertiary).fixedSize() }
                        }
                    }
                    if !(d.changes.isEmpty && d.latest.isEmpty) { Divider().opacity(0.4).padding(.vertical, 3) }
                    ForEach(d.files + d.unsaved) { f in
                        HStack(spacing: 6) {
                            Text(f.kind).foregroundStyle(.tertiary).frame(width: 52, alignment: .leading)
                            Text(f.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.leading, 12)
            }
        }
    }

    private func block<C: View>(_ title: String, trailing: String? = nil, tint: Color = .secondary, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Spacer(minLength: 6)
                if let trailing { Text(trailing).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            VStack(alignment: .leading, spacing: 4) { content() }
                .font(.system(size: 12))
        }
    }
}
