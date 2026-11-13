import SwiftUI
import AppKit
import WebKit

// MARK: - Helpers

extension Color {
    /// "#1A2B3C", "#abc" → Color. Returns nil for anything else.
    init?(cssHex: String) {
        let h = TokenGuard.normalize(hex: cssHex)
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}

// MARK: - Model

@MainActor
final class InspectorModel: ObservableObject {
    @Published var data = InspectorData()
    @Published var loading = true
    @Published var scope: InspectScope = .working
    private var cwd = ""
    private var generation = 0

    func load(cwd: String, scope: InspectScope? = nil) {
        self.cwd = cwd
        if let scope { self.scope = scope }
        generation += 1
        let gen = generation, sc = self.scope, dir = cwd
        loading = true
        Task.detached(priority: .userInitiated) {
            let d = Inspector.inspect(cwd: dir, scope: sc)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.data = d
                self.loading = false
            }
        }
    }
}

// MARK: - Window

struct InspectorWindow: View {
    let sessionID: String
    @EnvironmentObject var store: SessionStore
    @StateObject private var model = InspectorModel()
    @State private var tab: Tab = .changes
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes", tokens = "Tokens", timeline = "Timeline", preview = "Preview"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .changes: "rectangle.on.rectangle"
            case .tokens: "paintpalette"
            case .timeline: "clock.arrow.circlepath"
            case .preview: "macwindow"
            }
        }
    }

    private var session: CopilotSession? { store.sessions.first { $0.id == sessionID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                if let s = session, model.data.needsAccess {
                    VStack(spacing: 12) {
                        EmptyNote(symbol: "lock", title: "Allow access to this project",
                                  message: "macOS keeps apps out of your folders until you say so. Pick this project, or a parent folder such as Developer to cover all of them.")
                        Button("Choose folder…") {
                            if Access.requestProjectFolder(for: s.cwd) { model.load(cwd: s.cwd); InspectorCache.shared.forget(s.id) }
                        }.buttonStyle(PillButtonStyle(tint: Palette.accent, filled: true)).padding(.bottom, 30)
                    }
                } else if model.data.gitMissing {
                    EmptyNote(symbol: "exclamationmark.triangle", title: "Git isn't available here",
                              message: "Review needs git to compare versions. Install Xcode or the Command Line Tools (xcode-select --install) and reopen this window.")
                } else if let s = session {
                    switch tab {
                    case .changes: ChangesTab(model: model, session: s)
                    case .tokens: TokensTab(model: model, session: s)
                    case .timeline: TimelineTab(model: model, session: s, goToChanges: { tab = .changes })
                    case .preview: PreviewTab(session: s)
                    }
                } else {
                    EmptyNote(symbol: "questionmark.folder", title: "This session isn't here any more", message: "It may have been removed from Copilot.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Palette.canvas)
        .onAppear { if let s = session { model.load(cwd: s.cwd) } }
        // Follow along while the session keeps working.
        .onChange(of: session?.updatedAt) { _, _ in if let s = session { model.load(cwd: s.cwd) } }
        .navigationTitle(session?.title ?? "Review")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    if let c = session?.tag.color { Circle().fill(c).frame(width: 9, height: 9) }
                    Text(session?.title ?? "Review").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let s = session { StatusPill(status: s.status) }
                    if let b = model.data.branch { Label(b, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { t in
                    let on = t == tab
                    Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { tab = t } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.symbol).font(.system(size: 11))
                            Text(t.rawValue)
                            if t == .tokens, !model.data.findings.isEmpty {
                                Text("\(model.data.findings.count)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.attention)
                            }
                        }
                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(on ? Palette.card : .clear).shadow(color: .black.opacity(on ? 0.1 : 0), radius: 1.5, y: 0.5))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(Tab.allCases.firstIndex(of: t)! + 1)")), modifiers: .command)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2).background(Capsule().fill(Palette.well))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}

struct EmptyNote: View {
    let symbol: String, title: String, message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Changes

private struct ChangesTab: View {
    @ObservedObject var model: InspectorModel
    let session: CopilotSession

    var body: some View {
        let d = model.data
        if model.loading && d.changes.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !d.isRepo {
            EmptyNote(symbol: "folder.badge.questionmark", title: "No version history here",
                      message: "This project isn't tracked with git, so there's nothing to compare against.")
        } else if d.changes.isEmpty {
            EmptyNote(symbol: "checkmark.circle", title: scopeIsCommit ? "Nothing visible in this version" : "No changes right now",
                      message: scopeIsCommit ? "This version only changed things behind the scenes." : "Everything is saved. New changes show up here as the session works.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary(d)
                    ForEach(d.changes) { ChangeCard(change: $0, cwd: session.cwd) }
                }
                .padding(18)
            }
        }
    }

    private var scopeIsCommit: Bool { if case .commit = model.scope { return true }; return false }

    private func summary(_ d: InspectorData) -> some View {
        HStack(spacing: 10) {
            if case .commit(let sha) = model.scope {
                Button { model.load(cwd: session.cwd, scope: .working) } label: { Label("Back to current changes", systemImage: "chevron.left") }
                    .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                Text("Version \(String(sha.prefix(7)))").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Text("\(d.changes.count) \(d.changes.count == 1 ? "thing" : "things") changed, not yet saved as a version")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("+\(d.added)").foregroundStyle(Palette.ready)
            Text("−\(d.removed)").foregroundStyle(Palette.attention)
        }
        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
    }
}

private struct ChangeCard: View {
    let change: ScreenChange
    let cwd: String
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: change.kind.symbol).font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26).background(Circle().fill(Palette.well))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(change.name).font(.system(size: 13, weight: .semibold))
                        if change.isNew { Tag(text: "New", tint: Palette.ready) }
                        if change.isDeleted { Tag(text: "Removed", tint: Palette.attention) }
                    }
                    Text(change.kind.label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("+\(change.added) −\(change.removed)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
            }
            if !change.changes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(change.changes.enumerated()), id: \.element.id) { i, c in
                        ChangeRow(change: c)
                        if i < change.changes.count - 1 { Divider().opacity(0.4) }
                    }
                }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.well.opacity(0.55)))
            }
            Button { withAnimation(.snappy(duration: 0.25)) { showFiles.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(showFiles ? "Hide files" : "\(change.files.count) \(change.files.count == 1 ? "file" : "files")")
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).rotationEffect(.degrees(showFiles ? 180 : 0))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            if showFiles {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(change.files, id: \.self) { f in
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: cwd).appendingPathComponent(f)) } label: {
                            Text(f).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.buttonStyle(.plain).help("Open in your default app")
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Palette.hairline))
        .accessibilityElement(children: .contain)
    }
}

private struct Tag: View {
    let text: String, tint: Color
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(tint)
            .padding(.horizontal, 6).frame(height: 15).background(Capsule().fill(tint.opacity(0.14)))
    }
}

private struct Swatch: View {
    let hex: String
    var body: some View {
        if let c = Color(cssHex: hex) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(c).frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }
}

private struct ChangeRow: View {
    let change: DesignChange
    var body: some View {
        HStack(spacing: 8) {
            Text(change.label).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
            if let b = change.before {
                value(b)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            } else {
                Text("New").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ready)
            }
            value(change.after).fontWeight(.semibold)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(change.label): \(change.before.map { "from \($0) to " } ?? "new ")\(change.after)")
    }

    private func value(_ v: String) -> some View {
        HStack(spacing: 5) {
            if change.kind == .colour || change.kind == .added { Swatch(hex: v) }
            Text(v).font(.system(size: 11.5, design: change.kind == .text ? .default : .monospaced)).lineLimit(1)
        }
    }
}

// MARK: - Tokens

private struct TokensTab: View {
    @ObservedObject var model: InspectorModel
    let session: CopilotSession

    var body: some View {
        let d = model.data
        if !d.isRepo {
            EmptyNote(symbol: "folder.badge.questionmark", title: "No version history here", message: "The token check compares new changes against your project's own values.")
        } else if d.findings.isEmpty {
            EmptyNote(symbol: "checkmark.seal", title: "On-system",
                      message: d.hasTokenFile
                        ? "No hard-coded colours, text sizes or spacing outside your design tokens in the current changes."
                        : "No hard-coded colours or off-grid spacing in the current changes. (No token or theme file was found, so the 4-point grid is used.)")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention)
                        Text("\(d.findings.count) \(d.findings.count == 1 ? "value" : "values") outside your design system")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    if !d.hasTokenFile {
                        Text("No token or theme file was found in this project, so every hard-coded colour is flagged and spacing is checked against a 4-point grid.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(d.findings) { f in
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd).appendingPathComponent(f.file)) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                if f.kind == .colour { Swatch(hex: f.value).padding(.top, 1) }
                                else { Image(systemName: f.kind == .spacing ? "ruler" : "textformat.size").frame(width: 16).foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(f.kind.rawValue).font(.system(size: 11.5, weight: .semibold))
                                        Text(f.value).font(.system(size: 11.5, design: .monospaced))
                                    }
                                    Text(f.message + (f.suggestion.map { " " + $0 + "." } ?? ""))
                                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Text("\(f.file):\(f.line)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Open this file")
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - Timeline

private struct TimelineTab: View {
    @ObservedObject var model: InspectorModel
    let session: CopilotSession
    let goToChanges: () -> Void
    @State private var copied: String?

    var body: some View {
        let d = model.data
        if !d.isRepo {
            EmptyNote(symbol: "folder.badge.questionmark", title: "No version history here", message: "Timelines are built from git versions, and this project doesn't use git.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(title: "Now", subtitle: d.dirtyFiles == 0 ? "Everything is saved" : "\(d.dirtyFiles) \(d.dirtyFiles == 1 ? "file" : "files") not yet saved as a version",
                        date: nil, sha: nil, current: true, last: d.commits.isEmpty)
                    ForEach(Array(d.commits.enumerated()), id: \.element.id) { i, c in
                        row(title: c.subject, subtitle: nil, date: c.date, sha: c, current: false, last: i == d.commits.count - 1)
                    }
                }
                .padding(18)
            }
        }
    }

    private func row(title: String, subtitle: String?, date: Date?, sha: CommitEntry?, current: Bool, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(current ? Palette.working : Palette.muted.opacity(0.6)).frame(width: 9, height: 9).padding(.top, 5)
                if !last { Rectangle().fill(Palette.hairline).frame(width: 1.5).frame(maxHeight: .infinity) }
            }.frame(width: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: current ? .semibold : .medium)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let subtitle { Text(subtitle) }
                    if let date { Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated)) }
                    if let sha { Text(sha.short).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if current {
                        Button("See changes") { model.load(cwd: session.cwd, scope: .working); goToChanges() }.buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                    } else if let sha {
                        Button("See what changed") { model.load(cwd: session.cwd, scope: .commit(sha.sha)); goToChanges() }
                            .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false))
                        Menu {
                            Button { copy("git -C \"\(session.cwd)\" restore --source=\(sha.sha) --worktree -- .", id: sha.sha) } label: {
                                Label("Copy command to bring these files back", systemImage: "arrow.uturn.backward")
                            }
                            Button { copy(sha.sha, id: sha.sha) } label: { Label("Copy version ID", systemImage: "doc.on.doc") }
                            if let url = SessionActions.githubURL(session, path: "/commit/\(sha.sha)") {
                                Button { NSWorkspace.shared.open(url) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                            }
                        } label: { Text(copied == sha.sha ? "Copied" : "More") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Nothing is changed in your project. Restoring is a command you run yourself.")
                    }
                }
            }
            .padding(.bottom, 16)
            Spacer(minLength: 0)
        }
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if copied == id { copied = nil } }
    }
}

// MARK: - Preview

@MainActor
final class PreviewController: ObservableObject {
    weak var webView: WKWebView?
    @Published var reloadToken = 0

    func snapshot() async -> NSImage? {
        guard let w = webView else { return nil }
        return try? await w.takeSnapshot(configuration: WKSnapshotConfiguration())
    }
}

struct WebPreview: NSViewRepresentable {
    let url: URL
    let readAccess: URL?
    let controller: PreviewController

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded: URL?; var token = 0 }

    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero)
        v.allowsMagnification = true
        controller.webView = v
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        let c = context.coordinator
        if c.loaded != url {
            c.loaded = url
            if url.isFileURL { v.loadFileURL(url, allowingReadAccessTo: readAccess ?? url.deletingLastPathComponent()) }
            else { v.load(URLRequest(url: url)) }
        } else if c.token != controller.reloadToken {
            v.reload()
        }
        c.token = controller.reloadToken
        controller.webView = v
    }
}

private enum Device: String, CaseIterable, Identifiable {
    case desktop = "Desktop", tablet = "Tablet", phone = "Phone"
    var id: Self { self }
    var width: CGFloat? { switch self { case .desktop: nil; case .tablet: 768; case .phone: 390 } }
    var symbol: String { switch self { case .desktop: "desktopcomputer"; case .tablet: "ipad"; case .phone: "iphone" } }
}

private struct PreviewTab: View {
    let session: CopilotSession
    @StateObject private var controller = PreviewController()
    @State private var urlText = ""
    @State private var url: URL?
    @State private var detected: [URL] = []
    @State private var device: Device = .desktop
    @State private var compare = false
    @State private var before: NSImage?
    @State private var after: NSImage?
    @State private var split: CGFloat = 0.5
    @State private var autoRefresh = true

    private var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PajlotAssist/Snapshots/\(session.id)", isDirectory: true)
    }
    private var defaultsKey: String { "previewURL.\(session.id)" }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            ZStack {
                Palette.well.opacity(0.5)
                if compare { compareView }
                else if let url {
                    WebPreview(url: url, readAccess: URL(fileURLWithPath: session.cwd), controller: controller)
                        .frame(maxWidth: device.width ?? .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: device == .desktop ? 0 : 12, style: .continuous))
                        .shadow(color: .black.opacity(device == .desktop ? 0 : 0.15), radius: 8, y: 2)
                        .padding(device == .desktop ? 0 : 14)
                } else {
                    EmptyNote(symbol: "macwindow", title: "Nothing to preview yet",
                              message: "Start your project's dev server and it shows up here, or paste an address above. Pages saved as files in the project also work.")
                }
            }
        }
        .task { await setup() }
        .onChange(of: session.updatedAt) { _, _ in if autoRefresh && !compare { controller.reloadToken += 1 } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("Address, e.g. localhost:3000", text: $urlText)
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(minWidth: 160)
                .onSubmit { open(urlText) }
            if !detected.isEmpty {
                Menu {
                    ForEach(detected, id: \.self) { u in Button(u.absoluteString) { urlText = u.absoluteString; open(u.absoluteString) } }
                } label: { Label("Found \(detected.count)", systemImage: "dot.radiowaves.left.and.right") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Picker("", selection: $device) {
                ForEach(Device.allCases) { Image(systemName: $0.symbol).help($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 100).help("Preview width")
            Spacer(minLength: 0)
            Toggle("Auto", isOn: $autoRefresh).toggleStyle(.switch).controlSize(.mini).help("Reload the preview whenever the session does something")
            IconButton(symbol: "arrow.clockwise", help: "Reload") { controller.reloadToken += 1 }
            Button { Task { await setBefore() } } label: { Label("Set as before", systemImage: "camera") }
                .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: false)).disabled(url == nil || compare)
            Button { Task { await toggleCompare() } } label: { Label(compare ? "Live view" : "Compare", systemImage: compare ? "macwindow" : "square.split.2x1") }
                .buttonStyle(PillButtonStyle(tint: Palette.accent, filled: compare)).disabled(before == nil && !compare)
                .help(before == nil ? "Save a “before” first" : "Slide between before and now")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder private var compareView: some View {
        if let before, let after {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Image(nsImage: after).resizable().scaledToFit().frame(width: g.size.width, height: g.size.height)
                    Image(nsImage: before).resizable().scaledToFit().frame(width: g.size.width, height: g.size.height)
                        .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * split) }
                    Rectangle().fill(Color.white).frame(width: 2).shadow(radius: 2).offset(x: g.size.width * split - 1)
                    Circle().fill(Color.white).frame(width: 26, height: 26).shadow(radius: 3)
                        .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
                        .offset(x: g.size.width * split - 13)
                    VStack { HStack {
                        label("Before"); Spacer(); label("Now")
                    }.padding(10); Spacer() }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(1, max(0, $0.location.x / g.size.width)) })
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Before and now comparison slider")
            .accessibilityValue("\(Int(split * 100)) percent before")
            .accessibilityAdjustableAction { dir in split = min(1, max(0, split + (dir == .increment ? 0.1 : -0.1))) }
        } else { ProgressView().controlSize(.small) }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(.black.opacity(0.55)))
    }

    // MARK: Logic

    private func setup() async {
        urlText = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        before = NSImage(contentsOf: dir.appendingPathComponent("before.png"))
        let found = await Self.detectServers()
        detected = found
        if !urlText.isEmpty { open(urlText) }
        else if let first = found.first { urlText = first.absoluteString; open(urlText) }
        else if let file = Self.localHTML(in: session.cwd) { urlText = file.path; url = file }
    }

    private func open(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t.hasPrefix("/") { url = URL(fileURLWithPath: t) }
        else {
            if !t.contains("://") { t = "http://" + t }
            url = URL(string: t)
        }
        UserDefaults.standard.set(text, forKey: defaultsKey)
        controller.reloadToken += 1
    }

    private func save(_ img: NSImage, as name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
    }

    private func setBefore() async {
        guard let img = await controller.snapshot() else { return }
        before = img; save(img, as: "before.png")
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
    }

    private func toggleCompare() async {
        if compare { compare = false; return }
        after = await controller.snapshot()
        compare = after != nil
    }

    nonisolated static func localHTML(in cwd: String) -> URL? {
        for rel in ["index.html", "public/index.html", "dist/index.html", "build/index.html", "docs/index.html"] {
            let p = cwd + "/" + rel
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// Looks for a dev server on the usual ports of the common web tools.
    nonisolated static func detectServers() async -> [URL] {
        let ports = [3000, 3001, 4200, 4321, 5173, 5174, 6006, 8000, 8080, 8081, 1313, 9000]
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 0.6
        let session = URLSession(configuration: cfg)
        return await withTaskGroup(of: URL?.self) { group in
            for p in ports {
                group.addTask {
                    guard let u = URL(string: "http://localhost:\(p)") else { return nil }
                    var r = URLRequest(url: u); r.httpMethod = "HEAD"
                    return (try? await session.data(for: r)) != nil ? u : nil
                }
            }
            var found: [URL] = []
            for await u in group { if let u { found.append(u) } }
            return found.sorted { $0.absoluteString < $1.absoluteString }
        }
    }
}
