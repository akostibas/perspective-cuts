import Testing
import Foundation
@testable import perspective_cuts

@Suite("Preprocessor")
struct PreprocessorTests {

    /// Creates a temporary directory with the given files and returns its URL.
    private func makeTempDir(files: [String: String]) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perspective-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for (name, content) in files {
            let fileURL = tmpDir.appendingPathComponent(name)
            // Create subdirectories if needed
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return tmpDir
    }

    private func parse(_ source: String) throws -> [ASTNode] {
        let tokens = try Lexer(source: source).tokenize()
        return try Parser(tokens: tokens).parse()
    }

    // MARK: - Parser: #include and #fragment

    @Test("Parser parses #include directive")
    func parseInclude() throws {
        let nodes = try parse("#include \"fragments/foo.perspective\"")
        guard case .includeDirective(let path, _) = nodes[0] else {
            Issue.record("Expected includeDirective")
            return
        }
        #expect(path == "fragments/foo.perspective")
    }

    @Test("Parser parses #fragment marker")
    func parseFragment() throws {
        let nodes = try parse("#fragment")
        guard case .fragmentMarker = nodes[0] else {
            Issue.record("Expected fragmentMarker")
            return
        }
    }

    @Test("Parser errors on #include without path")
    func includeWithoutPath() throws {
        #expect(throws: ParserError.self) {
            _ = try parse("#include")
        }
    }

    // MARK: - Preprocessor: Include Resolution

    @Test("Include inlines fragment actions at include site")
    func basicInclude() throws {
        let dir = try makeTempDir(files: [
            "fragment.perspective": """
            #fragment
            // Setup step
            """
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"fragment.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // Should have 1 node: the comment (fragment marker stripped)
        #expect(result.count == 1)
        guard case .comment(let text, _) = result[0] else {
            Issue.record("Expected comment node, got \(result[0])")
            return
        }
        #expect(text == "Setup step")
    }

    @Test("Include strips import and metadata from fragment")
    func stripsImportAndMetadata() throws {
        let dir = try makeTempDir(files: [
            "standalone.perspective": """
            import Shortcuts
            #name: Helper
            #color: blue
            // The real work
            """
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"standalone.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // Only the comment should survive — import and metadata stripped
        #expect(result.count == 1)
        guard case .comment = result[0] else {
            Issue.record("Expected comment, got \(result[0])")
            return
        }
    }

    @Test("Including a non-fragment file works")
    func includeNonFragment() throws {
        let dir = try makeTempDir(files: [
            "other.perspective": """
            import Shortcuts
            #name: Other Shortcut
            // Action from other
            """
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"other.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        #expect(result.count == 1)
        guard case .comment = result[0] else {
            Issue.record("Expected comment")
            return
        }
    }

    @Test("Multiple includes inline in order")
    func multipleIncludes() throws {
        let dir = try makeTempDir(files: [
            "a.perspective": "#fragment\n// Part A",
            "b.perspective": "#fragment\n// Part B",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        #include "a.perspective"
        #include "b.perspective"
        """)
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        #expect(result.count == 2)
        guard case .comment(let textA, _) = result[0] else {
            Issue.record("Expected comment A")
            return
        }
        guard case .comment(let textB, _) = result[1] else {
            Issue.record("Expected comment B")
            return
        }
        #expect(textA == "Part A")
        #expect(textB == "Part B")
    }

    @Test("Include resolves relative to including file directory")
    func relativePathResolution() throws {
        let dir = try makeTempDir(files: [
            "fragments/helper.perspective": "#fragment\n// Helper action"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"fragments/helper.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        #expect(result.count == 1)
    }

    @Test("Main file nodes are preserved around includes")
    func mainNodesPreserved() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": "#fragment\n// Fragment"
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        // Before
        #include "frag.perspective"
        // After
        """)
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        #expect(result.count == 3)
        guard case .comment(let t0, _) = result[0] else { Issue.record("Expected comment 0"); return }
        guard case .comment(let t1, _) = result[1] else { Issue.record("Expected comment 1"); return }
        guard case .comment(let t2, _) = result[2] else { Issue.record("Expected comment 2"); return }
        #expect(t0 == "Before")
        #expect(t1 == "Fragment")
        #expect(t2 == "After")
    }

    // MARK: - Error Cases

    @Test("Include of missing file produces error")
    func missingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perspective-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"nonexistent.perspective\"")

        #expect(throws: PreprocessorError.self) {
            _ = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        }
    }

    @Test("Compiling a #fragment file directly produces error")
    func fragmentStandaloneError() throws {
        let nodes = try parse("""
        #fragment
        // Some actions
        """)

        #expect(throws: PreprocessorError.self) {
            _ = try Preprocessor(sourceDirectory: URL(fileURLWithPath: "/tmp")).preprocess(nodes: nodes)
        }
    }

    // MARK: - End-to-End: Include + Compile

    @Test("Included fragment actions compile into final shortcut")
    func includeAndCompile() throws {
        let dir = try makeTempDir(files: [
            "fragment.perspective": """
            #fragment
            // Setup comment
            """
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = """
        #name: Main
        #include "fragment.perspective"
        """
        let tokens = try Lexer(source: source).tokenize()
        let parsed = try Parser(tokens: tokens).parse()
        let preprocessed = try Preprocessor(sourceDirectory: dir).preprocess(nodes: parsed)

        let registry = ActionRegistry(actions: [:], controlFlow: [:], iconColors: [:])
        let result = try Compiler(registry: registry).compile(nodes: preprocessed)

        #expect(result["WFWorkflowName"] as? String == "Main")
        let actions = result["WFWorkflowActions"] as! [[String: Any]]
        // The comment from the fragment should be compiled as an action
        #expect(actions.count == 1)
        let id = actions[0]["WFWorkflowActionIdentifier"] as? String
        #expect(id == "is.workflow.actions.comment")
    }

    @Test("Multiple fragments compose into single shortcut")
    func multiFragmentComposition() throws {
        let dir = try makeTempDir(files: [
            "a.perspective": "#fragment\n// Part A",
            "b.perspective": "#fragment\n// Part B",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = """
        #name: Composed
        #include "a.perspective"
        #include "b.perspective"
        """
        let tokens = try Lexer(source: source).tokenize()
        let parsed = try Parser(tokens: tokens).parse()
        let preprocessed = try Preprocessor(sourceDirectory: dir).preprocess(nodes: parsed)

        let registry = ActionRegistry(actions: [:], controlFlow: [:], iconColors: [:])
        let result = try Compiler(registry: registry).compile(nodes: preprocessed)

        let actions = result["WFWorkflowActions"] as! [[String: Any]]
        #expect(actions.count == 2)
    }

    // MARK: - Parser: #provides and #requires

    @Test("Parser parses #provides directive")
    func parseProvides() throws {
        let nodes = try parse("#provides: apiKey, serverURL")
        guard case .providesDeclaration(let vars, _) = nodes[0] else {
            Issue.record("Expected providesDeclaration")
            return
        }
        #expect(vars == ["apiKey", "serverURL"])
    }

    @Test("Parser parses #requires directive")
    func parseRequires() throws {
        let nodes = try parse("#requires: serverURL")
        guard case .requiresDeclaration(let vars, _) = nodes[0] else {
            Issue.record("Expected requiresDeclaration")
            return
        }
        #expect(vars == ["serverURL"])
    }

    @Test("Parser errors on empty #provides")
    func emptyProvides() throws {
        #expect(throws: ParserError.self) {
            _ = try parse("#provides:")
        }
    }

    // MARK: - Dependency Validation

    @Test("Satisfied #requires passes validation")
    func satisfiedRequires() throws {
        let dir = try makeTempDir(files: [
            "config.perspective": """
            #fragment
            #provides: apiKey
            var apiKey = "sk-123"
            """,
            "api.perspective": """
            #fragment
            #requires: apiKey
            #provides: result
            // uses apiKey
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        #include "config.perspective"
        #include "api.perspective"
        """)
        // Should not throw
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        #expect(!result.isEmpty)
    }

    @Test("Main file var satisfies #requires")
    func mainFileVarSatisfiesRequires() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #requires: serverURL
            // uses serverURL
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        var serverURL = "https://example.com"
        #include "frag.perspective"
        """)
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        #expect(!result.isEmpty)
    }

    @Test("Main file -> capture satisfies #requires")
    func mainFileOutputSatisfiesRequires() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #requires: data
            // uses data
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        getBattery() -> data
        #include "frag.perspective"
        """)
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        #expect(!result.isEmpty)
    }

    @Test("Unsatisfied #requires produces error")
    func unsatisfiedRequires() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #requires: missingVar
            // needs missingVar
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"frag.perspective\"")
        #expect(throws: PreprocessorError.self) {
            _ = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        }
    }

    @Test("Duplicate #provides produces error")
    func duplicateProvides() throws {
        let dir = try makeTempDir(files: [
            "a.perspective": """
            #fragment
            #provides: token
            var token = "abc"
            """,
            "b.perspective": """
            #fragment
            #provides: token
            var token = "xyz"
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        #include "a.perspective"
        #include "b.perspective"
        """)
        #expect(throws: PreprocessorError.self) {
            _ = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        }
    }

    // MARK: - Variable Auto-Prefixing

    @Test("Fragment prefix derives camelCase from filename")
    func fragmentPrefixDerivation() {
        #expect(Preprocessor.fragmentPrefix(from: "config-loader.perspective") == "configLoader__")
        #expect(Preprocessor.fragmentPrefix(from: "fragments/api-call.perspective") == "apiCall__")
        #expect(Preprocessor.fragmentPrefix(from: "simple.perspective") == "simple__")
        #expect(Preprocessor.fragmentPrefix(from: "a_b_c.perspective") == "aBC__")
    }

    @Test("Internal variables are prefixed")
    func internalVarsPrefixed() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #provides: result
            var temp = "working"
            var result = "done"
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"frag.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // temp should be prefixed, result should not
        guard case .variableDeclaration(let name1, _, _, _) = result[0] else {
            Issue.record("Expected var declaration")
            return
        }
        guard case .variableDeclaration(let name2, _, _, _) = result[1] else {
            Issue.record("Expected var declaration")
            return
        }
        #expect(name1 == "frag__temp")
        #expect(name2 == "result")
    }

    @Test("Action output captures are prefixed when internal")
    func outputCapturesPrefixed() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #provides: finalResult
            // internal capture gets prefixed
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let dir2 = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #provides: publicVar
            getBattery() -> internalOutput
            var publicVar = "done"
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir2) }

        let mainNodes = try parse("#include \"frag.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir2).preprocess(nodes: mainNodes)

        // getBattery() -> frag__internalOutput
        guard case .actionCall(_, _, let output, _) = result[0] else {
            Issue.record("Expected action call")
            return
        }
        #expect(output == "frag__internalOutput")

        // var publicVar = "done" (not prefixed)
        guard case .variableDeclaration(let name, _, _, _) = result[1] else {
            Issue.record("Expected var declaration")
            return
        }
        #expect(name == "publicVar")
    }

    @Test("Variable references in expressions are prefixed")
    func expressionReferencesPrefixed() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #provides: output
            var temp = "hello"
            var output = temp
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"frag.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // var frag__temp = "hello"
        guard case .variableDeclaration(let name1, _, _, _) = result[0] else {
            Issue.record("Expected var declaration")
            return
        }
        #expect(name1 == "frag__temp")

        // var output = frag__temp  (reference should be prefixed)
        guard case .variableDeclaration(let name2, let value, _, _) = result[1] else {
            Issue.record("Expected var declaration")
            return
        }
        #expect(name2 == "output")
        guard case .variableReference(let ref) = value else {
            Issue.record("Expected variable reference")
            return
        }
        #expect(ref == "frag__temp")
    }

    @Test("Interpolated string variable references are prefixed")
    func interpolationReferencesPrefixed() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #provides: msg
            var temp = "world"
            var msg = "hello \\(temp)"
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"frag.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        guard case .variableDeclaration(_, let value, _, _) = result[1] else {
            Issue.record("Expected var declaration")
            return
        }
        guard case .interpolatedString(let parts) = value else {
            Issue.record("Expected interpolated string")
            return
        }
        // Should have text "hello " and variable "frag__temp"
        guard case .variable(let varName) = parts[1] else {
            Issue.record("Expected variable part")
            return
        }
        #expect(varName == "frag__temp")
    }

    @Test("For-each loop variables are NOT prefixed")
    func loopVarsExempt() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #requires: items
            #provides: count
            var count = 0
            for item in items {
                var count = 0
            }
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        getBattery() -> items
        #include "frag.perspective"
        """)
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // Find the for-each loop node
        let forNode = result.first(where: { if case .forEachLoop = $0 { return true } else { return false } })
        guard case .forEachLoop(let itemName, _, _, _) = forNode else {
            Issue.record("Expected forEachLoop")
            return
        }
        #expect(itemName == "item") // NOT frag__item
    }

    @Test("Requires variables are NOT prefixed in references")
    func requiresVarsNotPrefixed() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #requires: apiKey
            #provides: result
            var result = apiKey
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        var apiKey = "sk-123"
        #include "frag.perspective"
        """)
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // The fragment's "var result = apiKey" — apiKey should NOT be prefixed
        let fragVarNode = result.last!
        guard case .variableDeclaration(let name, let value, _, _) = fragVarNode else {
            Issue.record("Expected var declaration")
            return
        }
        #expect(name == "result")
        guard case .variableReference(let ref) = value else {
            Issue.record("Expected variable reference")
            return
        }
        #expect(ref == "apiKey") // NOT frag__apiKey
    }

    @Test("Fragments without contracts are NOT prefixed")
    func noContractsNoPrefixing() throws {
        let dir = try makeTempDir(files: [
            "simple.perspective": """
            #fragment
            var temp = "hello"
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"simple.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        guard case .variableDeclaration(let name, _, _, _) = result[0] else {
            Issue.record("Expected var declaration")
            return
        }
        #expect(name == "temp") // NOT prefixed since no #provides/#requires
    }

    // MARK: - End-to-End: Phase 2 with Compilation

    @Test("Auto-prefixed fragment compiles correctly")
    func prefixedFragmentCompiles() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": """
            #fragment
            #provides: greeting
            var temp = "world"
            var greeting = "hello"
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = """
        #name: Test
        #include "frag.perspective"
        """
        let tokens = try Lexer(source: source).tokenize()
        let parsed = try Parser(tokens: tokens).parse()
        let preprocessed = try Preprocessor(sourceDirectory: dir).preprocess(nodes: parsed)

        let registry = ActionRegistry(actions: [:], controlFlow: [:], iconColors: [:])
        let result = try Compiler(registry: registry).compile(nodes: preprocessed)

        let actions = result["WFWorkflowActions"] as! [[String: Any]]
        // temp: text + setvariable, greeting: text + setvariable = 4 actions
        #expect(actions.count == 4)

        // First setvariable should use prefixed name "frag__temp"
        let firstSetVar = actions[1]["WFWorkflowActionParameters"] as! [String: Any]
        #expect(firstSetVar["WFVariableName"] as? String == "frag__temp")

        // Second setvariable should use unprefixed "greeting"
        let secondSetVar = actions[3]["WFWorkflowActionParameters"] as! [String: Any]
        #expect(secondSetVar["WFVariableName"] as? String == "greeting")
    }

    @Test("Auto-prefixing exempts shortcutInput built-in variable")
    func shortcutInputNotPrefixed() throws {
        let tmpDir = try makeTempDir(files: [
            "main.perspective": """
            import Shortcuts
            #name: Test
            #include "frag.perspective"
            """,
            "frag.perspective": """
            #fragment
            #provides: result
            var input = shortcutInput
            showResult(text: "\\(input)")
            var result = input
            """,
        ])
        let mainSource = try String(contentsOf: tmpDir.appendingPathComponent("main.perspective"), encoding: .utf8)
        let nodes = try parse(mainSource)
        let processed = try Preprocessor(sourceDirectory: tmpDir).preprocess(nodes: nodes)

        // "input" should be prefixed (internal), "shortcutInput" should NOT be
        var foundVarDecl = false
        for node in processed {
            if case .variableDeclaration(let name, let value, _, _) = node {
                if name.contains("__") && name.hasSuffix("__input") {
                    foundVarDecl = true
                    // The value should reference unprefixed shortcutInput
                    if case .variableReference(let ref) = value {
                        #expect(ref == "shortcutInput", "shortcutInput should not be prefixed, got: \\(ref)")
                    }
                }
            }
        }
        #expect(foundVarDecl, "Expected prefixed internal variable for 'input'")
    }

    // MARK: - Nested Includes

    @Test("Nested include resolves correctly")
    func nestedInclude() throws {
        let dir = try makeTempDir(files: [
            "a.perspective": """
            #fragment
            #include "helpers/b.perspective"
            // From A
            """,
            "helpers/b.perspective": """
            #fragment
            // From B
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"a.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        #expect(result.count == 2)
        guard case .comment(let t0, _) = result[0] else { Issue.record("Expected comment 0"); return }
        guard case .comment(let t1, _) = result[1] else { Issue.record("Expected comment 1"); return }
        #expect(t0 == "From B")
        #expect(t1 == "From A")
    }

    @Test("Three levels of nesting work")
    func threeLevelNesting() throws {
        let dir = try makeTempDir(files: [
            "a.perspective": "#fragment\n#include \"b.perspective\"\n// A",
            "b.perspective": "#fragment\n#include \"c.perspective\"\n// B",
            "c.perspective": "#fragment\n// C",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"a.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        #expect(result.count == 3)
        guard case .comment(let t0, _) = result[0] else { Issue.record("Expected C"); return }
        guard case .comment(let t1, _) = result[1] else { Issue.record("Expected B"); return }
        guard case .comment(let t2, _) = result[2] else { Issue.record("Expected A"); return }
        #expect(t0 == "C")
        #expect(t1 == "B")
        #expect(t2 == "A")
    }

    @Test("Nested include paths resolve relative to included file")
    func nestedRelativePaths() throws {
        let dir = try makeTempDir(files: [
            "fragments/api.perspective": """
            #fragment
            #include "helpers/http.perspective"
            // API
            """,
            "fragments/helpers/http.perspective": """
            #fragment
            // HTTP helper
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"fragments/api.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        #expect(result.count == 2)
        guard case .comment(let t0, _) = result[0] else { Issue.record("Expected HTTP helper"); return }
        #expect(t0 == "HTTP helper")
    }

    @Test("Nested fragment with contracts works")
    func nestedFragmentContracts() throws {
        let dir = try makeTempDir(files: [
            "outer.perspective": """
            #fragment
            #provides: finalResult
            #include "inner.perspective"
            var finalResult = innerResult
            """,
            "inner.perspective": """
            #fragment
            #provides: innerResult
            var temp = "working"
            var innerResult = "done"
            """,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"outer.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // inner's temp should be prefixed with inner__, not double-prefixed
        var foundInnerTemp = false
        var foundInnerResult = false
        var foundFinalResult = false
        for node in result {
            if case .variableDeclaration(let name, _, _, _) = node {
                if name == "inner__temp" { foundInnerTemp = true }
                if name == "innerResult" { foundInnerResult = true }
                if name == "finalResult" { foundFinalResult = true }
                // Should NOT have outer__inner__temp (double-prefix)
                #expect(!name.contains("outer__inner__"), "Double-prefixed variable found: \(name)")
            }
        }
        #expect(foundInnerTemp, "Expected inner__temp")
        #expect(foundInnerResult, "Expected innerResult (provided, not prefixed)")
        #expect(foundFinalResult, "Expected finalResult (provided, not prefixed)")
    }

    // MARK: - Cycle Detection

    @Test("Direct cycle produces error")
    func directCycle() throws {
        let dir = try makeTempDir(files: [
            "a.perspective": "#fragment\n#include \"b.perspective\"",
            "b.perspective": "#fragment\n#include \"a.perspective\"",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"a.perspective\"")
        #expect(throws: PreprocessorError.self) {
            _ = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        }
    }

    @Test("Indirect cycle produces error")
    func indirectCycle() throws {
        let dir = try makeTempDir(files: [
            "a.perspective": "#fragment\n#include \"b.perspective\"",
            "b.perspective": "#fragment\n#include \"c.perspective\"",
            "c.perspective": "#fragment\n#include \"a.perspective\"",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"a.perspective\"")
        #expect(throws: PreprocessorError.self) {
            _ = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        }
    }

    @Test("Self-include produces error")
    func selfInclude() throws {
        let dir = try makeTempDir(files: [
            "self.perspective": "#fragment\n#include \"self.perspective\"",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"self.perspective\"")
        #expect(throws: PreprocessorError.self) {
            _ = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        }
    }

    @Test("Diamond dependency is allowed (not a cycle)")
    func diamondDependency() throws {
        let dir = try makeTempDir(files: [
            "b.perspective": "#fragment\n#include \"d.perspective\"\n// B",
            "c.perspective": "#fragment\n#include \"d.perspective\"\n// C",
            "d.perspective": "#fragment\n// D",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("""
        #include "b.perspective"
        #include "c.perspective"
        """)
        // Should not throw — D is included twice but from separate branches
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)
        let comments = result.compactMap { node -> String? in
            if case .comment(let text, _) = node { return text }
            return nil
        }
        // D appears twice (once from B, once from C), plus B and C
        #expect(comments == ["D", "B", "D", "C"])
    }

    // MARK: - Error Reporting: File Context

    @Test("SourceLocation with file includes filename in description")
    func sourceLocationFileDescription() {
        let loc = SourceLocation(line: 5, column: 3, file: "fragments/helper.perspective")
        #expect(loc.description.contains("fragments/helper.perspective"))
    }

    @Test("SourceLocation without file is backwards compatible")
    func sourceLocationNoFile() {
        let loc = SourceLocation(line: 5, column: 3)
        #expect(loc.file == nil)
        #expect(loc.description == "line 5, column 3")
    }

    @Test("Included fragment nodes have file set in SourceLocation")
    func includedNodesHaveFile() throws {
        let dir = try makeTempDir(files: [
            "frag.perspective": "#fragment\n// From fragment",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"frag.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        guard case .comment(_, let loc) = result[0] else {
            Issue.record("Expected comment")
            return
        }
        #expect(loc.file == "frag.perspective")
    }

    @Test("Nested include preserves inner file in SourceLocation")
    func nestedIncludeFileContext() throws {
        let dir = try makeTempDir(files: [
            "outer.perspective": "#fragment\n#include \"inner.perspective\"\n// outer line",
            "inner.perspective": "#fragment\n// inner line",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let mainNodes = try parse("#include \"outer.perspective\"")
        let result = try Preprocessor(sourceDirectory: dir).preprocess(nodes: mainNodes)

        // "inner line" should have file = "inner.perspective" (not overwritten by outer)
        guard case .comment(let text0, let loc0) = result[0] else {
            Issue.record("Expected comment 0")
            return
        }
        #expect(text0 == "inner line")
        #expect(loc0.file == "inner.perspective")

        // "outer line" should have file = "outer.perspective"
        guard case .comment(let text1, let loc1) = result[1] else {
            Issue.record("Expected comment 1")
            return
        }
        #expect(text1 == "outer line")
        #expect(loc1.file == "outer.perspective")
    }

    @Test("PreprocessorError includeChain formats correctly")
    func preprocessorErrorIncludeChain() {
        let error = PreprocessorError(
            message: "unknown action",
            location: SourceLocation(line: 5, column: 1, file: "inner.perspective"),
            includeChain: [
                (file: "outer.perspective", line: 3),
                (file: "main.perspective", line: 1),
            ]
        )
        let desc = error.description
        #expect(desc.contains("inner.perspective"))
        #expect(desc.contains("included from outer.perspective:3"))
        #expect(desc.contains("included from main.perspective:1"))
    }

} // end PreprocessorTests
