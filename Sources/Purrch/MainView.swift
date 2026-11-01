import PurrchCore
import ServiceManagement
import SwiftUI

// The macOS 27 SDK makes @State a macro whose plugin ships only with Xcode. Purrch builds with
// the Command Line Tools, so view state lives in ObservableObjects instead.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

struct RootView: View {
    @ObservedObject private var settings = Services.shared.settings

    var body: some View {
        Group {
            if settings.hasOnboarded || settings.skipOnboardingThisRun {
                MainView()
            } else {
                OnboardingView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

struct MainView: View {
    @ObservedObject private var navigator = Services.shared.navigator

    var body: some View {
        NavigationSplitView {
            List(Navigator.Page.allCases, selection: $navigator.page) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch navigator.page ?? .widgets {
            case .widgets: WidgetsPage()
            case .ideas: IdeasPage()
            case .activity: ActivityPage()
            case .shortcuts: ShortcutsPage()
            case .privacy: PrivacyPage()
            case .settings: SettingsPage()
            }
        }
    }
}

// MARK: Onboarding

private struct OnboardingView: View {
    @ObservedObject private var agent = Services.shared.agent
    @StateObject private var step = ViewState(0)

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "pawprint.fill").font(.system(size: 44)).foregroundStyle(.tint)
            switch step.value {
            case 0:
                page("Welcome to Purrch", "Widgets live under your notch. Hover over it to open them, or press \(Services.shared.settings.searchShortcut.label) to search. Describe a new widget and your coding agent builds it.")
            case 1:
                page("Your activity stays on this Mac", "Purrch logs which app is in front and an hourly keystroke count, in a local database. It never records which keys you press or saves images of your screen. If you ask your agent for ideas, what it reads goes to that agent's provider.")
            default:
                page(agent.available.isEmpty ? "Install a coding agent" : "You're ready", agent.available.isEmpty
                    ? "Purrch didn't find Claude Code, Codex, Gemini CLI, Cursor, GitHub Copilot or OpenCode. The starter widgets work without one, but building new widgets needs one."
                    : "Purrch will build widgets with \(agent.available.map(\.name).joined(separator: ", ")). No extra subscription is needed. You can turn on more detailed activity in Privacy, whenever you like.")
            }
            Spacer()
            HStack {
                if step.value > 0 { Button("Back") { step.value -= 1 } }
                Spacer()
                Button(step.value == 2 ? "Get Started" : "Continue") {
                    if step.value == 2 {
                        Services.shared.settings.hasOnboarded = true
                    } else {
                        step.value += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
    }

    private func page(_ title: String, _ body: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.title.weight(.semibold))
            Text(body).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

// MARK: Widgets

private struct WidgetsPage: View {
    @ObservedObject private var store = Services.shared.widgets
    @ObservedObject private var agent = Services.shared.agent
    @ObservedObject private var navigator = Services.shared.navigator
    @StateObject private var request = ViewState("")

    private var editing: Widget? { store.widgets.first { $0.id == navigator.editingWidgetID } }

    var body: some View {
        if let editing {
            WidgetEditor(widget: editing)
                .id(editing.id)
                .navigationTitle(editing.name)
        } else {
            list.navigationTitle("Widgets")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe a widget").font(.headline)
            HStack {
                TextField("A countdown to Friday with a cat that gets happier", text: $request.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                AgentPicker()
                Button("Build", action: submit)
                    .disabled(request.value.isEmpty || agent.isBuilding || agent.available.isEmpty)
            }
            AgentStatus()

            List(store.widgets) { widget in
                HStack {
                    Image(systemName: widget.icon).frame(width: 22)
                    Text(widget.name)
                    Spacer()
                    Button("Open") { Services.shared.notch.open(widget) }
                    Button("Edit") { navigator.editingWidgetID = widget.id }
                }
            }
        }
        .padding()
    }

    private func submit() {
        agent.run(request: request.value)
        request.value = ""
    }
}

private struct AgentPicker: View {
    @ObservedObject private var agent = Services.shared.agent

    var body: some View {
        Picker("Agent", selection: $agent.selectedID) {
            ForEach(agent.available) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .frame(width: 140)
        .disabled(agent.available.isEmpty)
    }
}

private struct AgentStatus: View {
    @ObservedObject private var agent = Services.shared.agent

    var body: some View {
        if agent.available.isEmpty {
            HStack {
                Text("No coding agent found. Install Claude Code, Codex, Gemini CLI, Cursor, GitHub Copilot or OpenCode.").foregroundStyle(.secondary)
                Link("Request another agent", destination: ProjectLinks.newIssue(title: "Support a new agent: ", body: ""))
            }
        }
        if let status = agent.status {
            HStack {
                if agent.isBuilding { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct WidgetEditor: View {
    let widget: Widget
    @ObservedObject private var store = Services.shared.widgets
    @ObservedObject private var agent = Services.shared.agent
    @ObservedObject private var settings = Services.shared.settings
    @StateObject private var name: ViewState<String>
    @StateObject private var icon: ViewState<String>
    @StateObject private var height: ViewState<Double>
    @StateObject private var url: ViewState<String>
    @StateObject private var change = ViewState("")
    @StateObject private var confirmingRemove = ViewState(false)

    private static let icons = [
        "square.grid.2x2", "timer", "clock", "calendar", "checklist", "note.text", "chart.bar.fill", "chart.line.uptrend.xyaxis",
        "network", "globe", "terminal", "hammer", "cup.and.saucer.fill", "music.note", "cloud.sun", "bolt.fill",
        "cat.fill", "pawprint.fill", "star.fill", "heart.fill", "flame.fill", "leaf.fill", "gamecontroller", "sparkles",
    ]

    init(widget: Widget) {
        self.widget = widget
        _name = StateObject(wrappedValue: ViewState(widget.name))
        _icon = StateObject(wrappedValue: ViewState(widget.icon))
        _height = StateObject(wrappedValue: ViewState(Double(widget.height)))
        _url = StateObject(wrappedValue: ViewState(widget.url?.absoluteString ?? ""))
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name.value)
                if widget.url != nil {
                    TextField("Web address", text: $url.value)
                }
                LabeledContent("Height") {
                    Slider(value: $height.value, in: 80...480, step: 10)
                }
                LabeledContent("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 8), spacing: 6) {
                        ForEach(Self.icons, id: \.self) { symbol in
                            Button { icon.value = symbol } label: {
                                Image(systemName: symbol)
                                    .frame(width: 28, height: 28)
                                    .background(icon.value == symbol ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                LabeledContent("Shortcut") {
                    ShortcutField(combo: settings.widgetShortcuts[widget.id]) { combo in
                        settings.widgetShortcuts[widget.id] = combo
                        Services.shared.hotKeys.reload()
                    }
                }
            }
            if widget.url == nil {
                Section("Change with your agent") {
                    TextField("Make it show seconds too", text: $change.value)
                    HStack {
                        AgentPicker()
                        Button("Change") {
                            agent.run(request: change.value, existing: widget)
                            change.value = ""
                        }
                        .disabled(change.value.isEmpty || agent.isBuilding || agent.available.isEmpty)
                    }
                    AgentStatus()
                }
            }
            Section {
                HStack {
                    Button("Done") { save() }.keyboardShortcut(.defaultAction)
                    Button("Open") {
                        save()
                        if let updated = store.widgets.first(where: { $0.id == widget.id }) { Services.shared.notch.open(updated) }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([widget.directory]) }
                    Spacer()
                    Button("Remove", role: .destructive) { confirmingRemove.value = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Move “\(widget.name)” to the Trash?", isPresented: $confirmingRemove.value) {
            Button("Move to Trash", role: .destructive) {
                store.remove(widget)
                Services.shared.navigator.editingWidgetID = nil
            }
        }
    }

    private func save() {
        store.update(widget, name: name.value.isEmpty ? widget.name : name.value, icon: icon.value, height: height.value, url: widget.url == nil ? nil : url.value)
        Services.shared.navigator.editingWidgetID = nil
    }
}

// MARK: Ideas

private struct IdeasPage: View {
    @ObservedObject private var engine = Services.shared.ideas
    @ObservedObject private var settings = Services.shared.settings
    @ObservedObject private var agent = Services.shared.agent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your agent looks through your activity and suggests widgets. This sends app names, app switches, and any window titles and website hostnames you've chosen to record to \(agent.selected?.name ?? "your agent")'s provider. Screen text and copied text are never included.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Get Ideas Now") { engine.run() }
                    .disabled(engine.isRunning || agent.isBuilding || agent.available.isEmpty)
                if engine.isRunning { ProgressView().controlSize(.small) }
                if let status = engine.status { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            }

            List {
                ForEach(engine.ideas) { idea in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(idea.title).font(.headline)
                        Text(idea.reason).foregroundStyle(.secondary)
                        Text(idea.prompt).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Build") { engine.build(idea) }.disabled(agent.isBuilding)
                            Button("Dismiss") { engine.dismiss(idea) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            GroupBox("Automatic ideas") {
                VStack(alignment: .leading) {
                    Toggle("Look for ideas automatically", isOn: $settings.autoIdeas)
                    Picker("How often", selection: $settings.ideaIntervalHours) {
                        Text("Every 6 hours").tag(6)
                        Text("Every day").tag(24)
                        Text("Every week").tag(168)
                    }
                    Toggle("Only when plugged in", isOn: $settings.ideaRequiresPower)
                    Toggle("Only when I'm away from the keyboard", isOn: $settings.ideaRequiresIdle)
                }
                .padding(6)
            }
        }
        .padding()
        .navigationTitle("Ideas")
    }
}

// MARK: Activity

private struct ActivityPage: View {
    private let tracker = Services.shared.activity
    @StateObject private var state = ViewState(ActivitySummary())
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var summary: ActivitySummary { state.value }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Stat(title: "Active", value: Self.duration(summary.activeSeconds))
                    Stat(title: "Longest focus", value: Self.duration(summary.longestFocusSeconds))
                    Stat(title: "App switches", value: "\(summary.appSwitches)")
                    Stat(title: "Keystrokes", value: tracker.canCountKeystrokes ? summary.keystrokes.formatted() : "Off")
                }

                section("Timeline") {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                            ForEach(summary.timeline) { block in
                                Rectangle()
                                    .fill(Self.color(for: block.app))
                                    .frame(width: max(1, (block.endFraction - block.startFraction) * geometry.size.width))
                                    .offset(x: block.startFraction * geometry.size.width)
                                    .help(block.app)
                            }
                        }
                    }
                    .frame(height: 22)
                    HStack {
                        ForEach([0, 6, 12, 18], id: \.self) { hour in
                            Text("\(hour):00").font(.caption2).foregroundStyle(.secondary)
                            if hour != 18 { Spacer() }
                        }
                        Spacer()
                    }
                }

                section("When you work") {
                    let peak = max(summary.hourly.max() ?? 0, 1)
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<24, id: \.self) { hour in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.tint)
                                    .frame(height: max(2, 90 * summary.hourly[hour] / peak))
                                Text(hour % 6 == 0 ? "\(hour)" : " ").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 24) {
                    section("Top apps") {
                        ForEach(summary.topApps) { app in
                            row(app.app, Self.duration(app.seconds))
                        }
                    }
                    section("Most common switches") {
                        ForEach(summary.topSwitches) { item in
                            row("\(item.from) → \(item.to)", "\(item.count)×")
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Today")
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() { state.value = tracker.summary(for: Date()) }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// The same app gets the same color across launches.
    private static func color(for app: String) -> Color {
        let hash = app.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.85)
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Shortcuts

private struct ShortcutsPage: View {
    @ObservedObject private var settings = Services.shared.settings
    @ObservedObject private var store = Services.shared.widgets

    var body: some View {
        Form {
            Section("Global") {
                LabeledContent("Search") {
                    ShortcutField(combo: settings.searchShortcut) { combo in
                        settings.searchShortcut = combo ?? AppSettings.defaultSearchShortcut
                        Services.shared.hotKeys.reload()
                    }
                }
            }
            Section("Open a widget") {
                ForEach(store.widgets) { widget in
                    LabeledContent(widget.name) {
                        ShortcutField(combo: settings.widgetShortcuts[widget.id]) { combo in
                            settings.widgetShortcuts[widget.id] = combo
                            Services.shared.hotKeys.reload()
                        }
                    }
                }
            }
            Section("In the panel") {
                LabeledContent("Go to a widget", value: "⌘1 to ⌘9, or click its tab")
                LabeledContent("Next or previous widget", value: "⌘→  ⌘←, or swipe")
                LabeledContent("Widget settings", value: "⌘,")
                LabeledContent("Close", value: "Esc, or click outside")
                LabeledContent("Ask your agent from search", value: "Tab")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}

// MARK: Privacy

private struct PrivacyPage: View {
    private let tracker = Services.shared.activity
    @ObservedObject private var settings = Services.shared.settings
    @StateObject private var rows = ViewState<[ActivityDetail]>([])
    @StateObject private var confirmingDelete = ViewState(false)
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    // Repaints permission buttons after the user returns from System Settings.
    @StateObject private var tick = ViewState(0)

    var body: some View {
        Form {
            Section {
                Text("Everything below stays in a database on this Mac. Purrch never records which keys you press and never saves images of your screen. Detail is deleted after 30 days.")
                    .foregroundStyle(.secondary)
            }
            Section("What's recorded") {
                LabeledContent("Frontmost app and time spent", value: "Always")
                permission("Hourly keystroke count", detail: "A count only, never the keys. Needs Input Monitoring.", granted: tracker.canCountKeystrokes) {
                    tracker.requestKeystrokeAccess()
                }
                Toggle(isOn: $settings.recordWindowTitles) {
                    description("Window titles", "Needs Accessibility.")
                }
                if settings.recordWindowTitles, !tracker.hasAccessibility {
                    Button("Grant Accessibility") { tracker.requestAccessibility() }
                }
                Toggle(isOn: $settings.recordURLs) {
                    description("Full web addresses", "Asks to control each browser. Skips Chrome-based incognito windows, but can't detect Safari private windows.")
                }
                Toggle(isOn: $settings.recordScreenText) {
                    description("Text on screen", "Reads the main display every 5 minutes and discards the image. Skips common password managers. Needs Screen Recording.")
                }
                if settings.recordScreenText, !tracker.hasScreenRecording {
                    Button("Grant Screen Recording") { tracker.requestScreenRecording() }
                }
                Toggle(isOn: $settings.recordClipboard) {
                    description("Copied text", "Skips anything an app marks as concealed.")
                }
            }
            Section("Recorded detail") {
                if rows.value.isEmpty {
                    Text("Nothing recorded yet.").foregroundStyle(.secondary)
                }
                ForEach(rows.value) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.time.formatted(date: .abbreviated, time: .shortened)) · \(row.kind.label) · \(row.app)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(row.text).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
            Section {
                Button("Delete All Activity", role: .destructive) { confirmingDelete.value = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in
            tick.value += 1
            refresh()
        }
        .confirmationDialog("Delete all recorded activity?", isPresented: $confirmingDelete.value) {
            Button("Delete", role: .destructive) {
                tracker.deleteAll()
                refresh()
            }
        }
    }

    private func refresh() { rows.value = tracker.store.details(limit: 200) }

    private func description(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func permission(_ title: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Text("On").foregroundStyle(.secondary)
            } else {
                Button("Turn On", action: request)
            }
        } label: {
            description(title, detail)
        }
    }
}

// MARK: Settings

private struct SettingsPage: View {
    @ObservedObject private var settings = Services.shared.settings
    @ObservedObject private var agent = Services.shared.agent
    @StateObject private var launchAtLogin = ViewState(SMAppService.mainApp.status == .enabled)
    @StateObject private var loginError = ViewState<String?>(nil)

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin.value },
                    set: setLaunchAtLogin
                ))
                if let error = loginError.value {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Panel") {
                Picker("Show on", selection: $settings.display) {
                    ForEach(AppSettings.Display.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.display) { Services.shared.notch.applyDisplaySetting() }
                Toggle("Only switch between widgets opened since launch", isOn: $settings.switchLiveOnly)
            }
            Section("Agent") {
                LabeledContent("Build widgets with") { AgentPicker() }
                Button("Look for Agents Again") { agent.detect() }
                Link("Request another agent", destination: ProjectLinks.newIssue(title: "Support a new agent: ", body: ""))
            }
            Section("About") {
                LabeledContent("Version", value: ProjectLinks.environment)
                Link("Source code", destination: URL(string: ProjectLinks.repository)!)
                Button("Send Feedback…") { (NSApp.delegate as? AppDelegate)?.sendFeedback() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError.value = nil
        } catch {
            loginError.value = error.localizedDescription
        }
        launchAtLogin.value = SMAppService.mainApp.status == .enabled
    }
}
