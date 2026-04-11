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

@Test("shortcutInput is pre-declared and emits ExtensionInput")
func shortcutInputCompiles() throws {
    let source = """
    showResult(text: "\\(shortcutInput)")
    """
    let tokens = try Lexer(source: source).tokenize()
    let nodes = try Parser(tokens: tokens).parse()
    let result = try Compiler(registry: testRegistry()).compile(nodes: nodes)

    let actions = result["WFWorkflowActions"] as! [[String: Any]]
    #expect(actions.count == 1)

    // Verify the interpolation emits ExtensionInput attachment
    let params = actions[0]["WFWorkflowActionParameters"] as! [String: Any]
    let text = params["Text"] as! [String: Any]
    let value = text["Value"] as! [String: Any]
    let attachments = value["attachmentsByRange"] as! [String: Any]
    let attachment = attachments["{0, 1}"] as! [String: Any]
    #expect(attachment["Type"] as? String == "ExtensionInput")
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
