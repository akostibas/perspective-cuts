import Testing
@testable import perspective_cuts

/// Stub that returns configurable policies per identifier.
struct StubPolicyProvider: AuthenticationPolicyProvider {
    let policies: [String: String]

    func getAuthenticationPolicy(identifier: String) -> String? {
        policies[identifier]
    }
}

@Suite("LockAnalyzer")
struct LockAnalyzerTests {

    private let registry = ActionRegistry(
        actions: [
            "getClipboard": ActionDefinition(
                identifier: "is.workflow.actions.getclipboard",
                description: "Get clipboard",
                parameters: [:]
            ),
            "openApp": ActionDefinition(
                identifier: "is.workflow.actions.openapp",
                description: "Open app",
                parameters: [
                    "app": ActionParameter(type: "string", required: true, key: "WFAppIdentifier")
                ]
            ),
            "text": ActionDefinition(
                identifier: "is.workflow.actions.gettext",
                description: "Get text",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "WFTextActionText")
                ]
            ),
        ],
        controlFlow: [:],
        iconColors: [:]
    )

    private let provider = StubPolicyProvider(policies: [
        "is.workflow.actions.getclipboard": "requiresAuthenticationOnOriginAndRemote",
        "is.workflow.actions.openapp": "requiresAuthenticationOnOriginAndRemote",
        "is.workflow.actions.gettext": "none",
    ])

    private func loc(_ line: Int) -> perspective_cuts.SourceLocation {
        perspective_cuts.SourceLocation(line: line, column: 1)
    }

    @Test("No diagnostics for safe actions")
    func safeActions() {
        let nodes: [ASTNode] = [
            .actionCall(name: "text", arguments: [(label: "text", value: .stringLiteral("hello"))], output: nil, location: loc(1))
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.isEmpty)
    }

    @Test("Detects unlock-requiring action at top level")
    func topLevelUnlock() {
        let nodes: [ASTNode] = [
            .actionCall(name: "getClipboard", arguments: [], output: "clip", location: loc(3))
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].actionName == "getClipboard")
        #expect(diags[0].branchContext == nil)
        #expect(diags[0].description.contains("always reachable"))
    }

    @Test("Reports branch context for if-then")
    func ifThenBranch() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("mode"), right: .stringLiteral("copy")),
                thenBody: [
                    .actionCall(name: "getClipboard", arguments: [], output: "clip", location: loc(5))
                ],
                elseBody: nil,
                location: loc(4)
            )
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "when mode == \"copy\"")
    }

    @Test("Reports branch context for if-else")
    func ifElseBranch() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("x"), right: .numberLiteral(1)),
                thenBody: [
                    .actionCall(name: "text", arguments: [(label: "text", value: .stringLiteral("safe"))], output: nil, location: loc(3))
                ],
                elseBody: [
                    .actionCall(name: "openApp", arguments: [(label: "app", value: .stringLiteral("Safari"))], output: nil, location: loc(5))
                ],
                location: loc(2)
            )
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].actionName == "openApp")
        #expect(diags[0].branchContext == "when not (x == 1)")
    }

    @Test("Reports branch context for nested ifs")
    func nestedIfs() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("a"), right: .stringLiteral("1")),
                thenBody: [
                    .ifStatement(
                        condition: .equals(left: .variableReference("b"), right: .stringLiteral("2")),
                        thenBody: [
                            .actionCall(name: "getClipboard", arguments: [], output: nil, location: loc(7))
                        ],
                        elseBody: nil,
                        location: loc(5)
                    )
                ],
                elseBody: nil,
                location: loc(3)
            )
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "when a == \"1\", when b == \"2\"")
    }

    @Test("Reports menu case context")
    func menuCase() {
        let nodes: [ASTNode] = [
            .menu(
                title: "Pick one",
                cases: [
                    (label: "Safe", body: [
                        .actionCall(name: "text", arguments: [(label: "text", value: .stringLiteral("ok"))], output: nil, location: loc(4))
                    ]),
                    (label: "Risky", body: [
                        .actionCall(name: "openApp", arguments: [(label: "app", value: .stringLiteral("Safari"))], output: nil, location: loc(6))
                    ]),
                ],
                location: loc(2)
            )
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "in menu \"Pick one\" case \"Risky\"")
    }

    @Test("Actions inside for-each inherit parent context")
    func forEachLoop() {
        let nodes: [ASTNode] = [
            .ifStatement(
                condition: .equals(left: .variableReference("x"), right: .stringLiteral("go")),
                thenBody: [
                    .forEachLoop(
                        itemName: "item",
                        collection: .variableReference("items"),
                        body: [
                            .actionCall(name: "getClipboard", arguments: [], output: nil, location: loc(6))
                        ],
                        location: loc(4)
                    )
                ],
                elseBody: nil,
                location: loc(2)
            )
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == "when x == \"go\"")
    }

    @Test("Actions inside repeat loop inherit parent context")
    func repeatLoop() {
        let nodes: [ASTNode] = [
            .repeatLoop(
                count: .numberLiteral(3),
                body: [
                    .actionCall(name: "openApp", arguments: [(label: "app", value: .stringLiteral("Safari"))], output: nil, location: loc(3))
                ],
                location: loc(1)
            )
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].branchContext == nil)
    }

    @Test("Dotted 3rd-party identifiers are looked up directly")
    func thirdPartyAction() {
        let thirdPartyProvider = StubPolicyProvider(policies: [
            "com.example.app.SomeIntent": "requiresAuthenticationOnOrigin",
        ])
        let nodes: [ASTNode] = [
            .actionCall(name: "com.example.app.SomeIntent", arguments: [], output: nil, location: loc(1))
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: thirdPartyProvider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 1)
        #expect(diags[0].identifier == "com.example.app.SomeIntent")
        #expect(diags[0].policy == "requiresAuthenticationOnOrigin")
    }

    @Test("Unknown actions produce no diagnostics")
    func unknownAction() {
        let nodes: [ASTNode] = [
            .actionCall(name: "madeUpAction", arguments: [], output: nil, location: loc(1))
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.isEmpty)
    }

    @Test("Multiple diagnostics across branches")
    func multipleDiagnostics() {
        let nodes: [ASTNode] = [
            .actionCall(name: "getClipboard", arguments: [], output: nil, location: loc(1)),
            .ifStatement(
                condition: .equals(left: .variableReference("x"), right: .stringLiteral("y")),
                thenBody: [
                    .actionCall(name: "openApp", arguments: [(label: "app", value: .stringLiteral("Safari"))], output: nil, location: loc(4))
                ],
                elseBody: nil,
                location: loc(3)
            )
        ]
        let analyzer = LockAnalyzer(registry: registry, policyProvider: provider)
        let diags = analyzer.analyze(nodes: nodes)
        #expect(diags.count == 2)
        #expect(diags[0].branchContext == nil) // top-level getClipboard
        #expect(diags[1].branchContext == "when x == \"y\"") // conditional openApp
    }
}
