import AppKit
import SwiftUI

/// Shared app services. Everything here is created and used on the main thread.
final class Services {
    static let shared = Services()
    let settings = AppSettings()
    let navigator = Navigator()
    let widgets = WidgetStore()
    let webViews = WebViewPool()
    let activity = ActivityTracker()
    let clipboard = ClipboardWatcher()
    let agent = AgentRunner()
    let ideas = IdeaEngine()
    let hotKeys = HotKeyCenter()
    let notch = NotchController()
}

enum ProjectLinks {
    static let repository = "https://github.com/pranspach/purrch"

    /// Opens a prefilled GitHub issue. The user reviews and submits it themselves.
    static func newIssue(title: String, body: String) -> URL {
        var components = URLComponents(string: repository + "/issues/new")!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return components.url!
    }

    static var environment: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Purrch \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = Services.shared
        services.widgets.reload()
        services.activity.start()
        services.clipboard.start()
        services.notch.show()
        services.hotKeys.reload()
        services.ideas.startSchedule()
        NSApp.mainMenu = makeMainMenu()
        installStatusItem()

        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--self-test"), args.indices.contains(index + 1) {
            SelfTest(directory: URL(fileURLWithPath: args[index + 1]), delegate: self).run()
        } else if let index = args.firstIndex(of: "--record-demo"), args.indices.contains(index + 1) {
            DemoRecorder(output: URL(fileURLWithPath: args[index + 1])).run()
        } else if let index = args.firstIndex(of: "--describe"), args.indices.contains(index + 1) {
            services.agent.run(request: args[index + 1])
        } else {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Services.shared.activity.stop()
    }

    /// The app has no visible menu bar, but this is what makes ⌘W, ⌘, and ⌘V work in its windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Purrch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Purrch", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        return main
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Purrch")

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Purrch", action: #selector(openWindowFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Search", action: #selector(openSearchFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Send Feedback…", action: #selector(sendFeedback), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Purrch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openWindowFromMenu() { showWindow() }
    @objc private func openSearchFromMenu() { Services.shared.notch.openSearch() }
    @objc private func openSettings() { showWindow(page: .settings) }

    @objc func sendFeedback() {
        NSWorkspace.shared.open(ProjectLinks.newIssue(title: "", body: "\n\n---\n\(ProjectLinks.environment)"))
    }

    func showWindow(page: Navigator.Page? = nil) {
        if let page { Services.shared.navigator.page = page }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow().makeKeyAndOrderFront(nil)
    }

    func mainWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Purrch"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RootView())
        window.center()
        self.window = window
        return window
    }
}
