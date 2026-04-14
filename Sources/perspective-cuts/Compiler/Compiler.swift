import Foundation

struct CompilerError: Error, CustomStringConvertible {
    let message: String
    let location: SourceLocation?

    var description: String {
        if let loc = location {
            return "Compile error at \(loc): \(message)"
        }
        return "Compile error: \(message)"
    }
}

struct Compiler: Sendable {
    let registry: ActionRegistry
    let toolKitReader: ToolKitReader?

    init(registry: ActionRegistry, toolKitReader: ToolKitReader? = nil) {
        self.registry = registry
        self.toolKitReader = toolKitReader
    }

    // Track output name -> UUID mapping so variable references use ActionOutput
    private struct OutputRef {
        let uuid: String
        let name: String
    }

    /// Name of the built-in variable that references the Shortcut Input
    /// (the value passed to a shortcut via `runShortcut(input:)`).
    static let shortcutInputName = "shortcutInput"

    /// Returns true when `name` refers to the Shortcut Input magic variable.
    private static func isShortcutInput(_ name: String) -> Bool {
        name == shortcutInputName
    }

    /// Builds the ExtensionInput attachment dict used wherever shortcutInput appears.
    private static func extensionInputAttachment() -> [String: Any] {
        ["Type": "ExtensionInput"]
    }

    /// Maps user-chosen for-each loop variable names to the Shortcuts
    /// runtime name "Repeat Item".
    private static func resolveVariableName(_ name: String, forEachVars: Set<String>) -> String {
        forEachVars.contains(name) ? "Repeat Item" : name
    }

    func compile(nodes: [ASTNode]) throws -> [String: Any] {
        var outputMap: [String: OutputRef] = [:]
        var declaredVariables: Set<String> = [Self.shortcutInputName]
        var forEachVarNames: Set<String> = []
        return try compileWithOutputMap(nodes: nodes, outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarNames: &forEachVarNames)
    }

    private func compileWithOutputMap(nodes: [ASTNode], outputMap: inout [String: OutputRef], declaredVariables: inout Set<String>, forEachVarNames: inout Set<String>) throws -> [String: Any] {
        var actions: [[String: Any]] = []
        var shortcutName = "Perspective Shortcut"
        var iconColor = 463140863 // blue default
        var iconGlyph = 59771 // gear default

        for node in nodes {
            switch node {
            case .importStatement: break // handled at validation
            case .metadata(let key, let value, _):
                if key == "color", let color = registry.iconColors[value] {
                    iconColor = color
                }
                if key == "icon" {
                    // Map common icon names to glyph numbers
                    iconGlyph = iconGlyphNumber(for: value)
                }
                if key == "name" {
                    shortcutName = value
                }
            case .comment(let text, _):
                actions.append(buildAction(
                    identifier: "is.workflow.actions.comment",
                    parameters: ["WFCommentActionText": text]
                ))
            case .variableDeclaration(let name, let value, _, let location):
                try validateExpression(value, declaredVariables: declaredVariables, location: location)
                // When the value is a bare variable reference, set directly without an intermediary action
                if case .variableReference(let refName) = value {
                    let wfInput: [String: Any]
                    if let ref = outputMap[refName] {
                        // Reference to an action output (-> varName)
                        wfInput = [
                            "Value": [
                                "OutputUUID": ref.uuid,
                                "Type": "ActionOutput",
                                "OutputName": ref.name
                            ] as [String: Any],
                            "WFSerializationType": "WFTextTokenAttachment"
                        ]
                    } else if Self.isShortcutInput(refName) {
                        wfInput = [
                            "Value": [
                                "Type": "ExtensionInput"
                            ] as [String: Any],
                            "WFSerializationType": "WFTextTokenAttachment"
                        ]
                    } else {
                        // Reference to a named variable (var varName = ...) or for-each loop variable
                        wfInput = [
                            "Value": [
                                "VariableName": Self.resolveVariableName(refName, forEachVars: forEachVarNames),
                                "Type": "Variable"
                            ] as [String: Any],
                            "WFSerializationType": "WFTextTokenAttachment"
                        ]
                    }
                    actions.append(buildAction(
                        identifier: "is.workflow.actions.setvariable",
                        parameters: [
                            "WFVariableName": name,
                            "WFInput": wfInput
                        ]
                    ))
                } else {
                    // For other expressions, emit a source action then set the variable to its output
                    let sourceAction: [String: Any]
                    if case .dictionaryLiteral = value {
                        sourceAction = try buildDictionaryAction(from: value, outputMap: outputMap, forEachVarNames: forEachVarNames)
                    } else {
                        sourceAction = try buildTextAction(from: value)
                    }
                    actions.append(sourceAction)
                    actions.append(buildAction(
                        identifier: "is.workflow.actions.setvariable",
                        parameters: [
                            "WFVariableName": name,
                            "WFInput": buildMagicVariable(outputOf: sourceAction)
                        ]
                    ))
                }
                declaredVariables.insert(name)
            case .actionCall(let name, let arguments, let output, let location):
                let def = registry.actions[name]
                // If action contains dots, treat as raw identifier (3rd party app action)
                let isThirdParty = def == nil && name.contains(".")
                let identifier: String
                if let def {
                    identifier = def.identifier
                } else if isThirdParty {
                    identifier = name
                } else {
                    var msg = "Unknown action: '\(name)'"
                    if let suggestion = registry.findClosestAction(to: name) {
                        msg += ". Did you mean '\(suggestion)'?"
                    }
                    throw CompilerError(message: msg, location: location)
                }

                // For 3rd-party actions, look up parameter types from the ToolKit DB
                let toolKitParams: [String: ToolKitParameterDetail]? = isThirdParty
                    ? toolKitReader?.getParameterInfo(actionIdentifier: name) : nil

                var params: [String: Any] = [:]
                let uuid = UUID().uuidString
                params["UUID"] = uuid
                if let output {
                    params["CustomOutputName"] = output
                }

                for (label, value) in arguments {
                    try validateExpression(value, declaredVariables: declaredVariables, location: location)
                    if let label {
                        let resolvedValue: Any

                        if isThirdParty {
                            // 3rd-party App Intent action — use ToolKit type info
                            let tkParam = toolKitParams?[label]
                            if tkParam?.isDynamicEntity == true || tkParam?.typeKind == 2 {
                                // Dynamic entity: wrap as { value, title, subtitle }
                                let plainVal = try expressionToPlainValue(value)
                                let strVal = "\(plainVal)"
                                resolvedValue = [
                                    "value": strVal,
                                    "title": ["key": strVal],
                                    "subtitle": ["key": strVal]
                                ] as [String: Any]
                            } else if tkParam?.typeKind == 3 || tkParam?.typeKind == 4 {
                                // Static enum: use plain value
                                resolvedValue = try expressionToPlainValue(value)
                            } else {
                                // Primitives (string, int, bool, etc.): use plain values
                                resolvedValue = try expressionToPlainValue(value)
                            }
                        } else {
                            // Built-in action — use ActionRegistry parameter definitions
                            let paramDef: ActionParameter? = def.flatMap { d in
                                d.parameters[label] ??
                                d.parameters.first(where: { $0.key.caseInsensitiveCompare(label) == .orderedSame })?.value ??
                                d.parameters.first(where: {
                                    let stripped = $0.key.replacingOccurrences(of: "WF", with: "", options: [.anchored, .caseInsensitive])
                                    return stripped.caseInsensitiveCompare(label) == .orderedSame
                                })?.value
                            }

                            if let paramType = paramDef?.type, paramType == "enumInt",
                               let valueMap = paramDef?.valueMap,
                               case .stringLiteral(let s) = value,
                               let intVal = valueMap[s] {
                                resolvedValue = intVal
                            } else if let paramType = paramDef?.type, (paramType == "enum" || paramType == "boolean" || paramType == "plainString") {
                                resolvedValue = try expressionToPlainValue(value)
                            } else if let paramType = paramDef?.type, paramType == "variable",
                                      case .variableReference(let varName) = value {
                                // Variable-typed parameters need WFTextTokenAttachment,
                                // not WFTextTokenString, so the action receives the
                                // output directly rather than as interpolated text.
                                if let ref = outputMap[varName] {
                                    resolvedValue = [
                                        "Value": [
                                            "OutputUUID": ref.uuid,
                                            "Type": "ActionOutput",
                                            "OutputName": ref.name
                                        ],
                                        "WFSerializationType": "WFTextTokenAttachment"
                                    ] as [String: Any]
                                } else if Self.isShortcutInput(varName) {
                                    resolvedValue = [
                                        "Value": Self.extensionInputAttachment(),
                                        "WFSerializationType": "WFTextTokenAttachment"
                                    ] as [String: Any]
                                } else {
                                    resolvedValue = [
                                        "Value": ["VariableName": Self.resolveVariableName(varName, forEachVars: forEachVarNames), "Type": "Variable"],
                                        "WFSerializationType": "WFTextTokenAttachment"
                                    ] as [String: Any]
                                }
                            } else {
                                resolvedValue = try expressionToValueWithOutputMap(value, outputMap: outputMap, forEachVarNames: forEachVarNames)
                            }

                            // For built-in actions, map friendly name to plist key
                            let plistKey = paramDef?.key ?? label
                            params[plistKey] = resolvedValue
                            // runShortcut needs both WFWorkflowName and WFWorkflow
                            // for dynamic shortcut name resolution at runtime
                            if plistKey == "WFWorkflowName" {
                                params["WFWorkflow"] = resolvedValue
                            }
                            continue
                        }

                        // For 3rd-party actions, use the label directly as the key
                        params[label] = resolvedValue
                    }
                }

                actions.append(buildAction(identifier: identifier, parameters: params))

                // Track output for ActionOutput references
                if let output {
                    outputMap[output] = OutputRef(uuid: uuid, name: output)
                    declaredVariables.insert(output)
                }

            case .ifStatement(let condition, let thenBody, let elseBody, let location):
                try validateCondition(condition, declaredVariables: declaredVariables, location: location)
                let groupID = UUID().uuidString
                // Emit conditional start
                var condParams: [String: Any] = ["GroupingIdentifier": groupID, "WFControlFlowMode": 0]
                try applyCondition(condition, to: &condParams, outputMap: outputMap, forEachVarNames: forEachVarNames)
                actions.append(buildAction(identifier: "is.workflow.actions.conditional", parameters: condParams))

                // Emit then body
                for bodyNode in thenBody {
                    let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarNames: &forEachVarNames)
                    if let bodyActions = compiled["WFWorkflowActions"] as? [[String: Any]] {
                        actions.append(contentsOf: bodyActions)
                    }
                }

                // Emit else branch
                if let elseBody {
                    actions.append(buildAction(
                        identifier: "is.workflow.actions.conditional",
                        parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 1]
                    ))
                    for bodyNode in elseBody {
                        let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarNames: &forEachVarNames)
                        if let bodyActions = compiled["WFWorkflowActions"] as? [[String: Any]] {
                            actions.append(contentsOf: bodyActions)
                        }
                    }
                }

                // Emit conditional end
                actions.append(buildAction(
                    identifier: "is.workflow.actions.conditional",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 2]
                ))

            case .repeatLoop(let count, let body, _):
                let groupID = UUID().uuidString
                let countValue = try expressionToValue(count)
                actions.append(buildAction(
                    identifier: "is.workflow.actions.repeat.count",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 0, "WFRepeatCount": countValue]
                ))
                for bodyNode in body {
                    let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarNames: &forEachVarNames)
                    if let bodyActions = compiled["WFWorkflowActions"] as? [[String: Any]] {
                        actions.append(contentsOf: bodyActions)
                    }
                }
                actions.append(buildAction(
                    identifier: "is.workflow.actions.repeat.count",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 2]
                ))

            case .forEachLoop(let itemName, let collection, let body, _):
                let groupID = UUID().uuidString
                // WFInput for repeat-each needs WFTextTokenAttachment (direct
                // variable reference), not WFTextTokenString.
                let collectionValue: Any
                if case .variableReference(let varName) = collection {
                    if let ref = outputMap[varName] {
                        collectionValue = [
                            "Value": [
                                "OutputUUID": ref.uuid,
                                "Type": "ActionOutput",
                                "OutputName": ref.name
                            ],
                            "WFSerializationType": "WFTextTokenAttachment"
                        ] as [String: Any]
                    } else if Self.isShortcutInput(varName) {
                        collectionValue = [
                            "Value": Self.extensionInputAttachment(),
                            "WFSerializationType": "WFTextTokenAttachment"
                        ] as [String: Any]
                    } else {
                        collectionValue = [
                            "Value": ["VariableName": Self.resolveVariableName(varName, forEachVars: forEachVarNames), "Type": "Variable"],
                            "WFSerializationType": "WFTextTokenAttachment"
                        ] as [String: Any]
                    }
                } else {
                    collectionValue = try expressionToValueWithOutputMap(collection, outputMap: outputMap, forEachVarNames: forEachVarNames)
                }
                actions.append(buildAction(
                    identifier: "is.workflow.actions.repeat.each",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 0, "WFInput": collectionValue]
                ))
                // Declare the loop variable so it can be referenced in the body.
                // Shortcuts always calls this "Repeat Item" at runtime.
                declaredVariables.insert(itemName)
                forEachVarNames.insert(itemName)
                for bodyNode in body {
                    let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarNames: &forEachVarNames)
                    if let bodyActions = compiled["WFWorkflowActions"] as? [[String: Any]] {
                        actions.append(contentsOf: bodyActions)
                    }
                }
                actions.append(buildAction(
                    identifier: "is.workflow.actions.repeat.each",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 2]
                ))

            case .menu(let title, let cases, _):
                let groupID = UUID().uuidString
                let caseLabels = cases.map { $0.label }
                actions.append(buildAction(
                    identifier: "is.workflow.actions.choosefrommenu",
                    parameters: [
                        "GroupingIdentifier": groupID,
                        "WFControlFlowMode": 0,
                        "WFMenuPrompt": title,
                        "WFMenuItems": caseLabels
                    ]
                ))
                for menuCase in cases {
                    actions.append(buildAction(
                        identifier: "is.workflow.actions.choosefrommenu",
                        parameters: [
                            "GroupingIdentifier": groupID,
                            "WFControlFlowMode": 1,
                            "WFMenuItemTitle": menuCase.label
                        ]
                    ))
                    for bodyNode in menuCase.body {
                        let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarNames: &forEachVarNames)
                        if let bodyActions = compiled["WFWorkflowActions"] as? [[String: Any]] {
                            actions.append(contentsOf: bodyActions)
                        }
                    }
                }
                actions.append(buildAction(
                    identifier: "is.workflow.actions.choosefrommenu",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 2]
                ))

            case .functionDeclaration, .returnStatement:
                // Functions are inlined at call sites (macro-style for now)
                break
            }
        }

        return [
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowClientVersion": "1200",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": iconColor,
                "WFWorkflowIconGlyphNumber": iconGlyph
            ],
            "WFWorkflowTypes": ["NCWidget", "WatchKit"],
            "WFWorkflowInputContentItemClasses": [
                "WFAppStoreAppContentItem",
                "WFArticleContentItem",
                "WFContactContentItem",
                "WFDateContentItem",
                "WFEmailAddressContentItem",
                "WFGenericFileContentItem",
                "WFImageContentItem",
                "WFiTunesProductContentItem",
                "WFLocationContentItem",
                "WFDCMapsLinkContentItem",
                "WFAVAssetContentItem",
                "WFPDFContentItem",
                "WFPhoneNumberContentItem",
                "WFRichTextContentItem",
                "WFSafariWebPageContentItem",
                "WFStringContentItem",
                "WFURLContentItem"
            ],
            "WFWorkflowActions": actions,
            "WFWorkflowName": shortcutName
        ]
    }

    // MARK: - Helpers

    private func buildAction(identifier: String, parameters: [String: Any]) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": parameters
        ]
    }

    private func buildDictionaryAction(from expression: Expression, outputMap: [String: OutputRef], forEachVarNames: Set<String> = []) throws -> [String: Any] {
        let value = try expressionToValueWithOutputMap(expression, outputMap: outputMap, forEachVarNames: forEachVarNames)
        let uuid = UUID().uuidString
        return buildAction(
            identifier: "is.workflow.actions.dictionary",
            parameters: ["WFItems": value, "UUID": uuid, "CustomOutputName": "Dictionary"]
        )
    }

    private func buildTextAction(from expression: Expression) throws -> [String: Any] {
        let value = try expressionToValue(expression)
        let uuid = UUID().uuidString
        return buildAction(
            identifier: "is.workflow.actions.gettext",
            parameters: ["WFTextActionText": value, "UUID": uuid]
        )
    }

    private func buildMagicVariable(outputOf action: [String: Any]) -> [String: Any] {
        let params = action["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
        let uuid = params["UUID"] as? String ?? UUID().uuidString
        return [
            "Value": [
                "OutputUUID": uuid,
                "Type": "ActionOutput",
                "OutputName": params["CustomOutputName"] ?? "Text"
            ],
            "WFSerializationType": "WFTextTokenAttachment"
        ]
    }

    private func expressionToPlainValue(_ expr: Expression) throws -> Any {
        switch expr {
        case .stringLiteral(let s): return s
        case .numberLiteral(let n): return n == n.rounded() ? Int(n) : n
        case .boolLiteral(let b): return b
        case .dictionaryLiteral: return try expressionToValue(expr)
        default: return try expressionToValue(expr)
        }
    }

    private func expressionToValue(_ expr: Expression) throws -> Any {
        return try expressionToValueWithOutputMap(expr, outputMap: [:])
    }

    private func expressionToValueWithOutputMap(_ expr: Expression, outputMap: [String: OutputRef], forEachVarNames: Set<String> = []) throws -> Any {
        switch expr {
        case .stringLiteral(let s):
            return [
                "Value": ["string": s, "attachmentsByRange": [String: Any]()],
                "WFSerializationType": "WFTextTokenString"
            ] as [String: Any]
        case .numberLiteral(let n): return n == n.rounded() ? Int(n) : n
        case .boolLiteral(let b): return b
        case .variableReference(let name):
            // Use WFTextTokenString with attachmentsByRange -- this is how Apple's own shortcuts pass variables
            if let ref = outputMap[name] {
                return [
                    "Value": [
                        "string": "\u{FFFC}",
                        "attachmentsByRange": [
                            "{0, 1}": [
                                "OutputName": ref.name,
                                "OutputUUID": ref.uuid,
                                "Type": "ActionOutput"
                            ]
                        ]
                    ],
                    "WFSerializationType": "WFTextTokenString"
                ] as [String: Any]
            }
            let attachment: [String: Any] = Self.isShortcutInput(name)
                ? Self.extensionInputAttachment()
                : ["VariableName": Self.resolveVariableName(name, forEachVars: forEachVarNames), "Type": "Variable"]
            return [
                "Value": [
                    "string": "\u{FFFC}",
                    "attachmentsByRange": [
                        "{0, 1}": attachment
                    ]
                ],
                "WFSerializationType": "WFTextTokenString"
            ] as [String: Any]
        case .interpolatedString(let parts):
            var text = ""
            var attachments: [String: Any] = [:]
            for part in parts {
                switch part {
                case .text(let t):
                    text += t
                case .variable(let name):
                    let pos = text.count
                    text += "\u{FFFC}"
                    let range = "{\(pos), 1}"
                    if let ref = outputMap[name] {
                        attachments[range] = [
                            "OutputName": ref.name,
                            "OutputUUID": ref.uuid,
                            "Type": "ActionOutput"
                        ]
                    } else if Self.isShortcutInput(name) {
                        attachments[range] = Self.extensionInputAttachment()
                    } else {
                        attachments[range] = ["VariableName": Self.resolveVariableName(name, forEachVars: forEachVarNames), "Type": "Variable"]
                    }
                }
            }
            return [
                "Value": ["string": text, "attachmentsByRange": attachments],
                "WFSerializationType": "WFTextTokenString"
            ] as [String: Any]
        case .dictionaryLiteral(let entries):
            var items: [[String: Any]] = []
            for entry in entries {
                var item: [String: Any] = [:]
                item["WFKey"] = try expressionToValueWithOutputMap(entry.key, outputMap: outputMap, forEachVarNames: forEachVarNames)

                switch entry.value {
                case .numberLiteral(let n):
                    item["WFItemType"] = 3
                    let s = n == n.rounded() ? String(Int(n)) : String(n)
                    item["WFValue"] = [
                        "Value": ["string": s, "attachmentsByRange": [String: Any]()],
                        "WFSerializationType": "WFTextTokenString"
                    ] as [String: Any]
                case .boolLiteral(let b):
                    item["WFItemType"] = 4
                    item["WFValue"] = [
                        "Value": b,
                        "WFSerializationType": "WFNumberSubstitutableState"
                    ] as [String: Any]
                case .dictionaryLiteral:
                    item["WFItemType"] = 1
                    item["WFValue"] = try expressionToValueWithOutputMap(entry.value, outputMap: outputMap, forEachVarNames: forEachVarNames)
                default:
                    item["WFItemType"] = 0
                    item["WFValue"] = try expressionToValueWithOutputMap(entry.value, outputMap: outputMap, forEachVarNames: forEachVarNames)
                }
                items.append(item)
            }
            return [
                "Value": ["WFDictionaryFieldValueItems": items],
                "WFSerializationType": "WFDictionaryFieldValue"
            ] as [String: Any]
        }
    }

    private func applyCondition(_ condition: Condition, to params: inout [String: Any], outputMap: [String: OutputRef], forEachVarNames: Set<String> = []) throws {
        // Helper: resolve the left-hand side of a condition.
        // Conditionals use a nested format for WFInput:
        //   { Type: "Variable", Variable: { Value: { ..., Aggrandizements: [coerce to string] }, WFSerializationType: "WFTextTokenAttachment" } }
        // The Aggrandizements coercion to WFStringContentItem is required
        // so Shortcuts treats the value as a string before comparing.
        func resolveInput(_ expr: Expression) throws -> Any {
            if case .variableReference(let name) = expr {
                let coercion: [[String: Any]] = [
                    [
                        "CoercionItemClass": "WFStringContentItem",
                        "Type": "WFCoercionVariableAggrandizement"
                    ]
                ]
                let inner: [String: Any]
                if let ref = outputMap[name] {
                    inner = [
                        "Value": [
                            "Aggrandizements": coercion,
                            "OutputUUID": ref.uuid,
                            "Type": "ActionOutput",
                            "OutputName": ref.name
                        ] as [String: Any],
                        "WFSerializationType": "WFTextTokenAttachment"
                    ] as [String: Any]
                } else if Self.isShortcutInput(name) {
                    inner = [
                        "Value": [
                            "Aggrandizements": coercion,
                            "Type": "ExtensionInput"
                        ] as [String: Any],
                        "WFSerializationType": "WFTextTokenAttachment"
                    ] as [String: Any]
                } else {
                    inner = [
                        "Value": [
                            "Aggrandizements": coercion,
                            "VariableName": Self.resolveVariableName(name, forEachVars: forEachVarNames),
                            "Type": "Variable"
                        ] as [String: Any],
                        "WFSerializationType": "WFTextTokenAttachment"
                    ] as [String: Any]
                }
                return [
                    "Type": "Variable",
                    "Variable": inner
                ] as [String: Any]
            }
            return try expressionToValueWithOutputMap(expr, outputMap: outputMap, forEachVarNames: forEachVarNames)
        }

        switch condition {
        case .equals(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 4 // equals
            params["WFConditionalActionString"] = try expressionToPlainValue(right)
        case .notEquals(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 5 // not equals
            params["WFConditionalActionString"] = try expressionToPlainValue(right)
        case .contains(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 99 // contains
            params["WFConditionalActionString"] = try expressionToPlainValue(right)
        case .greaterThan(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 2 // greater than
            params["WFConditionalActionString"] = try expressionToPlainValue(right)
        case .lessThan(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 3 // less than
            params["WFConditionalActionString"] = try expressionToPlainValue(right)
        }
    }

    // MARK: - Variable validation

    private func validateExpression(_ expr: Expression, declaredVariables: Set<String>, location: SourceLocation) throws {
        switch expr {
        case .variableReference(let name):
            if !declaredVariables.contains(name) {
                throw CompilerError(message: "undefined variable '\(name)'", location: location)
            }
        case .interpolatedString(let parts):
            for case .variable(let name) in parts {
                if !declaredVariables.contains(name) {
                    throw CompilerError(message: "undefined variable '\(name)'", location: location)
                }
            }
        case .dictionaryLiteral(let entries):
            for entry in entries {
                try validateExpression(entry.key, declaredVariables: declaredVariables, location: location)
                try validateExpression(entry.value, declaredVariables: declaredVariables, location: location)
            }
        default:
            break
        }
    }

    private func validateCondition(_ condition: Condition, declaredVariables: Set<String>, location: SourceLocation) throws {
        switch condition {
        case .equals(let left, let right),
             .notEquals(let left, let right),
             .contains(let left, let right),
             .greaterThan(let left, let right),
             .lessThan(let left, let right):
            try validateExpression(left, declaredVariables: declaredVariables, location: location)
            try validateExpression(right, declaredVariables: declaredVariables, location: location)
        }
    }

    private func iconGlyphNumber(for name: String) -> Int {
        let glyphs: [String: Int] = [
            "gear": 59771, "compose": 59772, "star": 59773,
            "heart": 59774, "bolt": 59775, "globe": 59776,
            "mic": 59777, "music": 59778, "play": 59779,
            "camera": 59780, "photo": 59781, "film": 59782,
            "mail": 59783, "message": 59784, "phone": 59785,
            "clock": 59786, "alarm": 59787, "calendar": 59788,
            "map": 59789, "location": 59790, "bookmark": 59791,
            "tag": 59792, "folder": 59793, "doc": 59794,
            "list": 59795, "cart": 59796, "bag": 59797,
            "gift": 59798, "lock": 59799, "key": 59800,
            "link": 59801, "flag": 59802, "bell": 59803,
            "eye": 59804, "hand": 59805, "person": 59806,
            "house": 59807, "car": 59808, "airplane": 59809,
            "sun": 59810, "moon": 59811, "cloud": 59812,
            "umbrella": 59813, "flame": 59814, "drop": 59815,
            "leaf": 59816, "paintbrush": 59817, "pencil": 59818,
            "scissors": 59819, "wand": 59820, "cube": 59821,
            "download": 59822, "upload": 59823, "share": 59824,
            "trash": 59825, "magnifyingglass": 59826
        ]
        return glyphs[name.lowercased()] ?? 59771
    }
}
