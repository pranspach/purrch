import Foundation

public struct WidgetIdea: Codable, Equatable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let reason: String
    public let prompt: String

    public init(title: String, reason: String, prompt: String) {
        self.title = title
        self.reason = reason
        self.prompt = prompt
    }
}

public enum IdeaParser {
    /// Agents often wrap their JSON in prose or code fences, so this reads the outermost array.
    public static func parse(_ output: String) -> [WidgetIdea] {
        guard
            let start = output.firstIndex(of: "["),
            let end = output.lastIndex(of: "]"),
            start < end,
            let ideas = try? JSONDecoder().decode([WidgetIdea].self, from: Data(output[start...end].utf8))
        else { return [] }
        return ideas.filter { !$0.title.isEmpty && !$0.prompt.isEmpty }
    }
}
