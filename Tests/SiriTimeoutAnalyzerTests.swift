import Testing
@testable import perspective_cuts

@Suite("SiriTimeoutAnalyzer")
struct SiriTimeoutAnalyzerTests {

    private let registry = ActionRegistry(
        actions: [
            "downloadURL": ActionDefinition(
                identifier: "is.workflow.actions.downloadurl",
                description: "Download URL",
                parameters: [
                    "url": ActionParameter(type: "string", required: true, key: "WFURL")
                ]
            ),
            "showResult": ActionDefinition(
                identifier: "is.workflow.actions.showresult",
                description: "Show result",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "Text")
                ]
            ),
            "text": ActionDefinition(
                identifier: "is.workflow.actions.gettext",
                description: "Get text",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "WFTextActionText")
                ]
            ),
            "runShortcut": ActionDefinition(
                identifier: "is.workflow.actions.runworkflow",
                description: "Run shortcut",
                parameters: [
                    "name": ActionParameter(type: "variable", required: true, key: "WFWorkflowName")
                ]
            ),
            "getCurrentLocation": ActionDefinition(
                identifier: "is.workflow.actions.getcurrentlocation",
                description: "Get current location",
                parameters: [:]
            ),
            "speakText": ActionDefinition(
                identifier: "is.workflow.actions.speaktext",
                description: "Speak text",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "WFText")
                ]
            ),
        ],
        controlFlow: [:],
        iconColors: [:]
    )

    private func loc(_ line: Int) -> perspective_cuts.SourceLocation {
        perspective_cuts.SourceLocation(line: line, column: 1)
    }

    @Test("No warnings for shortcut with no slow actions")
    func noSlowActions() {
        let nodes: [ASTNode] = [
            .actionCall(name: "text", arguments: [(label: "text", value: .stringLiteral("hi"))], output: nil, location: loc(1)),
            .actionCall(name: "showResult", arguments: [(label: "text", value: .variableReference("r"))], output: nil, location: loc(2)),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        #expect(analyzer.analyze(nodes: nodes).isEmpty)
    }

    @Test("No warnings when output precedes slow action")
    func outputBeforeSlow() {
        let nodes: [ASTNode] = [
            .actionCall(name: "showResult", arguments: [(label: "text", value: .stringLiteral("Loading..."))], output: nil, location: loc(1)),
            .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://example.com"))], output: nil, location: loc(2)),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        #expect(analyzer.analyze(nodes: nodes).isEmpty)
    }

    @Test("Warns when slow action has no prior output")
    func slowWithoutOutput() {
        let nodes: [ASTNode] = [
            .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://example.com"))], output: nil, location: loc(1)),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].actionName == "downloadURL")
        #expect(diags[0].branchContext == nil)
    }

    @Test("Output in parent scope protects actions in branches")
    func outputProtectsBranch() {
        let nodes: [ASTNode] = [
            .actionCall(name: "showResult", arguments: [(label: "text", value: .stringLiteral("Starting..."))], output: nil, location: loc(1)),
            .ifStatement(
                condition: .equals(left: .variableReference("x"), right: .stringLiteral("y")),
                thenBody: [
                    .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://example.com"))], output: nil, location: loc(4)),
                ],
                elseBody: nil,
                location: loc(2)
            ),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        #expect(analyzer.analyze(nodes: nodes).isEmpty)
    }

    @Test("Slow action in branch without prior output warns with context")
    func slowInBranch() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("mode"), right: .stringLiteral("fetch")),
                thenBody: [
                    .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://example.com"))], output: nil, location: loc(4)),
                ],
                elseBody: nil,
                location: loc(2)
            ),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "when mode == \"fetch\"")
    }

    @Test("Output inside branch does not protect sibling branch")
    func outputInOneBranchOnly() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("x"), right: .stringLiteral("a")),
                thenBody: [
                    .actionCall(name: "showResult", arguments: [(label: "text", value: .stringLiteral("hi"))], output: nil, location: loc(3)),
                    .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://example.com"))], output: nil, location: loc(4)),
                ],
                elseBody: [
                    // No output here, so downloadURL should warn
                    .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://other.com"))], output: nil, location: loc(6)),
                ],
                location: loc(2)
            ),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].location.line == 6) // only the else branch
    }

    @Test("Multiple slow actions without output reports all of them")
    func multipleSlowActions() {
        let nodes: [ASTNode] = [
            .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://a.com"))], output: nil, location: loc(1)),
            .actionCall(name: "getCurrentLocation", arguments: [], output: nil, location: loc(2)),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 2)
    }

    @Test("speakText counts as output")
    func speakTextIsOutput() {
        let nodes: [ASTNode] = [
            .actionCall(name: "speakText", arguments: [(label: "text", value: .stringLiteral("Loading"))], output: nil, location: loc(1)),
            .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://example.com"))], output: nil, location: loc(2)),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        #expect(analyzer.analyze(nodes: nodes).isEmpty)
    }

    @Test("runShortcut is flagged as potentially slow")
    func runShortcutIsSlow() {
        let nodes: [ASTNode] = [
            .actionCall(name: "runShortcut", arguments: [(label: "name", value: .stringLiteral("Helper"))], output: nil, location: loc(1)),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].actionName == "runShortcut")
    }

    @Test("For-each inherits parent output state")
    func forEachInheritsOutput() {
        let nodes: [ASTNode] = [
            .actionCall(name: "showResult", arguments: [(label: "text", value: .stringLiteral("Starting"))], output: nil, location: loc(1)),
            .forEachLoop(
                itemName: "item",
                collection: .variableReference("items"),
                body: [
                    .actionCall(name: "downloadURL", arguments: [(label: "url", value: .stringLiteral("https://example.com"))], output: nil, location: loc(4)),
                ],
                location: loc(2)
            ),
        ]
        let analyzer = SiriTimeoutAnalyzer(registry: registry)
        #expect(analyzer.analyze(nodes: nodes).isEmpty)
    }
}
