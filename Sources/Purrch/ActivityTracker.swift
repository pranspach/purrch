import AppKit
import Foundation
import SQLite3

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

    var activeSeconds = 0.0
    var longestFocusSeconds = 0.0
    var appSwitches = 0
    var keystrokes = 0
    var hourly = [Double](repeating: 0, count: 24)
    var topApps: [AppTime] = []
    var topSwitches: [Switch] = []

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

/// Local SQLite log of which app was frontmost and how many keys were pressed per hour.
/// It never stores which keys were pressed, window titles, or screen contents.
final class ActivityStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let url = WidgetStore.supportDirectory.appendingPathComponent("activity.sqlite")
        try? FileManager.default.createDirectory(at: WidgetStore.supportDirectory, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS sessions (id INTEGER PRIMARY KEY, app TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start);
        CREATE TABLE IF NOT EXISTS keystrokes (hour REAL PRIMARY KEY, count INTEGER NOT NULL);
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

    func deleteAll() {
        sqlite3_exec(db, "DELETE FROM sessions; DELETE FROM keystrokes;", nil, nil, nil)
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
    private let store = ActivityStore()
    private var sessionID: Int64?
    private var flushTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var eventTap: CFMachPort?

    private static let idleThreshold: TimeInterval = 120

    var canCountKeystrokes: Bool { CGPreflightListenEventAccess() }

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
        flushTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.flush() }
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

    func summary(for day: Date) -> ActivitySummary {
        flush()
        return store.summary(for: day)
    }

    func deleteAll() {
        sessionID = nil
        store.deleteAll()
        beginSession(app: NSWorkspace.shared.frontmostApplication)
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
}

/// Keeps recent copied text in memory only, skipping anything marked concealed, such as passwords.
final class ClipboardWatcher {
    private(set) var history: [String] = []
    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    private static let limit = 40
    private static let skippedTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount

        let types = pasteboard.types ?? []
        guard !types.contains(where: Self.skippedTypes.contains), let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        history = Array(history.prefix(Self.limit))
    }
}
