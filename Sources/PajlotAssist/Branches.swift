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
private struct LocalRepo { var current: String?; var dirty = 0; var branches: [LocalBranch] = []; var basic = false; var defaultName: String? }

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
                    b.ahead = lb.ahead ?? b.ahead
                    b.merged = lb.merged ?? b.merged
                    b.defaultName = local.defaultName ?? b.defaultName
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
    @AppStorage("branches.introDismissed") private var introDismissed = false

    enum BranchFilter: String, CaseIterable, Identifiable {
        case working = "In progress", closeable = "Ready to close", all = "All"
        var id: Self { self }
    }
    private var filter: BranchFilter { BranchFilter(rawValue: filterRaw) ?? .all }

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
            toolbar
            filterBar
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
                        if !introDismissed { BranchIntro { withAnimation { introDismissed = true } } }
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
                .help("Hide the main version itself and Copilot's temporary branches, unless they have unsaved work")
            Button { showGlossary.toggle() } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("What do branches, main and merged mean?")
            .accessibilityLabel("Explain the words in this window")
            .popover(isPresented: $showGlossary, arrowEdge: .bottom) { BranchGlossary().padding(16).frame(width: 340) }
            IconButton(symbol: "arrow.clockwise", help: "Reload", shortcut: "r") { model.refresh() }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var counts: (working: Int, closeable: Int, all: Int) {
        var w = 0, c = 0, a = 0
        for r in model.repos { for b in candidates(r) { a += 1; if b.working { w += 1 }; if b.closeable { c += 1 } } }
        return (w, c, a)
    }

    /// The three questions you actually have: what am I working on, what can go, and everything.
    private var filterBar: some View {
        let n = counts
        return HStack(spacing: 8) {
            ForEach(BranchFilter.allCases) { f in
                let on = f == filter
                let count = f == .working ? n.working : f == .closeable ? n.closeable : n.all
                let tint: Color = f == .working ? Palette.working : f == .closeable ? Palette.ready : Palette.accent
                Button { withAnimation(.snappy(duration: 0.2)) { filterRaw = f.rawValue } } label: {
                    HStack(spacing: 6) {
                        Circle().fill(f == .all ? Palette.muted : tint).frame(width: 7, height: 7)
                        Text(f.rawValue)
                        Text("\(count)").monospacedDigit().foregroundStyle(on ? tint : .secondary)
                    }
                    .font(.system(size: 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Capsule().fill(on ? tint.opacity(0.15) : Palette.well))
                    .overlay(Capsule().strokeBorder(on ? tint.opacity(0.6) : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(f == .working ? "Work you are in the middle of: unsaved changes, a Copilot session working on it, open on your Mac, or touched in the last 7 days"
                      : f == .closeable ? "Work that is finished and already part of the main version. These can be closed to keep things tidy."
                      : "Everything Copilot has worked on")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
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
    @State private var copied = false

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(repo.name).font(.system(size: 12.5, weight: .semibold))
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
                    IconButton(symbol: "arrow.up.right.square", help: "Open on GitHub") { NSWorkspace.shared.open(url) }
                }
            }
            if !working.isEmpty { group("In progress", Palette.working, working, nil) }
            if !other.isEmpty { group("Paused", Palette.muted, other, nil) }
            if !closeable.isEmpty {
                group("Done · safe to close", Palette.ready, closeable) {
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

    @ViewBuilder private func group(_ title: String, _ tint: Color, _ list: [BranchRow], _ trailing: (() -> some View)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(tint)
                Text("\(list.count)").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                if title == "Paused" {
                    Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help("Nothing has happened here for a week, nothing is unsaved and no Copilot session is using it, and it isn't marked as finished. Old or unfinished work.")
                }
                if title == "Done · safe to close" {
                    Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .help("This work has already been added to the main version, so the separate copy isn't needed any more.")
                }
                Spacer()
                trailing?()
            }
            .padding(.leading, 3)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, b in
                    BranchLine(row: b)
                    if i < list.count - 1 { Divider().opacity(0.4) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(tint.opacity(title == "Paused" ? 0 : 0.35)))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }

    private func group(_ title: String, _ tint: Color, _ list: [BranchRow], _ trailing: Void?) -> some View {
        group(title, tint, list, Optional<() -> EmptyView>.none)
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
        Button { if let u = branchURL { NSWorkspace.shared.open(u) } } label: { Label("View on GitHub", systemImage: "arrow.up.right.square") }
            .disabled(branchURL == nil)
        Button { if let u = pullsURL { NSWorkspace.shared.open(u) } } label: { Label("See review requests on GitHub", systemImage: "arrow.triangle.pull") }
            .disabled(pullsURL == nil)
        Button { if let u = compareURL { NSWorkspace.shared.open(u) } } label: { Label("Compare with main or ask for a review", systemImage: "arrow.left.arrow.right") }
            .disabled(compareURL == nil)
        Divider()
        Button { if let d = folderURL { NSWorkspace.shared.activateFileViewerSelecting([d]) } } label: { Label("Show project folder in Finder", systemImage: "folder") }
            .disabled(folderURL == nil)
        Button { openApp("com.github.githubapp") } label: { Label("Open project in GitHub Copilot", systemImage: "sparkles") }
            .disabled(folderURL == nil || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.githubapp") == nil)
        Button { openApp("com.microsoft.VSCode") } label: { Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            .disabled(folderURL == nil || NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") == nil)
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
            .disabled(branchURL == nil)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(row.isCurrent ? Palette.working : Palette.muted).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(row.closeable ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                    if row.working { filledChip("In progress", Palette.working, "You have unsaved changes here, a Copilot session is working on it, it is open on your Mac, or it was touched in the last 7 days") }
                    if row.closeable {
                        if row.merged == true { filledChip("Done · safe to close", Palette.ready, "Everything on this branch has already been added to the main version. The separate copy can be closed.") }
                        else { filledChip("Done · removed on GitHub", Palette.ready, "This branch was removed on GitHub, which usually means the work was reviewed and added to the main version. The app can't prove it, so check before removing it from your Mac.") }
                    }
                    if row.isCurrent { chip("Open on your Mac", Palette.working, "This is the version currently open in the project folder on your Mac") }
                    if let a = row.ahead, a > 0, !row.closeable { chip(a == 1 ? "1 change not in main yet" : "\(a) changes not in main yet", Palette.muted, "\(a) saved changes on this branch haven't been added to the main (finished) version yet") }
                    if row.dirty > 0 { chip(row.dirty == 1 ? "1 unsaved file" : "\(row.dirty) unsaved files", Palette.attention, "\(row.dirty) files have edits that aren't saved as a version yet. They exist only on your Mac.") }
                    if let t = row.track, !t.isEmpty, t != "gone", let plain = Self.plainTrack(t) { chip(plain.text, Palette.attention, plain.help) }
                    if row.existsLocally == true, row.upstream == nil, row.upstreamKnown { chip("Only on your Mac", Palette.attention, "This branch hasn't been sent to GitHub, so nobody else can see it and it isn't backed up") }
                    if row.merged == nil, !row.isDefault, row.existsLocally != false {
                        chip("Can't tell if it's done", Palette.muted, "The app can't compare this branch with the main version yet. Click “Show local details…” on the project and allow its folder.")
                    }
                    if row.existsLocally == false { chip("Not on this Mac", Palette.muted, "Copilot worked on this, but it is gone from your project folder. Often a temporary workspace that was cleaned up.") }
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
                IconButton(symbol: "arrow.up.right.square", help: "View this branch on GitHub") { if let u = branchURL { NSWorkspace.shared.open(u) } }
                    .disabled(branchURL == nil)
                IconButton(symbol: "folder", help: "Show the project folder in Finder") { if let d = folderURL { NSWorkspace.shared.activateFileViewerSelecting([d]) } }
                    .disabled(folderURL == nil)
                IconButton(symbol: "doc.on.doc", help: "Copy the name of this branch") { copy(row.name, label: "name") }
                Menu { actions } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11.5, weight: .semibold))
                        .help("More actions for this branch. Right-click the row for the same menu.")
                        .accessibilityLabel("More actions for \(row.name)")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26, height: 26)
                .help("More actions: review requests, compare with main, open in GitHub Copilot, VS Code or Terminal, copy commands. Right-click the row for the same menu.")
            }.opacity(hover ? 1 : 0.45)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .padding(.leading, 3)
        .background(Palette.well.opacity(hover ? 0.5 : 0))
        .overlay(alignment: .leading) {
            if row.working || row.closeable { Rectangle().fill(row.working ? Palette.working : Palette.ready).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open on GitHub") { if let u = branchURL { NSWorkspace.shared.open(u) } }
        .accessibilityAction(named: "Copy branch name") { copy(row.name, label: "name") }
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

    private func filledChip(_ text: String, _ tint: Color, _ help: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 7).frame(height: 17).background(Capsule().fill(tint))
            .help(help)
    }

    private func chip(_ text: String, _ tint: Color, _ help: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(tint.opacity(0.13)))
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
