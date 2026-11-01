import AppKit
import Foundation

struct Widget: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let height: CGFloat
    let directory: URL

    var entry: URL { directory.appendingPathComponent("index.html") }
}

private struct Manifest: Decodable {
    let name: String
    let icon: String?
    let height: Double?
}

/// Widgets are folders holding manifest.json and index.html, so an agent can write one with plain file edits.
final class WidgetStore: ObservableObject {
    @Published private(set) var widgets: [Widget] = []

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Purrch", isDirectory: true)
    }()
    static let widgetsDirectory = supportDirectory.appendingPathComponent("widgets", isDirectory: true)

    private static let seededKey = "seededStarterWidgets"

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
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html").path)
        else { return nil }

        return Widget(
            id: directory.lastPathComponent,
            name: manifest.name,
            icon: manifest.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? "square.grid.2x2",
            height: CGFloat(min(max(manifest.height ?? 220, 80), 480)),
            directory: directory
        )
    }

    /// Moves to the Trash rather than deleting, so a removed widget can be recovered.
    func remove(_ widget: Widget) {
        try? FileManager.default.trashItem(at: widget.directory, resultingItemURL: nil)
        Services.shared.webViews.invalidate(widget.id)
        reload()
    }

    /// Copies each starter once, so one the user removed stays removed.
    private func seedStarters() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("widgets") else { return }
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
}
