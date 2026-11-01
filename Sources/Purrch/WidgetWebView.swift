import AppKit
import WebKit

final class WidgetWKWebView: WKWebView {
    // The notch panel is rarely key, and a widget's first click should still land.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps one web view per widget, so timers and other state stay live while switching.
final class WebViewPool: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private var views: [String: WKWebView] = [:]

    private static let bridgeScript = """
    window.purrch = {
      exec: (command) => webkit.messageHandlers.purrch.postMessage({op: 'exec', command}),
      activity: () => webkit.messageHandlers.purrch.postMessage({op: 'activity'}),
      clipboard: () => webkit.messageHandlers.purrch.postMessage({op: 'clipboard'}),
      copy: (text) => webkit.messageHandlers.purrch.postMessage({op: 'copy', text}),
    };
    """

    func view(for widget: Widget) -> WKWebView {
        if let existing = views[widget.id] { return existing }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "purrch")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let view = WidgetWKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(widget.entry, allowingReadAccessTo: widget.directory)
        views[widget.id] = view
        return view
    }

    func invalidate(_ id: String) {
        views.removeValue(forKey: id)?.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // The bridge can run shell commands, so remote pages never get to load in the main frame.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false, let url = navigationAction.request.url, !url.isFileURL else {
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
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "Bridge is only available to the widget's main frame")
            return
        }

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
            replyHandler(Services.shared.activity.summary(for: Date()).dictionary, nil)
        case "clipboard":
            replyHandler(Services.shared.clipboard.history, nil)
        case "copy":
            Services.shared.clipboard.copy(body["text"] as? String ?? "")
            replyHandler(true, nil)
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
