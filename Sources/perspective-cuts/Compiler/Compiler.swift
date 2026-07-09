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

    /// Returns the inner reference dict for a non-captured, non-shortcutInput
    /// name. For-each iterators get Shortcuts' canonical magic-variable form:
    /// `Type: ActionOutput` with `OutputUUID` pointing at the enclosing
    /// repeat.each block, `OutputName: "Repeat Item"`. The older
    /// `Type: Variable, VariableName: "Repeat Item"` form was tolerated at
    /// runtime but rendered as an unresolved (red) pill in the Shortcuts UI
    /// and could fail to bind in some parameter contexts (issue #12). Plain
    /// named variables still get `Type: Variable, VariableName: name`.
    private static func variableReferenceDict(
        name: String,
        forEachVarRefs: [String: String]
    ) -> [String: Any] {
        if let uuid = forEachVarRefs[name] {
            return [
                "Type": "ActionOutput",
                "OutputUUID": uuid,
                "OutputName": "Repeat Item"
            ]
        }
        return [
            "Type": "Variable",
            "VariableName": name
        ]
    }

    /// Maps a friendly `coerce` value from actions.json to the Shortcuts
    /// `CoercionItemClass` string used inside a WFCoercionVariableAggrandizement.
    /// Unknown values are ignored (treated as no coercion).
    private func coerceItemClass(for coerce: String) -> String? {
        switch coerce {
        case "string", "text": return "WFStringContentItem"
        case "number": return "WFNumberContentItem"
        case "dictionary": return "WFDictionaryContentItem"
        default: return nil
        }
    }

    func compile(nodes: [ASTNode]) throws -> [String: Any] {
        var outputMap: [String: OutputRef] = [:]
        var declaredVariables: Set<String> = [Self.shortcutInputName]
        var forEachVarRefs: [String: String] = [:]
        return try compileWithOutputMap(nodes: nodes, outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarRefs: &forEachVarRefs)
    }

    private func compileWithOutputMap(nodes: [ASTNode], outputMap: inout [String: OutputRef], declaredVariables: inout Set<String>, forEachVarRefs: inout [String: String]) throws -> [String: Any] {
        var actions: [[String: Any]] = []
        var shortcutName = "Perspective Shortcut"
        var iconColor = 463140863 // blue default
        var iconGlyph = 59743 // gear default
        var noInputBehavior: String? = nil

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
                if key == "noInputBehavior" {
                    noInputBehavior = value
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
                            "Value": Self.variableReferenceDict(name: refName, forEachVarRefs: forEachVarRefs),
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
                        sourceAction = try buildDictionaryAction(from: value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                    } else {
                        sourceAction = try buildTextAction(from: value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
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
                                let plainVal = try expressionToPlainValue(value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                                let strVal = "\(plainVal)"
                                resolvedValue = [
                                    "value": strVal,
                                    "title": ["key": strVal],
                                    "subtitle": ["key": strVal]
                                ] as [String: Any]
                            } else if tkParam?.typeKind == 3 || tkParam?.typeKind == 4 {
                                // Static enum: use plain value
                                resolvedValue = try expressionToPlainValue(value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                            } else {
                                // Primitives (string, int, bool, etc.): use plain values
                                resolvedValue = try expressionToPlainValue(value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
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
                                resolvedValue = try expressionToPlainValue(value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                            } else if let paramType = paramDef?.type, paramType == "textSeparator",
                                      case .stringLiteral(let s) = value {
                                // Shortcuts' splitText/combineText take WFTextSeparator
                                // as an enum ("New Lines", "Spaces", "Every Character",
                                // "Custom"). When the enum is "Custom", a sibling
                                // WFTextCustomSeparator carries the actual character.
                                // Accept any string from the user and auto-route:
                                // known enum values pass through; anything else becomes
                                // a Custom separator. Without this, `separator: ","`
                                // silently set WFTextSeparator="," and Shortcuts fell
                                // back to the default (New Lines), producing a single-
                                // element list instead of three.
                                let knownEnums: Set<String> = ["New Lines", "Spaces", "Every Character", "Custom"]
                                if knownEnums.contains(s) {
                                    resolvedValue = s
                                } else {
                                    resolvedValue = "Custom"
                                    params["WFTextCustomSeparator"] = s
                                }
                            } else if let paramType = paramDef?.type, paramType == "variable",
                                      case .variableReference(let varName) = value {
                                // Variable-typed parameters need WFTextTokenAttachment,
                                // not WFTextTokenString, so the action receives the
                                // output directly rather than as interpolated text.
                                //
                                // Optional `coerce` on the parameter injects a
                                // WFCoercionVariableAggrandizement so Shortcuts reads
                                // the upstream value in the requested form — e.g.
                                // "string" forces a File (such as downloadURL's
                                // response) to be read as its text content rather
                                // than as the File object itself, which is what
                                // makes `getDictionary` actually see the JSON body.
                                let coerceClass: String? = paramDef?.coerce.flatMap { coerceItemClass(for: $0) }
                                let aggrandizements: [[String: Any]]? = coerceClass.map { cls in
                                    [[
                                        "CoercionItemClass": cls,
                                        "Type": "WFCoercionVariableAggrandizement"
                                    ]]
                                }
                                var inner: [String: Any]
                                if let ref = outputMap[varName] {
                                    inner = [
                                        "OutputUUID": ref.uuid,
                                        "Type": "ActionOutput",
                                        "OutputName": ref.name
                                    ]
                                } else if Self.isShortcutInput(varName) {
                                    inner = Self.extensionInputAttachment()
                                } else {
                                    inner = Self.variableReferenceDict(name: varName, forEachVarRefs: forEachVarRefs)
                                }
                                if let aggrandizements {
                                    inner["Aggrandizements"] = aggrandizements
                                }
                                resolvedValue = [
                                    "Value": inner,
                                    "WFSerializationType": "WFTextTokenAttachment"
                                ] as [String: Any]
                            } else if let paramType = paramDef?.type, paramType == "iCloudFolder" {
                                // iCloudFolder: emit an implicit Text action with the
                                // folder name string, then reference its output as a
                                // WFTextTokenAttachment. This lets Shortcuts resolve
                                // the iCloud Drive folder at runtime without embedding
                                // device-specific bookmark UUIDs.
                                let folderAction = try buildTextAction(from: value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                                actions.append(folderAction)
                                resolvedValue = buildMagicVariable(outputOf: folderAction)
                            } else if let paramType = paramDef?.type, paramType == "formDictionary",
                                      case .dictionaryLiteral(let entries) = value {
                                // Form dictionary: variable references become file items (WFItemType 5),
                                // strings become text items (WFItemType 0).
                                resolvedValue = try buildFormDictionary(entries: entries, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                            } else {
                                resolvedValue = try expressionToValueWithOutputMap(value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
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
                try applyCondition(condition, to: &condParams, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                actions.append(buildAction(identifier: "is.workflow.actions.conditional", parameters: condParams))

                // Emit then body
                for bodyNode in thenBody {
                    let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarRefs: &forEachVarRefs)
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
                        let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarRefs: &forEachVarRefs)
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
                let countValue = try expressionToValueWithOutputMap(count, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                actions.append(buildAction(
                    identifier: "is.workflow.actions.repeat.count",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 0, "WFRepeatCount": countValue]
                ))
                for bodyNode in body {
                    let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarRefs: &forEachVarRefs)
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
                // Separate UUID for the start-marker action itself; the
                // iterator's magic-variable refs (Repeat Item) bind to this
                // UUID via OutputUUID, not to the GroupingIdentifier.
                let startUUID = UUID().uuidString
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
                            "Value": Self.variableReferenceDict(name: varName, forEachVarRefs: forEachVarRefs),
                            "WFSerializationType": "WFTextTokenAttachment"
                        ] as [String: Any]
                    }
                } else {
                    collectionValue = try expressionToValueWithOutputMap(collection, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                }
                actions.append(buildAction(
                    identifier: "is.workflow.actions.repeat.each",
                    parameters: ["GroupingIdentifier": groupID, "WFControlFlowMode": 0, "WFInput": collectionValue, "UUID": startUUID]
                ))
                // Declare the loop variable so it can be referenced in the body.
                // Shortcuts always calls this "Repeat Item" at runtime.
                declaredVariables.insert(itemName)
                // Bind the user's iterator name to the start-marker's UUID so
                // references inside the body resolve via Type:ActionOutput
                // (Shortcuts' canonical magic-var shape) rather than
                // Type:Variable+VariableName:"Repeat Item".
                forEachVarRefs[itemName] = startUUID
                for bodyNode in body {
                    let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarRefs: &forEachVarRefs)
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
                        let compiled = try compileWithOutputMap(nodes: [bodyNode], outputMap: &outputMap, declaredVariables: &declaredVariables, forEachVarRefs: &forEachVarRefs)
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

            case .includeDirective(_, let location):
                throw CompilerError(message: "#include directives must be resolved by the preprocessor before compilation", location: location)
            case .fragmentMarker(let location):
                throw CompilerError(message: "#fragment markers must be resolved by the preprocessor before compilation", location: location)
            case .providesDeclaration(_, let location):
                throw CompilerError(message: "#provides declarations must be resolved by the preprocessor before compilation", location: location)
            case .requiresDeclaration(_, _, let location):
                throw CompilerError(message: "#requires declarations must be resolved by the preprocessor before compilation", location: location)
            }
        }

        var result: [String: Any] = [
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

        if let behavior = noInputBehavior {
            let behaviorMap: [String: String] = [
                "doNothing": "WFWorkflowNoInputBehaviorDoNothing",
                "askForInput": "WFWorkflowNoInputBehaviorAskForInput",
                "getClipboard": "WFWorkflowNoInputBehaviorGetClipboard",
            ]
            if let name = behaviorMap[behavior] {
                result["WFWorkflowNoInputBehavior"] = ["Name": name, "Parameters": [:] as [String: Any]]
            }
        }

        return result
    }

    // MARK: - Helpers

    private func buildAction(identifier: String, parameters: [String: Any]) -> [String: Any] {
        [
            "WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": parameters
        ]
    }

    private func buildDictionaryAction(from expression: Expression, outputMap: [String: OutputRef], forEachVarRefs: [String: String] = [:]) throws -> [String: Any] {
        let value = try expressionToValueWithOutputMap(expression, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
        let uuid = UUID().uuidString
        return buildAction(
            identifier: "is.workflow.actions.dictionary",
            parameters: ["WFItems": value, "UUID": uuid, "CustomOutputName": "Dictionary"]
        )
    }

    /// Builds a WFDictionaryFieldValue for form uploads.
    /// Variable references become file items (WFItemType 5), everything else becomes text (WFItemType 0).
    private func buildFormDictionary(entries: [DictionaryEntry], outputMap: [String: OutputRef], forEachVarRefs: [String: String]) throws -> Any {
        var items: [[String: Any]] = []
        for entry in entries {
            var item: [String: Any] = [:]
            item["WFKey"] = try expressionToValueWithOutputMap(entry.key, outputMap: outputMap, forEachVarRefs: forEachVarRefs)

            if case .variableReference(let varName) = entry.value {
                // Variable reference → file item (WFItemType 5)
                item["WFItemType"] = 5
                let attachment: [String: Any]
                if let ref = outputMap[varName] {
                    attachment = [
                        "Value": [
                            "OutputUUID": ref.uuid,
                            "Type": "ActionOutput",
                            "OutputName": ref.name
                        ] as [String: Any],
                        "WFSerializationType": "WFTextTokenAttachment"
                    ]
                } else if Self.isShortcutInput(varName) {
                    attachment = [
                        "Value": Self.extensionInputAttachment(),
                        "WFSerializationType": "WFTextTokenAttachment"
                    ]
                } else {
                    attachment = [
                        "Value": Self.variableReferenceDict(name: varName, forEachVarRefs: forEachVarRefs),
                        "WFSerializationType": "WFTextTokenAttachment"
                    ]
                }
                item["WFValue"] = [
                    "Value": attachment,
                    "WFSerializationType": "WFTokenAttachmentParameterState"
                ] as [String: Any]
            } else {
                // String/other → text item (WFItemType 0)
                item["WFItemType"] = 0
                item["WFValue"] = try expressionToValueWithOutputMap(entry.value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
            }
            items.append(item)
        }
        return [
            "Value": ["WFDictionaryFieldValueItems": items],
            "WFSerializationType": "WFDictionaryFieldValue"
        ] as [String: Any]
    }

    private func buildTextAction(from expression: Expression, outputMap: [String: OutputRef] = [:], forEachVarRefs: [String: String] = [:]) throws -> [String: Any] {
        let value = try expressionToValueWithOutputMap(expression, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
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

    private func expressionToPlainValue(_ expr: Expression, outputMap: [String: OutputRef] = [:], forEachVarRefs: [String: String] = [:]) throws -> Any {
        switch expr {
        case .stringLiteral(let s): return s
        case .numberLiteral(let n): return n == n.rounded() ? Int(n) : n
        case .boolLiteral(let b): return b
        case .dictionaryLiteral: return try expressionToValueWithOutputMap(expr, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
        default: return try expressionToValueWithOutputMap(expr, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
        }
    }

    private func expressionToValueWithOutputMap(_ expr: Expression, outputMap: [String: OutputRef], forEachVarRefs: [String: String] = [:]) throws -> Any {
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
                : Self.variableReferenceDict(name: name, forEachVarRefs: forEachVarRefs)
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
                        attachments[range] = Self.variableReferenceDict(name: name, forEachVarRefs: forEachVarRefs)
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
                item["WFKey"] = try expressionToValueWithOutputMap(entry.key, outputMap: outputMap, forEachVarRefs: forEachVarRefs)

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
                    item["WFValue"] = try expressionToValueWithOutputMap(entry.value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                default:
                    item["WFItemType"] = 0
                    item["WFValue"] = try expressionToValueWithOutputMap(entry.value, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
                }
                items.append(item)
            }
            return [
                "Value": ["WFDictionaryFieldValueItems": items],
                "WFSerializationType": "WFDictionaryFieldValue"
            ] as [String: Any]
        }
    }

    private func applyCondition(_ condition: Condition, to params: inout [String: Any], outputMap: [String: OutputRef], forEachVarRefs: [String: String] = [:]) throws {
        // Helper: resolve the left-hand side of a condition.
        // Conditionals use a nested format for WFInput:
        //   { Type: "Variable", Variable: { Value: { ..., Aggrandizements: [coerce] }, WFSerializationType: "WFTextTokenAttachment" } }
        // String comparisons (==, !=, contains) coerce to WFStringContentItem.
        // Numeric comparisons (>, <) coerce to WFNumberContentItem.
        func resolveInput(_ expr: Expression, coercionClass: String = "WFStringContentItem") throws -> Any {
            if case .variableReference(let name) = expr {
                let coercion: [[String: Any]] = [
                    [
                        "CoercionItemClass": coercionClass,
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
                    var ref = Self.variableReferenceDict(name: name, forEachVarRefs: forEachVarRefs)
                    ref["Aggrandizements"] = coercion
                    inner = [
                        "Value": ref,
                        "WFSerializationType": "WFTextTokenAttachment"
                    ] as [String: Any]
                }
                return [
                    "Type": "Variable",
                    "Variable": inner
                ] as [String: Any]
            }
            return try expressionToValueWithOutputMap(expr, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
        }

        switch condition {
        case .equals(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 4 // equals
            params["WFConditionalActionString"] = try expressionToPlainValue(right, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
        case .notEquals(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 5 // not equals
            params["WFConditionalActionString"] = try expressionToPlainValue(right, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
        case .contains(let left, let right):
            params["WFInput"] = try resolveInput(left)
            params["WFCondition"] = 99 // contains
            params["WFConditionalActionString"] = try expressionToPlainValue(right, outputMap: outputMap, forEachVarRefs: forEachVarRefs)
        case .greaterThan(let left, let right):
            params["WFInput"] = try resolveInput(left, coercionClass: "WFNumberContentItem")
            params["WFCondition"] = 2 // greater than
            params["WFNumberValue"] = "\(try expressionToPlainValue(right, outputMap: outputMap, forEachVarRefs: forEachVarRefs))"
        case .lessThan(let left, let right):
            params["WFInput"] = try resolveInput(left, coercionClass: "WFNumberContentItem")
            params["WFCondition"] = 3 // less than
            params["WFNumberValue"] = "\(try expressionToPlainValue(right, outputMap: outputMap, forEachVarRefs: forEachVarRefs))"
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
        // Real WFWorkflowIconGlyphNumber values (private-use codepoints in the
        // Shortcuts glyph font). Names without an exact glyph map to the
        // closest available one: eye→glasses, leaf→pine tree, share→repost
        // arrows, bag→handbag, film→filmstrip.
        let glyphs: [String: Int] = [
            "gear": 59743, "compose": 61514, "star": 59841,
            "heart": 59754, "bolt": 59764, "globe": 59412,
            "mic": 59780, "music": 59790, "play": 59508,
            "camera": 59682, "photo": 59784, "film": 59733,
            "mail": 59773, "message": 59779, "phone": 59814,
            "clock": 59712, "alarm": 59649, "calendar": 59681,
            "map": 61444, "location": 59769, "bookmark": 59670,
            "tag": 59848, "folder": 59737, "doc": 59725,
            "list": 59445, "cart": 59828, "bag": 59750,
            "gift": 59744, "lock": 59770, "key": 59760,
            "link": 59685, "flag": 59736, "bell": 59667,
            "eye": 59745, "hand": 59751, "person": 59801,
            "house": 59755, "car": 59452, "airplane": 59648,
            "sun": 59845, "moon": 59782, "cloud": 59714,
            "umbrella": 59861, "flame": 59734, "drop": 59866,
            "leaf": 59731, "paintbrush": 59793, "pencil": 59798,
            "scissors": 59824, "wand": 59511, "cube": 59721,
            "download": 59693, "upload": 59708, "share": 59821,
            "trash": 59859, "magnifyingglass": 59772,
            "robot": 61566, "skull": 61569
        ]
        return glyphs[name.lowercased()] ?? 59743
    }
}
