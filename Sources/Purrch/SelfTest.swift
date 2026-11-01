import AppKit
import WebKit

/// `Purrch --self-test <dir>` drives the real UI and saves screenshots and page text, for checking
/// changes without granting Screen Recording. It reads data but doesn't change anything.
final class SelfTest {
    private let directory: URL
    private let delegate: AppDelegate
    private var report: [String: Any] = [:]

    init(directory: URL, delegate: AppDelegate) {
        self.directory = directory
        self.delegate = delegate
    }

    func run() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { @MainActor in
            await self.drive()
            let data = try? JSONSerialization.data(withJSONObject: self.report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: self.directory.appendingPathComponent("report.json"))
            NSApp.terminate(nil)
        }
    }

    @MainActor private func drive() async {
        let services = Services.shared
        let notch = services.notch

        delegate.showWindow()
        try? await Task.sleep(for: .seconds(1))
        save(view: delegate.mainWindow().contentView, as: "first-window")
        services.settings.skipOnboardingThisRun = true
        for page in Navigator.Page.allCases {
            services.navigator.page = page
            try? await Task.sleep(for: .seconds(1))
            save(view: delegate.mainWindow().contentView, as: "page-\(page.rawValue)")
        }

        var widgets: [String: Any] = [:]
        for widget in services.widgets.widgets {
            notch.open(widget)
            notch.isPinned = true
            try? await Task.sleep(for: .seconds(2.5))
            save(view: notch.panel?.contentView, as: "notch-\(widget.id)")

            let view = services.webViews.view(for: widget)
            let text = try? await view.evaluateJavaScript("document.body.innerText") as? String
            widgets[widget.id] = ["text": text ?? "<none>", "frame": "\(view.frame.size)"]
            if let image = try? await view.takeSnapshot(configuration: nil) {
                write(image, as: "widget-\(widget.id)")
            }
        }
        report["widgets"] = widgets

        notch.select(index: 2)
        try? await Task.sleep(for: .seconds(1))
        report["selectIndex2"] = notch.selected?.name ?? "<none>"
        notch.select(offset: 1)
        try? await Task.sleep(for: .seconds(1))
        report["selectNext"] = notch.selected?.name ?? "<none>"
        notch.hoverTab(services.widgets.widgets.last?.id ?? "", inside: true)
        try? await Task.sleep(for: .seconds(0.5))
        save(view: notch.panel?.contentView, as: "tabs-hovering-last")
        notch.hoverTab(services.widgets.widgets.last?.id ?? "", inside: false)

        var search: [String: [String]] = [:]
        notch.openSearch()
        for query in ["2^10 / (3+5)", "15% of 80", "kill port 1", "weather in Berlin", "timer", "cal"] {
            notch.query = query
            try? await Task.sleep(for: .seconds(query.hasPrefix("weather") ? 6 : 2))
            search[query] = notch.results.map { "\($0.title) [\($0.detail)]" }
        }
        report["search"] = search
        notch.query = "2^10 / (3+5)"
        try? await Task.sleep(for: .seconds(0.5))
        save(view: notch.panel?.contentView, as: "search")

        report["trust"] = checkTrust()
        report["agents"] = services.agent.available.map(\.name)
        report["panel"] = [
            "level": notch.panel?.level.rawValue ?? -1,
            "frame": "\(notch.panel?.frame ?? .zero)",
        ] as [String: Any]
        report["hotKeyConflicts"] = services.hotKeys.conflicts.map(\.value)
        notch.collapse()
    }

    /// Uses a throwaway widget, which it removes again.
    private func checkTrust() -> [String: Bool] {
        let store = Services.shared.widgets
        var results = ["allStartersTrusted": store.widgets.filter { $0.url == nil }.allSatisfy(store.isTrusted)]

        let folder = WidgetStore.widgetsDirectory.appendingPathComponent("self-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? #"{"name": "Test"}"#.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try? "<p>one</p>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        guard let widget = WidgetStore.load(folder) else { return results }

        results["newWidgetUntrusted"] = !store.isTrusted(widget)
        store.trust(widget)
        results["approvedWidgetTrusted"] = store.isTrusted(widget)
        try? "<p>two</p>".write(to: widget.entry, atomically: true, encoding: .utf8)
        results["changedWidgetUntrusted"] = !store.isTrusted(widget)
        store.forgetTrust(widget)
        return results
    }

    @MainActor private func save(view: NSView?, as name: String) {
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        write(image, background: .windowBackgroundColor, as: name)
    }

    /// Views render with a transparent background, which would hide light text.
    private func write(_ image: NSImage, background: NSColor = .black, as name: String) {
        let flattened = NSImage(size: image.size)
        flattened.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        flattened.unlockFocus()
        guard let tiff = flattened.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
