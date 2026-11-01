import AppKit
import Foundation
import ScreenCaptureKit
import SQLite3
import Vision

struct ActivitySummary {
    struct AppTime: Identifiable {
        let app: String
        let seconds: Double
        var id: String { app }
    }
    struct Switch: Identifiable {
        let from: String
        let to: String
        let count: Int
        var id: String { from + "→" + to }
    }
    struct Block: Identifiable {
        let app: String
        let startFraction: Double
        let endFraction: Double
        var id: Double { startFraction }
    }

    var activeSeconds = 0.0
    var longestFocusSeconds = 0.0
    var appSwitches = 0
    var keystrokes = 0
    var hourly = [Double](repeating: 0, count: 24)
    var topApps: [AppTime] = []
    var topSwitches: [Switch] = []
    var timeline: [Block] = []

    var dictionary: [String: Any] {
        [
            "activeSeconds": activeSeconds,
            "longestFocusSeconds": longestFocusSeconds,
            "appSwitches": appSwitches,
            "keystrokes": keystrokes,
            "hourly": hourly,
            "topApps": topApps.map { ["app": $0.app, "seconds": $0.seconds] as [String: Any] },
            "topSwitches": topSwitches.map { ["from": $0.from, "to": $0.to, "count": $0.count] as [String: Any] },
        ]
    }
}

struct ActivityDetail: Identifiable {
    enum Kind: String, CaseIterable {
        case window, url, screen, clipboard

        var label: String {
            switch self {
            case .window: "Window title"
            case .url: "Web address"
            case .screen: "Screen text"
            case .clipboard: "Copied text"
            }
        }
    }

    let id: Int64
    let time: Date
    let kind: Kind
    let app: String
    let text: String
}

/// Local SQLite log of which app was frontmost, keys pressed per hour, and any detail the user opted into.
/// It never stores which keys were pressed or images of the screen.
final class ActivityStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let url = WidgetStore.supportDirectory.appendingPathComponent("activity.sqlite")
        try? FileManager.default.createDirectory(at: WidgetStore.supportDirectory, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY, app TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start);
        CREATE TABLE IF NOT EXISTS keystrokes (hour REAL PRIMARY KEY, count INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS details (id INTEGER PRIMARY KEY, time REAL NOT NULL, kind TEXT NOT NULL, app TEXT NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS details_time ON details(time);
        """, nil, nil, nil)
    }

    func insertSession(app: String, start: Date) -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "INSERT INTO sessions (app, start, end) VALUES (?, ?, ?)", -1, &statement, nil)
        sqlite3_bind_text(statement, 1, app, -1, Self.transient)
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, start.timeIntervalSince1970)
        sqlite3_step(statement)
        return sqlite3_last_insert_rowid(db)
    }

    func updateSession(id: Int64, end: Date) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "UPDATE sessions SET end = MAX(start, ?) WHERE id = ?", -1, &statement, nil)
        sqlite3_bind_double(statement, 1, end.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    func addKeystrokes(_ count: Int, at date: Date) {
        let hour = (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "INSERT INTO keystrokes (hour, count) VALUES (?, ?) ON CONFLICT(hour) DO UPDATE SET count = count + excluded.count", -1, &statement, nil)
        sqlite3_bind_double(statement, 1, hour)
        sqlite3_bind_int64(statement, 2, Int64(count))
        sqlite3_step(statement)
    }

    func addDetail(kind: ActivityDetail.Kind, app: String, text: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "INSERT INTO details (time, kind, app, text) VALUES (?, ?, ?, ?)", -1, &statement, nil)
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, Self.transient)
        sqlite3_bind_text(statement, 3, app, -1, Self.transient)
        sqlite3_bind_text(statement, 4, text, -1, Self.transient)
        sqlite3_step(statement)
    }

    func details(kinds: [ActivityDetail.Kind] = ActivityDetail.Kind.allCases, limit: Int) -> [ActivityDetail] {
        let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "SELECT id, time, kind, app, text FROM details WHERE kind IN (\(placeholders)) ORDER BY time DESC LIMIT ?", -1, &statement, nil)
        for (index, kind) in kinds.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), kind.rawValue, -1, Self.transient)
        }
        sqlite3_bind_int(statement, Int32(kinds.count + 1), Int32(limit))

        var rows: [ActivityDetail] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let kind = ActivityDetail.Kind(rawValue: String(cString: sqlite3_column_text(statement, 2))) else { continue }
            rows.append(ActivityDetail(
                id: sqlite3_column_int64(statement, 0),
                time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: kind,
                app: String(cString: sqlite3_column_text(statement, 3)),
                text: String(cString: sqlite3_column_text(statement, 4))
            ))
        }
        return rows
    }

    func purgeDetails(olderThan date: Date) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "DELETE FROM details WHERE time < ?", -1, &statement, nil)
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    func deleteAll() {
        sqlite3_exec(db, "DELETE FROM sessions; DELETE FROM keystrokes; DELETE FROM details; VACUUM;", nil, nil, nil)
    }

    func summary(for day: Date) -> ActivitySummary {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
        let lower = dayStart.timeIntervalSince1970
        let upper = dayEnd.timeIntervalSince1970

        var summary = ActivitySummary()
        var appTotals: [String: Double] = [:]
        var switchCounts: [String: (from: String, to: String, count: Int)] = [:]
        var previousApp: String?
        var runApp: String?
        var runEnd = 0.0
        var runLength = 0.0

        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT app, start, end FROM sessions WHERE end > ? AND start < ? ORDER BY start", -1, &statement, nil)
        sqlite3_bind_double(statement, 1, lower)
        sqlite3_bind_double(statement, 2, upper)
        while sqlite3_step(statement) == SQLITE_ROW {
            let app = String(cString: sqlite3_column_text(statement, 0))
            let start = max(sqlite3_column_double(statement, 1), lower)
            let end = min(sqlite3_column_double(statement, 2), upper)
            let duration = max(end - start, 0)

            summary.activeSeconds += duration
            appTotals[app, default: 0] += duration
            if duration > 0 {
                summary.timeline.append(.init(app: app, startFraction: (start - lower) / (upper - lower), endFraction: (end - lower) / (upper - lower)))
            }

            var cursor = start
            while cursor < end {
                let date = Date(timeIntervalSince1970: cursor)
                let hour = calendar.component(.hour, from: date)
                let nextHour = calendar.nextDate(after: date, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)?.timeIntervalSince1970 ?? end
                let sliceEnd = min(nextHour, end)
                summary.hourly[hour] += sliceEnd - cursor
                cursor = sliceEnd
            }

            if let previousApp, previousApp != app {
                summary.appSwitches += 1
                let key = previousApp + "→" + app
                switchCounts[key, default: (previousApp, app, 0)].count += 1
            }
            previousApp = app

            // A focus run ends on a switch, or on any gap such as going idle.
            if runApp == app, start - runEnd < 1 {
                runLength += duration
            } else {
                runLength = duration
            }
            runApp = app
            runEnd = end
            summary.longestFocusSeconds = max(summary.longestFocusSeconds, runLength)
        }
        sqlite3_finalize(statement)

        var keyStatement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(count), 0) FROM keystrokes WHERE hour >= ? AND hour < ?", -1, &keyStatement, nil)
        sqlite3_bind_double(keyStatement, 1, lower)
        sqlite3_bind_double(keyStatement, 2, upper)
        if sqlite3_step(keyStatement) == SQLITE_ROW {
            summary.keystrokes = Int(sqlite3_column_int64(keyStatement, 0))
        }
        sqlite3_finalize(keyStatement)

        summary.topApps = appTotals
            .map { ActivitySummary.AppTime(app: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(6).map { $0 }
        summary.topSwitches = switchCounts.values
            .map { ActivitySummary.Switch(from: $0.from, to: $0.to, count: $0.count) }
            .sorted { $0.count > $1.count }
            .prefix(6).map { $0 }
        return summary
    }
}

private var pendingKeystrokes = 0

final class ActivityTracker {
    let store = ActivityStore()
    private var sessionID: Int64?
    private var flushTimer: Timer?
    private var detailTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var eventTap: CFMachPort?
    private var lastWindowTitle: String?
    private var lastURL: String?
    private var lastScreenCapture = Date.distantPast

    private static let idleThreshold: TimeInterval = 120
    private static let screenTextInterval: TimeInterval = 300
    private static let detailRetention: TimeInterval = 30 * 86400
    private static let maxScreenText = 4000

    /// Screen text is never read while one of these is in front.
    private static let sensitiveApps = ["Passwords", "1Password", "Keychain Access", "Bitwarden", "LastPass", "Dashlane", "Proton Pass", "KeePassXC"]

    private static let browserScripts: [String: String] = [
        "com.apple.Safari": #"tell application id "com.apple.Safari" to get URL of front document"#,
        "com.google.Chrome": #"tell application id "com.google.Chrome" to if mode of front window is "normal" then get URL of active tab of front window"#,
        "com.brave.Browser": #"tell application id "com.brave.Browser" to if mode of front window is "normal" then get URL of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application id "company.thebrowser.Browser" to if mode of front window is "normal" then get URL of active tab of front window"#,
        "com.microsoft.edgemac": #"tell application id "com.microsoft.edgemac" to if mode of front window is "normal" then get URL of active tab of front window"#,
    ]

    var canCountKeystrokes: Bool { CGPreflightListenEventAccess() }
    var hasAccessibility: Bool { AXIsProcessTrusted() }
    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.beginSession(app: app)
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.endSession()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.beginSession(app: NSWorkspace.shared.frontmostApplication)
            })
        }

        beginSession(app: NSWorkspace.shared.frontmostApplication)
        startKeystrokeCounter()
        store.purgeDetails(olderThan: Date().addingTimeInterval(-Self.detailRetention))
        flushTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.flush() }
        detailTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.captureDetails() }
    }

    func stop() {
        endSession()
        flushKeystrokes()
    }

    /// Asks macOS for Input Monitoring. It takes effect after the user grants it and reopens the app.
    func requestKeystrokeAccess() {
        CGRequestListenEventAccess()
        startKeystrokeCounter()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    func summary(for day: Date) -> ActivitySummary {
        flush()
        return store.summary(for: day)
    }

    func deleteAll() {
        sessionID = nil
        store.deleteAll()
        beginSession(app: NSWorkspace.shared.frontmostApplication)
    }

    func recordClipboard(_ text: String) {
        guard Services.shared.settings.recordClipboard else { return }
        store.addDetail(kind: .clipboard, app: NSWorkspace.shared.frontmostApplication?.localizedName ?? "", text: String(text.prefix(Self.maxScreenText)))
    }

    /// What the idea agent sees. It leaves out screen text and copied text, which are the likeliest to hold secrets.
    func ideaDigest() -> String {
        let summary = summary(for: Date())
        var lines = ["Active minutes today: \(Int(summary.activeSeconds / 60))", "App switches today: \(summary.appSwitches)"]
        lines += summary.topApps.map { "App: \($0.app), \(Int($0.seconds / 60)) minutes" }
        lines += summary.topSwitches.map { "Switch: \($0.from) to \($0.to), \($0.count) times" }

        var seen = Set<String>()
        for detail in store.details(kinds: [.window, .url], limit: 300) {
            var text = detail.text
            if detail.kind == .url, let host = URL(string: text)?.host { text = host }
            if seen.insert(text).inserted { lines.append("\(detail.kind.label) in \(detail.app): \(text)") }
        }
        return lines.joined(separator: "\n")
    }

    private func beginSession(app: NSRunningApplication?) {
        endSession()
        guard let name = app?.localizedName else { return }
        sessionID = store.insertSession(app: name, start: Date())
    }

    private func endSession() {
        if let sessionID { store.updateSession(id: sessionID, end: Date()) }
        sessionID = nil
    }

    private func flush() {
        flushKeystrokes()

        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        if idle >= Self.idleThreshold {
            if let sessionID {
                store.updateSession(id: sessionID, end: Date().addingTimeInterval(-idle))
                self.sessionID = nil
            }
        } else if let sessionID {
            store.updateSession(id: sessionID, end: Date())
        } else {
            beginSession(app: NSWorkspace.shared.frontmostApplication)
        }
    }

    private func flushKeystrokes() {
        guard pendingKeystrokes > 0 else { return }
        store.addKeystrokes(pendingKeystrokes, at: Date())
        pendingKeystrokes = 0
    }

    private func startKeystrokeCounter() {
        guard eventTap == nil, canCountKeystrokes else { return }

        // Listen-only, and the callback only ever increments a counter. It never reads the key.
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, _ in
                if type == .keyDown { pendingKeystrokes += 1 }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
    }

    // MARK: Optional detail

    private func captureDetails() {
        guard sessionID != nil, let app = NSWorkspace.shared.frontmostApplication, let name = app.localizedName else { return }
        let settings = Services.shared.settings

        if settings.recordWindowTitles, hasAccessibility, let title = Self.focusedWindowTitle(of: app), title != lastWindowTitle {
            lastWindowTitle = title
            store.addDetail(kind: .window, app: name, text: title)
        }

        if settings.recordURLs, let bundleID = app.bundleIdentifier, let script = Self.browserScripts[bundleID] {
            let command = "osascript -e '\(script)'"
            Shell.run(arguments: ["-c", command], directory: nil, timeout: 5) { [weak self] result in
                let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, result.code == 0, url.hasPrefix("http"), url != self.lastURL else { return }
                self.lastURL = url
                self.store.addDetail(kind: .url, app: name, text: url)
            }
        }

        if settings.recordScreenText, hasScreenRecording, !Self.sensitiveApps.contains(name),
           Date().timeIntervalSince(lastScreenCapture) >= Self.screenTextInterval {
            lastScreenCapture = Date()
            Task { [weak self] in
                guard let text = await Self.readScreenText() else { return }
                DispatchQueue.main.async {
                    self?.store.addDetail(kind: .screen, app: name, text: String(text.prefix(Self.maxScreenText)))
                }
            }
        }
    }

    private static func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return (title as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Captures the main display, reads the text in memory, and discards the image.
    private static func readScreenText() async -> String? {
        guard
            let content = try? await SCShareableContent.current,
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

/// Keeps recent copies in memory only, skipping anything marked concealed, such as passwords.
final class ClipboardWatcher {
    struct Item {
        let id = UUID().uuidString
        let kind: String
        let text: String
        let thumbnail: String?
        let write: (NSPasteboard) -> Void

        var dictionary: [String: Any] {
            var result: [String: Any] = ["id": id, "kind": kind, "text": text]
            if let thumbnail { result["thumbnail"] = thumbnail }
            return result
        }
    }

    private(set) var items: [Item] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    private static let limit = 40
    private static let maxImageBytes = 20_000_000
    private static let skippedTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    func copy(_ text: String) {
        write { $0.setString(text, forType: .string) }
    }

    func copyItem(id: String) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        write(item.write)
        return true
    }

    /// Returns false when it could only copy, because pasting into other apps needs Accessibility.
    func pasteItem(id: String) -> Bool {
        guard copyItem(id: id) else { return false }
        Services.shared.notch.collapse()
        guard AXIsProcessTrusted() else { return false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let keyV: CGKeyCode = 9
            let source = CGEventSource(stateID: .combinedSessionState)
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: isDown)
                event?.flags = .maskCommand
                event?.post(tap: .cgSessionEventTap)
            }
        }
        return true
    }

    private func write(_ body: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        body(pasteboard)
        changeCount = pasteboard.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount

        let types = pasteboard.types ?? []
        guard !types.contains(where: Self.skippedTypes.contains), let item = Self.read(pasteboard) else { return }
        items.removeAll { $0.kind == item.kind && $0.text == item.text && item.kind != "image" }
        items.insert(item, at: 0)
        items = Array(items.prefix(Self.limit))
        if item.kind == "text" { Services.shared.activity.recordClipboard(item.text) }
    }

    private static func read(_ pasteboard: NSPasteboard) -> Item? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            return Item(kind: "file", text: names, thumbnail: nil) { $0.writeObjects(urls as [NSURL]) }
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return Item(kind: "text", text: text, thumbnail: nil) { $0.setString(text, forType: .string) }
        }
        if let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png), data.count <= maxImageBytes,
           let image = NSImage(data: data) {
            return Item(kind: "image", text: "Image", thumbnail: thumbnail(of: image)) { $0.setData(data, forType: pasteboard.availableType(from: [.tiff, .png]) ?? .tiff) }
        }
        return nil
    }

    private static func thumbnail(of image: NSImage) -> String? {
        let side: CGFloat = 64
        let scale = side / max(image.size.width, image.size.height, 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        result.unlockFocus()
        guard let tiff = result.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
