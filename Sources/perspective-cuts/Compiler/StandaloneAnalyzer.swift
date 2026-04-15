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
        walk(nodes: nodes, branchContext: nil, diagnostics: &diagnostics)
        return diagnostics
    }

    // MARK: - Private

    private func walk(nodes: [ASTNode], branchContext: String?, diagnostics: inout [Diagnostic]) {
        for node in nodes {
            switch node {
            case .actionCall(let name, let arguments, _, let location):
                // Dotted names are 3rd-party app actions
                if name.contains(".") {
                    diagnostics.append(Diagnostic(
                        dependency: .thirdPartyApp(identifier: name),
                        location: location,
                        branchContext: branchContext
                    ))
                }
                // runShortcut depends on another shortcut
                if name == "runShortcut" {
                    let shortcutName = extractShortcutName(from: arguments)
                    diagnostics.append(Diagnostic(
                        dependency: .shortcut(name: shortcutName),
                        location: location,
                        branchContext: branchContext
                    ))
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
        case let e?: return describeExpr(e)
        case nil: return "<unknown>"
        }
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
