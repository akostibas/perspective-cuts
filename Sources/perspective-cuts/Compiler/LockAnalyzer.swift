import Foundation

/// Provides authentication policy lookups for actions.
/// Production code uses ToolKitReader; tests can supply a stub.
protocol AuthenticationPolicyProvider {
    func getAuthenticationPolicy(identifier: String) -> String?
}

extension ToolKitReader: AuthenticationPolicyProvider {}

/// Analyzes a shortcut's AST to determine which actions require the device to be unlocked.
///
/// Authentication policy data comes from Apple's ToolKit database (the authoritative source).
/// If this approach proves problematic (e.g., ToolKit DB not available on all machines),
/// the fallback plan is to copy authenticationPolicy values into actions.json as traits.
/// See: https://github.com/akostibas/perspective-cuts/issues/3
struct LockAnalyzer {

    /// A single finding: an action that requires device unlock.
    struct Diagnostic: CustomStringConvertible {
        let actionName: String
        let identifier: String
        let policy: String
        let location: SourceLocation
        /// Describes the branch context, e.g. "when x == \"foo\"", or nil if always reachable.
        let branchContext: String?

        var description: String {
            let reachability = branchContext.map { "reachable \($0)" } ?? "always reachable"
            return "\(location): \(actionName) (\(policy)) — \(reachability)"
        }
    }

    let registry: ActionRegistry
    let policyProvider: AuthenticationPolicyProvider

    func analyze(nodes: [ASTNode]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        walk(nodes: nodes, branchContext: nil, diagnostics: &diagnostics)
        return diagnostics
    }

    // MARK: - Private

    private func walk(nodes: [ASTNode], branchContext: String?, diagnostics: inout [Diagnostic]) {
        for node in nodes {
            switch node {
            case .actionCall(let name, _, _, let location):
                if let diag = checkAction(name: name, location: location, branchContext: branchContext) {
                    diagnostics.append(diag)
                }

            case .ifStatement(let condition, let thenBody, let elseBody, _):
                let condStr = describeCondition(condition)
                walk(nodes: thenBody, branchContext: composeContext(branchContext, "when \(condStr)"), diagnostics: &diagnostics)
                if let elseBody {
                    walk(nodes: elseBody, branchContext: composeContext(branchContext, "when not (\(condStr))"), diagnostics: &diagnostics)
                }

            case .menu(let title, let cases, _):
                for menuCase in cases {
                    let caseContext = "in menu \"\(title)\" case \"\(menuCase.label)\""
                    walk(nodes: menuCase.body, branchContext: composeContext(branchContext, caseContext), diagnostics: &diagnostics)
                }

            case .repeatLoop(_, let body, _):
                walk(nodes: body, branchContext: branchContext, diagnostics: &diagnostics)

            case .forEachLoop(_, _, let body, _):
                walk(nodes: body, branchContext: branchContext, diagnostics: &diagnostics)

            case .functionDeclaration(_, let body, _):
                walk(nodes: body, branchContext: branchContext, diagnostics: &diagnostics)

            default:
                break
            }
        }
    }

    private func checkAction(name: String, location: SourceLocation, branchContext: String?) -> Diagnostic? {
        // Resolve the ToolKit identifier: dotted names are already identifiers,
        // short names go through the registry.
        let identifier: String
        if name.contains(".") {
            identifier = name
        } else if let def = registry.actions[name] {
            identifier = def.identifier
        } else {
            return nil // Unknown action — can't check
        }

        guard let policy = policyProvider.getAuthenticationPolicy(identifier: identifier) else {
            return nil // Not in ToolKit DB — can't verify
        }

        guard policy != "none" else {
            return nil // No unlock required
        }

        return Diagnostic(
            actionName: name,
            identifier: identifier,
            policy: policy,
            location: location,
            branchContext: branchContext
        )
    }

    private func composeContext(_ existing: String?, _ new: String) -> String {
        if let existing {
            return "\(existing), \(new)"
        }
        return new
    }

    private func describeCondition(_ condition: Condition) -> String {
        switch condition {
        case .equals(let left, let right):
            return "\(describeExpr(left)) == \(describeExpr(right))"
        case .notEquals(let left, let right):
            return "\(describeExpr(left)) != \(describeExpr(right))"
        case .contains(let left, let right):
            return "\(describeExpr(left)) contains \(describeExpr(right))"
        case .greaterThan(let left, let right):
            return "\(describeExpr(left)) > \(describeExpr(right))"
        case .lessThan(let left, let right):
            return "\(describeExpr(left)) < \(describeExpr(right))"
        }
    }

    private func describeExpr(_ expr: Expression) -> String {
        switch expr {
        case .stringLiteral(let s): return "\"\(s)\""
        case .numberLiteral(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .boolLiteral(let b): return String(b)
        case .variableReference(let v): return v
        case .interpolatedString: return "<interpolated string>"
        case .dictionaryLiteral: return "<dictionary>"
        }
    }
}
