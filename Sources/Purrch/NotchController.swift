import AppKit
import PurrchCore
import SwiftUI
import WebKit

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

struct SearchResult: Identifiable {
    enum Action {
        case widget(Widget)
        case app(URL)
        case copy(String)
        case killPort(Int)
        case askAgent(String)
        case none
    }

    let id: String
    let icon: Image
    let title: String
    let detail: String
    let action: Action
}

/// The panel at the top of the screen: collapsed around the notch, expanded on hover or the search shortcut.
final class NotchController: NSObject, ObservableObject, NSWindowDelegate {
    enum Mode { case widget, search }

    @Published private(set) var isExpanded = false
    @Published private(set) var mode = Mode.widget
    @Published private(set) var selectedID = UserDefaults.standard.string(forKey: "selectedWidget") {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedWidget") }
    }
    @Published private(set) var hoveredTabID: String?
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var highlighted = 0
    @Published var isPinned = false { didSet { updatePanelKeys() } }
    @Published var query = "" { didSet { queryChanged() } }

    private(set) var panel: NotchPanel?
    private var collapseWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var preview: SearchResult?
    private var monitors: [Any] = []
    private var isPointerInside = false
    private var swipeDistance: CGFloat = 0
    private var didSwipe = false

    private static let expandedWidth: CGFloat = 440
    private static let toolbarHeight: CGFloat = 26
    private static let tabRowHeight: CGFloat = 30
    private static let tabsPerRow = 4
    private static let maxTabRows = 3
    private static let searchHeight: CGFloat = 300
    private static let swipeThreshold: CGFloat = 60

    private static let applications: [URL] = {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"].flatMap { path in
            ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }()

    var screen: NSScreen? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        switch Services.shared.settings.display {
        case .automatic: return notched ?? NSScreen.main
        case .main: return NSScreen.main
        case .builtIn:
            let builtIn = NSScreen.screens.first {
                let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
            }
            return builtIn ?? NSScreen.main
        }
    }
    var notchHeight: CGFloat { screen?.safeAreaInsets.top ?? 0 }

    var selected: Widget? {
        let widgets = Services.shared.widgets.widgets
        return widgets.first { $0.id == selectedID } ?? widgets.first
    }

    func show() {
        let panel = NotchPanel(
            contentRect: collapsedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .mainMenu + 3 // After isFloatingPanel, which resets the level to below the menu bar.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.delegate = self

        let hover = HoverView()
        hover.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        let host = NSHostingView(rootView: NotchView(controller: self, widgets: Services.shared.widgets))
        host.translatesAutoresizingMaskIntoConstraints = false
        hover.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: hover.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: hover.trailingAnchor),
            host.topAnchor.constraint(equalTo: hover.topAnchor),
            host.bottomAnchor.constraint(equalTo: hover.bottomAnchor),
        ])
        panel.contentView = hover
        panel.orderFrontRegardless()
        self.panel = panel

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyFrame(animated: false)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKey(event) ?? event
        }) { monitors.append(keys) }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.handleScroll(event)
            return event
        }) { monitors.append(scroll) }
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            guard let self, self.isExpanded, !self.isPinned else { return }
            self.collapse()
        }) { monitors.append(outside) }
    }

    func applyDisplaySetting() { applyFrame(animated: false) }

    func open(_ widget: Widget) {
        selectedID = widget.id
        mode = .widget
        expand()
        updatePanelKeys()
    }

    func openSearch() {
        query = ""
        mode = .search
        expand()
        updatePanelKeys()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        collapseWork?.cancel()
        isExpanded = false
        isPinned = false
        mode = .widget
        hoveredTabID = nil
        applyFrame(animated: true)
        updatePanelKeys()
    }

    func hoverTab(_ id: String, inside: Bool) {
        if inside {
            hoveredTabID = id
        } else if hoveredTabID == id {
            hoveredTabID = nil
        }
    }

    /// Jumps by position, so ⌘1 to ⌘9 match the tab strip's stable order.
    func select(index: Int) {
        let widgets = Services.shared.widgets.widgets
        guard widgets.indices.contains(index) else { return }
        open(widgets[index])
    }

    /// Search leaves these keys to the text field. A pinned panel only claims them while the pointer is
    /// on it, because it can stay open for hours and ⌘1 should still reach your browser.
    private func updatePanelKeys() {
        let enabled = isExpanded && mode == .widget && (!isPinned || isPointerInside)
        Services.shared.hotKeys.setPanelKeys(enabled: enabled)
    }

    func select(offset: Int) {
        let services = Services.shared
        var candidates = services.widgets.widgets
        if services.settings.switchLiveOnly {
            let live = candidates.filter { services.webViews.liveIDs.contains($0.id) }
            if !live.isEmpty { candidates = live }
        }
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = candidates[(current + offset + candidates.count) % candidates.count].id
        mode = .widget
        applyFrame(animated: true)
    }

    func run(_ result: SearchResult) {
        switch result.action {
        case .widget(let widget):
            open(widget)
        case .app(let url):
            NSWorkspace.shared.open(url)
            collapse()
        case .copy(let text):
            Services.shared.clipboard.copy(text)
            collapse()
        case .killPort(let port):
            Shell.run("lsof -ti tcp:\(port) -sTCP:LISTEN | xargs kill") { _ in }
            collapse()
        case .askAgent(let request):
            collapse()
            Services.shared.agent.run(request: request)
        case .none:
            break
        }
    }

    func openSelectedWidgetSettings() {
        guard let widget = selected else { return }
        collapse()
        Services.shared.navigator.editingWidgetID = widget.id
        (NSApp.delegate as? AppDelegate)?.showWindow(page: .widgets)
    }

    private func expand() {
        collapseWork?.cancel()
        Services.shared.widgets.reload()
        isExpanded = true
        applyFrame(animated: true)
    }

    private func hoverChanged(_ inside: Bool) {
        isPointerInside = inside
        collapseWork?.cancel()
        defer { updatePanelKeys() }
        if inside {
            if !isExpanded { expand() }
        } else if !isPinned, mode == .widget {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if mode == .search { collapse() }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        switch event.keyCode {
        case 53: // Esc
            collapse()
        case 125 where mode == .search: // ↓
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
        case 126 where mode == .search: // ↑
            highlighted = max(highlighted - 1, 0)
        case 36 where mode == .search: // Return
            if results.indices.contains(highlighted) { run(results[highlighted]) }
        case 48 where mode == .search: // Tab
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                collapse()
                Services.shared.agent.run(request: query)
            }
        default:
            return event
        }
        return nil
    }

    private func handleScroll(_ event: NSEvent) {
        guard event.window === panel, event.hasPreciseScrollingDeltas, mode == .widget else { return }
        if event.phase == .began {
            swipeDistance = 0
            didSwipe = false
        }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), !didSwipe else { return }
        swipeDistance += event.scrollingDeltaX
        if abs(swipeDistance) >= Self.swipeThreshold {
            didSwipe = true
            select(offset: swipeDistance < 0 ? 1 : -1)
        }
    }

    // MARK: Search

    private func queryChanged() {
        previewWork?.cancel()
        preview = nil
        highlighted = 0
        rebuildResults()

        switch SearchCommand.parse(query) {
        case .killPort(let port): schedulePortPreview(port)
        case .weather(let place): scheduleWeatherPreview(place)
        case nil: break
        }
    }

    private func rebuildResults() {
        let query = self.query.trimmingCharacters(in: .whitespaces)
        var results: [SearchResult] = []

        if let value = Calculator.evaluate(query) {
            let text = Calculator.format(value)
            results.append(SearchResult(id: "calc", icon: Image(systemName: "equal.circle"), title: text, detail: "Copy", action: .copy(text)))
        }
        if let preview { results.append(preview) }

        let widgets = Services.shared.widgets.widgets
        results += widgets
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .map { SearchResult(id: "widget:" + $0.id, icon: Image(systemName: $0.icon), title: $0.name, detail: "Widget", action: .widget($0)) }

        if !query.isEmpty {
            results += Self.applications
                .filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) }
                .prefix(8)
                .map { url in
                    SearchResult(id: url.path, icon: Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)), title: url.deletingPathExtension().lastPathComponent, detail: "App", action: .app(url))
                }
            results.append(SearchResult(id: "ask", icon: Image(systemName: "sparkles"), title: "Ask your agent to build this", detail: "Tab", action: .askAgent(query)))
        }
        self.results = results
    }

    private func schedulePreview(_ body: @escaping () -> Void) {
        let work = DispatchWorkItem(block: body)
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func schedulePortPreview(_ port: Int) {
        let expected = query
        schedulePreview {
            Shell.run("lsof -nP -iTCP:\(port) -sTCP:LISTEN -Fc | grep '^c' | head -1 | cut -c2-") { [weak self] result in
                guard let self, self.query == expected else { return }
                let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                self.preview = name.isEmpty
                    ? SearchResult(id: "port", icon: Image(systemName: "network"), title: "Nothing is listening on port \(port)", detail: "", action: .none)
                    : SearchResult(id: "port", icon: Image(systemName: "xmark.octagon"), title: "Stop \(name) on port \(port)", detail: "Return", action: .killPort(port))
                self.rebuildResults()
            }
        }
    }

    /// Only runs for an explicit "weather …" query, since it sends the place name to wttr.in.
    private func scheduleWeatherPreview(_ place: String) {
        let expected = query
        schedulePreview {
            var components = URLComponents(string: "https://wttr.in")!
            components.path = "/" + place
            components.queryItems = [URLQueryItem(name: "format", value: "3")]
            guard let url = components.url else { return }
            URLSession.shared.dataTask(with: url) { data, response, _ in
                let isOK = (response as? HTTPURLResponse)?.statusCode == 200
                let text = isOK ? data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } : nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.query == expected, let text, !text.isEmpty else { return }
                    self.preview = SearchResult(id: "weather", icon: Image(systemName: "cloud.sun"), title: text, detail: "Copy", action: .copy(text))
                    self.rebuildResults()
                }
            }.resume()
        }
    }

    // MARK: Frames

    private var collapsedFrame: NSRect {
        guard let screen else { return NSRect(x: 0, y: 0, width: 180, height: 10) }
        var size = NSSize(width: 180, height: 10)
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            size = NSSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Fits every tab up to the row limit. Beyond that, the tab area scrolls.
    var tabAreaHeight: CGFloat {
        let count = Services.shared.widgets.widgets.count
        let rows = min((count + Self.tabsPerRow - 1) / Self.tabsPerRow, Self.maxTabRows)
        return CGFloat(rows) * Self.tabRowHeight + 8
    }

    private var expandedFrame: NSRect {
        guard let screen else { return collapsedFrame }
        let content = mode == .search ? Self.searchHeight : (selected?.height ?? 220)
        let height = notchHeight + (mode == .search ? 0 : Self.toolbarHeight + tabAreaHeight) + content
        return NSRect(x: screen.frame.midX - Self.expandedWidth / 2, y: screen.frame.maxY - height, width: Self.expandedWidth, height: height)
    }

    private func applyFrame(animated: Bool) {
        panel?.setFrame(isExpanded ? expandedFrame : collapsedFrame, display: true, animate: animated)
    }
}

private struct WidgetContainer: NSViewRepresentable {
    let widget: Widget

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let view = Services.shared.webViews.view(for: widget)
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}

private struct NotchView: View {
    @ObservedObject var controller: NotchController
    @ObservedObject var widgets: WidgetStore
    @ObservedObject private var agent = Services.shared.agent
    @ObservedObject private var settings = Services.shared.settings

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(.black)
            if controller.isExpanded {
                VStack(spacing: 0) {
                    // Clicking the notch itself opens search.
                    Color.black.frame(height: controller.notchHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.openSearch() }
                    if controller.mode == .search {
                        SearchView(controller: controller)
                    } else if let widget = controller.selected {
                        toolbar
                        tabs
                        WidgetContainer(widget: widget).id(widget.id)
                    } else {
                        Text("No widgets yet").foregroundStyle(.secondary).frame(maxHeight: .infinity)
                    }
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if agent.isBuilding {
                ProgressView().controlSize(.small)
                Text("Building…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.openSearch() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text(settings.searchShortcut.label).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Search")
            Button { controller.openSelectedWidgetSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("Widget settings (⌘,)")
            Button { controller.isPinned.toggle() } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .help(controller.isPinned ? "Unpin" : "Keep showing")
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    /// Anchored to the top so it never moves when the panel resizes. See docs/DESIGN.md.
    private var tabs: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 2) {
                    ForEach(Array(widgets.widgets.enumerated()), id: \.element.id) { index, widget in
                        tab(widget, shortcut: index < 9 ? "⌘\(index + 1)" : nil).id(widget.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: controller.selected?.id) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(id) } }
            }
        }
        .frame(height: controller.tabAreaHeight)
    }

    private func tab(_ widget: Widget, shortcut: String?) -> some View {
        let isSelected = widget.id == controller.selected?.id
        let isHovered = widget.id == controller.hoveredTabID
        return Button { controller.open(widget) } label: {
            HStack(spacing: 5) {
                Image(systemName: widget.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(widget.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                isSelected ? Color.white.opacity(0.2) : (isHovered ? Color.white.opacity(0.1) : .clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(HoverTracker { controller.hoverTab(widget.id, inside: $0) })
        .help(shortcut.map { "\(widget.name) (\($0))" } ?? widget.name)
    }
}

/// SwiftUI's onHover can miss events in a panel that isn't key, so this tracks with an always-active area.
private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        view.onHover = onChange
        return view
    }

    func updateNSView(_ view: HoverView, context: Context) { view.onHover = onChange }
}

private struct SearchView: View {
    @ObservedObject var controller: NotchController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search, calculate, or describe a widget and press Tab", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, result in
                        Button { controller.run(result) } label: {
                            HStack {
                                result.icon.resizable().scaledToFit().frame(width: 16, height: 16)
                                Text(result.title).lineLimit(1)
                                Spacer()
                                Text(result.detail).foregroundStyle(.secondary).font(.caption)
                            }
                            .padding(6)
                            .background(index == controller.highlighted ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .onAppear { focused = true }
    }
}
