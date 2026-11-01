import Foundation
import PurrchCore

/// User preferences, saved to UserDefaults as they change.
final class AppSettings: ObservableObject {
    enum Display: String, CaseIterable, Identifiable {
        case automatic, builtIn, main
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: "Notch if there is one, otherwise main display"
            case .builtIn: "Built-in display"
            case .main: "Main display"
            }
        }
    }

    private static let defaults = UserDefaults.standard
    static let defaultSearchShortcut = KeyCombo(keyCode: 49, modifiers: KeyCombo.option, key: "Space")

    @Published var hasOnboarded = defaults.bool(forKey: "hasOnboarded") {
        didSet { Self.defaults.set(hasOnboarded, forKey: "hasOnboarded") }
    }
    /// Lets the self-test reach the main pages without marking onboarding as done.
    @Published var skipOnboardingThisRun = false
    @Published var display = Display(rawValue: defaults.string(forKey: "display") ?? "") ?? .automatic {
        didSet { Self.defaults.set(display.rawValue, forKey: "display") }
    }
    @Published var switchLiveOnly = defaults.bool(forKey: "switchLiveOnly") {
        didSet { Self.defaults.set(switchLiveOnly, forKey: "switchLiveOnly") }
    }

    @Published var searchShortcut = load("searchShortcut") ?? defaultSearchShortcut {
        didSet { Self.save(searchShortcut, "searchShortcut") }
    }
    @Published var widgetShortcuts: [String: KeyCombo] = load("widgetShortcuts") ?? [:] {
        didSet { Self.save(widgetShortcuts, "widgetShortcuts") }
    }

    // Each kind of detail is opt-in, on top of the macOS permission it needs.
    @Published var recordWindowTitles = defaults.bool(forKey: "recordWindowTitles") {
        didSet { Self.defaults.set(recordWindowTitles, forKey: "recordWindowTitles") }
    }
    @Published var recordURLs = defaults.bool(forKey: "recordURLs") {
        didSet { Self.defaults.set(recordURLs, forKey: "recordURLs") }
    }
    @Published var recordScreenText = defaults.bool(forKey: "recordScreenText") {
        didSet { Self.defaults.set(recordScreenText, forKey: "recordScreenText") }
    }
    @Published var recordClipboard = defaults.bool(forKey: "recordClipboard") {
        didSet { Self.defaults.set(recordClipboard, forKey: "recordClipboard") }
    }

    @Published var autoIdeas = defaults.bool(forKey: "autoIdeas") {
        didSet { Self.defaults.set(autoIdeas, forKey: "autoIdeas") }
    }
    @Published var ideaIntervalHours = defaults.object(forKey: "ideaIntervalHours") as? Int ?? 24 {
        didSet { Self.defaults.set(ideaIntervalHours, forKey: "ideaIntervalHours") }
    }
    @Published var ideaRequiresPower = defaults.object(forKey: "ideaRequiresPower") as? Bool ?? true {
        didSet { Self.defaults.set(ideaRequiresPower, forKey: "ideaRequiresPower") }
    }
    @Published var ideaRequiresIdle = defaults.object(forKey: "ideaRequiresIdle") as? Bool ?? true {
        didSet { Self.defaults.set(ideaRequiresIdle, forKey: "ideaRequiresIdle") }
    }

    private static func load<Value: Decodable>(_ key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private static func save<Value: Encodable>(_ value: Value, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

/// Which page the main window shows, so other parts of the app can send the user somewhere.
final class Navigator: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case widgets = "Widgets"
        case ideas = "Ideas"
        case activity = "Activity"
        case shortcuts = "Shortcuts"
        case privacy = "Privacy"
        case settings = "Settings"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .widgets: "square.grid.2x2"
            case .ideas: "lightbulb"
            case .activity: "chart.bar"
            case .shortcuts: "command"
            case .privacy: "hand.raised"
            case .settings: "gearshape"
            }
        }
    }

    @Published var page: Page? = .widgets
    @Published var editingWidgetID: String?
}
