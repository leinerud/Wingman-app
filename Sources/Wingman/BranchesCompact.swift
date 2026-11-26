import SwiftUI
import AppKit

/// Branches in the menu bar panel: a narrow list with each branch's next step and a menu of actions.
/// Cleaning up and the full details live in the main window's Branches tab.
struct CompactBranchesView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var model = BranchStore()
    @AppStorage("branches.hideMain") private var hideMain = true
    @AppStorage("popover.branches.filter") private var filterRaw = BranchesWindow.BranchFilter.working.rawValue
    @State private var listHeight: CGFloat = 0
    @Environment(\.openWindow) private var openWindow

    private typealias Filter = BranchesWindow.BranchFilter
    private var filter: Filter { Filter(saved: filterRaw) ?? .working }

    private var liveKeys: Set<String> {
        Set(store.sessions.filter(\.isActive).compactMap { s in s.branch.map { (s.repository ?? "") + "|" + $0 } })
    }

    /// Every branch that passes "hide main", with live sessions marked, newest first.
    private var all: [BranchRow] {
        let live = liveKeys
        return model.repos.flatMap { r in
            r.branches.map { b -> BranchRow in var b = b; b.sessionActive = live.contains(r.name + "|" + b.name); return b }
        }
        .filter { b in !(hideMain && (b.isDefault || b.isNoise) && !b.isCurrent && b.dirty == 0) }
        .sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }
    private func matching(_ f: Filter, in rows: [BranchRow]) -> [BranchRow] {
        switch f { case .all: rows; case .working: rows.filter(\.working); case .closeable: rows.filter(\.closeable) }
    }
    private var needsAccess: Bool { model.repos.contains(where: \.needsAccess) }

    var body: some View {
        let rows = all
        let shown = matching(filter, in: rows)
        VStack(spacing: 0) {
            HStack {
                CapsuleFilter(options: Filter.allCases, selection: Binding(get: { filter }, set: { filterRaw = $0.rawValue }),
                              title: { $0.rawValue },
                              count: { matching($0, in: rows).count },
                              dot: { $0 == .working ? Palette.working : $0 == .closeable ? Palette.ready : Palette.muted })
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.gutter).padding(.bottom, 10)

            if !Access.hasCopilotAccess && !model.loadedOnce {
                note("lock", "Allow access to your sessions first", "Branches come from your Copilot sessions.")
            } else if !model.loadedOnce {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if shown.isEmpty {
                note("arrow.triangle.branch", filter == .working ? "Nothing in progress" : filter == .closeable ? "Nothing to tidy up" : "No branches yet",
                     filter == .closeable ? "Finished branches show up here, ready to remove." : "Branches your Copilot sessions use show up here.")
            } else {
                list(shown)
            }

            HStack(spacing: 8) {
                if filter == .closeable && !shown.isEmpty {
                    Button { openFull(.closeable) } label: { Label("Clean up \(shown.count)…", systemImage: "sparkles") }
                        .buttonStyle(PillButtonStyle(tint: Palette.ready, filled: true))
                        .help("Opens the Branches view, where you review and remove finished branches")
                } else if needsAccess {
                    Text("Some project folders aren't allowed yet").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { openFull(filter) } label: {
                    HStack(spacing: 4) { Text("Open Branches"); Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold)) }
                }
                .buttonStyle(FooterLinkStyle())
                .help("Opens the full Branches view in the main window")
            }
            .padding(.horizontal, Metrics.gutter).padding(.top, 8).padding(.bottom, 10)
        }
        .onAppear { model.refresh() }
        .onChange(of: store.sessions.first?.updatedAt) { _, _ in model.refresh() }
    }

    private func list(_ rows: [BranchRow]) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, b in
                    CompactBranchRow(row: b, needsAccess: model.repos.first { $0.name == b.repo }?.needsAccess ?? false,
                                     openFull: { openFull(filter, query: b.name) })
                    if i < rows.count - 1 { Divider().opacity(0.35).padding(.leading, 44) }
                }
            }
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Palette.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .padding(.horizontal, Metrics.gutter)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in listHeight = h }
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(listHeight, 60), Metrics.maxListHeight))
    }

    private func note(_ symbol: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }

    /// The main window on its Branches tab, optionally with a filter and a search already set.
    private func openFull(_ f: Filter, query: String? = nil) {
        let d = UserDefaults.standard
        d.set(MainWindowView.Tab.branches.rawValue, forKey: MainWindow.tabKey)
        d.set(f.rawValue, forKey: "branches.filter")
        if let query { d.set(query, forKey: BranchesWindow.pendingQueryKey) }
        openWindow(id: MainWindow.id)
        NSApp.activate()
    }
}

/// One branch on one line, with its suggested next step underneath and the actions in a menu.
private struct CompactBranchRow: View {
    let row: BranchRow
    let needsAccess: Bool
    let openFull: () -> Void
    @State private var hover = false

    private var tint: Color { row.working ? Palette.working : row.closeable ? Palette.ready : Palette.muted }
    private var advice: Advice? { row.advice(repoNeedsAccess: needsAccess) }
    private var repoName: String { row.repo.split(separator: "/").last.map(String.init) ?? row.repo }
    private var folderURL: URL? { row.folder.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil } }
    private var prURL: URL? {
        guard let n = row.prs.max(), row.repo.contains("/") else { return nil }
        return URL(string: "https://github.com/\(row.repo)/pull/\(n)")
    }

    /// What the line under the name says: the next step if there is one, otherwise what is going on.
    private var status: (text: String, color: Color)? {
        if let a = advice { return (a.headline, a.tone == .decide ? Palette.attention : a.tone == .done ? Palette.ready : .secondary) }
        var parts: [String] = []
        if row.sessionActive { parts.append("Copilot is working on it") }
        if row.dirty > 0 { parts.append(row.dirty == 1 ? "1 unsaved file" : "\(row.dirty) unsaved files") }
        if row.isCurrent { parts.append("open on your Mac") }
        if let a = row.ahead, a > 0 { parts.append(a == 1 ? "1 change not in main" : "\(a) changes not in main") }
        return parts.isEmpty ? nil : (parts.joined(separator: " · ").prefix(1).uppercased() + parts.joined(separator: " · ").dropFirst(), .secondary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.closeable ? "checkmark" : "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 22, height: 22).background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(row.closeable ? .secondary : .primary)
                HStack(spacing: 4) {
                    Text(repoName).lineLimit(1)
                    if let d = row.lastActive {
                        Text("·").foregroundStyle(.quaternary)
                        Text(d, format: .relative(presentation: .named, unitsStyle: .abbreviated)).lineLimit(1).fixedSize()
                    }
                    if row.copilot == .closed && !row.working {
                        Text("·").foregroundStyle(.quaternary)
                        Text("closed in Copilot").lineLimit(1).fixedSize()
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                if let s = status {
                    Text(s.text).font(.system(size: 11, weight: .medium)).foregroundStyle(s.color).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu { actions } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hover ? 1 : 0.5)
            .help("Actions for this branch")
            .accessibilityLabel("Actions for \(row.name)")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(Palette.well.opacity(hover ? 0.45 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { openFull() }
        .contextMenu { actions }
        .help(row.topic.map { "\($0)\n\nClick to see this branch in the Branches view." } ?? "Click to see this branch in the Branches view.")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Show in Branches") { openFull() }
    }

    @ViewBuilder private var actions: some View {
        Button { openFull() } label: { Label("Show in Branches", systemImage: "arrow.triangle.branch") }
        Divider()
        if row.copilot == .closed && row.closeable {
            Button {} label: { Label("Closed in GitHub Copilot", systemImage: "checkmark.circle") }.disabled(true)
        } else {
            Button { SessionActions.openCopilot(workspace: row.folder, branch: row.name, repo: row.repo.contains("/") ? row.repo : nil) } label: {
                Label(row.copilot == .closed ? "Reopen in GitHub Copilot" : "Open in GitHub Copilot", systemImage: "sparkles")
            }
            .disabled(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.github.githubapp") == nil)
        }
        if let u = prURL, let n = row.prs.max() {
            Button { Links.open(u) } label: { Label("Open pull request #\(n)", systemImage: "arrow.triangle.pull") }
        }
        Button { if let d = folderURL { NSWorkspace.shared.activateFileViewerSelecting([d]) } } label: { Label("Show in Finder", systemImage: "folder") }
            .disabled(folderURL == nil)
        Divider()
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.name, forType: .string)
        } label: { Label("Copy branch name", systemImage: "doc.on.doc") }
    }
}

/// A row of capsule options with a sliding highlight, a coloured dot and a count, like the window's filters.
struct CapsuleFilter<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    let count: (T) -> Int
    let dot: (T) -> Color
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selection
                Button { withAnimation(.snappy(duration: 0.22)) { selection = o } } label: {
                    HStack(spacing: 5) {
                        Circle().fill(dot(o)).frame(width: 6, height: 6)
                        Text(title(o))
                        Text("\(count(o))").monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background {
                        if on {
                            Capsule().fill(Palette.card).shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.well))
    }
}
