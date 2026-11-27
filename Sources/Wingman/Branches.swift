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
    var defaultName: String?          // the branch everything is compared with, e.g. "origin/main"
    var ahead: Int?                   // commits on this branch that main doesn't have
    var merged: Bool?                 // nil = couldn't tell (no git)
    var sessionActive = false         // a Copilot session is working on it right now
    var onGitHub: Bool?               // is there a branch of this name on GitHub (as of the last fetch)? nil = couldn't tell
    var prs: [Int] = []               // pull requests Copilot opened for this branch (from the session list)
    var topic: String?                // what the latest session on this branch was about
    var commits = 0                   // how many changes Copilot saved while working on it (from the session list)
    var copilot: CopilotWorkspace?    // the GitHub Copilot app's workspace for this branch; nil = it has none we know of
    var folder: String?

    var isDefault: Bool { ["main", "master", "develop", "development", "trunk"].contains(name) }
    var isNoise: Bool { name.hasPrefix("copilot-prewarm") || name.hasPrefix("copilot/prewarm") }
    var remoteGone: Bool { track == "gone" }

    /// Finished work that can be cleaned up: merged into main (or its GitHub branch was deleted after a merge),
    /// with nothing unsaved and no session using it.
    var closeable: Bool { !isDefault && (merged == true || remoteGone) && dirty == 0 && !sessionActive }
    var touchedRecently: Bool { !isDefault && (lastActive ?? .distantPast) > Date().addingTimeInterval(-7 * 86400) }
    /// What you are actually working on: unsaved changes, a live session, checked out, or touched this week.
    var working: Bool { !closeable && (dirty > 0 || sessionActive || (isCurrent && !isDefault) || touchedRecently) }
}

/// Whether the GitHub Copilot app still has a workspace open for a branch.
enum CopilotWorkspace { case active, closed }

/// A suggested next step for a branch, in plain language, for people who don't use git.
struct Advice {
    enum Tone { case done, check, decide, nothing, needsInfo }
    enum Action { case openPR, compare, openCopilot, remove, allowFolder }
    let tone: Tone
    let headline: String
    let detail: String
    let action: Action?
    let actionLabel: String?
}

extension BranchRow {
    /// GitHub answers “Page not found” for a private repo when the browser is signed in with an account that can't see it
    /// (common with work accounts such as name_company next to a personal one).
    static let signInHint = "If GitHub says “Page not found”, your browser is signed in with a GitHub account that can't see this project. Sign in with your work account and try again."
    /// What to do about this branch. Nil for branches you are actively working on.
    func advice(repoNeedsAccess: Bool) -> Advice? {
        if working { return nil }
        let removable = BranchCleanup.blocker(self) == nil
        if closeable {
            return Advice(tone: .done, headline: "Done. Safe to close.",
                          detail: copilot == .closed
                            ? "This work is already part of the main version and it is closed in Copilot. Only the copy on your Mac is left."
                            : "This work is already part of the main version, so the separate copy isn't needed any more.",
                          action: removable ? .remove : nil, actionLabel: removable ? "Remove from this Mac…" : nil)
        }
        if !prs.isEmpty {
            return Advice(tone: .check, headline: "Check its pull request",
                          detail: "A pull request is how work gets reviewed and added to main. Open it: if it says “Merged”, this branch can be closed. If it is still open, it is waiting for someone to review it. \(Self.signInHint)",
                          action: .openPR, actionLabel: "Open its pull request")
        }
        if existsLocally == false {
            if commits == 0 {
                return Advice(tone: .nothing, headline: "Nothing to do",
                              detail: "Copilot never saved any changes here, and its temporary workspace is gone. There is nothing left to keep.",
                              action: nil, actionLabel: nil)
            }
            if onGitHub == true {
                return Advice(tone: .decide, headline: "Decide: ask for a review or leave it",
                              detail: "The work is on GitHub but nobody has been asked to review it. If it should become part of the product, open a pull request.",
                              action: .compare, actionLabel: "Ask for a review")
            }
            return Advice(tone: .nothing, headline: "Probably nothing to keep",
                          detail: "Copilot saved changes here, but the workspace is gone and, as far as this Mac can tell, they never reached GitHub. If you still want this work, start a new Copilot session and ask for it again.",
                          action: nil, actionLabel: nil)
        }
        if existsLocally == true {
            if onGitHub == true {
                return Advice(tone: .decide, headline: "Decide: ask for a review or leave it",
                              detail: "The work is on GitHub but nobody has been asked to review it. If it should become part of the product, open a pull request.",
                              action: .compare, actionLabel: "Ask for a review")
            }
            if (ahead ?? commits) > 0 {
                let closed = copilot == .closed
                return Advice(tone: .decide, headline: "Decide: finish it or let it go",
                              detail: closed
                                ? "This work only exists on your Mac, and it is closed in Copilot. To finish it, reopen it in Copilot (Restore) and ask it to open a pull request. If you don't need it, remove it."
                                : "This work only exists on your Mac. To finish it, open it in Copilot and ask it to open a pull request. If you don't need it, remove it.",
                              action: .openCopilot, actionLabel: closed ? "Reopen in GitHub Copilot" : "Open in GitHub Copilot")
            }
            return Advice(tone: .nothing, headline: "Empty. Safe to remove.",
                          detail: "Nothing was changed on this branch, so removing it loses nothing.",
                          action: removable ? .remove : nil, actionLabel: removable ? "Remove from this Mac…" : nil)
        }
        return Advice(tone: .needsInfo, headline: repoNeedsAccess ? "Allow the project folder to get advice" : "Not enough information yet",
                      detail: "To say whether this is finished, the app needs to look at the project folder on your Mac.",
                      action: repoNeedsAccess ? .allowFolder : nil, actionLabel: repoNeedsAccess ? "Allow folder…" : nil)
    }
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

private struct LocalBranch { var name: String; var upstream: String?; var track: String?; var date: Date?; var ahead: Int?; var merged: Bool? }
private struct LocalRepo { var current: String?; var dirty = 0; var branches: [LocalBranch] = []; var basic = false; var defaultName: String?; var remotes: Set<String> = [] }

// MARK: - Loading

enum BranchLoader {
    nonisolated static func load() -> [RepoBranches] {
        if Demo.isOn { return Demo.repos }
        let rows = SQLiteReader.rows(path: Access.copilotPath + "/session-store.db",
                                     sql: "SELECT repository, branch, cwd, summary, updated_at FROM sessions ORDER BY updated_at DESC")
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
                if b.topic == nil { b.topic = cleanTopic(r["summary"]) }   // rows are newest first
                acc.branches[branch] = b
            }
            repos[repo] = acc
        }

        // Pull requests Copilot recorded per branch. A PR page always exists, even if the branch has since been removed.
        var prMap: [String: Set<Int>] = [:]
        for row in SQLiteReader.rows(path: Access.copilotPath + "/session-store.db", sql: """
            SELECT s.repository AS repository, s.branch AS branch, r.ref_value AS value FROM session_refs r
            JOIN sessions s ON s.id = r.session_id WHERE r.ref_type = 'pr'
            """) {
            if let repo = row["repository"], let b = row["branch"], let n = row["value"].flatMap({ Int($0) }) { prMap[repo + "|" + b, default: []].insert(n) }
        }

        // How many changes Copilot saved per branch (zero means it never got as far as saving anything).
        var commitMap: [String: Int] = [:]
        for row in SQLiteReader.rows(path: Access.copilotPath + "/session-store.db", sql: """
            SELECT s.repository AS repository, s.branch AS branch, COUNT(DISTINCT r.ref_value) AS n FROM session_refs r
            JOIN sessions s ON s.id = r.session_id WHERE r.ref_type = 'commit' GROUP BY s.repository, s.branch
            """) {
            if let repo = row["repository"], let b = row["branch"], let n = row["n"].flatMap({ Int($0) }) { commitMap[repo + "|" + b] = n }
        }

        // The GitHub Copilot app's own workspaces: active if any workspace on the branch isn't archived.
        var copilotMap: [String: CopilotWorkspace] = [:]
        for row in SQLiteReader.rows(path: Access.copilotPath + "/data.db", sql: """
            SELECT w.branch AS branch, b.repo_full_name AS repo, w.archived_at AS archived
            FROM workspaces w LEFT JOIN workspace_checkout_bindings b ON b.workspace_id = w.id
            """) {
            guard let b = row["branch"], !b.isEmpty else { continue }
            let state: CopilotWorkspace = row["archived"] == nil ? .active : .closed
            for key in [(row["repo"] ?? "") + "|" + b, "|" + b] where copilotMap[key] != .active { copilotMap[key] = state }
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
                    // The folder git actually found the branch in. Copilot's session folder is often a temporary
                    // worktree that has since been deleted, so it can't be used for actions on the branch.
                    if b.existsLocally != true { b.folder = folder }
                    b.existsLocally = true
                    if local.basic { b.upstreamKnown = false }
                    b.upstream = lb.upstream ?? b.upstream
                    b.track = lb.track ?? b.track
                    b.ahead = lb.ahead ?? b.ahead
                    b.merged = lb.merged ?? b.merged
                    b.defaultName = local.defaultName ?? b.defaultName
                    if b.lastActive == nil { b.lastActive = lb.date }
                    if b.folder == nil { b.folder = folder }
                    branches[lb.name] = b
                }
                // Which branch names exist on GitHub, as far as this folder knows from its last fetch.
                for key in Array(branches.keys) {
                    let known = branches[key]?.onGitHub ?? false
                    branches[key]?.onGitHub = known || local.remotes.contains(key)
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
            for key in Array(branches.keys) {
                branches[key]?.prs = (prMap[name + "|" + key] ?? []).sorted()
                branches[key]?.commits = commitMap[name + "|" + key] ?? 0
                let isDefault = branches[key]?.isDefault == true
                branches[key]?.copilot = copilotMap[name + "|" + key] ?? (isDefault ? nil : copilotMap["|" + key])
            }
            out.append(RepoBranches(name: name, folders: folders, branches: Array(branches.values), needsAccess: needsAccess, basicLocal: basic))
        }
        return out.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// "The user asked: “add the A40 asset…”" -> "add the A40 asset…"
    private nonisolated static func cleanTopic(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        for prefix in ["The user asked: ", "The user wants ", "The user "] where t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)); break }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' "))
        t = t.replacingOccurrences(of: "\n", with: " ")
        return t.count > 140 ? String(t.prefix(140)) + "…" : t
    }

    // MARK: Reading a checkout

    private nonisolated static func readLocal(_ cwd: String) -> LocalRepo? {
        if Git.run(["--version"], cwd: cwd) != nil, Git.run(["rev-parse", "--is-inside-work-tree"], cwd: cwd) != nil {
            var repo = LocalRepo()
            repo.current = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if repo.current == "HEAD" { repo.current = nil }
            repo.dirty = (Git.run(["status", "--porcelain"], cwd: cwd) ?? "").split(separator: "\n").count
            // What "merged" means: contained in the project's main branch (as it is on GitHub when we know it).
            let base = defaultRef(cwd)
            repo.defaultName = base
            var fmt = "%(refname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)"
            if let base { fmt += "%1f%(ahead-behind:\(base))" }
            var out = Git.run(["for-each-ref", "--format=" + fmt, "refs/heads"], cwd: cwd)
            if out == nil, base != nil {   // older git without ahead-behind: use --merged instead
                fmt = "%(refname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:unix)"
                out = Git.run(["for-each-ref", "--format=" + fmt, "refs/heads"], cwd: cwd)
            }
            let mergedSet: Set<String> = base.flatMap { b in
                Git.run(["for-each-ref", "--merged=" + b, "--format=%(refname:short)", "refs/heads"], cwd: cwd)
            }.map { Set($0.split(separator: "\n").map(String.init)) } ?? []
            for line in (Git.run(["for-each-ref", "--format=%(refname)", "refs/remotes"], cwd: cwd) ?? "").split(separator: "\n") {
                // refs/remotes/origin/some/branch -> some/branch
                let parts = line.split(separator: "/", maxSplits: 3).map(String.init)
                if parts.count == 4, parts[3] != "HEAD" { repo.remotes.insert(parts[3]) }
            }
            for line in (out ?? "").split(separator: "\n") {
                let p = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard p.count >= 4 else { continue }
                var ahead: Int?, behind: Int?
                if p.count >= 5 {
                    let parts = p[4].split(separator: " ").compactMap { Int($0) }
                    if parts.count == 2 { ahead = parts[0]; behind = parts[1] }
                }
                // Merged = everything on the branch is already in main, and main has moved on since. A branch that is
                // still identical to main is just new, not finished.
                let merged: Bool? = base == nil ? nil : (ahead.map { $0 == 0 && (behind ?? 1) > 0 } ?? mergedSet.contains(p[0]))
                repo.branches.append(LocalBranch(name: p[0], upstream: p[1].isEmpty ? nil : p[1], track: p[2].isEmpty ? nil : p[2],
                                                 date: TimeInterval(p[3]).map { Date(timeIntervalSince1970: $0) }, ahead: ahead, merged: merged))
            }
            return repo
        }
        return readBasic(cwd)
    }

    /// The branch that finished work gets merged into: GitHub's default if known, otherwise main or master.
    private nonisolated static func defaultRef(_ cwd: String) -> String? {
        if let ref = Git.run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], cwd: cwd)?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty { return ref }
        for c in ["origin/main", "origin/master", "main", "master"] where Git.run(["rev-parse", "--verify", "--quiet", c], cwd: cwd) != nil { return c }
        return nil
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
        let remotesRoot = common + "/refs/remotes"
        if let en = fm.enumerator(atPath: remotesRoot) {
            for case let rel as String in en {
                var d: ObjCBool = false
                guard fm.fileExists(atPath: remotesRoot + "/" + rel, isDirectory: &d), !d.boolValue else { continue }
                let parts = rel.split(separator: "/", maxSplits: 1).map(String.init)   // origin/some/branch
                if parts.count == 2, parts[1] != "HEAD" { repo.remotes.insert(parts[1]) }
            }
        }
        if let packed = try? String(contentsOfFile: common + "/packed-refs", encoding: .utf8) {
            for line in packed.split(separator: "\n") {
                guard let rr = line.range(of: " refs/remotes/") else { continue }
                let parts = line[rr.upperBound...].split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[1] != "HEAD" { repo.remotes.insert(parts[1]) }
            }
        }
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
    @AppStorage("branches.filter") private var filterRaw = BranchFilter.all.rawValue
    @State private var query = ""
    @State private var showGlossary = false
    @State private var cleanup: CleanupRequest?
    @State private var lastRemoval: [RemovedBranch] = []
    @AppStorage("branches.introDismissed") private var introDismissed = false
    @Namespace private var filterNS

    /// A search the menu bar panel hands over when you click a branch there.
    static let pendingQueryKey = "branches.pendingQuery"

    enum BranchFilter: String, CaseIterable, Identifiable {
        case working = "In progress", closeable = "Done", all = "All"

        /// Reads a saved choice, including the old name "Ready to close".
        init?(saved: String) {
            if let f = BranchFilter(rawValue: saved) { self = f }
            else if saved == "Ready to close" { self = .closeable }
            else { return nil }
        }
        var id: Self { self }
    }
    private var filter: BranchFilter { BranchFilter(saved: filterRaw) ?? .all }

    /// Branches a live Copilot session is using right now.
    private var liveKeys: Set<String> {
        Set(store.sessions.filter(\.isActive).compactMap { s in s.branch.map { (s.repository ?? "") + "|" + $0 } })
    }

    /// Everything that matches the search and "hide main", before the Working/Ready/All filter.
    private func candidates(_ r: RepoBranches) -> [BranchRow] {
        let live = liveKeys
        return r.branches.map { b -> BranchRow in
            var b = b; b.sessionActive = live.contains(r.name + "|" + b.name); return b
        }
        .filter { b in
            if hideMain && (b.isDefault || b.isNoise) && !b.isCurrent && b.dirty == 0 { return false }
            if !query.isEmpty && !(b.name + " " + r.name).localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    private func visible(_ r: RepoBranches) -> [BranchRow] {
        candidates(r).filter { b in
            switch filter { case .all: true; case .working: b.working; case .closeable: b.closeable }
        }
        .sorted { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return (a.lastActive ?? .distantPast) > (b.lastActive ?? .distantPast)
        }
    }

    private var shown: [(repo: RepoBranches, rows: [BranchRow])] {
        model.repos.compactMap { r in let rows = visible(r); return rows.isEmpty && (!query.isEmpty || filter != .all) ? nil : (r, rows) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !Access.hasCopilotAccess && !model.loadedOnce {
                EmptyNote(symbol: "lock", title: "Allow access to your sessions first", message: "Branches come from your Copilot sessions. Allow the .copilot folder in Settings or the main window.")
            } else if !model.loadedOnce {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                EmptyNote(symbol: "arrow.triangle.branch", title: "No branches to show", message: query.isEmpty ? "Nothing matches the current filters." : "Nothing matches “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28, pinnedViews: []) {
                        if !introDismissed { BranchIntro { withAnimation { introDismissed = true } } }
                        ForEach(shown, id: \.repo.id) { item in
                            RepoSection(repo: item.repo, rows: item.rows, reload: model.refresh) { rows in
                                cleanup = CleanupRequest(repo: item.repo.name, rows: rows)
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 28)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .background(Palette.canvas)
        .searchable(text: $query, placement: .toolbar, prompt: "Search repos and branches")
        .toolbar { toolbarItems }
        .onAppear { model.refresh(); takePendingQuery() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in takePendingQuery() }
        .onChange(of: store.sessions.first?.updatedAt) { _, _ in model.refresh() }
        .sheet(item: $cleanup) { req in
            CleanupSheet(request: req) { outcome in
                cleanup = nil
                if let o = outcome, !o.removed.isEmpty { withAnimation { lastRemoval = o.removed }; model.refresh() }
            }
        }
        .overlay(alignment: .bottom) {
            if !lastRemoval.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                    Text(lastRemoval.count == 1 ? "Removed 1 branch from your Mac" : "Removed \(lastRemoval.count) branches from your Mac").font(.system(size: 12, weight: .medium))
                    Button("Undo") { undo() }
                        .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: true))
                        .help("Bring the removed branches back exactly as they were")
                    IconButton(symbol: "xmark", help: "Dismiss this message") { withAnimation { lastRemoval = [] } }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Palette.card).shadow(color: .black.opacity(0.18), radius: 10, y: 3))
                .overlay(Capsule().strokeBorder(Palette.hairline))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: lastRemoval.first?.date) {
                    try? await Task.sleep(for: .seconds(90))
                    withAnimation { lastRemoval = [] }
                }
            }
        }
    }

    /// Count line and the three filters, sitting directly on the window background.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
            filterBar
        }
        .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Toggle("Hide main and temporary branches", isOn: $hideMain)
            } label: {
                Label("View options", systemImage: "line.3.horizontal.decrease")
            }
            .help("Hide the main version itself and Copilot's temporary branches, unless they have unsaved work")
            Button { showGlossary.toggle() } label: { Label("What do these words mean?", systemImage: "questionmark.circle") }
                .help("What do branches, main and merged mean?")
                .popover(isPresented: $showGlossary, arrowEdge: .bottom) { BranchGlossary().padding(16).frame(width: 340) }
            Button { model.refresh() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("Reload")
        }
    }

    private func takePendingQuery() {
        let d = UserDefaults.standard
        guard let q = d.string(forKey: Self.pendingQueryKey) else { return }
        d.removeObject(forKey: Self.pendingQueryKey)
        query = q
    }

    private func undo() {
        let items = lastRemoval
        withAnimation { lastRemoval = [] }
        Task.detached(priority: .userInitiated) {
            _ = BranchCleanup.restore(items)
            await MainActor.run { model.refresh() }
        }
    }

    private var counts: (working: Int, closeable: Int, all: Int) {
        var w = 0, c = 0, a = 0
        for r in model.repos { for b in candidates(r) { a += 1; if b.working { w += 1 }; if b.closeable { c += 1 } } }
        return (w, c, a)
    }

    /// The three questions you actually have: what am I working on, what can go, and everything.
    private var filterBar: some View {
        let n = counts
        return HStack(spacing: 2) {
            ForEach(BranchFilter.allCases) { f in
                let on = f == filter
                let count = f == .working ? n.working : f == .closeable ? n.closeable : n.all
                let tint: Color = f == .working ? Palette.working : f == .closeable ? Palette.ready : Palette.muted
                Button { withAnimation(.snappy(duration: 0.22)) { filterRaw = f.rawValue } } label: {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 6, height: 6)
                        Text(f.rawValue)
                        Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .padding(.horizontal, 12).frame(height: 26)
                    .background {
                        if on {
                            Capsule().fill(Palette.card)
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "filter", in: filterNS)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(f == .working ? "Work you are in the middle of: unsaved changes, a Copilot session working on it, open on your Mac, or touched in the last 7 days"
                      : f == .closeable ? "Work that is finished and already part of the main version. These can be closed to keep things tidy."
                      : "Everything Copilot has worked on")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.well))
    }

    private var summary: String {
        let repos = model.repos.count
        let branches = model.repos.reduce(0) { $0 + $1.branches.count }
        return model.loadedOnce ? "\(branches) branches (separate versions of the work) in \(repos) projects" : "Loading…"
    }
}

private struct RepoSection: View {
    let repo: RepoBranches
    let rows: [BranchRow]
    let reload: () -> Void
    let cleanup: ([BranchRow]) -> Void
    @State private var copied = false

    private var gitOK: Bool { !repo.basicLocal }
    private func allowFolder() {
        if let f = repo.folders.first(where: { !Access.canRead($0) }), Access.requestProjectFolder(for: f) { reload() }
    }
    private var removable: [BranchRow] { closeable.filter { BranchCleanup.blocker($0) == nil } }

    private var working: [BranchRow] { rows.filter(\.working) }
    private var closeable: [BranchRow] { rows.filter(\.closeable) }
    private var other: [BranchRow] { rows.filter { !$0.working && !$0.closeable } }

    /// Commands to remove finished branches. Nothing is run by the app: you copy them and run them yourself.
    private func cleanupCommands() -> String {
        let local = closeable.filter { $0.existsLocally == true && $0.folder != nil }
        guard let folder = local.first?.folder else { return "" }
        var lines = ["git -C \"\(folder)\" branch -d " + local.map(\.name).joined(separator: " ")]
        let remote = local.filter { $0.upstream != nil && !$0.remoteGone }
        if !remote.isEmpty { lines.append("git -C \"\(folder)\" push origin --delete " + remote.map(\.name).joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                let parts = repo.name.split(separator: "/", maxSplits: 1).map(String.init)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.last ?? repo.name).font(.system(size: 15, weight: .semibold)).tracking(-0.2)
                    if parts.count == 2 { Text(parts[0]).font(.system(size: 12)).foregroundStyle(.tertiary) }
                }
                .lineLimit(1)
                Spacer()
                if repo.needsAccess, let f = repo.folders.first(where: { !Access.canRead($0) }) {
                    Button("Show local details…") { if Access.requestProjectFolder(for: f) { reload() } }
                        .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                        .help("Allow this project folder to see unsaved changes, what is merged, and whether each branch still exists")
                }
                if let f = repo.folders.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    IconButton(symbol: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
                }
                if let url = URL(string: "https://github.com/\(repo.name)"), repo.name.contains("/") {
                    IconButton(symbol: "arrow.up.right.square", help: "Open on GitHub") { Links.open(url) }
                }
            }
            if !working.isEmpty { group("In progress", Palette.working, working) { EmptyView() } }
            if !other.isEmpty { group("Paused", Palette.muted, other) { EmptyView() } }
            if !closeable.isEmpty {
                group("Done · safe to close", Palette.ready, closeable) {
                    Button { cleanup(closeable) } label: {
                        HStack(spacing: 4) { Image(systemName: "sparkles"); Text("Clean up \(removable.count)…") }
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.ready, filled: true))
                    .disabled(removable.isEmpty || !gitOK)
                    .help(!gitOK ? "Git can't run in this version of the app, so use “Copy tidy-up commands” instead."
                          : removable.isEmpty ? "Nothing here can be removed right now."
                          : "Review and remove these finished branches from your Mac. You see the list first, and can undo.")
                    Button {
                        let cmd = cleanupCommands()
                        guard !cmd.isEmpty else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "terminal")
                            Text(copied ? "Copied" : "Copy tidy-up commands")
                        }
                    }
                    .buttonStyle(PillButtonStyle(tint: Palette.ready, filled: false))
                    .disabled(cleanupCommands().isEmpty)
                    .help("Copies a command that removes these \(closeable.count) finished branches from your Mac. It refuses if anything isn't actually finished. Nothing is removed until you paste it into Terminal yourself.")
                }
            }
        }
    }

    @ViewBuilder private func group<T: View>(_ title: String, _ tint: Color, _ list: [BranchRow], @ViewBuilder trailing: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(list.count)").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                if title == "Paused" {
                    Text("Each has a suggested next step").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help("Nothing has happened here for a week, nothing is unsaved and no Copilot session is using it, and it isn't marked as finished. Old or unfinished work.")
                }
                if title == "Done · safe to close" {
                    Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help("This work has already been added to the main version, so the separate copy isn't needed any more.")
                }
                Spacer()
                trailing()
            }
            .padding(.leading, 3)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                    BranchLine(row: b, gitOK: gitOK, repoNeedsAccess: repo.needsAccess, remove: { cleanup([b]) }, allowFolder: allowFolder)
                    if i < list.count - 1 { Divider().opacity(0.35).padding(.leading, 46) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
    }
}

private struct BranchLine: View {
    let row: BranchRow
    var gitOK = true
    var repoNeedsAccess = false
    var remove: () -> Void = {}
    var allowFolder: () -> Void = {}
    @State private var hover = false
    @State private var copied: String?
    @State private var showDetails = false

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
    /// Pull requests made from this branch. Copilot only records PR numbers a session mentioned, which can belong
    /// to another branch, so we let GitHub find the ones whose source really is this branch.
    private var pullsURL: URL? { github("/pulls?q=is%3Apr+head%3A\(encodedQuery)") }
    private var prURL: URL? { row.prs.isEmpty ? nil : pullsURL }
    private var compareURL: URL? { github("/compare/\(encodedName)") }
    /// False only when we know there is no such branch on GitHub, so the link would be a 404.
    private var linkable: Bool { row.onGitHub == true }
    private var missingOnGitHub: String {
        row.onGitHub == false
            ? "This branch isn't on GitHub (it was never sent there, or has been removed), so there is no page to open."
            : "The app can't tell yet whether this branch is on GitHub, and many aren't. Click “Show local details…” on the project and allow its folder."
    }

    // MARK: Actions (the same list is used by the ⋯ menu and by right-click)

    /// The Copilot session that worked on this branch (its folder), else just the app.
    private func openInCopilot() {
        SessionActions.openCopilot(workspace: row.folder, branch: row.name, repo: row.repo.contains("/") ? row.repo : nil)
    }
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
        Button { if let u = branchURL { Links.open(u) } } label: { Label(linkable ? "View on GitHub" : (row.onGitHub == false ? "Not on GitHub" : "May not be on GitHub"), systemImage: "arrow.up.right.square") }
            .disabled(branchURL == nil || !linkable)
        Button { if let u = pullsURL { Links.open(u) } } label: { Label(row.prs.isEmpty ? "See review requests on GitHub" : "Open its pull request", systemImage: "arrow.triangle.pull") }
            .disabled(pullsURL == nil)
        Button { if let u = compareURL { Links.open(u) } } label: { Label("Compare with main or ask for a review", systemImage: "arrow.left.arrow.right") }
            .disabled(compareURL == nil || !linkable)
        Button(role: .destructive) { remove() } label: { Label(row.closeable ? "Remove from this Mac…" : "Remove from this Mac (not finished)…", systemImage: "trash") }
            .disabled(!gitOK || BranchCleanup.blocker(row) != nil)
        Divider()
        Button { if let d = folderURL { NSWorkspace.shared.activateFileViewerSelecting([d]) } } label: { Label("Show project folder in Finder", systemImage: "folder") }
            .disabled(folderURL == nil)
        // Archived workspaces open too: Copilot shows them read-only with a Restore button.
        Button { openInCopilot() } label: {
            Label(row.copilot != .closed ? "Open in GitHub Copilot" : row.closeable ? "Open in GitHub Copilot (closed)" : "Reopen in GitHub Copilot",
                  systemImage: "sparkles")
        }
        .disabled(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.githubapp") == nil)
        .help(row.copilot == .closed ? "Opens the closed workspace in the GitHub Copilot app. Use Restore there to work on it again." : "Opens this branch's session in the GitHub Copilot app")
        Button { openApp("com.apple.Terminal") } label: { Label("Open in Terminal", systemImage: "terminal") }
            .disabled(folderURL == nil)
        Divider()
        if row.closeable, row.existsLocally == true, let f = row.folder {
            Button { copy("git -C \"\(f)\" branch -d \(row.name)", label: "delete command") } label: { Label("Copy command to remove this branch (safe)", systemImage: "trash") }
            if row.upstream != nil, !row.remoteGone {
                Button { copy("git -C \"\(f)\" push origin --delete \(row.name)", label: "delete command") } label: { Label("Copy command to remove it on GitHub too", systemImage: "trash.circle") }
            }
            Divider()
        }
        Button { copy(row.name, label: "name") } label: { Label("Copy branch name", systemImage: "doc.on.doc") }
        Button { copy("git -C \"\(row.folder ?? ".")\" switch \(row.name)", label: "command") } label: { Label("Copy command to switch to this version", systemImage: "terminal.fill") }
            .disabled(row.folder == nil || row.existsLocally == false)
        Button { if let u = branchURL { copy(u.absoluteString, label: "link") } } label: { Label("Copy GitHub link", systemImage: "link") }
            .disabled(branchURL == nil || !linkable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 10) {
            let statusTint: Color = row.working ? Palette.working : row.closeable ? Palette.ready : Palette.muted
            Image(systemName: row.closeable ? "checkmark" : "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(statusTint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(statusTint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .medium)).foregroundStyle(row.closeable ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    if row.closeable, row.merged != true { chip("Removed on GitHub", Palette.ready, "This branch was removed on GitHub, which usually means the work was reviewed and added to the main version. The app can't prove it, so check before removing it from your Mac.") }
                    if row.isCurrent { chip("Open on your Mac", Palette.working, "This is the version currently open in the project folder on your Mac") }
                    if let a = row.ahead, a > 0, !row.closeable { chip(a == 1 ? "1 change not in main yet" : "\(a) changes not in main yet", Palette.muted, "\(a) saved changes on this branch haven't been added to the main (finished) version yet") }
                    if row.dirty > 0 { chip(row.dirty == 1 ? "1 unsaved file" : "\(row.dirty) unsaved files", Palette.attention, "\(row.dirty) files have edits that aren't saved as a version yet. They exist only on your Mac.") }
                    if let t = row.track, !t.isEmpty, t != "gone", let plain = Self.plainTrack(t) { chip(plain.text, Palette.attention, plain.help) }
                    if row.existsLocally == true, row.upstream == nil, row.upstreamKnown { chip("Only on your Mac", Palette.attention, "This branch hasn't been sent to GitHub, so nobody else can see it and it isn't backed up") }
                    if row.merged == nil, !row.isDefault, row.existsLocally != false {
                        chip("Can't tell if it's done", Palette.muted, "The app can't compare this branch with the main version yet. Click “Show local details…” on the project and allow its folder.")
                    }
                    if !row.prs.isEmpty { chip("Pull request", Palette.muted, "Copilot worked with a pull request in this session. Use the ⋯ menu to open this branch's pull requests on GitHub.") }
                    if row.onGitHub == false, row.existsLocally == false { chip("Not on GitHub", Palette.muted, missingOnGitHub) }
                    if row.copilot == .closed, !row.working { chip("Closed in Copilot", Palette.muted, "Its workspace in the GitHub Copilot app is archived. Restore it there if you want to keep working on it.") }
                    if row.existsLocally == false { chip("Not on this Mac", Palette.muted, "Copilot worked on this, but it is gone from your project folder. Often a temporary workspace that was cleaned up.") }
                }
                if let t = row.topic {
                    Text(t).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help("What the latest Copilot session on this branch was about")
                }
                HStack(spacing: 5) {
                    if let c = copied { Text("Copied \(c)").foregroundStyle(Palette.ready) }
                    else {
                        if let d = row.lastActive { Text(d, format: .relative(presentation: .named, unitsStyle: .abbreviated)) }
                        if row.sessions > 0 { Text("· \(row.sessions) \(row.sessions == 1 ? "session" : "sessions")") }
                    }
                    detailsToggle.padding(.leading, 4)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                IconButton(symbol: "arrow.up.right.square",
                           help: linkable ? "View this branch on GitHub" : (prURL != nil ? "Open this branch's pull request on GitHub" : missingOnGitHub)) {
                    if linkable, let u = branchURL { Links.open(u) } else if let u = prURL { Links.open(u) }
                }
                .disabled(!(linkable && branchURL != nil) && prURL == nil)
                IconButton(symbol: "folder", help: "Show the project folder in Finder") { if let d = folderURL { NSWorkspace.shared.activateFileViewerSelecting([d]) } }
                    .disabled(folderURL == nil)
                if row.closeable {
                    IconButton(symbol: "trash", help: gitOK ? (BranchCleanup.blocker(row).map { "Can't remove: \($0)" } ?? "Remove this finished branch from your Mac. You confirm first and can undo.") : "Git can't run in this version of the app. Use the menu to copy a command instead.") { remove() }
                        .disabled(!gitOK || BranchCleanup.blocker(row) != nil)
                }
                IconButton(symbol: "doc.on.doc", help: "Copy the name of this branch") { copy(row.name, label: "name") }
                Menu { actions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11.5, weight: .semibold))
                        .help("More actions for this branch. Right-click the row for the same menu.")
                        .accessibilityLabel("More actions for \(row.name)")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26, height: 26)
                .help("More actions: review requests, compare with main, open in GitHub Copilot or Terminal, copy commands. Right-click the row for the same menu.")
            }.opacity(hover ? 1 : 0)
        }
        adviceBox
        if showDetails {
            BranchDetailsPanel(row: row)
                .padding(.leading, 34)
                .transition(.opacity)
        }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Palette.well.opacity(hover ? 0.45 : 0))
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { actions }
        .onAppear { if Demo.opensDetails(row.name) { showDetails = true } }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open on GitHub") { if linkable, let u = branchURL { Links.open(u) } }
        .accessibilityAction(named: "Copy branch name") { copy(row.name, label: "name") }
    }

    /// Opens "What's in it": saved changes, files, unsaved edits and Copilot sessions for this branch.
    private var detailsToggle: some View {
        Button { withAnimation(.snappy(duration: 0.25)) { showDetails.toggle() } } label: {
            HStack(spacing: 4) {
                Text("What's in it")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(showDetails ? 180 : 0))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill(Palette.well.opacity(hover || showDetails ? 1 : 0.6)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(showDetails ? "Hide what's in this branch" : "See what has been done on this branch: saved changes, files, unsaved edits and Copilot sessions")
    }

    /// "ahead 2, behind 1" in words a designer can use.
    static func plainTrack(_ t: String) -> (text: String, help: String)? {
        func num(_ word: String) -> Int? {
            guard let r = t.range(of: word + " ") else { return nil }
            return Int(t[r.upperBound...].prefix { $0.isNumber })
        }
        var parts: [String] = [], helps: [String] = []
        if let a = num("ahead") {
            parts.append(a == 1 ? "1 not on GitHub yet" : "\(a) not on GitHub yet")
            helps.append("\(a) saved changes on your Mac haven't been sent to GitHub yet.")
        }
        if let b = num("behind") {
            parts.append(b == 1 ? "1 new on GitHub" : "\(b) new on GitHub")
            helps.append("\(b) changes on GitHub aren't on your Mac yet.")
        }
        return parts.isEmpty ? nil : (parts.joined(separator: " · "), helps.joined(separator: " "))
    }

    // MARK: Suggested next step

    private var advice: Advice? { row.advice(repoNeedsAccess: repoNeedsAccess) }

    private func tint(_ t: Advice.Tone) -> Color {
        switch t { case .done: Palette.ready; case .check: Palette.working; case .decide: Palette.attention; case .nothing, .needsInfo: Palette.muted }
    }
    private func symbol(_ t: Advice.Tone) -> String {
        switch t { case .done: "checkmark.circle.fill"; case .check: "eye.circle.fill"; case .decide: "questionmark.circle.fill"; case .nothing: "minus.circle.fill"; case .needsInfo: "lock.circle.fill" }
    }

    private func perform(_ a: Advice.Action) {
        switch a {
        case .openPR: if let u = pullsURL { Links.open(u) }
        case .compare: if let u = compareURL { Links.open(u) }
        case .openCopilot: openInCopilot()
        case .remove: remove()
        case .allowFolder: allowFolder()
        }
    }

    /// "What should I do with this?", answered in one sentence with a button that does it.
    @ViewBuilder private var adviceBox: some View {
        if let a = advice {
            let c = tint(a.tone)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol(a.tone)).font(.system(size: 14)).foregroundStyle(c).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested: " + a.headline).font(.system(size: 12, weight: .semibold))
                    Text(a.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let action = a.action, let label = a.actionLabel {
                    Button { perform(action) } label: { Text(label) }
                        .buttonStyle(PillButtonStyle(tint: c, filled: false))
                        .disabled(!enabled(action))
                        .help(helpText(action))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.opacity(0.07)))
            .padding(.leading, 34)
            .accessibilityElement(children: .combine)
        }
    }

    private func enabled(_ a: Advice.Action) -> Bool {
        switch a {
        case .remove: gitOK && BranchCleanup.blocker(row) == nil
        case .compare: linkable && compareURL != nil
        case .openCopilot: folderURL != nil
        default: true
        }
    }
    private func helpText(_ a: Advice.Action) -> String {
        switch a {
        case .openPR: "Opens this branch's pull requests on GitHub in your browser"
        case .compare: "Opens GitHub where you can ask for a review"
        case .openCopilot: "Opens the project in the GitHub Copilot app"
        case .remove: gitOK ? "Shows what will be removed first. You can undo." : "Git can't run in this version of the app. Use the ⋯ menu to copy a command instead."
        case .allowFolder: "Choose the project folder (or a parent folder like “Volvo CE” to cover all projects at once)"
        }
    }

    private func chip(_ text: String, _ tint: Color, _ help: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(tint.opacity(0.10)))
            .help(help)
    }
}


// MARK: - Plain-language help

/// What the words in this window mean, for people who don't live in git.
struct BranchGlossary: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The words in this window").font(.system(size: 13, weight: .semibold))
            item("Branch", "A separate copy of the project where changes can be made safely, without touching the finished version. Copilot makes one for each task.")
            item("Main", "The finished, shared version of the project. Everyone builds on it.")
            item("Done · safe to close", "The work in this branch has been added to main. The separate copy isn't needed any more.")
            item("In progress", "You or Copilot are working on it: unsaved edits, a session running, or touched in the last week.")
            item("Paused", "Nothing has happened for a while and it isn't finished. It might be forgotten or waiting.")
            item("Unsaved", "Edits that only exist on your Mac and aren't saved as a version yet.")
            item("Only on your Mac", "Not sent to GitHub, so nobody else can see it and it isn't backed up.")
        }
    }
    private func item(_ term: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(term).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown on top until dismissed.
private struct BranchIntro: View {
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lightbulb").foregroundStyle(Palette.working)
                Text("New to branches?").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Got it", action: dismiss).buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
            }
            Text("Each Copilot task works in its own copy of the project, called a branch, so your finished version (“main”) stays safe. When the work is approved it gets added to main, and the copy can be closed. This window shows which copies you are working on and which are done.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                legend(Palette.working, "In progress: you're working on it")
                legend(Palette.ready, "Done: safe to close")
                legend(Palette.muted, "Paused: quiet for a week")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.working.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Palette.working.opacity(0.25)))
    }
    private func legend(_ tint: Color, _ text: String) -> some View {
        HStack(spacing: 5) { Circle().fill(tint).frame(width: 7, height: 7); Text(text).font(.system(size: 11)).foregroundStyle(.secondary) }
    }
}

// MARK: - Cleaning up branches

/// A branch that was removed from this Mac, with the exact point it pointed at so it can be brought back.
struct RemovedBranch: Codable, Hashable, Identifiable {
    var id: String { folder + "|" + name }
    let repo: String
    let name: String
    let folder: String
    let sha: String
    let date: Date
}

struct RemoveOutcome {
    var removed: [RemovedBranch] = []
    var failed: [(name: String, reason: String)] = []
    /// Branch name -> folder of the other workspace that has it open, when git says so.
    var workspaces: [String: String] = [:]
}

/// Removing finished branches. Only ever deletes the local copy on this Mac, never anything on GitHub.
enum BranchCleanup {
    enum Safety { case merged, probablyMerged, unmerged(Int?) }

    nonisolated static func safety(_ b: BranchRow) -> Safety {
        if b.merged == true { return .merged }
        if b.remoteGone { return .probablyMerged }
        return .unmerged(b.ahead)
    }

    /// nil when the branch can be removed; otherwise the reason it can't.
    nonisolated static func blocker(_ b: BranchRow) -> String? {
        if b.isDefault { return "This is the main version." }
        if b.isCurrent { return "It is open on your Mac right now." }
        if b.sessionActive { return "A Copilot session is using it." }
        if b.dirty > 0 { return "It has unsaved changes." }
        if b.existsLocally != true || b.folder == nil { return "It isn't on this Mac." }
        return nil
    }

    /// `force` removes it even when git can't confirm it is merged (the commits would only survive in git's history).
    nonisolated static func remove(_ items: [(row: BranchRow, force: Bool)]) -> RemoveOutcome {
        var out = RemoveOutcome()
        for (row, force) in items {
            if let why = blocker(row) { out.failed.append((row.name, why)); continue }
            guard let folder = row.folder else { continue }
            // Remember where the branch pointed so it can be restored.
            let sha = Git.runResult(["rev-parse", "--verify", "refs/heads/" + row.name], cwd: folder)
            guard sha.ok else { out.failed.append((row.name, plain(sha.err))); continue }
            // `git branch -d` checks against the local main (or HEAD), which is often behind GitHub's main. Check
            // against the same main the app used, and only then delete without git's own check.
            var confirmed = false
            if !force, let base = row.defaultName {
                confirmed = Git.runResult(["merge-base", "--is-ancestor", "refs/heads/" + row.name, base], cwd: folder).ok
            }
            let res = Git.runResult(["branch", force || confirmed ? "-D" : "-d", "--", row.name], cwd: folder)
            if res.ok {
                out.removed.append(RemovedBranch(repo: row.repo, name: row.name, folder: folder,
                                                 sha: sha.out.trimmingCharacters(in: .whitespacesAndNewlines), date: Date()))
            } else {
                out.failed.append((row.name, plain(res.err)))
                if let path = workspacePath(res.err) { out.workspaces[row.name] = path }
            }
        }
        record(out.removed)
        return out
    }

    nonisolated static func restore(_ items: [RemovedBranch]) -> RemoveOutcome {
        var out = RemoveOutcome()
        for b in items {
            let res = Git.runResult(["branch", "--", b.name, b.sha], cwd: b.folder)
            if res.ok { out.removed.append(b) } else { out.failed.append((b.name, plain(res.err))) }
        }
        return out
    }

    /// "cannot delete branch 'x' used by worktree at '/path'" (or "checked out at '/path'") -> "/path"
    nonisolated static func workspacePath(_ err: String) -> String? {
        for marker in ["used by worktree at '", "checked out at '"] {
            if let r = err.range(of: marker), let end = err[r.upperBound...].firstIndex(of: "'") {
                let path = String(err[r.upperBound..<end])
                return path.isEmpty ? nil : path
            }
        }
        return nil
    }

    private nonisolated static func plain(_ err: String) -> String {
        let e = err.lowercased()
        if e.contains("not fully merged") { return "Git can't confirm this is merged into main." }
        if e.contains("checked out at") || e.contains("used by worktree") { return "It is open in another workspace." }
        if e.contains("already exists") { return "A branch with this name already exists." }
        if e.contains("not found") || e.contains("not a valid") { return "It no longer exists." }
        return err.isEmpty ? "Git couldn't do it." : err
    }

    // A small log so removed branches can always be found again (also in git's own history).
    private nonisolated static var logURL: URL {
        AppFolders.support.appendingPathComponent("removed-branches.json")
    }
    private nonisolated static func record(_ items: [RemovedBranch]) {
        guard !items.isEmpty else { return }
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([RemovedBranch].self, from: $0) } ?? []
        all.append(contentsOf: items)
        if all.count > 500 { all.removeFirst(all.count - 500) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(all) { try? data.write(to: url, options: .atomic) }
    }
}

struct CleanupRequest: Identifiable {
    let id = UUID()
    let repo: String
    let rows: [BranchRow]
}

/// Confirmation step: shows exactly which branches go, why they are safe, and what each choice means.
struct CleanupSheet: View {
    let request: CleanupRequest
    let finish: (RemoveOutcome?) -> Void
    @State private var selected: Set<String>
    @State private var phase: Phase = .confirm
    enum Phase { case confirm, running, done(RemoveOutcome) }

    init(request: CleanupRequest, finish: @escaping (RemoveOutcome?) -> Void) {
        self.request = request; self.finish = finish
        // Safe ones are ticked. Anything git can't confirm is left for you to choose, unless it is the only one.
        let safe = request.rows.filter { if case .merged = BranchCleanup.safety($0) { return BranchCleanup.blocker($0) == nil } else { return false } }
        let pre = request.rows.count == 1 ? request.rows.filter { BranchCleanup.blocker($0) == nil } : safe
        _selected = State(initialValue: Set(pre.map(\.id)))
    }

    private var chosen: [BranchRow] { request.rows.filter { selected.contains($0.id) } }
    private var forced: [BranchRow] { chosen.filter { if case .merged = BranchCleanup.safety($0) { return false } else { return true } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch phase {
            case .confirm: confirm
            case .running:
                VStack(spacing: 10) { ProgressView(); Text("Removing…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 160)
            case .done(let outcome): done(outcome)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Palette.canvas)
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.rows.count == 1 ? "Remove this branch from your Mac?" : "Tidy up \(request.repo.split(separator: "/").last.map(String.init) ?? request.repo)")
                    .font(.system(size: 15, weight: .semibold))
                Text("This only removes the copies on your Mac. Nothing is deleted on GitHub, and finished work stays in main. You can undo right afterwards.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(request.rows.enumerated()), id: \.element.id) { i, b in
                        line(b)
                        if i < request.rows.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))

            if !forced.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention)
                    Text("\(forced.count) of these can't be confirmed as merged. If they hold work that isn't on GitHub or in main, it will be removed from your Mac (you can still undo right after).")
                        .font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Palette.attention.opacity(0.1)))
            }
            HStack {
                if request.rows.count > 1 {
                    Button(selected.count == request.rows.filter({ BranchCleanup.blocker($0) == nil }).count ? "Select none" : "Select all") {
                        let all = Set(request.rows.filter { BranchCleanup.blocker($0) == nil }.map(\.id))
                        selected = selected.count == all.count ? [] : all
                    }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
                      .help("Tick or untick every branch in the list")
                }
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button { run() } label: { Text(chosen.count == 1 ? "Remove 1 branch" : "Remove \(chosen.count) branches") }
                    .buttonStyle(PillButtonStyle(tint: forced.isEmpty ? Palette.ready : Palette.attention, filled: true))
                    .disabled(chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .help("Removes the ticked branches from your Mac only")
            }
        }
    }

    private func line(_ b: BranchRow) -> some View {
        let blocker = BranchCleanup.blocker(b)
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { selected.contains(b.id) }, set: { on in if on { selected.insert(b.id) } else { selected.remove(b.id) } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(blocker != nil)
                .accessibilityLabel("Remove \(b.name)")
            VStack(alignment: .leading, spacing: 2) {
                Text(b.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Group {
                    if let blocker { Text("Can't remove: \(blocker)").foregroundStyle(.secondary) }
                    else {
                        switch BranchCleanup.safety(b) {
                        case .merged: Text("Already in main").foregroundStyle(Palette.ready)
                        case .probablyMerged: Text("Removed on GitHub, probably merged. Git can't confirm.").foregroundStyle(Palette.attention)
                        case .unmerged(let n): Text(n.map { "\($0) changes that are not in main" } ?? "Not confirmed as merged").foregroundStyle(Palette.attention)
                        }
                    }
                }.font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(blocker == nil ? 1 : 0.6)
    }

    private func run() {
        let items = chosen.map { (row: $0, force: { if case .merged = BranchCleanup.safety($0) { return false } else { return true } }($0)) }
        phase = .running
        Task.detached(priority: .userInitiated) {
            let outcome = BranchCleanup.remove(items)
            await MainActor.run { phase = .done(outcome) }
        }
    }

    private func done(_ o: RemoveOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: o.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(o.failed.isEmpty ? Palette.ready : Palette.attention)
                Text(o.removed.isEmpty ? "Nothing was removed" : o.removed.count == 1 ? "Removed 1 branch from your Mac" : "Removed \(o.removed.count) branches from your Mac")
                    .font(.system(size: 14, weight: .semibold))
            }
            if !o.failed.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These were kept:").font(.system(size: 11.5, weight: .semibold))
                    ForEach(Array(o.failed.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(f.name): \(f.reason)").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let path = o.workspaces[f.name] { WorkspaceLink(path: path, branch: f.name) }
                        }
                    }
                }
            }
            if !o.removed.isEmpty {
                Text("Changed your mind? Use Undo in the bar at the bottom of the window.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Done") { finish(o) }.buttonStyle(PillButtonStyle(tint: Palette.accent, filled: true)).keyboardShortcut(.defaultAction) }
        }
    }
}

/// Where the other workspace is, with ways to get there. Shown when a branch can't be removed because it is open there.
private struct WorkspaceLink: View {
    let path: String
    let branch: String
    @State private var copied = false

    private var url: URL { URL(fileURLWithPath: path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: path) }
    private var shortPath: String { (path as NSString).abbreviatingWithTildeInPath }
    private var isCopilot: Bool { path.contains("copilot-worktrees") }
    private var copilotApp: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.githubapp") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(Palette.working)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(shortPath).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .help(path).textSelection(.enabled)
                }
            }
            Text(isCopilot
                 ? "A Copilot workspace still has this branch open. Open it in GitHub Copilot to finish or close that session, then try again."
                 : "Another folder on your Mac has this branch open. Switch that folder to another branch, then try again.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if copilotApp != nil {
                Button { SessionActions.openCopilot(workspace: path, branch: branch) } label: {
                    Label("Open in GitHub Copilot", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: isCopilot))
                .disabled(!exists)
                .help(exists ? "Opens the Copilot session for this workspace in the GitHub Copilot app" : "This folder no longer exists")
            }
            HStack(spacing: 6) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                .disabled(!exists)
                .help(exists ? "Opens the workspace folder in Finder" : "This folder no longer exists")
                Button { openInTerminal() } label: { Label("Open in Terminal", systemImage: "terminal") }
                    .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                    .disabled(!exists)
                    .help("Opens a Terminal window in this workspace")
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy path", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                    .help("Copies the folder path")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.well.opacity(0.6)))
    }

    private func openInTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
