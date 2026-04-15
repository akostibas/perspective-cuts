import Testing
@testable import perspective_cuts

@Suite("Compiler")
struct CompilerTests {

/// Minimal registry with actions needed for tests.
private func testRegistry() -> ActionRegistry {
    ActionRegistry(
        actions: [
            "getBattery": ActionDefinition(
                identifier: "is.workflow.actions.getbatterylevel",
                description: "Get the current battery level",
                parameters: [:]
            ),
            "showResult": ActionDefinition(
                identifier: "is.workflow.actions.showresult",
                description: "Show the result of the shortcut",
                parameters: [
                    "text": ActionParameter(type: "string", required: true, key: "Text")
                ]
            ),
            "setVariable": ActionDefinition(
                identifier: "is.workflow.actions.setvariable",
                description: "Set a variable",
                parameters: [
                    "name": ActionParameter(type: "plainString", required: true, key: "WFVariableName"),
                    "input": ActionParameter(type: "variable", required: true, key: "WFInput")
                ]
            ),
            "getFile": ActionDefinition(
                identifier: "is.workflow.actions.documentpicker.open",
                description: "Get file",
                parameters: [
                    "path": ActionParameter(type: "plainString", required: false, key: "WFGetFilePath"),
                    "errorIfNotFound": ActionParameter(type: "boolean", required: false, key: "WFFileErrorIfNotFound")
                ]
            ),
            "downloadURL": ActionDefinition(
                identifier: "is.workflow.actions.downloadurl",
                description: "Download URL",
                parameters: [
                    "url": ActionParameter(type: "string", required: true, key: "WFURL"),
                    "method": ActionParameter(type: "enum", required: false, key: "WFHTTPMethod"),
                    "headers": ActionParameter(type: "dictionary", required: false, key: "WFHTTPHeaders"),
                    "bodyType": ActionParameter(type: "enum", required: false, key: "WFHTTPBodyType"),
                    "body": ActionParameter(type: "variable", required: false, key: "WFRequestVariable"),
                    "formValues": ActionParameter(type: "formDictionary", required: false, key: "WFFormValues"),
                ]
            ),
        ],
        controlFlow: [:],
        iconColors: ["blue": 463140863, "red": 4271458559]
    )
}

private func compile(_ source: String) throws -> [String: Any] {
    let tokens = try Lexer(source: source).tokenize()
    let nodes = try Parser(tokens: tokens).parse()
    return try Compiler(registry: testRegistry()).compile(nodes: nodes)
}

private func actions(from result: [String: Any]) -> [[String: Any]] {
    result["WFWorkflowActions"] as! [[String: Any]]
}

private func params(of action: [String: Any]) -> [String: Any] {
    action["WFWorkflowActionParameters"] as! [String: Any]
}

private func identifier(of action: [String: Any]) -> String {
    action["WFWorkflowActionIdentifier"] as! String
}

// MARK: - Variable References (existing tests, expanded)

@Test("Declared variable references compile successfully")
func declaredVariableCompiles() throws {
    let result = try compile("""
    getBattery() -> level
    showResult(text: "\\(level)")
    """)
    #expect(actions(from: result).count == 2)
}

@Test("shortcutInput is pre-declared and emits ExtensionInput")
func shortcutInputCompiles() throws {
    let result = try compile("showResult(text: \"\\(shortcutInput)\")")
    let acts = actions(from: result)
    #expect(acts.count == 1)

    let p = params(of: acts[0])
    let text = p["Text"] as! [String: Any]
    let value = text["Value"] as! [String: Any]
    let attachments = value["attachmentsByRange"] as! [String: Any]
    let attachment = attachments["{0, 1}"] as! [String: Any]
    #expect(attachment["Type"] as? String == "ExtensionInput")
}

@Test("Undeclared variable reference produces compile error")
func undeclaredVariableThrows() throws {
    #expect(throws: CompilerError.self) {
        _ = try compile("showResult(text: \"\\(bogusVar)\")")
    }
}

// MARK: - Action Calls

@Test("Action call emits correct identifier")
func actionCallIdentifier() throws {
    let result = try compile("getBattery()")
    let acts = actions(from: result)
    #expect(acts.count == 1)
    #expect(identifier(of: acts[0]) == "is.workflow.actions.getbatterylevel")
}

@Test("Action call with labeled parameter maps to plist key")
func actionCallParameter() throws {
    let result = try compile("showResult(text: \"hello\")")
    let acts = actions(from: result)
    let p = params(of: acts[0])
    // "text" parameter maps to plist key "Text"
    #expect(p["Text"] != nil)
}

@Test("Unknown action produces compile error with suggestion")
func unknownActionError() throws {
    #expect(throws: CompilerError.self) {
        _ = try compile("getBatery()")
    }
}

// MARK: - Output Captures (-> varName)

@Test("Output capture sets UUID and CustomOutputName")
func outputCapture() throws {
    let result = try compile("getBattery() -> level")
    let acts = actions(from: result)
    let p = params(of: acts[0])
    #expect(p["CustomOutputName"] as? String == "level")
    #expect(p["UUID"] as? String != nil)
}

@Test("Output capture can be referenced as ActionOutput")
func outputCaptureReference() throws {
    let result = try compile("""
    getBattery() -> level
    showResult(text: "\\(level)")
    """)
    let acts = actions(from: result)
    let p = params(of: acts[1])
    let text = p["Text"] as! [String: Any]
    let value = text["Value"] as! [String: Any]
    let attachments = value["attachmentsByRange"] as! [String: Any]
    let attachment = attachments["{0, 1}"] as! [String: Any]
    #expect(attachment["Type"] as? String == "ActionOutput")
    #expect(attachment["OutputName"] as? String == "level")
    #expect(attachment["OutputUUID"] as? String != nil)
}

// MARK: - Variable Declarations

@Test("var declaration emits setvariable action")
func varDeclaration() throws {
    let result = try compile("var name = \"hello\"")
    let acts = actions(from: result)
    // String literal var: text action + setvariable
    #expect(acts.count == 2)
    #expect(identifier(of: acts[0]) == "is.workflow.actions.gettext")
    #expect(identifier(of: acts[1]) == "is.workflow.actions.setvariable")
    let p = params(of: acts[1])
    #expect(p["WFVariableName"] as? String == "name")
}

@Test("var with variable reference emits direct setvariable")
func varWithReference() throws {
    let result = try compile("""
    getBattery() -> level
    var x = level
    """)
    let acts = actions(from: result)
    // getBattery + setvariable (direct, no text action)
    #expect(acts.count == 2)
    #expect(identifier(of: acts[1]) == "is.workflow.actions.setvariable")
    let p = params(of: acts[1])
    #expect(p["WFVariableName"] as? String == "x")
    // The WFInput should reference level via ActionOutput
    let wfInput = p["WFInput"] as! [String: Any]
    let inputValue = wfInput["Value"] as! [String: Any]
    #expect(inputValue["Type"] as? String == "ActionOutput")
}

@Test("var with shortcutInput emits ExtensionInput in setvariable")
func varWithShortcutInput() throws {
    let result = try compile("var x = shortcutInput")
    let acts = actions(from: result)
    #expect(acts.count == 1)
    #expect(identifier(of: acts[0]) == "is.workflow.actions.setvariable")
    let p = params(of: acts[0])
    let wfInput = p["WFInput"] as! [String: Any]
    let inputValue = wfInput["Value"] as! [String: Any]
    #expect(inputValue["Type"] as? String == "ExtensionInput")
}

@Test("var with dictionary emits dictionary action + setvariable")
func varWithDictionary() throws {
    let result = try compile("var d = { \"key\": \"value\" }")
    let acts = actions(from: result)
    #expect(acts.count == 2)
    #expect(identifier(of: acts[0]) == "is.workflow.actions.dictionary")
    #expect(identifier(of: acts[1]) == "is.workflow.actions.setvariable")
}

// MARK: - If/Else

@Test("If statement emits conditional actions with grouping")
func ifStatement() throws {
    let result = try compile("""
    getBattery() -> level
    if level == "100" {
        showResult(text: "full")
    }
    """)
    let acts = actions(from: result)
    // getBattery, conditional(start), showResult, conditional(end)
    #expect(acts.count == 4)
    #expect(identifier(of: acts[1]) == "is.workflow.actions.conditional")
    #expect(identifier(of: acts[3]) == "is.workflow.actions.conditional")

    // Start has WFControlFlowMode 0, end has 2
    let startParams = params(of: acts[1])
    let endParams = params(of: acts[3])
    #expect(startParams["WFControlFlowMode"] as? Int == 0)
    #expect(endParams["WFControlFlowMode"] as? Int == 2)

    // Same GroupingIdentifier
    let groupID = startParams["GroupingIdentifier"] as! String
    #expect(endParams["GroupingIdentifier"] as? String == groupID)
}

@Test("If-else emits three conditional markers")
func ifElseStatement() throws {
    let result = try compile("""
    getBattery() -> level
    if level == "100" {
        showResult(text: "full")
    } else {
        showResult(text: "not full")
    }
    """)
    let acts = actions(from: result)
    // getBattery, conditional(start), showResult, conditional(else), showResult, conditional(end)
    #expect(acts.count == 6)
    let elseParams = params(of: acts[3])
    #expect(elseParams["WFControlFlowMode"] as? Int == 1)
}

@Test("If condition wires up correct WFCondition codes")
func conditionCodes() throws {
    let cases: [(String, Int)] = [
        ("==", 4),
        ("!=", 5),
        (">", 2),
        ("<", 3),
        ("contains", 99),
    ]
    for (op, code) in cases {
        let result = try compile("""
        getBattery() -> level
        if level \(op) "50" {
            showResult(text: "ok")
        }
        """)
        let acts = actions(from: result)
        let startParams = params(of: acts[1])
        #expect(startParams["WFCondition"] as? Int == code, "Expected code \(code) for operator \(op)")
    }
}

@Test("Numeric comparisons (> <) use WFNumberContentItem coercion")
func numericCoercion() throws {
    let result = try compile("""
    getBattery() -> level
    if level > "50" {
        showResult(text: "high")
    }
    """)
    let acts = actions(from: result)
    let condParams = params(of: acts[1])

    // LHS should be coerced to WFNumberContentItem, not WFStringContentItem
    let input = condParams["WFInput"] as! [String: Any]
    let variable = input["Variable"] as! [String: Any]
    let value = variable["Value"] as! [String: Any]
    let aggr = value["Aggrandizements"] as! [[String: Any]]
    #expect(aggr[0]["CoercionItemClass"] as? String == "WFNumberContentItem")
}

@Test("String comparisons (== != contains) use WFStringContentItem coercion")
func stringCoercion() throws {
    let result = try compile("""
    getBattery() -> level
    if level == "50" {
        showResult(text: "exact")
    }
    """)
    let acts = actions(from: result)
    let condParams = params(of: acts[1])

    let input = condParams["WFInput"] as! [String: Any]
    let variable = input["Variable"] as! [String: Any]
    let value = variable["Value"] as! [String: Any]
    let aggr = value["Aggrandizements"] as! [[String: Any]]
    #expect(aggr[0]["CoercionItemClass"] as? String == "WFStringContentItem")
}

@Test("Numeric comparisons use WFNumberValue instead of WFConditionalActionString")
func numericConditionValue() throws {
    let result = try compile("""
    getBattery() -> level
    if level > "0" {
        showResult(text: "positive")
    }
    """)
    let acts = actions(from: result)
    let condParams = params(of: acts[1])

    #expect(condParams["WFNumberValue"] as? String == "0")
    #expect(condParams["WFConditionalActionString"] == nil)
}

@Test("String comparisons use WFConditionalActionString, not WFNumberValue")
func stringConditionValue() throws {
    let result = try compile("""
    getBattery() -> level
    if level == "active" {
        showResult(text: "yes")
    }
    """)
    let acts = actions(from: result)
    let condParams = params(of: acts[1])

    #expect(condParams["WFConditionalActionString"] as? String == "active")
    #expect(condParams["WFNumberValue"] == nil)
}

@Test("Less-than uses WFNumberContentItem coercion and WFNumberValue")
func lessThanCoercion() throws {
    let result = try compile("""
    getBattery() -> level
    if level < "10" {
        showResult(text: "low")
    }
    """)
    let acts = actions(from: result)
    let condParams = params(of: acts[1])

    // Coercion
    let input = condParams["WFInput"] as! [String: Any]
    let variable = input["Variable"] as! [String: Any]
    let value = variable["Value"] as! [String: Any]
    let aggr = value["Aggrandizements"] as! [[String: Any]]
    #expect(aggr[0]["CoercionItemClass"] as? String == "WFNumberContentItem")

    // Value key
    #expect(condParams["WFNumberValue"] as? String == "10")
    #expect(condParams["WFConditionalActionString"] == nil)
}

// MARK: - Repeat Loop

@Test("Repeat loop emits repeat.count actions")
func repeatLoop() throws {
    let result = try compile("""
    repeat 3 {
        getBattery()
    }
    """)
    let acts = actions(from: result)
    // repeat(start), getBattery, repeat(end)
    #expect(acts.count == 3)
    #expect(identifier(of: acts[0]) == "is.workflow.actions.repeat.count")
    #expect(identifier(of: acts[2]) == "is.workflow.actions.repeat.count")
    let startParams = params(of: acts[0])
    #expect(startParams["WFControlFlowMode"] as? Int == 0)
    #expect(startParams["WFRepeatCount"] as? Int == 3)
    let endParams = params(of: acts[2])
    #expect(endParams["WFControlFlowMode"] as? Int == 2)
}

// MARK: - For Each Loop

@Test("For-each loop emits repeat.each actions")
func forEachLoop() throws {
    let result = try compile("""
    getBattery() -> items
    for item in items {
        showResult(text: "\\(item)")
    }
    """)
    let acts = actions(from: result)
    // getBattery, repeat.each(start), showResult, repeat.each(end)
    #expect(acts.count == 4)
    #expect(identifier(of: acts[1]) == "is.workflow.actions.repeat.each")
    #expect(identifier(of: acts[3]) == "is.workflow.actions.repeat.each")
    let startParams = params(of: acts[1])
    #expect(startParams["WFControlFlowMode"] as? Int == 0)
}

@Test("For-each loop variable resolves to Repeat Item")
func forEachVariableResolvesToRepeatItem() throws {
    let result = try compile("""
    getBattery() -> items
    for item in items {
        showResult(text: "\\(item)")
    }
    """)
    let acts = actions(from: result)
    let showParams = params(of: acts[2])
    let text = showParams["Text"] as! [String: Any]
    let value = text["Value"] as! [String: Any]
    let attachments = value["attachmentsByRange"] as! [String: Any]
    let attachment = attachments["{0, 1}"] as! [String: Any]
    #expect(attachment["VariableName"] as? String == "Repeat Item")
}

// MARK: - Menu

@Test("Menu emits choosefrommenu actions")
func menuActions() throws {
    let result = try compile("""
    menu "Pick" {
        case "A":
            getBattery()
        case "B":
            showResult(text: "b")
    }
    """)
    let acts = actions(from: result)
    // choosefrommenu(start), choosefrommenu(case A), getBattery, choosefrommenu(case B), showResult, choosefrommenu(end)
    #expect(acts.count == 6)
    #expect(identifier(of: acts[0]) == "is.workflow.actions.choosefrommenu")

    let startParams = params(of: acts[0])
    #expect(startParams["WFControlFlowMode"] as? Int == 0)
    #expect(startParams["WFMenuPrompt"] as? String == "Pick")
    let items = startParams["WFMenuItems"] as! [String]
    #expect(items == ["A", "B"])

    // Case markers have WFControlFlowMode 1
    let caseAParams = params(of: acts[1])
    #expect(caseAParams["WFControlFlowMode"] as? Int == 1)
    #expect(caseAParams["WFMenuItemTitle"] as? String == "A")
}

// MARK: - Dictionary Literals

@Test("Dictionary literal produces WFDictionaryFieldValue")
func dictionaryCompilation() throws {
    let result = try compile("var d = { \"name\": \"Alice\", \"age\": 30 }")
    let acts = actions(from: result)
    let dictParams = params(of: acts[0])
    let wfItems = dictParams["WFItems"] as! [String: Any]
    #expect(wfItems["WFSerializationType"] as? String == "WFDictionaryFieldValue")
    let value = wfItems["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]
    #expect(items.count == 2)
}

@Test("Dictionary number values use WFItemType 3")
func dictionaryNumberType() throws {
    let result = try compile("var d = { \"count\": 42 }")
    let acts = actions(from: result)
    let dictParams = params(of: acts[0])
    let wfItems = dictParams["WFItems"] as! [String: Any]
    let value = wfItems["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]
    #expect(items[0]["WFItemType"] as? Int == 3)
}

@Test("Dictionary bool values use WFItemType 4")
func dictionaryBoolType() throws {
    let result = try compile("var d = { \"flag\": true }")
    let acts = actions(from: result)
    let dictParams = params(of: acts[0])
    let wfItems = dictParams["WFItems"] as! [String: Any]
    let value = wfItems["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]
    #expect(items[0]["WFItemType"] as? Int == 4)
}

@Test("Nested dictionary uses WFItemType 1")
func dictionaryNestedType() throws {
    let result = try compile("var d = { \"outer\": { \"inner\": \"val\" } }")
    let acts = actions(from: result)
    let dictParams = params(of: acts[0])
    let wfItems = dictParams["WFItems"] as! [String: Any]
    let value = wfItems["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]
    #expect(items[0]["WFItemType"] as? Int == 1)
}

// MARK: - Form Dictionary (formValues)

@Test("formDictionary with variable reference produces WFItemType 5 (file)")
func formDictionaryFileItem() throws {
    let result = try compile("""
    getBattery() -> myFile
    downloadURL(url: "https://example.com/upload", method: "POST", bodyType: "Form", formValues: {"file": myFile})
    """)
    let acts = actions(from: result)
    let uploadParams = params(of: acts[1])
    let formValues = uploadParams["WFFormValues"] as! [String: Any]
    let value = formValues["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]

    #expect(items.count == 1)
    #expect(items[0]["WFItemType"] as? Int == 5)

    // Verify the value wrapping: WFTokenAttachmentParameterState > WFTextTokenAttachment
    let wfValue = items[0]["WFValue"] as! [String: Any]
    #expect(wfValue["WFSerializationType"] as? String == "WFTokenAttachmentParameterState")
    let innerValue = wfValue["Value"] as! [String: Any]
    #expect(innerValue["WFSerializationType"] as? String == "WFTextTokenAttachment")
}

@Test("formDictionary with string value produces WFItemType 0 (text)")
func formDictionaryTextItem() throws {
    let result = try compile("""
    downloadURL(url: "https://example.com/upload", method: "POST", bodyType: "Form", formValues: {"name": "test.txt"})
    """)
    let acts = actions(from: result)
    let uploadParams = params(of: acts[0])
    let formValues = uploadParams["WFFormValues"] as! [String: Any]
    let value = formValues["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]

    #expect(items.count == 1)
    #expect(items[0]["WFItemType"] as? Int == 0)
}

@Test("formDictionary with mixed file and text entries")
func formDictionaryMixed() throws {
    let result = try compile("""
    getBattery() -> myFile
    downloadURL(url: "https://example.com/upload", method: "POST", bodyType: "Form", formValues: {"file": myFile, "description": "a test file"})
    """)
    let acts = actions(from: result)
    let uploadParams = params(of: acts[1])
    let formValues = uploadParams["WFFormValues"] as! [String: Any]
    let value = formValues["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]

    #expect(items.count == 2)
    // First entry: variable → file (5)
    #expect(items[0]["WFItemType"] as? Int == 5)
    // Second entry: string → text (0)
    #expect(items[1]["WFItemType"] as? Int == 0)
}

@Test("formDictionary with shortcutInput produces ExtensionInput file item")
func formDictionaryShortcutInput() throws {
    let result = try compile("""
    downloadURL(url: "https://example.com/upload", method: "POST", bodyType: "Form", formValues: {"file": shortcutInput})
    """)
    let acts = actions(from: result)
    let uploadParams = params(of: acts[0])
    let formValues = uploadParams["WFFormValues"] as! [String: Any]
    let value = formValues["Value"] as! [String: Any]
    let items = value["WFDictionaryFieldValueItems"] as! [[String: Any]]

    #expect(items[0]["WFItemType"] as? Int == 5)

    let wfValue = items[0]["WFValue"] as! [String: Any]
    let innerValue = wfValue["Value"] as! [String: Any]
    let attachment = innerValue["Value"] as! [String: Any]
    #expect(attachment["Type"] as? String == "ExtensionInput")
}

// MARK: - Interpolated Strings

@Test("Interpolated string produces correct attachmentsByRange")
func interpolatedString() throws {
    let result = try compile("""
    getBattery() -> level
    showResult(text: "Battery: \\(level)%")
    """)
    let acts = actions(from: result)
    let p = params(of: acts[1])
    let text = p["Text"] as! [String: Any]
    let value = text["Value"] as! [String: Any]
    let str = value["string"] as! String
    // "Battery: " (9 chars) then \u{FFFC} then "%"
    #expect(str == "Battery: \u{FFFC}%")
    let attachments = value["attachmentsByRange"] as! [String: Any]
    // Attachment at position 9
    #expect(attachments["{9, 1}"] != nil)
}

@Test("Multiple interpolations in one string")
func multipleInterpolations() throws {
    let result = try compile("""
    getBattery() -> a
    getBattery() -> b
    showResult(text: "\\(a) and \\(b)")
    """)
    let acts = actions(from: result)
    let p = params(of: acts[2])
    let text = p["Text"] as! [String: Any]
    let value = text["Value"] as! [String: Any]
    let attachments = value["attachmentsByRange"] as! [String: Any]
    #expect(attachments.count == 2)
}

// MARK: - Metadata

@Test("Metadata #name sets WFWorkflowName")
func metadataName() throws {
    let result = try compile("#name: My Shortcut")
    #expect(result["WFWorkflowName"] as? String == "My Shortcut")
}

@Test("Metadata #color sets icon color")
func metadataColor() throws {
    let result = try compile("#color: red")
    let icon = result["WFWorkflowIcon"] as! [String: Any]
    #expect(icon["WFWorkflowIconStartColor"] as? Int == 4271458559)
}

@Test("Metadata #icon sets glyph number")
func metadataIcon() throws {
    let result = try compile("#icon: star")
    let icon = result["WFWorkflowIcon"] as! [String: Any]
    #expect(icon["WFWorkflowIconGlyphNumber"] as? Int == 59773)
}

@Test("Default shortcut name is 'Perspective Shortcut'")
func defaultName() throws {
    let result = try compile("getBattery()")
    #expect(result["WFWorkflowName"] as? String == "Perspective Shortcut")
}

@Test("Metadata #noInputBehavior: doNothing sets WFWorkflowNoInputBehavior")
func noInputBehaviorDoNothing() throws {
    let result = try compile("#noInputBehavior: doNothing")
    let behavior = result["WFWorkflowNoInputBehavior"] as? [String: Any]
    #expect(behavior?["Name"] as? String == "WFWorkflowNoInputBehaviorDoNothing")
}

@Test("Metadata #noInputBehavior: askForInput sets WFWorkflowNoInputBehavior")
func noInputBehaviorAskForInput() throws {
    let result = try compile("#noInputBehavior: askForInput")
    let behavior = result["WFWorkflowNoInputBehavior"] as? [String: Any]
    #expect(behavior?["Name"] as? String == "WFWorkflowNoInputBehaviorAskForInput")
}

@Test("No #noInputBehavior omits WFWorkflowNoInputBehavior key")
func noInputBehaviorDefault() throws {
    let result = try compile("getBattery()")
    #expect(result["WFWorkflowNoInputBehavior"] == nil)
}

// MARK: - Comments

@Test("Comments emit comment actions")
func commentActions() throws {
    let result = try compile("// This is a comment")
    let acts = actions(from: result)
    #expect(acts.count == 1)
    #expect(identifier(of: acts[0]) == "is.workflow.actions.comment")
    let p = params(of: acts[0])
    #expect(p["WFCommentActionText"] as? String == "This is a comment")
}

// MARK: - Boolean Parameters

@Test("Boolean parameter passes as plain value")
func booleanParameter() throws {
    let result = try compile("getFile(errorIfNotFound: true)")
    let acts = actions(from: result)
    let p = params(of: acts[0])
    #expect(p["WFFileErrorIfNotFound"] as? Bool == true)
}

// MARK: - PlainString Parameters

@Test("PlainString parameter passes as plain string")
func plainStringParameter() throws {
    let result = try compile("getFile(path: \"test.txt\")")
    let acts = actions(from: result)
    let p = params(of: acts[0])
    #expect(p["WFGetFilePath"] as? String == "test.txt")
}

// MARK: - Undeclared Variables in Different Positions

@Test("Undeclared variable in var assignment throws")
func undeclaredInVarAssignment() throws {
    #expect(throws: CompilerError.self) {
        _ = try compile("var x = bogus")
    }
}

@Test("Undeclared variable in if condition throws")
func undeclaredInCondition() throws {
    #expect(throws: CompilerError.self) {
        _ = try compile("""
        if bogus == "x" {
            getBattery()
        }
        """)
    }
}

// Note: for-each collection is not currently validated for undeclared variables.
// This is a known gap — the compiler doesn't call validateExpression on the
// collection expression in forEachLoop. Tracked for future fix.
@Test("For-each with undeclared collection compiles (known gap)")
func forEachUndeclaredCollectionCompiles() throws {
    // This should ideally throw, but currently doesn't validate the collection.
    let result = try compile("""
    for item in bogus {
        getBattery()
    }
    """)
    let acts = actions(from: result)
    #expect(acts.count == 3) // repeat.each(start), getBattery, repeat.each(end)
}

// MARK: - Plist Structure

@Test("Compiled output has required top-level keys")
func topLevelKeys() throws {
    let result = try compile("getBattery()")
    #expect(result["WFWorkflowMinimumClientVersionString"] as? String == "900")
    #expect(result["WFWorkflowClientVersion"] as? String == "1200")
    #expect(result["WFWorkflowActions"] != nil)
    #expect(result["WFWorkflowIcon"] != nil)
    #expect(result["WFWorkflowTypes"] != nil)
    #expect(result["WFWorkflowInputContentItemClasses"] != nil)
}

} // end CompilerTests
