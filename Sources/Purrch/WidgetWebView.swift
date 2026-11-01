import AppKit
import WebKit

final class WidgetWKWebView: WKWebView {
    // The notch panel is rarely key, and a widget's first click should still land.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps one web view per widget, so timers and other state stay live while switching.
final class WebViewPool: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private var views: [String: WKWebView] = [:]
    private var deniedThisSession: Set<String> = []
    private var pendingApprovals: [String: [(Bool) -> Void]] = [:]

    var liveIDs: Set<String> { Set(views.keys) }

    private static let bridgeScript = """
    (() => {
      const call = (message) => webkit.messageHandlers.purrch.postMessage(message);
      window.purrch = {
        exec: (command) => call({op: 'exec', command}),
        activity: () => call({op: 'activity'}),
        clipboard: () => call({op: 'clipboard'}),
        copy: (text) => call({op: 'copy', text}),
        copyItem: (id) => call({op: 'copyItem', id}),
        pasteItem: (id) => call({op: 'pasteItem', id}),
      };
    })();
    """

    func view(for widget: Widget) -> WKWebView {
        if let existing = views[widget.id] { return existing }

        let configuration = WKWebViewConfiguration()
        if widget.url == nil {
            configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "purrch")
            configuration.userContentController.addUserScript(
                WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        let view = WidgetWKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        if let url = widget.url {
            view.load(URLRequest(url: url))
        } else {
            view.loadFileURL(widget.entry, allowingReadAccessTo: widget.directory)
        }
        views[widget.id] = view
        return view
    }

    func invalidate(_ id: String) {
        deniedThisSession.remove(id)
        views.removeValue(forKey: id)?.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // The bridge can run shell commands, so a local widget never navigates its main frame to the web.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let isRemoteWidget = views.first { $0.value === webView }.flatMap { entry in
            Services.shared.widgets.widgets.first { $0.id == entry.key }?.url
        } != nil
        guard !isRemoteWidget, navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url, !url.isFileURL else {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              let webView = message.webView,
              let id = views.first(where: { $0.value === webView })?.key,
              let widget = Services.shared.widgets.widgets.first(where: { $0.id == id }),
              let body = message.body as? [String: Any],
              let op = body["op"] as? String else {
            replyHandler(nil, "The bridge is only available to a widget's main frame")
            return
        }

        requestAccess(for: widget) { allowed in
            guard allowed else {
                replyHandler(nil, "You didn't allow this widget to use Purrch's native features")
                return
            }
            self.perform(op, body: body, replyHandler: replyHandler)
        }
    }

    /// Asks once per version of a widget's code, because the bridge runs commands as the user.
    private func requestAccess(for widget: Widget, completion: @escaping (Bool) -> Void) {
        let store = Services.shared.widgets
        if store.isTrusted(widget) { return completion(true) }
        if deniedThisSession.contains(widget.id) { return completion(false) }

        // Widgets often call the bridge several times on load, and they should share one prompt.
        if pendingApprovals[widget.id] != nil {
            pendingApprovals[widget.id]?.append(completion)
            return
        }
        pendingApprovals[widget.id] = [completion]

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Allow “\(widget.name)” to use native features?"
            alert.informativeText = "This widget's code asked to use Purrch's bridge. If you allow it, it can run shell commands as you and read your activity and clipboard history. Only allow widgets you trust.\n\nYou'll be asked again if its code changes.\n\n\(widget.directory.path)"
            alert.addButton(withTitle: "Don't Allow")
            alert.addButton(withTitle: "Allow")
            alert.window.level = .mainMenu + 4
            NSApp.activate(ignoringOtherApps: true)
            let allowed = alert.runModal() == .alertSecondButtonReturn

            if allowed {
                store.trust(widget)
            } else {
                self.deniedThisSession.insert(widget.id)
            }
            let waiting = self.pendingApprovals.removeValue(forKey: widget.id) ?? []
            waiting.forEach { $0(allowed) }
        }
    }

    private func perform(_ op: String, body: [String: Any], replyHandler: @escaping (Any?, String?) -> Void) {
        let services = Services.shared
        switch op {
        case "exec":
            guard let command = body["command"] as? String else {
                replyHandler(nil, "exec needs a command")
                return
            }
            Shell.run(command) { result in
                replyHandler(["stdout": result.stdout, "stderr": result.stderr, "code": Int(result.code)], nil)
            }
        case "activity":
            replyHandler(services.activity.summary(for: Date()).dictionary, nil)
        case "clipboard":
            replyHandler(services.clipboard.items.map(\.dictionary), nil)
        case "copy":
            services.clipboard.copy(body["text"] as? String ?? "")
            replyHandler(true, nil)
        case "copyItem":
            replyHandler(services.clipboard.copyItem(id: body["id"] as? String ?? ""), nil)
        case "pasteItem":
            replyHandler(services.clipboard.pasteItem(id: body["id"] as? String ?? ""), nil)
        default:
            replyHandler(nil, "Unknown operation \(op)")
        }
    }
}

enum Shell {
    struct Result {
        let stdout: String
        let stderr: String
        let code: Int32
    }

    /// Runs through a login shell because apps opened from Finder don't inherit the user's PATH.
    static func run(_ command: String, timeout: TimeInterval = 20, completion: @escaping (Result) -> Void) {
        run(arguments: ["-lc", command], directory: nil, timeout: timeout, completion: completion)
    }

    static func run(arguments: [String], directory: URL?, timeout: TimeInterval, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let out = Pipe()
            let err = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(Result(stdout: "", stderr: error.localizedDescription, code: -1)) }
                return
            }

            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            watchdog.cancel()

            let result = Result(
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self),
                code: process.terminationStatus
            )
            DispatchQueue.main.async { completion(result) }
        }
    }
}
