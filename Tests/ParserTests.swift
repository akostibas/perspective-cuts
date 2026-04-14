import Testing
@testable import perspective_cuts

@Suite("Parser")
struct ParserTests {

private func parse(_ source: String) throws -> [ASTNode] {
    let tokens = try Lexer(source: source).tokenize()
    return try Parser(tokens: tokens).parse()
}

// MARK: - Import

@Test("Parser parses import statement")
func importStatement() throws {
    let nodes = try parse("import Shortcuts")
    guard case .importStatement(let module, _) = nodes[0] else {
        Issue.record("Expected importStatement")
        return
    }
    #expect(module == "Shortcuts")
}

// MARK: - Metadata

@Test("Parser parses metadata directives")
func metadata() throws {
    let nodes = try parse("#name: My Shortcut")
    guard case .metadata(let key, let value, _) = nodes[0] else {
        Issue.record("Expected metadata")
        return
    }
    #expect(key == "name")
    #expect(value == "My Shortcut")
}

@Test("Parser parses multiple metadata")
func multipleMetadata() throws {
    let nodes = try parse("#color: blue\n#icon: gear\n#name: Test")
    #expect(nodes.count == 3)
    for node in nodes {
        guard case .metadata = node else {
            Issue.record("Expected metadata node")
            return
        }
    }
}

// MARK: - Comments

@Test("Parser parses comments")
func comments() throws {
    let nodes = try parse("// hello world")
    guard case .comment(let text, _) = nodes[0] else {
        Issue.record("Expected comment")
        return
    }
    #expect(text == "hello world")
}

// MARK: - Variable Declarations

@Test("Parser parses var declaration with string")
func varDeclarationString() throws {
    let nodes = try parse("var name = \"hello\"")
    guard case .variableDeclaration(let name, let value, let isConstant, _) = nodes[0] else {
        Issue.record("Expected variableDeclaration")
        return
    }
    #expect(name == "name")
    #expect(isConstant == false)
    guard case .stringLiteral(let s) = value else {
        Issue.record("Expected string literal value")
        return
    }
    #expect(s == "hello")
}

@Test("Parser parses let declaration with number")
func letDeclarationNumber() throws {
    let nodes = try parse("let count = 42")
    guard case .variableDeclaration(let name, let value, let isConstant, _) = nodes[0] else {
        Issue.record("Expected variableDeclaration")
        return
    }
    #expect(name == "count")
    #expect(isConstant == true)
    guard case .numberLiteral(let n) = value else {
        Issue.record("Expected number literal value")
        return
    }
    #expect(n == 42.0)
}

@Test("Parser parses var with variable reference")
func varWithReference() throws {
    let nodes = try parse("var x = other")
    guard case .variableDeclaration(_, let value, _, _) = nodes[0] else {
        Issue.record("Expected variableDeclaration")
        return
    }
    guard case .variableReference(let ref) = value else {
        Issue.record("Expected variable reference")
        return
    }
    #expect(ref == "other")
}

@Test("Parser parses var with interpolated string")
func varWithInterpolation() throws {
    let nodes = try parse("var msg = \"hello \\(name)\"")
    guard case .variableDeclaration(_, let value, _, _) = nodes[0] else {
        Issue.record("Expected variableDeclaration")
        return
    }
    guard case .interpolatedString(let parts) = value else {
        Issue.record("Expected interpolated string")
        return
    }
    #expect(parts.count == 2)
}

// MARK: - Action Calls

@Test("Parser parses action call with no args")
func actionCallNoArgs() throws {
    let nodes = try parse("getBattery()")
    guard case .actionCall(let name, let args, let output, _) = nodes[0] else {
        Issue.record("Expected actionCall")
        return
    }
    #expect(name == "getBattery")
    #expect(args.isEmpty)
    #expect(output == nil)
}

@Test("Parser parses action call with labeled arg")
func actionCallWithArg() throws {
    let nodes = try parse("showResult(text: \"hello\")")
    guard case .actionCall(let name, let args, _, _) = nodes[0] else {
        Issue.record("Expected actionCall")
        return
    }
    #expect(name == "showResult")
    #expect(args.count == 1)
    #expect(args[0].label == "text")
    guard case .stringLiteral(let s) = args[0].value else {
        Issue.record("Expected string literal arg")
        return
    }
    #expect(s == "hello")
}

@Test("Parser parses action call with output capture")
func actionCallWithOutput() throws {
    let nodes = try parse("getBattery() -> level")
    guard case .actionCall(_, _, let output, _) = nodes[0] else {
        Issue.record("Expected actionCall")
        return
    }
    #expect(output == "level")
}

@Test("Parser parses action call with multiple args")
func actionCallMultipleArgs() throws {
    let nodes = try parse("doThing(a: \"x\", b: 42, c: true)")
    guard case .actionCall(_, let args, _, _) = nodes[0] else {
        Issue.record("Expected actionCall")
        return
    }
    #expect(args.count == 3)
    #expect(args[0].label == "a")
    #expect(args[1].label == "b")
    #expect(args[2].label == "c")
}

@Test("Parser parses dotted action names")
func dottedActionName() throws {
    let nodes = try parse("com.example.app.DoThing()")
    guard case .actionCall(let name, _, _, _) = nodes[0] else {
        Issue.record("Expected actionCall")
        return
    }
    #expect(name == "com.example.app.DoThing")
}

// MARK: - If Statements

@Test("Parser parses if statement")
func ifStatement() throws {
    let nodes = try parse("""
    if x == "yes" {
        getBattery()
    }
    """)
    guard case .ifStatement(let condition, let thenBody, let elseBody, _) = nodes[0] else {
        Issue.record("Expected ifStatement")
        return
    }
    guard case .equals = condition else {
        Issue.record("Expected equals condition")
        return
    }
    #expect(thenBody.count == 1)
    #expect(elseBody == nil)
}

@Test("Parser parses if-else statement")
func ifElseStatement() throws {
    let nodes = try parse("""
    if x == "yes" {
        getBattery()
    } else {
        showResult(text: "no")
    }
    """)
    guard case .ifStatement(_, let thenBody, let elseBody, _) = nodes[0] else {
        Issue.record("Expected ifStatement")
        return
    }
    #expect(thenBody.count == 1)
    #expect(elseBody?.count == 1)
}

@Test("Parser parses all comparison operators")
func comparisonOperators() throws {
    let cases: [(String, String)] = [
        ("x == \"a\"", "equals"),
        ("x != \"a\"", "notEquals"),
        ("x > 5", "greaterThan"),
        ("x < 5", "lessThan"),
        ("x contains \"a\"", "contains"),
    ]
    for (condSource, expectedOp) in cases {
        let nodes = try parse("if \(condSource) { getBattery() }")
        guard case .ifStatement(let condition, _, _, _) = nodes[0] else {
            Issue.record("Expected ifStatement for \(expectedOp)")
            continue
        }
        switch (condition, expectedOp) {
        case (.equals, "equals"),
             (.notEquals, "notEquals"),
             (.greaterThan, "greaterThan"),
             (.lessThan, "lessThan"),
             (.contains, "contains"):
            break // matched
        default:
            Issue.record("Expected \(expectedOp) condition, got \(condition)")
        }
    }
}

// MARK: - Repeat Loop

@Test("Parser parses repeat loop")
func repeatLoop() throws {
    let nodes = try parse("""
    repeat 5 {
        getBattery()
    }
    """)
    guard case .repeatLoop(let count, let body, _) = nodes[0] else {
        Issue.record("Expected repeatLoop")
        return
    }
    guard case .numberLiteral(let n) = count else {
        Issue.record("Expected number literal count")
        return
    }
    #expect(n == 5.0)
    #expect(body.count == 1)
}

// MARK: - For Each Loop

@Test("Parser parses for-each loop")
func forEachLoop() throws {
    let nodes = try parse("""
    for item in items {
        showResult(text: "hi")
    }
    """)
    guard case .forEachLoop(let itemName, let collection, let body, _) = nodes[0] else {
        Issue.record("Expected forEachLoop")
        return
    }
    #expect(itemName == "item")
    guard case .variableReference(let collName) = collection else {
        Issue.record("Expected variable reference collection")
        return
    }
    #expect(collName == "items")
    #expect(body.count == 1)
}

// MARK: - Menu

@Test("Parser parses menu with cases")
func menu() throws {
    let nodes = try parse("""
    menu "Pick one" {
        case "Option A":
            getBattery()
        case "Option B":
            showResult(text: "b")
    }
    """)
    guard case .menu(let title, let cases, _) = nodes[0] else {
        Issue.record("Expected menu")
        return
    }
    #expect(title == "Pick one")
    #expect(cases.count == 2)
    #expect(cases[0].label == "Option A")
    #expect(cases[1].label == "Option B")
    #expect(cases[0].body.count == 1)
    #expect(cases[1].body.count == 1)
}

// MARK: - Dictionary Literals

@Test("Parser parses dictionary literal")
func dictionaryLiteral() throws {
    let nodes = try parse("var d = { \"key\": \"value\", count: 42 }")
    guard case .variableDeclaration(_, let value, _, _) = nodes[0] else {
        Issue.record("Expected variableDeclaration")
        return
    }
    guard case .dictionaryLiteral(let entries) = value else {
        Issue.record("Expected dictionary literal")
        return
    }
    #expect(entries.count == 2)
}

@Test("Parser parses nested dictionary")
func nestedDictionary() throws {
    let nodes = try parse("var d = { outer: { inner: \"val\" } }")
    guard case .variableDeclaration(_, let value, _, _) = nodes[0] else {
        Issue.record("Expected variableDeclaration")
        return
    }
    guard case .dictionaryLiteral(let entries) = value else {
        Issue.record("Expected dictionary literal")
        return
    }
    #expect(entries.count == 1)
    guard case .dictionaryLiteral(let inner) = entries[0].value else {
        Issue.record("Expected nested dictionary")
        return
    }
    #expect(inner.count == 1)
}

// MARK: - Function Declaration

@Test("Parser parses function declaration")
func functionDeclaration() throws {
    let nodes = try parse("""
    func doStuff() {
        getBattery()
    }
    """)
    guard case .functionDeclaration(let name, let body, _) = nodes[0] else {
        Issue.record("Expected functionDeclaration")
        return
    }
    #expect(name == "doStuff")
    #expect(body.count == 1)
}

// MARK: - Return Statement

@Test("Parser parses return with value")
func returnWithValue() throws {
    let nodes = try parse("""
    func doStuff() {
        return "hello"
    }
    """)
    guard case .functionDeclaration(_, let body, _) = nodes[0] else {
        Issue.record("Expected functionDeclaration")
        return
    }
    guard case .returnStatement(let value, _) = body[0] else {
        Issue.record("Expected returnStatement")
        return
    }
    #expect(value != nil)
}

// MARK: - Error Cases

@Test("Parser errors on missing module name after import")
func importMissingModule() throws {
    #expect(throws: ParserError.self) {
        _ = try parse("import")
    }
}

@Test("Parser errors on missing closing paren")
func missingClosingParen() throws {
    #expect(throws: ParserError.self) {
        _ = try parse("getBattery(")
    }
}

@Test("Parser errors on unexpected token")
func unexpectedToken() throws {
    #expect(throws: ParserError.self) {
        _ = try parse("42")
    }
}

// MARK: - Multi-statement Programs

@Test("Parser handles multiple statements")
func multipleStatements() throws {
    let nodes = try parse("""
    import Shortcuts
    #name: Test
    var x = "hello"
    getBattery() -> level
    showResult(text: "\\(level)")
    """)
    #expect(nodes.count == 5)
}

} // end ParserTests
