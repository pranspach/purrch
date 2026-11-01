import Foundation

/// A global keyboard shortcut, with Carbon key code and modifier values.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public var label: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }

    /// A shortcut needs a modifier other than Shift, or it would fire while typing.
    public var isUsable: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    /// macOS claims these itself, so registering them would silently do nothing.
    public var systemConflict: String? {
        let space: UInt32 = 49
        let tab: UInt32 = 48
        if keyCode == space, modifiers == Self.command { return "Spotlight" }
        if keyCode == tab, modifiers == Self.command { return "the app switcher" }
        if keyCode == space, modifiers == Self.control { return "input source switching" }
        return nil
    }
}
