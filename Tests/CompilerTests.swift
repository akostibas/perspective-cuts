import Testing
@testable import perspective_cuts

/// Minimal registry with just the actions needed for tests.
private func testRegistry() -> ActionRegistry {
    ActionRegistry(
        actions: [
            "getBattery": ActionDefinition(
                identifier: "is.workflow.actions.getbatterylevel",
                description: "Get the current battery level",
                parameters: [:]
            ),
            "showResult": ActionDefinition(
                identifier: "is.workflow.actions.showresult",
                description: "Show the result of the shortcut",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "Text")
                ]
            ),
        ],
        controlFlow: [:],
        iconColors: [:]
    )
}

@Test("Declared variable references compile successfully")
func declaredVariableCompiles() throws {
    let source = """
    getBattery() -> level
    showResult(text: "\\(level)")
    """
    let tokens = try Lexer(source: source).tokenize()
    let nodes = try Parser(tokens: tokens).parse()
    let result = try Compiler(registry: testRegistry()).compile(nodes: nodes)

    let actions = result["WFWorkflowActions"] as! [[String: Any]]
    #expect(actions.count == 2)
}

@Test("Undeclared variable reference produces compile error")
func undeclaredVariableThrows() throws {
    let source = """
    showResult(text: "\\(bogusVar)")
    """
    let tokens = try Lexer(source: source).tokenize()
    let nodes = try Parser(tokens: tokens).parse()

    #expect(throws: CompilerError.self) {
        _ = try Compiler(registry: testRegistry()).compile(nodes: nodes)
    }
}
