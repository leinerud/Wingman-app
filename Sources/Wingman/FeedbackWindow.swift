import SwiftUI
import WebKit

// Send Feedback… (Help menu, the speech bubble in the panel, Settings): a window to write feedback in, sent straight to leinerud.se (functions/api/feedback.ts
// in the website repo), which saves it and emails it to me. The site keeps bots out with Cloudflare Turnstile,
// which only runs on the site's own pages, so a tiny page there (leinerud.se/turnstile/) runs in a hidden web
// view and hands over a token. If Turnstile wants a click, the web view shows in the window.

enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug, idea, love, question
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bug: "Problem"
        case .idea: "Idea"
        case .love: "Praise"
        case .question: "Question"
        }
    }
    var prompt: String {
        switch self {
        case .bug: "What happened, and what did you expect?"
        case .idea: "What would make Wingman better for you?"
        case .love: "What do you like?"
        case .question: "What would you like to know?"
        }
    }
}

@MainActor
final class FeedbackModel: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    enum Phase: Equatable { case writing, sending, sent }

    @Published var kind: FeedbackKind = .bug
    @Published var message = ""
    @Published var email = ""
    @Published var phase: Phase = .writing
    @Published var error: String?
    /// Turnstile wants the person to click: show its web view.
    @Published var needsCheck = false

    static let site = URL(string: "https://leinerud.se")!
    let webView: WKWebView
    private var token: String?
    private var checkFailed = false
    private var waiting: [CheckedContinuation<String?, Never>] = []

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let os: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }()

    var canSend: Bool {
        phase == .writing && message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 70), configuration: config)
        super.init()
        config.userContentController.add(FeedbackMessageHandler(self), name: "turnstile")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        loadCheck()
    }

    private func loadCheck() {
        checkFailed = false
        webView.load(URLRequest(url: Self.site.appending(path: "turnstile/")))
    }

    // MARK: The spam check

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let token = body["token"] as? String {
            self.token = token
            needsCheck = false
            resume(token)
        } else if body["expired"] != nil {
            token = nil
            webView.evaluateJavaScript("window.markdTurnstile && markdTurnstile.reset()", completionHandler: nil)
        } else if let interactive = body["interactive"] as? Bool {
            needsCheck = interactive
        } else if body["error"] != nil {
            token = nil
            checkFailed = true
            resume(nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed() }
    private func loadFailed() {
        checkFailed = true
        resume(nil)
    }

    private func resume(_ token: String?) {
        let list = waiting
        waiting = []
        list.forEach { $0.resume(returning: token) }
    }

    /// A token for one message: the one ready, or the next one (nil if the check can't run).
    private func freshToken() async -> String? {
        if let token {
            self.token = nil
            return token
        }
        if checkFailed { loadCheck() }
        // Give up after a while, unless the person is busy with the check.
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.waiting.isEmpty else { return }
                if self.needsCheck { continue }
            }
            self?.resume(nil)
        }
        return await withCheckedContinuation { waiting.append($0) }
    }

    // MARK: Sending

    func send() async {
        guard canSend else { return }
        phase = .sending
        error = nil
        guard let token = await freshToken() else {
            phase = .writing
            error = "The spam check couldn’t run. Check your connection and try again, or send it from the website."
            return
        }
        // Get the next token ready, in case this one is turned down.
        webView.evaluateJavaScript("window.markdTurnstile && markdTurnstile.reset()", completionHandler: nil)

        let fields: [(String, String)] = [
            ("app", "wingman"), ("name", "Wingman"), ("kind", kind.rawValue),
            ("message", message.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("email", email.trimmingCharacters(in: .whitespaces)),
            ("version", version), ("os", os), ("website", ""), ("cf-turnstile-response", token),
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")

        var request = URLRequest(url: Self.site.appending(path: "api/feedback"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (response as? HTTPURLResponse)?.statusCode == 200, reply?["ok"] as? Bool == true {
                phase = .sent
                return
            }
            error = reply?["error"] as? String ?? "Something went wrong. Try again in a moment."
        } catch {
            self.error = "Couldn’t reach leinerud.se. Check your connection and try again."
        }
        phase = .writing
    }
}

/// WKUserContentController keeps its handlers alive; this keeps the model from being one of them.
private final class FeedbackMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: FeedbackModel?
    init(_ target: FeedbackModel) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
    }
}

// MARK: - The window

struct FeedbackView: View {
    @StateObject private var model = FeedbackModel()
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var messageFocused: Bool

    var body: some View {
        Group {
            if model.phase == .sent { thanks } else { form }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tell me what you think")
                        .font(.headline)
                    Text("Found a bug, have an idea, or like something? I read everything, and I make Wingman on my own, so it really helps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Kind", selection: $model.kind) {
                ForEach(FeedbackKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($messageFocused)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                if model.message.isEmpty {
                    Text(model.kind.prompt)
                        .foregroundStyle(.placeholder)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))

            VStack(alignment: .leading, spacing: 5) {
                TextField("Email (optional)", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
                Text("Only if you’d like an answer. Wingman \(model.version) and \(model.os) are sent along.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The spam check: invisible, unless Cloudflare wants a click.
            TurnstileView(webView: model.webView)
                .frame(height: model.needsCheck ? 70 : 1)
                .opacity(model.needsCheck ? 1 : 0.01)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(!model.needsCheck)

            if let error = model.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open in Browser") { Feedback.openInBrowser() }
                        .controlSize(.small)
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismissWindow(id: Feedback.windowID) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await model.send() }
                } label: {
                    if model.phase == .sending {
                        ProgressView().controlSize(.small).frame(minWidth: 40)
                    } else {
                        Text("Send").frame(minWidth: 40)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
            }
        }
        .padding(20)
        .onAppear {
            messageFocused = true
        }
    }

    private var thanks: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
                .padding(.bottom, 4)
            Text("Thank you!")
                .font(.title2.weight(.semibold))
            Text(model.email.isEmpty
                 ? "Your feedback is on its way to me."
                 : "Your feedback is on its way to me, and I’ll get back to you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { dismissWindow(id: Feedback.windowID) }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

private struct TurnstileView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
