import Foundation

struct Agent: Identifiable, Hashable {
    let id: String
    let name: String
    let binary: String
    /// Lets the agent edit files in its working directory. The prompt is appended last.
    let buildArguments: [String]
    /// Answers without changing anything. Used when the prompt contains activity data, which is untrusted text.
    let askArguments: [String]

    static let known = [
        Agent(id: "claude", name: "Claude Code", binary: "claude", buildArguments: ["--permission-mode", "acceptEdits", "-p"], askArguments: ["--permission-mode", "default", "-p"]),
        Agent(id: "codex", name: "Codex", binary: "codex", buildArguments: ["exec", "--full-auto"], askArguments: ["exec", "--sandbox", "read-only"]),
        Agent(id: "gemini", name: "Gemini CLI", binary: "gemini", buildArguments: ["--approval-mode", "auto_edit", "-p"], askArguments: ["-p"]),
        Agent(id: "cursor", name: "Cursor", binary: "cursor-agent", buildArguments: ["--force", "-p"], askArguments: ["-p"]),
        Agent(id: "copilot", name: "GitHub Copilot", binary: "copilot", buildArguments: ["--allow-tool", "write", "-p"], askArguments: ["-p"]),
        Agent(id: "opencode", name: "OpenCode", binary: "opencode", buildArguments: ["run"], askArguments: ["run"]),
    ]
}

/// Builds widgets with whichever coding agent CLI the user already has installed.
final class AgentRunner: ObservableObject {
    @Published private(set) var available: [Agent] = []
    @Published var selectedID = UserDefaults.standard.string(forKey: "agent") ?? "claude" {
        didSet { UserDefaults.standard.set(selectedID, forKey: "agent") }
    }
    @Published private(set) var isBuilding = false
    @Published private(set) var status: String?

    var selected: Agent? { available.first { $0.id == selectedID } ?? available.first }

    init() { detect() }

    func detect() {
        let checks = Agent.known.map { "command -v \($0.binary) >/dev/null && echo \($0.id)" }.joined(separator: "; ")
        Shell.run(checks) { [weak self] result in
            let found = Set(result.stdout.split(separator: "\n").map(String.init))
            self?.available = Agent.known.filter { found.contains($0.id) }
        }
    }

    /// Creates a new widget, or changes `existing` when one is given.
    func run(request: String, existing: Widget? = nil) {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isBuilding else { return }
        guard let agent = selected ?? Agent.known.first else { return }

        let directory = existing?.directory ?? Self.newDirectory(for: request)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        isBuilding = true
        status = "\(agent.name) is building…"

        let invocation = agent.buildArguments + [Self.prompt(for: request, existing: existing)]
        Self.launch(agent, invocation, directory: directory, timeout: 600) { [weak self] result in
            guard let self else { return }
            self.isBuilding = false

            guard let widget = WidgetStore.load(directory) else {
                if existing == nil { try? FileManager.default.removeItem(at: directory) }
                let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).suffix(400)
                self.status = "\(agent.name) didn't produce a valid widget. \(detail)"
                return
            }

            let services = Services.shared
            services.webViews.invalidate(widget.id)
            services.widgets.reload()
            services.notch.open(widget)
            self.status = "Built \(widget.name)."
        }
    }

    /// Asks the agent a question from a scratch directory, with no permission to edit files.
    func ask(prompt: String, completion: @escaping (Shell.Result?) -> Void) {
        guard let agent = selected else { return completion(nil) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("purrch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.launch(agent, agent.askArguments + [prompt], directory: directory, timeout: 300) { result in
            try? FileManager.default.removeItem(at: directory)
            completion(result)
        }
    }

    private static func launch(_ agent: Agent, _ invocation: [String], directory: URL, timeout: TimeInterval, completion: @escaping (Shell.Result) -> Void) {
        // `exec "$0" "$@"` keeps the prompt out of shell parsing while still using the login PATH.
        Shell.run(arguments: ["-lc", #"exec "$0" "$@""#, agent.binary] + invocation, directory: directory, timeout: timeout, completion: completion)
    }

    private static func newDirectory(for request: String) -> URL {
        let words = request.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4)
        let slug = words.isEmpty ? "widget" : words.joined(separator: "-")
        var directory = WidgetStore.widgetsDirectory.appendingPathComponent(slug)
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.path) {
            directory = WidgetStore.widgetsDirectory.appendingPathComponent("\(slug)-\(suffix)")
            suffix += 1
        }
        return directory
    }

    private static func prompt(for request: String, existing: Widget?) -> String {
        """
        \(existing == nil ? "Build a new Purrch widget in the current directory." : "Change the Purrch widget in the current directory.")

        A Purrch widget is a small web page shown in a dark panel under the MacBook notch. Only touch this directory.

        Files:
        - manifest.json: {"name": "<12 characters or fewer>", "icon": "<SF Symbol name>", "height": <80-480>}
        - index.html: self-contained HTML, CSS and JS, with no build step.

        Design: the page is 440px wide with a transparent background on a black panel. Use white text, the system \
        font, 13px base size, and no outer margin larger than 12px. Fit within the declared height without scrolling \
        where possible.

        Native bridge, available as window.purrch (every call returns a Promise). The user is asked to approve the \
        widget the first time it uses any of these, so only call them if the request needs them:
        - purrch.exec(command) runs a shell command, resolving to {stdout, stderr, code}. It times out after 20s.
        - purrch.activity() resolves to today's stats: {activeSeconds, longestFocusSeconds, appSwitches, keystrokes, \
        hourly: [24 numbers of active seconds], topApps: [{app, seconds}], topSwitches: [{from, to, count}]}.
        - purrch.clipboard() resolves to recent copies, newest first: [{id, kind: "text"|"image"|"file", text, thumbnail}].
        - purrch.copy(text) puts text on the clipboard. purrch.copyItem(id) and purrch.pasteItem(id) reuse a past copy.

        Only use shell commands the request needs, and never send the user's data over the network unless asked.

        The request: \(request)
        """
    }
}
