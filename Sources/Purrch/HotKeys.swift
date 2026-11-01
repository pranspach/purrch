import AppKit
import Carbon.HIToolbox
import PurrchCore
import SwiftUI

/// Registers global shortcuts. Rebuilt whenever a shortcut changes.
final class HotKeyCenter {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var panelRefs: [EventHotKeyRef] = []
    private var panelActions: [UInt32: () -> Void] = [:]
    private(set) var conflicts: [KeyCombo: String] = [:]

    private static let signature = OSType(0x50525243) // "PRRC"
    private static let firstPanelID: UInt32 = 1000

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeyID = id.id
            DispatchQueue.main.async { Services.shared.hotKeys.fire(hotKeyID) }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    /// Replaces every registered shortcut with the ones in settings.
    func reload() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        conflicts = [:]

        let services = Services.shared
        register(services.settings.searchShortcut) { services.notch.openSearch() }
        for (id, combo) in services.settings.widgetShortcuts {
            register(combo) {
                if let widget = services.widgets.widgets.first(where: { $0.id == id }) { services.notch.open(widget) }
            }
        }
    }

    /// Claims the panel's keys only while it's open, so they never interfere with other apps otherwise.
    /// Global registration also means they work without the panel taking keyboard focus from your work.
    func setPanelKeys(enabled: Bool) {
        guard enabled == panelRefs.isEmpty else { return }
        panelRefs.forEach { UnregisterEventHotKey($0) }
        panelRefs = []
        panelActions = [:]
        guard enabled else { return }

        let notch = Services.shared.notch
        var keys: [(key: Int, modifiers: UInt32, action: () -> Void)] = [
            (kVK_LeftArrow, KeyCombo.command, { notch.select(offset: -1) }),
            (kVK_RightArrow, KeyCombo.command, { notch.select(offset: 1) }),
            (kVK_ANSI_Comma, KeyCombo.command, { notch.openSelectedWidgetSettings() }),
            (kVK_Escape, 0, { notch.collapse() }),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, digit) in digits.enumerated() {
            keys.append((digit, KeyCombo.command, { notch.select(index: index) }))
        }

        for (offset, entry) in keys.enumerated() {
            let id = Self.firstPanelID + UInt32(offset)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(entry.key), entry.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                panelRefs.append(ref)
                panelActions[id] = entry.action
            }
        }
    }

    private func register(_ combo: KeyCombo, action: @escaping () -> Void) {
        if let owner = combo.systemConflict {
            conflicts[combo] = "macOS uses this for \(owner)."
            return
        }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[id] = action
        } else {
            conflicts[combo] = "Another app is already using this shortcut."
        }
    }

    private func fire(_ id: UInt32) { (actions[id] ?? panelActions[id])?() }
}

/// Records one key press from the local event stream and reports it as a shortcut.
final class ShortcutRecording: ObservableObject {
    @Published var isRecording = false
    private var monitor: Any?

    func start(onRecord: @escaping (KeyCombo) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stop()
                return nil
            }
            let combo = Self.combo(from: event)
            if combo.isUsable {
                self.stop()
                onRecord(combo)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private static func combo(from event: NSEvent) -> KeyCombo {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= KeyCombo.command }
        if flags.contains(.shift) { modifiers |= KeyCombo.shift }
        if flags.contains(.option) { modifiers |= KeyCombo.option }
        if flags.contains(.control) { modifiers |= KeyCombo.control }

        let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let key = names[Int(event.keyCode)] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
    }
}

struct ShortcutField: View {
    let combo: KeyCombo?
    let onChange: (KeyCombo?) -> Void
    @StateObject private var recording = ShortcutRecording()

    var body: some View {
        HStack {
            if let combo, let conflict = Services.shared.hotKeys.conflicts[combo] {
                Label(conflict, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            Button(recording.isRecording ? "Press keys…" : (combo?.label ?? "Record")) {
                recording.start { onChange($0) }
            }
            .monospacedDigit()
            if combo != nil, !recording.isRecording {
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Clear")
            }
        }
    }
}
