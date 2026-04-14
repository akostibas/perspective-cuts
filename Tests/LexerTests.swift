import Testing
@testable import perspective_cuts

@Suite("Lexer")
struct LexerTests {

// MARK: - Keywords

@Test("Lexer tokenizes keywords")
func keywords() throws {
    let source = "import let var if else repeat for in menu case func return contains"
    let tokens = try Lexer(source: source).tokenize()
    let kinds = tokens.map(\.kind)
    #expect(kinds == [
        .importKeyword, .letKeyword, .varKeyword, .ifKeyword, .elseKeyword,
        .repeatKeyword, .forKeyword, .inKeyword, .menuKeyword, .caseKeyword,
        .funcKeyword, .returnKeyword, .containsKeyword, .eof
    ])
}

// MARK: - Identifiers

@Test("Lexer tokenizes identifiers")
func identifiers() throws {
    let tokens = try Lexer(source: "foo bar_baz _x").tokenize()
    let kinds = tokens.map(\.kind)
    #expect(kinds == [.identifier("foo"), .identifier("bar_baz"), .identifier("_x"), .eof])
}

@Test("Lexer allows hyphens in identifiers")
func hyphenatedIdentifiers() throws {
    let tokens = try Lexer(source: "my-action").tokenize()
    #expect(tokens[0].kind == .identifier("my-action"))
}

// MARK: - Literals

@Test("Lexer tokenizes string literals")
func stringLiterals() throws {
    let tokens = try Lexer(source: "\"hello world\"").tokenize()
    #expect(tokens[0].kind == .stringLiteral("hello world"))
}

@Test("Lexer handles escape sequences in strings")
func escapeSequences() throws {
    let tokens = try Lexer(source: "\"line1\\nline2\\ttab\\\\slash\\\"quote\"").tokenize()
    #expect(tokens[0].kind == .stringLiteral("line1\nline2\ttab\\slash\"quote"))
}

@Test("Lexer preserves interpolation markers in strings")
func stringInterpolation() throws {
    let tokens = try Lexer(source: "\"hello \\(name)\"").tokenize()
    #expect(tokens[0].kind == .stringLiteral("hello \\(name)"))
}

@Test("Lexer tokenizes integer numbers")
func integerNumbers() throws {
    let tokens = try Lexer(source: "42").tokenize()
    #expect(tokens[0].kind == .numberLiteral(42.0))
}

@Test("Lexer tokenizes decimal numbers")
func decimalNumbers() throws {
    let tokens = try Lexer(source: "3.14").tokenize()
    #expect(tokens[0].kind == .numberLiteral(3.14))
}

@Test("Lexer tokenizes booleans")
func booleans() throws {
    let tokens = try Lexer(source: "true false").tokenize()
    #expect(tokens[0].kind == .boolLiteral(true))
    #expect(tokens[1].kind == .boolLiteral(false))
}

// MARK: - Comments

@Test("Lexer tokenizes line comments")
func lineComments() throws {
    let tokens = try Lexer(source: "// this is a comment").tokenize()
    #expect(tokens[0].kind == .comment("this is a comment"))
}

@Test("Lexer tokenizes block comments")
func blockComments() throws {
    let tokens = try Lexer(source: "/* block comment */").tokenize()
    #expect(tokens[0].kind == .comment("block comment"))
}

@Test("Lexer handles multiline block comments")
func multilineBlockComments() throws {
    let tokens = try Lexer(source: "/* line1\nline2 */").tokenize()
    #expect(tokens[0].kind == .comment("line1\nline2"))
}

// MARK: - Operators and Punctuation

@Test("Lexer tokenizes operators")
func operators() throws {
    let tokens = try Lexer(source: "-> == != = > <").tokenize()
    let kinds = tokens.map(\.kind)
    #expect(kinds == [.arrow, .doubleEquals, .notEquals, .equals, .greaterThan, .lessThan, .eof])
}

@Test("Lexer tokenizes punctuation")
func punctuation() throws {
    let tokens = try Lexer(source: "( ) { } [ ] , : # .").tokenize()
    let kinds = tokens.map(\.kind)
    #expect(kinds == [
        .leftParen, .rightParen, .leftBrace, .rightBrace,
        .leftBracket, .rightBracket, .comma, .colon, .hash, .dot, .eof
    ])
}

// MARK: - Newlines

@Test("Lexer emits newline tokens")
func newlines() throws {
    let tokens = try Lexer(source: "foo\nbar").tokenize()
    let kinds = tokens.map(\.kind)
    #expect(kinds == [.identifier("foo"), .newline, .identifier("bar"), .eof])
}

// MARK: - Source Locations

@Test("Lexer tracks line and column numbers")
func sourceLocations() throws {
    let tokens = try Lexer(source: "foo\nbar baz").tokenize()
    #expect(tokens[0].location.line == 1)
    #expect(tokens[0].location.column == 1)
    // tokens[1] is newline
    #expect(tokens[2].location.line == 2)
    #expect(tokens[2].location.column == 1)
    #expect(tokens[3].location.line == 2)
    #expect(tokens[3].location.column == 5)
}

// MARK: - Error Cases

@Test("Lexer rejects unexpected characters")
func unexpectedCharacter() throws {
    #expect(throws: LexerError.self) {
        _ = try Lexer(source: "~").tokenize()
    }
}

// MARK: - Full Statement

@Test("Lexer tokenizes a complete action call")
func fullActionCall() throws {
    let tokens = try Lexer(source: "showResult(text: \"hello\") -> output").tokenize()
    let kinds = tokens.map(\.kind)
    #expect(kinds == [
        .identifier("showResult"), .leftParen,
        .identifier("text"), .colon, .stringLiteral("hello"),
        .rightParen, .arrow, .identifier("output"), .eof
    ])
}

} // end LexerTests
