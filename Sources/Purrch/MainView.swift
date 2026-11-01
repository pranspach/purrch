import SwiftUI

// The macOS 27 SDK makes @State a macro whose plugin ships only with Xcode. Purrch builds with
// the Command Line Tools, so view state lives in ObservableObjects instead.
private final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

struct MainView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case widgets = "Widgets"
        case activity = "Activity"
        var id: String { rawValue }
        var icon: String { self == .widgets ? "square.grid.2x2" : "chart.bar" }
    }

    @StateObject private var page = ViewState<Page?>(.widgets)

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page.value) { page in
                Label(page.rawValue, systemImage: page.icon).tag(page)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch page.value ?? .widgets {
            case .widgets: WidgetsPage()
            case .activity: ActivityPage()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct WidgetsPage: View {
    @ObservedObject private var store = Services.shared.widgets
    @ObservedObject private var agent = Services.shared.agent
    @StateObject private var request = ViewState("")
    @StateObject private var editing = ViewState<Widget?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing.value.map { "Change \($0.name)" } ?? "Describe a widget").font(.headline)
            HStack {
                TextField("A countdown to Friday with a cat that gets happier", text: $request.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Picker("Agent", selection: $agent.selectedID) {
                    ForEach(agent.available) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(agent.available.isEmpty)
                Button(editing.value == nil ? "Build" : "Change", action: submit)
                    .disabled(request.value.isEmpty || agent.isBuilding || agent.available.isEmpty)
                if editing.value != nil {
                    Button("Cancel") { editing.value = nil }
                }
            }
            if agent.available.isEmpty {
                Text("No coding agent found. Install Claude Code, Codex, Gemini CLI or OpenCode.").foregroundStyle(.secondary)
            }
            if let status = agent.status {
                HStack {
                    if agent.isBuilding { ProgressView().controlSize(.small) }
                    Text(status).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            List(store.widgets) { widget in
                HStack {
                    Image(systemName: widget.icon).frame(width: 22)
                    Text(widget.name)
                    Spacer()
                    Button("Open") { Services.shared.notch.open(widget) }
                    Button("Change") { editing.value = widget }
                    Button("Remove", role: .destructive) { store.remove(widget) }
                }
            }
        }
        .padding()
        .navigationTitle("Widgets")
    }

    private func submit() {
        agent.run(request: request.value, existing: editing.value)
        request.value = ""
        editing.value = nil
    }
}

private struct ActivityPage: View {
    private let tracker = Services.shared.activity
    @StateObject private var state = ViewState(ActivitySummary())
    @StateObject private var confirmingDelete = ViewState(false)

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

                section("Privacy") {
                    Text("Purrch logs which app is in front and how many keys you press each hour, in a database on this Mac. It never records which keys you press, window titles, or your screen.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if !tracker.canCountKeystrokes {
                            Button("Enable keystroke count") { tracker.requestKeystrokeAccess() }
                        }
                        Button("Delete all activity", role: .destructive) { confirmingDelete.value = true }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Today")
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
        .confirmationDialog("Delete all recorded activity?", isPresented: $confirmingDelete.value) {
            Button("Delete", role: .destructive) {
                tracker.deleteAll()
                refresh()
            }
        }
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
