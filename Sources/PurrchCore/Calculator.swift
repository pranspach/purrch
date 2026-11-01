import Foundation

/// Evaluates the arithmetic typed into search, such as `2^10 / (3+5)` or `15% of 80`.
public enum Calculator {
    /// Returns nil for anything that isn't a complete expression with at least one operator.
    public static func evaluate(_ input: String) -> Double? {
        var parser = Parser(input.lowercased().replacingOccurrences(of: " of ", with: " * "))
        guard let value = parser.parseExpression(), parser.isAtEnd, parser.sawOperator, value.isFinite else { return nil }
        return value
    }

    public static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }

    private struct Parser {
        private let characters: [Character]
        private var position = 0
        var sawOperator = false

        init(_ text: String) { characters = text.filter { !$0.isWhitespace } }

        var isAtEnd: Bool { position == characters.count }
        private var current: Character? { position < characters.count ? characters[position] : nil }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = current, op == "+" || op == "-" {
                position += 1
                sawOperator = true
                guard let right = parseTerm() else { return nil }
                value = op == "+" ? value + right : value - right
            }
            return value
        }

        private mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while let op = current, op == "*" || op == "/" || op == "×" || op == "÷" {
                position += 1
                sawOperator = true
                guard let right = parseUnary() else { return nil }
                value = (op == "*" || op == "×") ? value * right : value / right
            }
            return value
        }

        private mutating func parseUnary() -> Double? {
            if current == "-" {
                position += 1
                return parseUnary().map { -$0 }
            }
            return parsePower()
        }

        private mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            guard current == "^" else { return base }
            position += 1
            sawOperator = true
            return parseUnary().map { pow(base, $0) }
        }

        private mutating func parsePostfix() -> Double? {
            guard var value = parseAtom() else { return nil }
            while current == "%" {
                position += 1
                sawOperator = true
                value /= 100
            }
            return value
        }

        private mutating func parseAtom() -> Double? {
            if current == "(" {
                position += 1
                let value = parseExpression()
                guard current == ")" else { return nil }
                position += 1
                return value
            }
            let start = position
            while let character = current, character.isNumber || character == "." { position += 1 }
            return start == position ? nil : Double(String(characters[start..<position]))
        }
    }
}
