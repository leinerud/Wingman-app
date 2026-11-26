import Foundation
import SwiftUI

// Everything here only READS a project's git history. Nothing is ever written, checked out or reset.

// MARK: - Git

enum Git {
    /// Real git binaries are preferred over /usr/bin/git, which is a shim that can't run inside the sandbox.
    nonisolated static let executable: String? = ProcessInfo.processInfo.environment["WINGMAN_NO_GIT"] != nil ? nil : [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs a git command and returns its exit status and messages. Used only for actions the user explicitly confirms.
    nonisolated static func runResult(_ args: [String], cwd: String) -> (ok: Bool, out: String, err: String) {
        guard let exe = executable, FileManager.default.fileExists(atPath: cwd) else { return (false, "", "Git isn't available.") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-c", "core.quotepath=off", "-C", cwd] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return (false, "", "Git couldn't be started.") }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a read-only git command in `cwd`. Returns nil when git fails or the folder isn't a repository.
    nonisolated static func run(_ args: [String], cwd: String) -> String? {
        guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else { return nil }
        guard let exe = executable else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-c", "core.quotepath=off", "-C", cwd] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"      // never touch the index, so we can't disturb a running session
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Model

enum ChangeKind: String {
    case screen, component, style, content, asset, logic, config

    var label: String {
        switch self {
        case .screen: "Screen"
        case .component: "Component"
        case .style: "Styling"
        case .content: "Content"
        case .asset: "Image or asset"
        case .logic: "Behaviour"
        case .config: "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .screen: "rectangle.on.rectangle"
        case .component: "square.on.square"
        case .style: "paintpalette"
        case .content: "text.alignleft"
        case .asset: "photo"
        case .logic: "gearshape.2"
        case .config: "slider.horizontal.3"
        }
    }
    /// Designers care most about what people can see.
    var rank: Int {
        switch self {
        case .screen: 0
        case .component: 1
        case .style: 2
        case .content: 3
        case .asset: 4
        case .logic: 5
        case .config: 6
        }
    }
}

/// One visible difference, in plain language ("Text size 12 → 13").
struct DesignChange: Identifiable, Hashable {
    enum Kind { case colour, number, text, added }
    let id = UUID()
    let kind: Kind
    let label: String
    let before: String?
    let after: String
}

struct ScreenChange: Identifiable, Hashable {
    var id: String { name + kind.rawValue }
    let name: String
    let kind: ChangeKind
    var files: [String]
    var added: Int
    var removed: Int
    var changes: [DesignChange]
    var isNew: Bool
    var isDeleted: Bool
}

struct TokenFinding: Identifiable, Hashable {
    enum Kind: String { case colour = "Colour", fontSize = "Text size", spacing = "Spacing" }
    let id = UUID()
    let kind: Kind
    let file: String
    let line: Int
    let value: String
    let message: String
    let suggestion: String?
}

struct CommitEntry: Identifiable, Hashable {
    var id: String { sha }
    let sha: String
    let date: Date
    let subject: String
    var short: String { String(sha.prefix(7)) }
}

enum InspectScope: Hashable {
    case working
    case commit(String)
}

struct InspectorData {
    var isRepo = true
    /// The sandbox hasn't been given this project folder yet.
    var needsAccess = false
    /// Git can't be started here (e.g. inside the sandbox), so this is a simpler view: recently edited files and
    /// the commit history read straight from the repository, but no before/after values.
    var basicMode = false
    var branch: String?
    var scope: InspectScope = .working
    var changes: [ScreenChange] = []
    var findings: [TokenFinding] = []
    var hasTokenFile = false
    var commits: [CommitEntry] = []
    var dirtyFiles = 0
    var added: Int { changes.reduce(0) { $0 + $1.added } }
    var removed: Int { changes.reduce(0) { $0 + $1.removed } }
}

// MARK: - Diff parsing

struct DiffFile {
    var path: String
    var isNew = false
    var isDeleted = false
    var binary = false
    var added: [(line: Int, text: String)] = []
    var removed: [String] = []
    /// Hunks keep removed/added together so we can see what replaced what.
    var hunks: [(removed: [String], added: [(line: Int, text: String)])] = []
}

enum DiffParser {
    nonisolated static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var cur: DiffFile?
        var hunkR: [String] = [], hunkA: [(Int, String)] = []
        var newLine = 0

        func flushHunk() {
            if !hunkR.isEmpty || !hunkA.isEmpty { cur?.hunks.append((hunkR, hunkA)) }
            hunkR = []; hunkA = []
        }
        func flushFile() { flushHunk(); if let c = cur { files.append(c) }; cur = nil }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flushFile()
                // diff --git a/path b/path
                let parts = line.dropFirst("diff --git ".count)
                let path: String
                if let r = parts.range(of: " b/", options: .backwards) { path = String(parts[r.upperBound...]) }
                else { path = String(parts) }
                cur = DiffFile(path: path)
            } else if line.hasPrefix("new file mode") { cur?.isNew = true }
            else if line.hasPrefix("deleted file mode") { cur?.isDeleted = true }
            else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { cur?.binary = true }
            else if line.hasPrefix("@@") {
                flushHunk()
                // @@ -a,b +c,d @@
                if let plus = line.range(of: "+"), let end = line[plus.upperBound...].firstIndex(where: { $0 == "," || $0 == " " }) {
                    newLine = Int(line[plus.upperBound..<end]) ?? 0
                }
            } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") { continue }
            else if line.hasPrefix("+") {
                let t = String(line.dropFirst())
                cur?.added.append((newLine, t)); hunkA.append((newLine, t)); newLine += 1
            } else if line.hasPrefix("-") {
                let t = String(line.dropFirst())
                cur?.removed.append(t); hunkR.append(t)
            }
        }
        flushFile()
        return files
    }
}

// MARK: - File → "what is this, to a designer?"

enum Classify {
    nonisolated static func kind(of path: String) -> ChangeKind {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let lower = path.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "icns", "ico", "heic", "mp4", "mov", "riv", "lottie"].contains(ext)
            || lower.contains(".xcassets/") || lower.contains(".imageset") { return .asset }
        if ["css", "scss", "sass", "less", "styl"].contains(ext)
            || ["theme", "tokens", "palette", "colors", "colours", "typography", "styles", "style", "metrics", "spacing"].contains(where: { name.contains($0) })
            || name.hasPrefix("tailwind") { return .style }
        if ["strings", "xcstrings", "stringsdict", "md", "mdx", "txt"].contains(ext)
            || ["localizable", "copy", "content", "messages", "translations"].contains(where: { name.contains($0) })
            || (ext == "json" && ["en", "sv", "de", "fr", "es", "locale"].contains(where: { name.hasPrefix($0) })) { return .content }
        let componentWords = ["button", "card", "cell", "row", "badge", "icon", "pill", "chip", "field", "menu", "modal", "sheet",
                              "toast", "tooltip", "avatar", "tab", "toggle", "input", "dialog", "banner", "list", "header", "footer", "nav", "toolbar", "label"]
        let screenWords = ["screen", "page", "scene", "window", "welcome", "onboarding", "settings", "dashboard", "home", "view", "popover", "layout", "route"]
        let uiExt = ["swift", "tsx", "jsx", "vue", "svelte", "html", "htm", "kt", "dart", "xib", "storyboard"].contains(ext)
        if uiExt || ext == "astro" {
            if componentWords.contains(where: { name.contains($0) }) { return .component }
            if screenWords.contains(where: { name.contains($0) }) || ["html", "htm", "vue", "svelte", "tsx", "jsx", "astro"].contains(ext) { return .screen }
        }
        if ["json", "yml", "yaml", "plist", "toml", "xcconfig", "pbxproj", "lock", "entitlements", "gitignore"].contains(ext)
            || ["package", "tsconfig", "dockerfile", "makefile"].contains(name) { return .config }
        return .logic
    }

    /// "PopoverView.swift" → "Popover", "session-card.tsx" → "Session card".
    nonisolated static func humanName(of path: String) -> String {
        var base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if base.lowercased() == "index" || base.lowercased() == "page" || base.lowercased() == "layout" {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty && parent != "." { base = parent }
        }
        for suffix in ["View", "Screen", "Controller"] where base.hasSuffix(suffix) && base.count > suffix.count {
            base = String(base.dropLast(suffix.count))
        }
        var out = ""
        let chars = Array(base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
        for (i, c) in chars.enumerated() {
            if c.isUppercase, i > 0, chars[i - 1].isLowercase || chars[i - 1].isNumber { out.append(" ") }
            out.append(c)
        }
        let s = out.trimmingCharacters(in: .whitespaces)
        guard let f = s.first else { return path }
        return f.uppercased() + s.dropFirst().lowercased().replacingOccurrences(of: " ", with: " ")
    }
}

// MARK: - What changed, in plain words

enum DesignDiff {
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"|#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)|\b\d+(?:\.\d+)?\b"#)

    private struct Tok { let text: String; let range: NSRange; var isString: Bool { text.hasPrefix("\"") } }

    private static func tokens(_ line: String) -> [Tok] {
        let ns = line as NSString
        return tokenRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { Tok(text: ns.substring(with: $0.range), range: $0.range) }
    }

    /// The line with every value blanked out, so "size: 12" and "size: 13" look the same.
    private static func shape(_ line: String) -> String {
        let ns = NSMutableString(string: line.trimmingCharacters(in: .whitespaces))
        tokenRegex.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "§")
        return ns as String
    }

    private static func isColour(_ t: String) -> Bool {
        t.hasPrefix("#") || t.hasPrefix("rgb") || t.hasPrefix("hsl")
    }

    /// The word just before a value: `size: 12` → "size", `.padding(12)` → "padding".
    private static func key(before tok: Tok, in line: String) -> String {
        let ns = line as NSString
        let head = ns.substring(to: tok.range.location)
        let pat = try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9_-]*)\s*[:(=,]?\s*[\(\[]?\s*$"#)
        if let m = pat.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
            return (head as NSString).substring(with: m.range(at: 1))
        }
        return ""
    }

    private static func label(for key: String, colour: Bool, string: Bool) -> String {
        let k = key.lowercased()
        if string { return "Text" }
        if colour { return k.contains("background") || k.contains("fill") || k == "bg" ? "Background colour" : k.contains("border") || k.contains("stroke") ? "Border colour" : "Colour" }
        if k.contains("radius") { return "Corner radius" }
        if k.contains("fontsize") || k == "size" || k.contains("font-size") || k.contains("font") { return "Text size" }
        if k.contains("padding") || k.contains("margin") || k.contains("gap") || k.contains("spacing") { return "Spacing" }
        if k.contains("width") || k.contains("height") || k.contains("frame") { return "Size" }
        if k.contains("opacity") || k.contains("alpha") { return "Opacity" }
        if k.contains("weight") { return "Font weight" }
        if k.contains("line") && k.contains("height") { return "Line height" }
        if k.contains("duration") || k.contains("delay") { return "Animation timing" }
        if k.contains("shadow") || k.contains("blur") { return "Shadow" }
        if k.contains("border") || k.contains("stroke") || k.contains("line") { return "Line thickness" }
        return "Value"
    }

    /// Pairs up each replaced line with the line that replaced it and reports the values that moved.
    nonisolated static func changes(in file: DiffFile) -> [DesignChange] {
        guard !file.binary, !file.isDeleted else { return [] }
        var out: [DesignChange] = []
        for hunk in file.hunks {
            var removedPool = hunk.removed.map { (text: $0, shape: shape($0), used: false) }
            for add in hunk.added {
                let aTokens = tokens(add.text)
                guard !aTokens.isEmpty else { continue }
                let s = shape(add.text)
                if let idx = removedPool.firstIndex(where: { !$0.used && $0.shape == s }) {
                    removedPool[idx].used = true
                    let rTokens = tokens(removedPool[idx].text)
                    guard rTokens.count == aTokens.count else { continue }
                    for (r, a) in zip(rTokens, aTokens) where r.text != a.text {
                        let colour = isColour(a.text)
                        let k = key(before: a, in: add.text)
                        out.append(DesignChange(kind: colour ? .colour : a.isString ? .text : .number,
                                                label: label(for: k, colour: colour, string: a.isString),
                                                before: clean(r.text), after: clean(a.text)))
                    }
                } else if !file.isNew {
                    // A brand-new line with a visible value, e.g. a new colour or size.
                    for a in aTokens where isColour(a.text) {
                        out.append(DesignChange(kind: .added, label: label(for: key(before: a, in: add.text), colour: true, string: false), before: nil, after: clean(a.text)))
                    }
                }
            }
        }
        // De-duplicate identical rows (the same colour swapped in many places).
        var seen = Set<String>(), unique: [DesignChange] = []
        for c in out {
            let k = "\(c.label)|\(c.before ?? "")|\(c.after)"
            if seen.insert(k).inserted { unique.append(c) }
        }
        return Array(unique.prefix(14))
    }

    private static func clean(_ t: String) -> String {
        t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 ? String(t.dropFirst().dropLast()) : t
    }
}

// MARK: - Token guard

enum TokenGuard {
    struct Tokens { var colours: Set<String> = []; var scale: Set<Double> = []; var files: Set<String> = []; var isEmpty: Bool { colours.isEmpty && scale.isEmpty } }

    private static let hexRegex = try! NSRegularExpression(pattern: #"#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b"#)
    private static let numRegex = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)
    private static let fileHint = try! NSRegularExpression(
        pattern: #"(token|theme|palette|colou?rs?|variables|globals?|design-?system|tailwind\.config|spacing|typography|metrics)"#, options: .caseInsensitive)

    nonisolated static func normalize(hex: String) -> String {
        var h = hex.lowercased().replacingOccurrences(of: "#", with: "")
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        if h.count == 8 { h = String(h.prefix(6)) }
        return h
    }

    /// Finds the project's own design values (colours, spacing scale) in its token / theme files.
    nonisolated static func loadTokens(cwd: String) -> Tokens {
        var t = Tokens()
        guard let list = Git.run(["ls-files", "--cached", "--others", "--exclude-standard"], cwd: cwd) else { return t }
        let exts: Set<String> = ["css", "scss", "less", "json", "js", "ts", "mjs", "swift", "xml", "yaml", "yml"]
        let candidates = list.split(separator: "\n").map(String.init).filter { path in
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let name = URL(fileURLWithPath: path).lastPathComponent
            return exts.contains(ext) && !path.contains("node_modules") && !path.contains("package-lock")
                && fileHint.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
        }.prefix(40)
        for rel in candidates {
            let url = URL(fileURLWithPath: cwd).appendingPathComponent(rel)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  ((attrs[.size] as? NSNumber)?.intValue ?? 0) < 300_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            t.files.insert(rel)
            let ns = text as NSString
            for m in hexRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                t.colours.insert(normalize(hex: ns.substring(with: m.range)))
            }
            for line in text.split(separator: "\n") {
                let l = line.lowercased()
                guard l.contains("space") || l.contains("size") || l.contains("radius") || l.contains("gap") || l.contains("--") else { continue }
                let ln = String(line) as NSString
                for m in numRegex.matches(in: String(line), range: NSRange(location: 0, length: ln.length)) {
                    if let d = Double(ln.substring(with: m.range)) { t.scale.insert(d) }
                }
            }
        }
        return t
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255))
    }

    nonisolated static func nearest(to hex: String, in set: Set<String>) -> String? {
        guard let a = rgb(hex) else { return nil }
        var best: (String, Double)?
        for t in set {
            guard let b = rgb(t) else { continue }
            let d = sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
            if best == nil || d < best!.1 { best = (t, d) }
        }
        if let b = best, b.1 < 60 { return "#" + b.0.uppercased() }
        return nil
    }

    private static let spacingKeys = ["padding", "margin", "gap", "spacing", "inset"]
    private static let keyedNumber = try! NSRegularExpression(
        pattern: #"(padding|margin|gap|spacing|inset|font-size|fontSize|size|cornerRadius|border-radius|radius)\s*[:(=]\s*\(?\s*(\d+(?:\.\d+)?)"#, options: .caseInsensitive)

    nonisolated static func check(files: [DiffFile], tokens: Tokens) -> [TokenFinding] {
        var out: [TokenFinding] = []
        for f in files where !f.binary && !f.isDeleted {
            if tokens.files.contains(f.path) { continue }          // defining a token is not drift
            if Classify.kind(of: f.path) == .config || Classify.kind(of: f.path) == .content { continue }
            for (lineNo, text) in f.added {
                let ns = text as NSString
                for m in hexRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let raw = ns.substring(with: m.range)
                    let hex = normalize(hex: raw)
                    if tokens.colours.contains(hex) { continue }
                    let near = nearest(to: hex, in: tokens.colours)
                    out.append(TokenFinding(kind: .colour, file: f.path, line: lineNo, value: raw.uppercased(),
                        message: tokens.colours.isEmpty ? "Hard-coded colour. Consider adding it as a token."
                                                        : "Not one of your design colours.",
                        suggestion: near.map { "Closest token: \($0)" }))
                }
                for m in keyedNumber.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let key = ns.substring(with: m.range(at: 1)).lowercased()
                    guard let value = Double(ns.substring(with: m.range(at: 2))), value > 0 else { continue }
                    let isSpacing = spacingKeys.contains(where: { key.contains($0) })
                    let kind: TokenFinding.Kind = isSpacing ? .spacing : (key.contains("radius") ? .spacing : .fontSize)
                    if !tokens.scale.isEmpty {
                        if tokens.scale.contains(value) { continue }
                        let nearest = tokens.scale.min(by: { abs($0 - value) < abs($1 - value) })
                        out.append(TokenFinding(kind: kind, file: f.path, line: lineNo, value: trim(value),
                            message: "\(trim(value)) isn't on your scale.",
                            suggestion: nearest.map { "Closest on your scale: \(trim($0))" }))
                    } else if isSpacing, value > 2, value.truncatingRemainder(dividingBy: 4) != 0 {
                        out.append(TokenFinding(kind: .spacing, file: f.path, line: lineNo, value: trim(value),
                            message: "Off the 4-point grid.", suggestion: "Try \(trim((value / 4).rounded() * 4))"))
                    }
                }
            }
        }
        return Array(out.prefix(60))
    }

    private static func trim(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
}

// MARK: - Inspector (builds everything off the main thread)

enum Inspector {
    nonisolated static func inspect(cwd: String, scope: InspectScope) -> InspectorData {
        var data = InspectorData(scope: scope)
        guard Access.canRead(cwd) else { data.needsAccess = true; data.isRepo = false; return data }
        guard Git.run(["--version"], cwd: cwd) != nil else { return basic(cwd: cwd, data: data) }
        guard Git.run(["rev-parse", "--is-inside-work-tree"], cwd: cwd) != nil else { data.isRepo = false; return data }

        data.branch = Git.run(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let log = Git.run(["log", "-n", "40", "--format=%H%x1f%ct%x1f%s"], cwd: cwd) {
            data.commits = log.split(separator: "\n").compactMap { row in
                let p = row.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard p.count == 3, let t = TimeInterval(p[1]) else { return nil }
                return CommitEntry(sha: p[0], date: Date(timeIntervalSince1970: t), subject: p[2])
            }
        }

        var files: [DiffFile] = []
        switch scope {
        case .working:
            let hasHead = Git.run(["rev-parse", "--verify", "HEAD"], cwd: cwd) != nil
            let diff = Git.run(hasHead ? ["diff", "HEAD", "--no-color", "--no-ext-diff", "-U0"] : ["diff", "--no-color", "--no-ext-diff", "-U0"], cwd: cwd) ?? ""
            files = DiffParser.parse(diff)
            // New files git hasn't seen yet.
            if let untracked = Git.run(["ls-files", "--others", "--exclude-standard"], cwd: cwd) {
                for rel in untracked.split(separator: "\n").map(String.init).prefix(60) where !files.contains(where: { $0.path == rel }) {
                    var f = DiffFile(path: rel); f.isNew = true
                    let url = URL(fileURLWithPath: cwd).appendingPathComponent(rel)
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), ((attrs[.size] as? NSNumber)?.intValue ?? 0) < 400_000,
                       let text = try? String(contentsOf: url, encoding: .utf8) {
                        let lines = text.components(separatedBy: "\n")
                        f.added = lines.enumerated().map { ($0.offset + 1, $0.element) }
                    } else { f.binary = true }
                    files.append(f)
                }
            }
        case .commit(let sha):
            let diff = Git.run(["show", "--no-color", "--no-ext-diff", "-U0", "--format=", sha], cwd: cwd) ?? ""
            files = DiffParser.parse(diff)
        }
        data.dirtyFiles = files.count

        // Group files into "screens and components" the way a designer thinks of them.
        var groups: [String: ScreenChange] = [:]
        for f in files {
            let kind = Classify.kind(of: f.path)
            let name = kind == .asset ? "Images and assets" : kind == .config ? "Project settings" : kind == .logic ? "Behind the scenes" : Classify.humanName(of: f.path)
            let key = name + kind.rawValue
            var g = groups[key] ?? ScreenChange(name: name, kind: kind, files: [], added: 0, removed: 0, changes: [], isNew: true, isDeleted: true)
            g.files.append(f.path)
            g.added += f.binary ? 0 : f.added.count
            g.removed += f.removed.count
            // Numbers in code nobody sees on screen are noise to a designer; only keep what has a clear meaning.
            let visual = kind == .screen || kind == .component || kind == .style
            g.changes += DesignDiff.changes(in: f).filter { visual || $0.label != "Value" }
            if !visual { g.changes = g.changes.filter { $0.label != "Value" } }
            g.isNew = g.isNew && f.isNew
            g.isDeleted = g.isDeleted && f.isDeleted
            groups[key] = g
        }
        data.changes = groups.values.sorted { ($0.kind.rank, $1.added + $1.removed) < ($1.kind.rank, $0.added + $0.removed) }

        let tokens = TokenGuard.loadTokens(cwd: cwd)
        data.hasTokenFile = !tokens.files.isEmpty
        data.findings = TokenGuard.check(files: files, tokens: tokens)
        return data
    }
}

// MARK: - Basic mode (no git available)

extension Inspector {
    private static let skipDirs: Set<String> = ["node_modules", "build", "dist", "DerivedData", ".build", "Pods", "vendor", "target", "out", "coverage"]

    /// Reads what it can from the files themselves: recently edited files, and the commit list from `.git/logs/HEAD`.
    nonisolated static func basic(cwd: String, data input: InspectorData) -> InspectorData {
        var data = input
        data.basicMode = true
        data.isRepo = true

        if let head = try? String(contentsOfFile: cwd + "/.git/HEAD", encoding: .utf8), head.hasPrefix("ref: refs/heads/") {
            data.branch = head.dropFirst("ref: refs/heads/".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Reflog lines: "<old> <new> Name <email> <time> <zone>\t<message>"
        if let log = try? String(contentsOfFile: cwd + "/.git/logs/HEAD", encoding: .utf8) {
            var seen = Set<String>()
            for row in log.split(separator: "\n").reversed() {
                let halves = row.split(separator: "\t", maxSplits: 1).map(String.init)
                guard halves.count == 2 else { continue }
                let left = halves[0].split(separator: " ").map(String.init)
                guard left.count >= 5, let t = TimeInterval(left[left.count - 2]) else { continue }
                let sha = left[1]
                guard seen.insert(sha).inserted else { continue }
                var subject = halves[1]
                for prefix in ["commit: ", "commit (initial): ", "commit (merge): ", "merge ", "rebase (finish): "] where subject.hasPrefix(prefix) {
                    subject = String(subject.dropFirst(prefix.count)); break
                }
                data.commits.append(CommitEntry(sha: sha, date: Date(timeIntervalSince1970: t), subject: subject))
                if data.commits.count >= 40 { break }
            }
        }

        // Files edited in the last three hours stand in for "what this session changed".
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        var files: [DiffFile] = []
        let root = URL(fileURLWithPath: cwd)
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in en {
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if vals?.isDirectory == true {
                    if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                    continue
                }
                guard let m = vals?.contentModificationDate, m > cutoff else { continue }
                files.append(DiffFile(path: String(url.path.dropFirst(root.path.count + 1))))
                if files.count >= 300 { break }
            }
        }
        data.dirtyFiles = files.count

        var groups: [String: ScreenChange] = [:]
        for f in files {
            let kind = Classify.kind(of: f.path)
            let name = kind == .asset ? "Images and assets" : kind == .config ? "Project settings" : kind == .logic ? "Behind the scenes" : Classify.humanName(of: f.path)
            var g = groups[name + kind.rawValue] ?? ScreenChange(name: name, kind: kind, files: [], added: 0, removed: 0, changes: [], isNew: false, isDeleted: false)
            g.files.append(f.path)
            groups[name + kind.rawValue] = g
        }
        data.changes = groups.values.sorted { ($0.kind.rank, $1.files.count) < ($1.kind.rank, $0.files.count) }
        return data
    }
}

// MARK: - Cache used by the session cards

struct DriftSummary: Equatable {
    var isRepo = false
    var changedFiles = 0
    var drift = 0
}

@MainActor
final class InspectorCache: ObservableObject {
    static let shared = InspectorCache()
    @Published private(set) var summaries: [String: DriftSummary] = [:]
    private var lastKey: [String: Date] = [:]
    private var inFlight: Set<String> = []

    func summary(_ id: String) -> DriftSummary { summaries[id] ?? DriftSummary() }

    /// Forces a fresh look, e.g. after the user has allowed a project folder.
    func forget(_ id: String) { lastKey[id] = nil }

    /// Looks again only when the session has actually done something new.
    func refresh(_ s: CopilotSession) {
        guard !s.cwd.isEmpty, lastKey[s.id] != s.updatedAt, !inFlight.contains(s.id) else { return }
        lastKey[s.id] = s.updatedAt
        inFlight.insert(s.id)
        let cwd = s.cwd, id = s.id
        Task.detached(priority: .utility) {
            let d = Inspector.inspect(cwd: cwd, scope: .working)
            let summary = DriftSummary(isRepo: d.isRepo, changedFiles: d.dirtyFiles, drift: d.findings.count)
            await MainActor.run {
                InspectorCache.shared.inFlight.remove(id)
                if InspectorCache.shared.summaries[id] != summary { InspectorCache.shared.summaries[id] = summary }
            }
        }
    }
}
