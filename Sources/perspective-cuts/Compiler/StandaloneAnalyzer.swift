import Foundation

/// Analyzes a shortcut's AST to determine whether it can run independently,
/// without other shortcuts or third-party apps installed.
///
/// See: https://github.com/akostibas/perspective-cuts/issues/5
struct StandaloneAnalyzer {

    enum DependencyKind: CustomStringConvertible {
        case shortcut(name: String)
        case thirdPartyApp(identifier: String)

        var description: String {
            switch self {
            case .shortcut(let name): return "shortcut \"\(name)\""
            case .thirdPartyApp(let id): return "3rd-party action \(id)"
            }
        }
    }

    struct Diagnostic: CustomStringConvertible {
        let dependency: DependencyKind
        let location: SourceLocation
        let branchContext: String?

        var description: String {
            let reachability = branchContext.map { "reachable \($0)" } ?? "always reachable"
            return "\(location): \(dependency) — \(reachability)"
        }
    }

    let registry: ActionRegistry

    func analyze(nodes: [ASTNode]) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        ASTWalker.walk(nodes: nodes) { visit in
            // Dotted names are 3rd-party app actions
            if visit.name.contains(".") {
                diagnostics.append(Diagnostic(
                    dependency: .thirdPartyApp(identifier: visit.name),
                    location: visit.location,
                    branchContext: visit.branchContext
                ))
            }
            // runShortcut depends on another shortcut
            if visit.name == "runShortcut" {
                let shortcutName = extractShortcutName(from: visit.arguments)
                diagnostics.append(Diagnostic(
                    dependency: .shortcut(name: shortcutName),
                    location: visit.location,
                    branchContext: visit.branchContext
                ))
            }
        }
        return diagnostics
    }

    private func extractShortcutName(from arguments: [(label: String?, value: Expression)]) -> String {
        let expr: Expression?
        if let named = arguments.first(where: { $0.label == "name" }) {
            expr = named.value
        } else {
            expr = arguments.first?.value
        }
        // Extract raw string for string literals to avoid double-quoting
        // (DependencyKind.description already wraps in quotes)
        switch expr {
        case .stringLiteral(let s): return s
        case let e?: return ASTWalker.describeExpr(e)
        case nil: return "<unknown>"
        }
    }
}
