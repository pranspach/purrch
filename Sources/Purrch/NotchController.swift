import AppKit
import SwiftUI
import WebKit

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The panel at the top of the screen: collapsed around the notch, expanded on hover or ⌥Space.
final class NotchController: NSObject, ObservableObject, NSWindowDelegate {
    enum Mode { case widget, search }

    @Published private(set) var isExpanded = false
    @Published private(set) var mode = Mode.widget
    @Published private(set) var selectedID: String?
    @Published var isPinned = false
    @Published var query = ""

    private var panel: NotchPanel?
    private var collapseWork: DispatchWorkItem?
    private var keyMonitor: Any?

    private static let expandedWidth: CGFloat = 440
    private static let chromeHeight: CGFloat = 54
    private static let searchHeight: CGFloat = 300

    var screen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    func open(_ widget: Widget) {
        selectedID = widget.id
        mode = .widget
        expand()
    }

    func openSearch() {
        query = ""
        mode = .search
        expand()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    func collapse() {
        collapseWork?.cancel()
        isExpanded = false
        isPinned = false
        mode = .widget
        applyFrame(animated: true)
    }

    func select(offset: Int) {
        let widgets = Services.shared.widgets.widgets
        guard !widgets.isEmpty else { return }
        let current = widgets.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = widgets[(current + offset + widgets.count) % widgets.count].id
        mode = .widget
        applyFrame(animated: true)
    }

    func askAgentFromSearch() {
        let request = query
        collapse()
        Services.shared.agent.run(request: request)
    }

    private func expand() {
        collapseWork?.cancel()
        Services.shared.widgets.reload()
        isExpanded = true
        applyFrame(animated: true)
    }

    private func hoverChanged(_ inside: Bool) {
        collapseWork?.cancel()
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
        switch (event.keyCode, event.modifierFlags.contains(.command)) {
        case (53, _): // Esc
            collapse()
        case (123, true): // ⌘←
            select(offset: -1)
        case (124, true): // ⌘→
            select(offset: 1)
        case (48, _) where mode == .search: // Tab
            askAgentFromSearch()
        default:
            return event
        }
        return nil
    }

    private var collapsedFrame: NSRect {
        guard let screen else { return NSRect(x: 0, y: 0, width: 180, height: 10) }
        var size = NSSize(width: 180, height: 10)
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            size = NSSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private var expandedFrame: NSRect {
        guard let screen else { return collapsedFrame }
        let content = mode == .search ? Self.searchHeight : (selected?.height ?? 220)
        let height = notchHeight + Self.chromeHeight + content
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

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14).fill(.black)
            if controller.isExpanded {
                VStack(spacing: 0) {
                    Color.clear.frame(height: controller.notchHeight)
                    if controller.mode == .search {
                        SearchView(controller: controller, widgets: widgets)
                    } else if let widget = controller.selected {
                        header(widget)
                        WidgetContainer(widget: widget).id(widget.id)
                        dots
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

    private func header(_ widget: Widget) -> some View {
        HStack(spacing: 8) {
            Image(systemName: widget.icon)
            Text(widget.name).font(.system(size: 13, weight: .semibold))
            if agent.isBuilding { ProgressView().controlSize(.small) }
            Spacer()
            Button { controller.isPinned.toggle() } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .help(controller.isPinned ? "Unpin" : "Keep open")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(widgets.widgets) { widget in
                Circle()
                    .fill(widget.id == controller.selected?.id ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .onTapGesture { controller.open(widget) }
            }
        }
        .frame(height: 20)
    }
}

private struct SearchView: View {
    @ObservedObject var controller: NotchController
    @ObservedObject var widgets: WidgetStore
    @FocusState private var focused: Bool

    private static let applications: [URL] = {
        ["/Applications", "/System/Applications", "/System/Applications/Utilities"].flatMap { path in
            ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
        }
    }()

    private var matchingWidgets: [Widget] {
        let query = controller.query
        return query.isEmpty ? widgets.widgets : widgets.widgets.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var matchingApps: [URL] {
        let query = controller.query
        guard !query.isEmpty else { return [] }
        return Self.applications.filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search, or describe a widget and press Tab", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit(openFirst)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingWidgets) { widget in
                        row(icon: Image(systemName: widget.icon), title: widget.name, detail: "Widget") { controller.open(widget) }
                    }
                    ForEach(matchingApps, id: \.self) { url in
                        row(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)), title: url.deletingPathExtension().lastPathComponent, detail: "App") { open(url) }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .onAppear { focused = true }
    }

    private func row(icon: Image, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                icon.resizable().scaledToFit().frame(width: 16, height: 16)
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary).font(.caption)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openFirst() {
        if let widget = matchingWidgets.first, !controller.query.isEmpty {
            controller.open(widget)
        } else if let url = matchingApps.first {
            open(url)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        controller.collapse()
    }
}
