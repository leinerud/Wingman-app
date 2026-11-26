import SwiftUI
import AppKit

// Every repository your Copilot sessions have worked in, and the branches they used.
// Names, dates and session counts come from Copilot's own session list, so they work without any folder access.
// Details from the folder on disk (current branch, unsaved changes, ahead/behind) are added when the folder can be read.

// MARK: - Model

struct BranchRow: Identifiable, Hashable {
    var id: String { repo + "|" + name }
    let repo: String
    let name: String
    var sessions = 0
    var lastActive: Date?
    var existsLocally: Bool?          // nil = we couldn't look
    var isCurrent = false
    var upstream: String?
    var track: String?                // "ahead 2, behind 1"
    var dirty = 0                     // unsaved changes in the checkout that has this branch open
    var upstreamKnown = true          // false when git couldn't run, so "not pushed" can't be judged
    var folder: String?

    var isDefault: Bool { ["main", "master", "develop", "development", "trunk"].contains(name) }
    var isNoise: Bool { name.hasPrefix("copilot-prewarm") }
}

struct RepoBranches: Identifiable, Hashable {
    var id: String { name }
    let name: String                  // "owner/repo" or the folder name
    var folders: [String]
    var branches: [BranchRow]
    var needsAccess: Bool             // some folder couldn't be read, so local details are missing
    var basicLocal: Bool              // git couldn't run; local info came straight from .git files
    var lastActive: Date? { branches.compactMap(\.lastActive).max() }
}

private struct LocalBranch { var name: String; var upstream: String?; var track: String?; var date: Date? }
private struct LocalRepo { var current: String?; var dirty = 0; var branches: [LocalBranch] = []; var basic = false }

// MARK: - Loading

enum BranchLoader {
    nonisolated static func load() -> [RepoBranches] {
        let rows = SQLiteReader.rows(path: Access.copilotPath + "/session-store.db",
                                     sql: "SELECT repository, branch, cwd, updated_at FROM sessions ORDER BY updated_at DESC")
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = DateFormatter(); plain.dateFormat = "yyyy-MM-dd HH:mm:ss"; plain.timeZone = TimeZone(identifier: "UTC")

        struct Acc { var folders: [String] = []; var branches: [String: BranchRow] = [:] }
        var repos: [String: Acc] = [:]
        for r in rows {
            let cwd = r["cwd"] ?? ""
            var repo = (r["repository"] ?? "").trimmingCharacters(in: .whitespaces)
            if repo.isEmpty { repo = cwd.isEmpty ? "Unknown" : URL(fileURLWithPath: cwd).lastPathComponent }
            let branch = (r["branch"] ?? "").trimmingCharacters(in: .whitespaces)
            var acc = repos[repo] ?? Acc()
            if !cwd.isEmpty, !acc.folders.contains(cwd) { acc.folders.append(cwd) }
            if !branch.isEmpty {
                var b = acc.branches[branch] ?? BranchRow(repo: repo, name: branch)
                b.sessions += 1
                let when = (r["updated_at"]).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
                if let when, when > (b.lastActive ?? .distantPast) { b.lastActive = when }
                if b.folder == nil, !cwd.isEmpty { b.folder = cwd }
                acc.branches[branch] = b
            }
            repos[repo] = acc
        }

        var out: [RepoBranches] = []
        for (name, acc) in repos {
            var branches = acc.branches
            var needsAccess = false, basic = false
            // Prefer real checkouts over Copilot's temporary worktrees when reading local details.
            let folders = acc.folders.sorted { !$0.contains("copilot-worktrees") && $1.contains("copilot-worktrees") }
            for folder in folders.prefix(6) {
                guard FileManager.default.fileExists(atPath: folder) else { continue }
                guard Access.canRead(folder) else { needsAccess = true; continue }
                guard let local = readLocal(folder) else { continue }
                basic = basic || local.basic
                for lb in local.branches {
                    var b = branches[lb.name] ?? BranchRow(repo: name, name: lb.name)
                    if b.existsLocally == true, b.upstream != nil { continue }
                    b.existsLocally = true
                    if local.basic { b.upstreamKnown = false }
                    b.upstream = lb.upstream ?? b.upstream
                    b.track = lb.track ?? b.track
                    if b.lastActive == nil { b.lastActive = lb.date }
                    if b.folder == nil { b.folder = folder }
                    branches[lb.name] = b
                }
                if let cur = local.current {
                    var b = branches[cur] ?? BranchRow(repo: name, name: cur)
                    b.isCurrent = true; b.dirty = max(b.dirty, local.dirty); b.existsLocally = true; b.folder = folder
                    branches[cur] = b
                }
            }
            // Branches Copilot used that no longer exist in a folder we could read.
            for key in branches.keys where branches[key]?.existsLocally == nil && !needsAccess && !folders.isEmpty {
                branches[key]?.existsLocally = false
            }
            out.append(RepoBranches(name: name, folders: folders, branches: Array(branches.values), needsAccess: needsAccess, basicLocal: basic))
        }
        return out.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    // MARK: Reading a checkout

    private nonisolated static func readLocal(_ cwd: String) -> LocalRepo? {
        if Git.run(["--version"], cwd: cwd) != nil, Git.run(["rev-parse", "--is-inside-work-tree"], cwd: cwd) != nil {
            var repo = LocalRepo()
            repo.current = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if repo.current == "HEAD" { repo.current = nil }
            repo.dirty = (Git.run(["status", "--porcelain"], cwd: cwd) ?? "").split(separator: "\n").count
            let fmt = "%(refname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)"
            for line in (Git.run(["for-each-ref", "--format=" + fmt, "refs/heads"], cwd: cwd) ?? "").split(separator: "\n") {
                let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard p.count == 4 else { continue }
                repo.branches.append(LocalBranch(name: p[0], upstream: p[1].isEmpty ? nil : p[1], track: p[2].isEmpty ? nil : p[2],
                                                 date: TimeInterval(p[3]).map { Date(timeIntervalSince1970: $0) }))
            }
            return repo
        }
        return readBasic(cwd)
    }

    /// No git available: read branch names and the current branch straight from the repository's files.
    private nonisolated static func readBasic(_ cwd: String) -> LocalRepo? {
        let fm = FileManager.default
        var gitDir = cwd + "/.git"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitDir, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {   // a worktree: ".git" is a file pointing at the real folder
            guard let t = try? String(contentsOfFile: gitDir, encoding: .utf8), t.hasPrefix("gitdir:") else { return nil }
            gitDir = t.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var common = gitDir
        if let c = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) {
            let rel = c.trimmingCharacters(in: .whitespacesAndNewlines)
            common = rel.hasPrefix("/") ? rel : URL(fileURLWithPath: gitDir).appendingPathComponent(rel).standardized.path
        }
        var repo = LocalRepo(); repo.basic = true
        if let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8), head.hasPrefix("ref: refs/heads/") {
            repo.current = head.dropFirst(16).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var names: [String: Date?] = [:]
        let headsRoot = common + "/refs/heads"
        if let en = fm.enumerator(atPath: headsRoot) {
            for case let rel as String in en {
                let path = headsRoot + "/" + rel
                var d: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &d), !d.boolValue else { continue }
                names[rel] = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            }
        }
        if let packed = try? String(contentsOfFile: common + "/packed-refs", encoding: .utf8) {
            for line in packed.split(separator: "\n") {
                guard let r = line.range(of: " refs/heads/") else { continue }
                let n = String(line[r.upperBound...])
                if names[n] == nil { names[n] = .some(nil) }
            }
        }
        repo.branches = names.map { LocalBranch(name: $0.key, upstream: nil, track: nil, date: $0.value ?? nil) }
        return repo
    }
}

// MARK: - Store

@MainActor
final class BranchStore: ObservableObject {
    @Published var repos: [RepoBranches] = []
    @Published var loading = false
    @Published var loadedOnce = false

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let result = BranchLoader.load()
            await MainActor.run {
                self.repos = result
                self.loading = false
                self.loadedOnce = true
            }
        }
    }
}

// MARK: - Window

struct BranchesWindow: View {
    @StateObject private var model = BranchStore()
    @EnvironmentObject var store: SessionStore
    @AppStorage("branches.hideMain") private var hideMain = true
    @AppStorage("branches.onlyUnsaved") private var onlyUnsaved = false
    @State private var query = ""

    private func visible(_ r: RepoBranches) -> [BranchRow] {
        r.branches.filter { b in
            if hideMain && (b.isDefault || b.isNoise) && !b.isCurrent && b.dirty == 0 { return false }
            if onlyUnsaved && b.dirty == 0 && (b.track ?? "").isEmpty && (b.upstream != nil || !b.upstreamKnown) { return false }
            if !query.isEmpty && !(b.name + " " + r.name).localizedCaseInsensitiveContains(query) { return false }
            return true
        }
        .sorted { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
        }
    }

    private var shown: [(repo: RepoBranches, rows: [BranchRow])] {
        model.repos.compactMap { r in let rows = visible(r); return rows.isEmpty && (!query.isEmpty || onlyUnsaved) ? nil : (r, rows) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            if !Access.hasCopilotAccess && !model.loadedOnce {
                EmptyNote(symbol: "lock", title: "Allow access to your sessions first", message: "Branches come from your Copilot sessions. Allow the .copilot folder in Settings or the main window.")
            } else if !model.loadedOnce {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                EmptyNote(symbol: "arrow.triangle.branch", title: "No branches to show", message: query.isEmpty ? "Nothing matches the current filters." : "Nothing matches “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                        ForEach(shown, id: \.repo.id) { item in RepoSection(repo: item.repo, rows: item.rows, reload: model.refresh) }
                    }
                    .padding(18)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .background(Palette.canvas)
        .navigationTitle("Branches")
        .onAppear { model.refresh() }
        .onChange(of: store.sessions.first?.updatedAt) { _, _ in model.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Branches").font(.system(size: 15, weight: .semibold))
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            TextField("Search repos and branches", text: $query)
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 190)
            Toggle("Hide main", isOn: $hideMain).toggleStyle(.switch).controlSize(.mini)
                .help("Hide main, master and Copilot's temporary prewarm branches (unless they have unsaved work)")
            Toggle("Needs attention", isOn: $onlyUnsaved).toggleStyle(.switch).controlSize(.mini)
                .help("Only branches with unsaved changes, unpushed work or no remote")
            IconButton(symbol: "arrow.clockwise", help: "Reload", shortcut: "r") { model.refresh() }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var summary: String {
        let repos = model.repos.count
        let branches = model.repos.reduce(0) { $0 + $1.branches.count }
        return model.loadedOnce ? "\(branches) branches in \(repos) repositories from your Copilot sessions" : "Loading…"
    }
}

private struct RepoSection: View {
    let repo: RepoBranches
    let rows: [BranchRow]
    let reload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(repo.name).font(.system(size: 12.5, weight: .semibold))
                Text("\(rows.count)").font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                if repo.needsAccess, let f = repo.folders.first(where: { !Access.canRead($0) }) {
                    Button("Show local details…") { if Access.requestProjectFolder(for: f) { reload() } }
                        .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                        .help("Allow this project folder to see unsaved changes and whether each branch still exists")
                }
                if let f = repo.folders.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    IconButton(symbol: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
                }
                if let url = URL(string: "https://github.com/\(repo.name)"), repo.name.contains("/") {
                    IconButton(symbol: "arrow.up.right.square", help: "Open on GitHub") { NSWorkspace.shared.open(url) }
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, b in
                    BranchLine(row: b)
                    if i < rows.count - 1 { Divider().opacity(0.4) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Palette.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }
}

private struct BranchLine: View {
    let row: BranchRow
    @State private var hover = false
    @State private var copied: String?

    private var folderURL: URL? {
        guard let f = row.folder, FileManager.default.fileExists(atPath: f) else { return nil }
        return URL(fileURLWithPath: f)
    }
    private func github(_ path: String) -> URL? {
        row.repo.contains("/") ? URL(string: "https://github.com/\(row.repo)\(path)") : nil
    }
    private var encodedName: String { row.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? row.name }
    private var encodedQuery: String { row.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? row.name }
    private var branchURL: URL? { github("/tree/\(encodedName)") }
    private var pullsURL: URL? { github("/pulls?q=is%3Apr+head%3A\(encodedQuery)") }
    private var compareURL: URL? { github("/compare/\(encodedName)") }

    // MARK: Actions (the same list is used by the ⋯ menu and by right-click)

    private func openApp(_ bundleID: String) {
        guard let dir = folderURL, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([dir], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copied = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == label { copied = nil } }
    }

    @ViewBuilder private var actions: some View {
        Button { if let u = branchURL { NSWorkspace.shared.open(u) } } label: { Label("Open branch on GitHub", systemImage: "arrow.up.right.square") }
            .disabled(branchURL == nil)
        Button { if let u = pullsURL { NSWorkspace.shared.open(u) } } label: { Label("Show pull requests for this branch", systemImage: "arrow.triangle.pull") }
            .disabled(pullsURL == nil)
        Button { if let u = compareURL { NSWorkspace.shared.open(u) } } label: { Label("Compare or open a pull request on GitHub", systemImage: "arrow.left.arrow.right") }
            .disabled(compareURL == nil)
        Divider()
        Button { if let d = folderURL { NSWorkspace.shared.activateFileViewerSelecting([d]) } } label: { Label("Show project folder in Finder", systemImage: "folder") }
            .disabled(folderURL == nil)
        Button { openApp("com.microsoft.VSCode") } label: { Label("Open in code editor", systemImage: "chevron.left.forwardslash.chevron.right") }
            .disabled(folderURL == nil)
        Button { openApp("com.apple.Terminal") } label: { Label("Open in Terminal", systemImage: "terminal") }
            .disabled(folderURL == nil)
        Divider()
        Button { copy(row.name, label: "name") } label: { Label("Copy branch name", systemImage: "doc.on.doc") }
        Button { copy("git -C \"\(row.folder ?? ".")\" switch \(row.name)", label: "command") } label: { Label("Copy command to switch to this branch", systemImage: "terminal.fill") }
            .disabled(row.folder == nil || row.existsLocally == false)
        Button { if let u = branchURL { copy(u.absoluteString, label: "link") } } label: { Label("Copy GitHub link", systemImage: "link") }
            .disabled(branchURL == nil)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(row.isCurrent ? Palette.working : Palette.muted).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if row.isCurrent { chip("Checked out", Palette.working, "This branch is open in the project folder right now") }
                    if row.dirty > 0 { chip("\(row.dirty) unsaved", Palette.attention, "\(row.dirty) files have changes that aren't saved as a version yet") }
                    if let t = row.track, !t.isEmpty { chip(t, Palette.attention, "Compared with the same branch on GitHub") }
                    if row.existsLocally == true, row.upstream == nil, row.upstreamKnown { chip("Not pushed", Palette.attention, "This branch only exists on your Mac. It has not been sent to GitHub") }
                    if row.existsLocally == false { chip("Not on this Mac", Palette.muted, "Copilot used this branch, but it is gone from the project folder (often a temporary workspace that was cleaned up)") }
                }
                HStack(spacing: 5) {
                    if let c = copied { Text("Copied \(c)").foregroundStyle(Palette.ready) }
                    else {
                        if let d = row.lastActive { Text(d, format: .relative(presentation: .named, unitsStyle: .abbreviated)) }
                        if row.sessions > 0 { Text("· \(row.sessions) \(row.sessions == 1 ? "session" : "sessions")") }
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                IconButton(symbol: "arrow.up.right.square", help: "Open this branch on GitHub") { if let u = branchURL { NSWorkspace.shared.open(u) } }
                    .disabled(branchURL == nil)
                IconButton(symbol: "folder", help: "Show the project folder in Finder") { if let d = folderURL { NSWorkspace.shared.activateFileViewerSelecting([d]) } }
                    .disabled(folderURL == nil)
                IconButton(symbol: "doc.on.doc", help: "Copy the branch name") { copy(row.name, label: "name") }
                Menu { actions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11.5, weight: .semibold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26, height: 26)
                .help("More actions: pull requests, compare, open in editor or Terminal, copy a switch command. Right-click the row for the same menu.")
            }.opacity(hover ? 1 : 0.45)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.well.opacity(hover ? 0.5 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open on GitHub") { if let u = branchURL { NSWorkspace.shared.open(u) } }
        .accessibilityAction(named: "Copy branch name") { copy(row.name, label: "name") }
    }

    private func chip(_ text: String, _ tint: Color, _ help: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(tint.opacity(0.13)))
            .help(help)
    }
}
