import Testing
@testable import perspective_cuts

@Suite("CompiledWorkflowValidator")
struct CompiledWorkflowValidatorTests {

    private func textAction(uuid: String, output: String) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
            "WFWorkflowActionParameters": [
                "UUID": uuid,
                "CustomOutputName": output,
                "WFTextActionText": [
                    "Value": ["string": "hi", "attachmentsByRange": [String: Any]()],
                    "WFSerializationType": "WFTextTokenString"
                ]
            ]
        ]
    }

    private func showResult(refTo uuid: String, refName: String) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
            "WFWorkflowActionParameters": [
                "UUID": "AAAA-show",
                "Text": [
                    "Value": [
                        "string": "\u{FFFC}",
                        "attachmentsByRange": [
                            "{0, 1}": [
                                "OutputUUID": uuid,
                                "Type": "ActionOutput",
                                "OutputName": refName
                            ]
                        ]
                    ],
                    "WFSerializationType": "WFTextTokenString"
                ]
            ]
        ]
    }

    private func setVariable(name: String) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": "is.workflow.actions.setvariable",
            "WFWorkflowActionParameters": [
                "WFVariableName": name,
                "WFInput": [
                    "Value": ["string": "x", "attachmentsByRange": [String: Any]()],
                    "WFSerializationType": "WFTextTokenString"
                ]
            ]
        ]
    }

    private func readVariable(name: String) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": "is.workflow.actions.showresult",
            "WFWorkflowActionParameters": [
                "Text": [
                    "Value": [
                        "string": "\u{FFFC}",
                        "attachmentsByRange": [
                            "{0, 1}": [
                                "VariableName": name,
                                "Type": "Variable"
                            ]
                        ]
                    ],
                    "WFSerializationType": "WFTextTokenString"
                ]
            ]
        ]
    }

    private func repeatStart(group: String) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": "is.workflow.actions.repeat.each",
            "WFWorkflowActionParameters": [
                "GroupingIdentifier": group,
                "WFControlFlowMode": 0
            ]
        ]
    }

    private func repeatEnd(group: String) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": "is.workflow.actions.repeat.each",
            "WFWorkflowActionParameters": [
                "GroupingIdentifier": group,
                "WFControlFlowMode": 2
            ]
        ]
    }

    @Test("Valid workflow produces no diagnostics")
    func validWorkflow() {
        let actions = [
            textAction(uuid: "U1", output: "greeting"),
            showResult(refTo: "U1", refName: "greeting")
        ]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.isEmpty)
    }

    @Test("Dangling ActionOutput UUID is reported")
    func danglingUUID() {
        let actions = [
            textAction(uuid: "U1", output: "greeting"),
            showResult(refTo: "U-NOPE", refName: "greeting")
        ]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.count == 1)
        if case .unknownOutputUUID(let uuid, _) = diags[0].kind {
            #expect(uuid == "U-NOPE")
        } else {
            Issue.record("Expected unknownOutputUUID, got \(diags[0].kind)")
        }
    }

    @Test("Forward reference (UUID defined after use) is reported")
    func forwardReference() {
        let actions = [
            showResult(refTo: "U1", refName: "greeting"),
            textAction(uuid: "U1", output: "greeting")
        ]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.count == 1)
    }

    @Test("Named variable set then read is valid")
    func namedVarSetThenRead() {
        let actions = [
            setVariable(name: "msg"),
            readVariable(name: "msg")
        ]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.isEmpty)
    }

    @Test("Named variable read without prior set is reported")
    func namedVarReadWithoutSet() {
        let actions = [readVariable(name: "msg")]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.count == 1)
        if case .unknownVariableName(let n) = diags[0].kind {
            #expect(n == "msg")
        } else {
            Issue.record("Expected unknownVariableName, got \(diags[0].kind)")
        }
    }

    @Test("Repeat Item inside Repeat block is valid")
    func repeatItemInScope() {
        let actions = [
            repeatStart(group: "G1"),
            readVariable(name: "Repeat Item"),
            repeatEnd(group: "G1")
        ]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.isEmpty)
    }

    @Test("Repeat Item outside Repeat block is reported")
    func repeatItemOutOfScope() {
        let actions = [readVariable(name: "Repeat Item")]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.count == 1)
        if case .unknownVariableName(let n) = diags[0].kind {
            #expect(n == "Repeat Item")
        } else {
            Issue.record("Expected unknownVariableName for Repeat Item")
        }
    }

    @Test("Repeat Item after the loop ends is reported")
    func repeatItemAfterLoop() {
        let actions = [
            repeatStart(group: "G1"),
            readVariable(name: "Repeat Item"),
            repeatEnd(group: "G1"),
            readVariable(name: "Repeat Item")
        ]
        let diags = CompiledWorkflowValidator.validate(actions)
        #expect(diags.count == 1)
        #expect(diags[0].actionIndex == 3)
    }
}
