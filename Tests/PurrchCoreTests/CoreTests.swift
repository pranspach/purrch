import PurrchCore
import Testing

@Suite struct CalculatorTests {
    @Test(arguments: [
        ("2^10 / (3+5)", 128.0),
        ("15% of 80", 12.0),
        ("1 + 2 * 3", 7.0),
        ("(1 + 2) * 3", 9.0),
        ("2^3^2", 512.0),
        ("-3 + 5", 2.0),
        ("10 / 4", 2.5),
    ])
    func evaluates(input: String, expected: Double) {
        #expect(Calculator.evaluate(input) == expected)
    }

    @Test(arguments: ["hello", "3000", "", "1 +", "(1 + 2", "1 / 0", "1..2 + 1", "weather in berlin"])
    func rejects(input: String) {
        #expect(Calculator.evaluate(input) == nil)
    }

    @Test func formats() {
        #expect(Calculator.format(128) == "128")
        #expect(Calculator.format(2.5) == "2.5")
    }
}

@Suite struct SearchCommandTests {
    @Test func killPort() {
        #expect(SearchCommand.parse("kill port 3000") == .killPort(3000))
        #expect(SearchCommand.parse("KILL PORT 8080") == .killPort(8080))
        #expect(SearchCommand.parse("kill port 99999") == nil)
        #expect(SearchCommand.parse("kill port abc") == nil)
    }

    @Test func weather() {
        #expect(SearchCommand.parse("weather in Berlin") == .weather("Berlin"))
        #expect(SearchCommand.parse("weather New York") == .weather("New York"))
        #expect(SearchCommand.parse("weather") == nil)
        #expect(SearchCommand.parse("weather in") == nil)
    }
}

@Suite struct KeyComboTests {
    @Test func labelAndConflicts() {
        let search = KeyCombo(keyCode: 49, modifiers: KeyCombo.option, key: "Space")
        #expect(search.label == "⌥Space")
        #expect(search.isUsable)
        #expect(search.systemConflict == nil)
        #expect(KeyCombo(keyCode: 49, modifiers: KeyCombo.command, key: "Space").systemConflict == "Spotlight")
        #expect(!KeyCombo(keyCode: 0, modifiers: KeyCombo.shift, key: "A").isUsable)
    }
}

@Suite struct IdeaParserTests {
    @Test func readsArrayInsideProse() {
        let output = """
        Here are some ideas:
        ```json
        [{"title": "Standup", "reason": "You open Linear daily", "prompt": "Show my tickets"}]
        ```
        """
        #expect(IdeaParser.parse(output).map(\.title) == ["Standup"])
    }

    @Test func toleratesGarbage() {
        #expect(IdeaParser.parse("no json here").isEmpty)
        #expect(IdeaParser.parse("] backwards [").isEmpty)
        #expect(IdeaParser.parse("[{\"title\": \"missing fields\"}]").isEmpty)
    }
}
