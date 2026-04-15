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

    struct Diagnostic: CustomStringConvertible {
        let actionName: String
        let identifier: String
        let policy: String
        let location: SourceLocation
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
        ASTWalker.walk(nodes: nodes) { visit in
            if let diag = checkAction(visit) {
                diagnostics.append(diag)
            }
        }
        return diagnostics
    }

    private func checkAction(_ visit: ASTWalker.ActionVisit) -> Diagnostic? {
        let identifier: String
        if visit.name.contains(".") {
            identifier = visit.name
        } else if let def = registry.actions[visit.name] {
            identifier = def.identifier
        } else {
            return nil
        }

        guard let policy = policyProvider.getAuthenticationPolicy(identifier: identifier) else {
            return nil
        }

        guard policy != "none" else {
            return nil
        }

        return Diagnostic(
            actionName: visit.name,
            identifier: identifier,
            policy: policy,
            location: visit.location,
            branchContext: visit.branchContext
        )
    }
}
