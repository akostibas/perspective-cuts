import Foundation

/// Post-lowering structural check on the compiled action stream.
///
/// The AST-level validator (`Compiler.validateExpression`) catches user-facing
/// typos like `var z = y` where `y` was never declared. It does NOT catch
/// references the compiler itself emitted incorrectly — e.g., a magic-variable
/// reference to "Repeat Item" outside any Repeat block, an `ActionOutput`
/// reference to a UUID that no action produced, or a named-variable read of a
/// name that was never set.
///
/// Those failures resolve to empty string at Shortcuts runtime with NO error,
/// which is the worst possible failure mode. This pass walks the lowered
/// plist actions and reports each unresolved reference with the action index
/// and reference path, so they surface at compile time.
///
/// Tracks:
///   - Action UUIDs that have been assigned (so future ActionOutput refs can
///     point at them).
///   - Named variables set via `is.workflow.actions.setvariable` /
///     `is.workflow.actions.appendvariable`.
///   - Enclosing Repeat blocks (each / count), via GroupingIdentifier + mode.
///     Inside an active Repeat, "Repeat Item" and "Repeat Index" are valid
///     named-variable names.
enum CompiledWorkflowValidator {
    struct Diagnostic: Equatable {
        let actionIndex: Int
        let actionIdentifier: String
        let path: String
        let kind: Kind

        enum Kind: Equatable {
            case unknownOutputUUID(String, outputName: String?)
            case unknownVariableName(String)
        }

        var message: String {
            let where_ = "[action #\(actionIndex) \(actionIdentifier)] at \(path):"
            switch kind {
            case .unknownOutputUUID(let uuid, let name):
                let n = name.map { " (\($0))" } ?? ""
                return "\(where_) unknown ActionOutput UUID \(uuid)\(n) — no earlier action produced this output"
            case .unknownVariableName(let name):
                return "\(where_) unknown variable '\(name)' — not set by an earlier Set Variable, not a known magic variable, and not in scope"
            }
        }
    }

    /// Repeat-block start identifiers. These produce magic variables
    /// ("Repeat Item", "Repeat Index") that are valid only between the block's
    /// start (mode=0) and end (mode=2) markers.
    private static let repeatStartIdentifiers: Set<String> = [
        "is.workflow.actions.repeat.each",
        "is.workflow.actions.repeat.count"
    ]
    private static let magicRepeatVariables: Set<String> = ["Repeat Item", "Repeat Index"]
    private static let setVariableIdentifiers: Set<String> = [
        "is.workflow.actions.setvariable",
        "is.workflow.actions.appendvariable"
    ]

    static func validate(_ actions: [[String: Any]]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        var definedUUIDs: Set<String> = []
        var definedVariables: Set<String> = []
        // GroupingIdentifiers of currently-open Repeat blocks (stack-ish but
        // Shortcuts only flattens nesting via mode markers, so a set suffices).
        var activeRepeatGroups: Set<String> = []

        for (i, action) in actions.enumerated() {
            let identifier = action["WFWorkflowActionIdentifier"] as? String ?? "<unknown>"
            let params = action["WFWorkflowActionParameters"] as? [String: Any] ?? [:]
            let groupingID = params["GroupingIdentifier"] as? String
            let controlFlowMode = params["WFControlFlowMode"] as? Int

            // Update Repeat block scope BEFORE walking this action's refs,
            // so the start marker's WFInput (which usually references the
            // collection, not Repeat Item) is checked against the OUTER
            // scope. We re-add the group right after.
            let wasRepeatStart = repeatStartIdentifiers.contains(identifier) && controlFlowMode == 0
            let wasRepeatEnd = repeatStartIdentifiers.contains(identifier) && controlFlowMode == 2
            if wasRepeatEnd, let g = groupingID {
                activeRepeatGroups.remove(g)
            }

            // Walk this action's parameters for references.
            walkReferences(in: params, path: "params") { ref in
                let diag = check(
                    ref: ref,
                    actionIndex: i,
                    actionIdentifier: identifier,
                    definedUUIDs: definedUUIDs,
                    definedVariables: definedVariables,
                    repeatInScope: !activeRepeatGroups.isEmpty || wasRepeatStart
                )
                if let diag { diagnostics.append(diag) }
            }

            // Now register this action's outputs/definitions for future refs.
            if let uuid = params["UUID"] as? String {
                definedUUIDs.insert(uuid)
            }
            if setVariableIdentifiers.contains(identifier),
               let name = params["WFVariableName"] as? String {
                definedVariables.insert(name)
            }
            if wasRepeatStart, let g = groupingID {
                activeRepeatGroups.insert(g)
            }
        }
        return diagnostics
    }

    /// A reference is one of:
    ///   - {Type: "ActionOutput", OutputUUID: ..., OutputName: ...}
    ///   - {Type: "Variable", VariableName: ...}
    ///   - {Type: "ExtensionInput"}                  (always valid)
    /// References appear:
    ///   - As the leaf of an `attachmentsByRange` entry (in WFTextTokenString
    ///     interpolations).
    ///   - As `WFInput.Value` (in WFTextTokenAttachment direct refs).
    ///   - Nested inside `WFInput.Variable.Value` (the conditional form).
    private struct Reference {
        let dict: [String: Any]
        let path: String
    }

    private static func walkReferences(
        in obj: Any,
        path: String,
        emit: (Reference) -> Void
    ) {
        if let dict = obj as? [String: Any] {
            if let type = dict["Type"] as? String,
               ["ActionOutput", "Variable", "ExtensionInput"].contains(type) {
                emit(Reference(dict: dict, path: path))
                return  // leaf — don't descend further
            }
            for (k, v) in dict {
                walkReferences(in: v, path: "\(path).\(k)", emit: emit)
            }
        } else if let arr = obj as? [Any] {
            for (i, v) in arr.enumerated() {
                walkReferences(in: v, path: "\(path)[\(i)]", emit: emit)
            }
        }
    }

    private static func check(
        ref: Reference,
        actionIndex: Int,
        actionIdentifier: String,
        definedUUIDs: Set<String>,
        definedVariables: Set<String>,
        repeatInScope: Bool
    ) -> Diagnostic? {
        guard let type = ref.dict["Type"] as? String else { return nil }
        switch type {
        case "ActionOutput":
            guard let uuid = ref.dict["OutputUUID"] as? String else { return nil }
            if definedUUIDs.contains(uuid) { return nil }
            return Diagnostic(
                actionIndex: actionIndex,
                actionIdentifier: actionIdentifier,
                path: ref.path,
                kind: .unknownOutputUUID(uuid, outputName: ref.dict["OutputName"] as? String)
            )
        case "Variable":
            guard let name = ref.dict["VariableName"] as? String else { return nil }
            if definedVariables.contains(name) { return nil }
            if repeatInScope, magicRepeatVariables.contains(name) { return nil }
            return Diagnostic(
                actionIndex: actionIndex,
                actionIdentifier: actionIdentifier,
                path: ref.path,
                kind: .unknownVariableName(name)
            )
        case "ExtensionInput":
            return nil  // Always available at runtime.
        default:
            return nil
        }
    }
}
