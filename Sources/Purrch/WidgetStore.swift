import AppKit
import CryptoKit
import Foundation

struct Widget: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let height: CGFloat
    let directory: URL
    /// Set when the widget shows a remote page rather than local files. Such pages never get the bridge.
    let url: URL?

    var entry: URL { directory.appendingPathComponent("index.html") }
}

private struct Manifest: Decodable {
    let name: String
    let icon: String?
    let height: Double?
    let url: String?
}

/// Widgets are folders holding manifest.json and index.html, so an agent can write one with plain file edits.
final class WidgetStore: ObservableObject {
    @Published private(set) var widgets: [Widget] = []

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Purrch", isDirectory: true)
    }()
    static let widgetsDirectory = supportDirectory.appendingPathComponent("widgets", isDirectory: true)
    private static let startersDirectory = Bundle.main.resourceURL?.appendingPathComponent("widgets")

    private static let seededKey = "seededStarterWidgets"
    private static let trustedKey = "trustedWidgetHashes"

    init() {
        try? FileManager.default.createDirectory(at: Self.widgetsDirectory, withIntermediateDirectories: true)
        seedStarters()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Self.widgetsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        widgets = folders.compactMap(Self.load).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func load(_ directory: URL) -> Widget? {
        guard
            let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }

        let remote = manifest.url.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        guard remote != nil || FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path) else { return nil }

        return Widget(
            id: directory.lastPathComponent,
            name: manifest.name,
            icon: manifest.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? "square.grid.2x2",
            height: CGFloat(min(max(manifest.height ?? 220, 80), 480)),
            directory: directory,
            url: remote
        )
    }

    /// Updates the manifest in place, keeping any fields an agent added.
    func update(_ widget: Widget, name: String, icon: String, height: CGFloat, url: String?) {
        let file = widget.directory.appendingPathComponent("manifest.json")
        var json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        json["name"] = name
        json["icon"] = icon
        json["height"] = Double(height)
        if let url { json["url"] = url }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file)
        }
        Services.shared.webViews.invalidate(widget.id)
        reload()
    }

    /// Moves to the Trash rather than deleting, so a removed widget can be recovered.
    func remove(_ widget: Widget) {
        try? FileManager.default.trashItem(at: widget.directory, resultingItemURL: nil)
        Services.shared.webViews.invalidate(widget.id)
        Services.shared.settings.widgetShortcuts[widget.id] = nil
        Services.shared.hotKeys.reload()
        forgetTrust(widget)
        reload()
    }

    /// Copies each starter once, so one the user removed stays removed.
    private func seedStarters() {
        guard let source = Self.startersDirectory else { return }
        let starters = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        var seeded = Set(UserDefaults.standard.stringArray(forKey: Self.seededKey) ?? [])

        for starter in starters where !seeded.contains(starter.lastPathComponent) {
            let target = Self.widgetsDirectory.appendingPathComponent(starter.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: starter, to: target)
            }
            seeded.insert(starter.lastPathComponent)
        }
        UserDefaults.standard.set(Array(seeded), forKey: Self.seededKey)
    }

    // MARK: Trust

    /// A widget may use the bridge if it's an unmodified starter, or the user approved these exact files.
    func isTrusted(_ widget: Widget) -> Bool {
        let hash = Self.contentHash(of: widget.directory)
        if let starter = Self.startersDirectory?.appendingPathComponent(widget.id),
           Self.contentHash(of: starter) == hash {
            return true
        }
        return (UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: String])?[widget.id] == hash
    }

    func trust(_ widget: Widget) {
        var trusted = (UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: String]) ?? [:]
        trusted[widget.id] = Self.contentHash(of: widget.directory)
        UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
    }

    func forgetTrust(_ widget: Widget) {
        var trusted = (UserDefaults.standard.dictionary(forKey: Self.trustedKey) as? [String: String]) ?? [:]
        trusted[widget.id] = nil
        UserDefaults.standard.set(trusted, forKey: Self.trustedKey)
    }

    /// Covers code only, so renaming a widget or changing its icon or height doesn't ask again.
    private static func contentHash(of directory: URL) -> String {
        var hasher = SHA256()
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent != "manifest.json" && !$0.hasDirectoryPath }
            .sorted { $0.path < $1.path } ?? []
        for file in files {
            hasher.update(data: Data(String(file.path.dropFirst(directory.path.count)).utf8))
            hasher.update(data: (try? Data(contentsOf: file)) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
