import Foundation

struct Agent: Identifiable, Hashable {
    let id: String
    let name: String
    let binary: String
    let arguments: [String]

    func invocation(prompt: String) -> [String] { [binary] + arguments + [prompt] }

    static let known = [
        Agent(id: "claude", name: "Claude Code", binary: "claude", arguments: ["--permission-mode", "acceptEdits", "-p"]),
        Agent(id: "codex", name: "Codex", binary: "codex", arguments: ["exec", "--full-auto"]),
        Agent(id: "gemini", name: "Gemini CLI", binary: "gemini", arguments: ["--approval-mode", "auto_edit", "-p"]),
        Agent(id: "opencode", name: "OpenCode", binary: "opencode", arguments: ["run"]),
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
        guard let agent = available.first(where: { $0.id == selectedID }) ?? available.first ?? Agent.known.first else { return }

        let directory = existing?.directory ?? Self.newDirectory(for: request)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        isBuilding = true
        status = "\(agent.name) is building…"

        // `exec "$0" "$@"` keeps the prompt out of shell parsing while still using the login PATH.
        let arguments = ["-lc", #"exec "$0" "$@""#] + agent.invocation(prompt: Self.prompt(for: request, existing: existing))
        Shell.run(arguments: arguments, directory: directory, timeout: 600) { [weak self] result in
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
        - manifest.json: {"name": "Short Name", "icon": "<SF Symbol name>", "height": <80-480>}
        - index.html: self-contained HTML, CSS and JS, with no build step.

        Design: the page is 440px wide with a transparent background on a black panel. Use white text, the system \
        font, 13px base size, and no outer margin larger than 12px. Fit within the declared height without scrolling \
        where possible.

        Native bridge, available as window.purrch (every call returns a Promise):
        - purrch.exec(command) runs a shell command, resolving to {stdout, stderr, code}. It times out after 20s.
        - purrch.activity() resolves to today's stats: {activeSeconds, longestFocusSeconds, appSwitches, keystrokes, \
        hourly: [24 numbers of active seconds], topApps: [{app, seconds}], topSwitches: [{from, to, count}]}.
        - purrch.clipboard() resolves to an array of recent copied strings, newest first.
        - purrch.copy(text) puts text on the clipboard.

        Only use shell commands the request needs, and never send the user's data over the network unless asked.

        The request: \(request)
        """
    }
}
