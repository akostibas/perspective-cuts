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

} // end PreprocessorTests
