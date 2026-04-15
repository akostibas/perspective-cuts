import Foundation

/// Analyzes a shortcut's AST to detect code paths where a potentially slow action
/// runs without a preceding output-producing action, which can trigger Siri's
/// ~4-5 second timeout when invoked via "Hey Siri."
///
/// This is a heuristic check — false positives are expected. The goal is to remind
/// the author to add early output, not to guarantee correctness.
///
/// See: https://github.com/akostibas/perspective-cuts/issues/4
struct SiriTimeoutAnalyzer {

    struct Diagnostic: CustomStringConvertible {
        let actionName: String
        let location: SourceLocation
        let branchContext: String?

        var description: String {
            let reachability = branchContext.map { "reachable \($0)" } ?? "always reachable"
            return "\(location): \(actionName) may be slow with no prior output — \(reachability)"
        }
    }

    let registry: ActionRegistry

    /// Actions known to be potentially slow (network, external processes, etc.)
    static let potentiallySlowActions: Set<String> = [
        "downloadURL",
        "getContentsOfUrl",
        "getContentsOfURL",
        "runShortcut",
        "runSSHScript",
        "getWebPageContents",
        "getRSSFeed",
        "searchAppStore",
        "searchITunes",
        "searchLocalBusinesses",
        "getCurrentLocation",
        "getDirections",
        "getTravelTime",
        "useModel",
        "translateText",
    ]

    /// Corresponding ToolKit identifiers for the above
    static let potentiallySlowIdentifiers: Set<String> = [
        "is.workflow.actions.downloadurl",
        "is.workflow.actions.getcontentsofurl",
        "is.workflow.actions.runworkflow",
        "is.workflow.actions.runsshscript",
        "is.workflow.actions.getwebpagecontents",
        "is.workflow.actions.rss",
        "is.workflow.actions.searchappstore",
        "is.workflow.actions.searchitunes",
        "is.workflow.actions.searchlocalbusinesses",
        "is.workflow.actions.getcurrentlocation",
        "is.workflow.actions.getdirections",
        "is.workflow.actions.gettraveltime",
        "is.workflow.actions.usemodel",
        "is.workflow.actions.translatetext",
    ]

    /// Actions that produce visible output (satisfying Siri's timeout)
    static let outputProducingActions: Set<String> = [
        "showResult",
        "alert",
        "ask",
        "speakText",
    ]

    static let outputProducingIdentifiers: Set<String> = [
        "is.workflow.actions.showresult",
        "is.workflow.actions.alert",
        "is.workflow.actions.ask",
        "is.workflow.actions.speaktext",
    ]

    func analyze(nodes: [ASTNode]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        walkPath(nodes: nodes, hasOutput: false, branchContext: nil, diagnostics: &diagnostics)
        return diagnostics
    }

    // MARK: - Private

    /// Walks nodes sequentially, tracking whether output has been produced on this path.
    private func walkPath(nodes: [ASTNode], hasOutput: Bool, branchContext: String?, diagnostics: inout [Diagnostic]) {
        var hasOutput = hasOutput

        for node in nodes {
            switch node {
            case .actionCall(let name, _, _, let location):
                if !hasOutput && isPotentiallySlow(name) {
                    diagnostics.append(Diagnostic(
                        actionName: name,
                        location: location,
                        branchContext: branchContext
                    ))
                }
                if producesOutput(name) {
                    hasOutput = true
                }

            case .ifStatement(let condition, let thenBody, let elseBody, _):
                let condStr = ASTWalker.describeCondition(condition)
                walkPath(
                    nodes: thenBody,
                    hasOutput: hasOutput,
                    branchContext: ASTWalker.composeContext(branchContext, "when \(condStr)"),
                    diagnostics: &diagnostics
                )
                if let elseBody {
                    walkPath(
                        nodes: elseBody,
                        hasOutput: hasOutput,
                        branchContext: ASTWalker.composeContext(branchContext, "when not (\(condStr))"),
                        diagnostics: &diagnostics
                    )
                }

            case .menu(let title, let cases, _):
                for menuCase in cases {
                    let caseContext = "in menu \"\(title)\" case \"\(menuCase.label)\""
                    walkPath(
                        nodes: menuCase.body,
                        hasOutput: hasOutput,
                        branchContext: ASTWalker.composeContext(branchContext, caseContext),
                        diagnostics: &diagnostics
                    )
                }

            case .repeatLoop(_, let body, _):
                walkPath(nodes: body, hasOutput: hasOutput, branchContext: branchContext, diagnostics: &diagnostics)

            case .forEachLoop(_, _, let body, _):
                walkPath(nodes: body, hasOutput: hasOutput, branchContext: branchContext, diagnostics: &diagnostics)

            case .functionDeclaration(_, let body, _):
                walkPath(nodes: body, hasOutput: hasOutput, branchContext: branchContext, diagnostics: &diagnostics)

            default:
                break
            }
        }
    }

    private func isPotentiallySlow(_ name: String) -> Bool {
        if Self.potentiallySlowActions.contains(name) { return true }
        // 3rd-party actions: check identifier directly
        if name.contains(".") { return Self.potentiallySlowIdentifiers.contains(name) }
        // Check via registry identifier
        if let def = registry.actions[name] {
            return Self.potentiallySlowIdentifiers.contains(def.identifier)
        }
        return false
    }

    private func producesOutput(_ name: String) -> Bool {
        if Self.outputProducingActions.contains(name) { return true }
        if name.contains(".") { return Self.outputProducingIdentifiers.contains(name) }
        if let def = registry.actions[name] {
            return Self.outputProducingIdentifiers.contains(def.identifier)
        }
        return false
    }
}
