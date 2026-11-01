import Foundation

/// Natural commands that search can preview and run.
public enum SearchCommand: Equatable {
    case killPort(Int)
    case weather(String)

    public static func parse(_ input: String) -> SearchCommand? {
        let words = input.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)

        if words.count == 3, words[0] == "kill", words[1] == "port", let port = Int(words[2]), (1...65535).contains(port) {
            return .killPort(port)
        }
        if words.first == "weather" {
            let place = words.dropFirst(words.dropFirst().first == "in" ? 2 : 1)
            if !place.isEmpty {
                // Keeps the original capitalization of the place name.
                let original = input.split(whereSeparator: \.isWhitespace).suffix(place.count)
                return .weather(original.joined(separator: " "))
            }
        }
        return nil
    }
}
