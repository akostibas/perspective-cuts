import Testing
@testable import perspective_cuts

@Suite("StandaloneAnalyzer")
struct StandaloneAnalyzerTests {

    private let registry = ActionRegistry(
        actions: [
            "runShortcut": ActionDefinition(
                identifier: "is.workflow.actions.runworkflow",
                description: "Run another shortcut",
                parameters: [
                    "name": ActionParameter(type: "variable", required: true, key: "WFWorkflowName"),
                    "input": ActionParameter(type: "variable", required: false, key: "WFInput"),
                ]
            ),
            "text": ActionDefinition(
                identifier: "is.workflow.actions.gettext",
                description: "Get text",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "WFTextActionText")
                ]
            ),
            "showResult": ActionDefinition(
                identifier: "is.workflow.actions.showresult",
                description: "Show result",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "Text")
                ]
            ),
        ],
        controlFlow: [:],
        iconColors: [:]
    )

    private func loc(_ line: Int) -> perspective_cuts.SourceLocation {
        perspective_cuts.SourceLocation(line: line, column: 1)
    }

    @Test("No diagnostics for self-contained shortcut")
    func selfContained() {
        let nodes: [ASTNode] = [
            .actionCall(name: "text", arguments: [(label: "text", value: .stringLiteral("hello"))], output: nil, location: loc(1)),
            .actionCall(name: "showResult", arguments: [(label: "text", value: .variableReference("result"))], output: nil, location: loc(2)),
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.isEmpty)
    }

    @Test("Detects runShortcut as dependency")
    func runShortcutDependency() {
        let nodes: [ASTNode] = [
            .actionCall(name: "runShortcut", arguments: [(label: "name", value: .stringLiteral("Log Helper"))], output: nil, location: loc(3))
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].description.contains("shortcut \"Log Helper\""))
        #expect(diags[0].branchContext == nil)
    }

    @Test("Detects 3rd-party app action as dependency")
    func thirdPartyDependency() {
        let nodes: [ASTNode] = [
            .actionCall(name: "com.openai.chat.AskIntent", arguments: [(label: "prompt", value: .stringLiteral("hi"))], output: nil, location: loc(5))
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].description.contains("3rd-party action com.openai.chat.AskIntent"))
    }

    @Test("Reports branch context for conditional dependency")
    func conditionalDependency() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("mode"), right: .stringLiteral("advanced")),
                thenBody: [
                    .actionCall(name: "runShortcut", arguments: [(label: "name", value: .stringLiteral("Helper"))], output: nil, location: loc(4))
                ],
                elseBody: nil,
                location: loc(2)
            )
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "when mode == \"advanced\"")
    }

    @Test("Reports menu case context")
    func menuDependency() {
        let nodes: [ASTNode] = [
            .menu(
                title: "Choose",
                cases: [
                    (label: "Local", body: [
                        .actionCall(name: "text", arguments: [(label: "text", value: .stringLiteral("ok"))], output: nil, location: loc(4))
                    ]),
                    (label: "Remote", body: [
                        .actionCall(name: "com.example.app.DoThing", arguments: [], output: nil, location: loc(6))
                    ]),
                ],
                location: loc(2)
            )
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "in menu \"Choose\" case \"Remote\"")
    }

    @Test("Detects both shortcut and 3rd-party dependencies")
    func multipleDependencyTypes() {
        let nodes: [ASTNode] = [
            .actionCall(name: "runShortcut", arguments: [(label: "name", value: .stringLiteral("Helper"))], output: nil, location: loc(1)),
            .actionCall(name: "com.openai.chat.AskIntent", arguments: [], output: nil, location: loc(2)),
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 2)
    }

    @Test("Nested if reports composed context")
    func nestedIfContext() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("a"), right: .stringLiteral("1")),
                thenBody: [
                    .ifStatement(
                        condition: .equals(left: .variableReference("b"), right: .stringLiteral("2")),
                        thenBody: [
                            .actionCall(name: "runShortcut", arguments: [(label: "name", value: .stringLiteral("Deep"))], output: nil, location: loc(7))
                        ],
                        elseBody: nil,
                        location: loc(5)
                    )
                ],
                elseBody: nil,
                location: loc(3)
            )
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "when a == \"1\", when b == \"2\"")
    }

    @Test("For-each inherits parent context")
    func forEachContext() {
        let nodes: [ASTNode] = [
            .forEachLoop(
                itemName: "item",
                collection: .variableReference("items"),
                body: [
                    .actionCall(name: "com.example.app.Process", arguments: [], output: nil, location: loc(4))
                ],
                location: loc(2)
            )
        ]
        let analyzer = StandaloneAnalyzer(registry: registry)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == nil)
    }
}
