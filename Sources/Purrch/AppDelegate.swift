import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shared app services. Everything here is created and used on the main thread.
final class Services {
    static let shared = Services()
    let widgets = WidgetStore()
    let webViews = WebViewPool()
    let activity = ActivityTracker()
    let clipboard = ClipboardWatcher()
    let agent = AgentRunner()
    let notch = NotchController()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = Services.shared
        services.widgets.reload()
        services.activity.start()
        services.clipboard.start()
        services.notch.show()
        installStatusItem()
        installHotKey()

        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--describe"), args.indices.contains(index + 1) {
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

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Purrch")

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Purrch", action: #selector(openWindowFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Search", action: #selector(openSearchFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Purrch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openWindowFromMenu() { showWindow() }
    @objc private func openSearchFromMenu() { Services.shared.notch.openSearch() }

    func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Purrch"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView())
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// ⌥Space opens search from anywhere.
    private func installHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Services.shared.notch.openSearch() }
            return noErr
        }, 1, &eventType, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x50525243), id: 1) // "PRRC"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}
