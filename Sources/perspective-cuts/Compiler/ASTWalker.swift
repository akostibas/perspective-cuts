import Foundation

/// Walks the AST tracking branch context, calling a visitor for each action encountered.
/// Shared infrastructure for all static analyzers (lock check, standalone check, etc.).
struct ASTWalker {

    /// Info passed to the visitor for each action call encountered during the walk.
    struct ActionVisit {
        let name: String
        let arguments: [(label: String?, value: Expression)]
        let output: String?
        let location: SourceLocation
        let branchContext: String?
    }

    /// Walks the AST and calls `visitor` for each action call, passing branch context.
    static func walk(nodes: [ASTNode], visitor: (ActionVisit) -> Void) {
        walkNodes(nodes, branchContext: nil, visitor: visitor)
    }

    // MARK: - Private

    private static func walkNodes(_ nodes: [ASTNode], branchContext: String?, visitor: (ActionVisit) -> Void) {
        for node in nodes {
            switch node {
            case .actionCall(let name, let arguments, let output, let location):
                visitor(ActionVisit(
                    name: name,
                    arguments: arguments,
                    output: output,
                    location: location,
                    branchContext: branchContext
                ))

            case .ifStatement(let condition, let thenBody, let elseBody, _):
                let condStr = describeCondition(condition)
                walkNodes(thenBody, branchContext: composeContext(branchContext, "when \(condStr)"), visitor: visitor)
                if let elseBody {
                    walkNodes(elseBody, branchContext: composeContext(branchContext, "when not (\(condStr))"), visitor: visitor)
                }

            case .menu(let title, let cases, _):
                for menuCase in cases {
                    let caseContext = "in menu \"\(title)\" case \"\(menuCase.label)\""
                    walkNodes(menuCase.body, branchContext: composeContext(branchContext, caseContext), visitor: visitor)
                }

            case .repeatLoop(_, let body, _):
                walkNodes(body, branchContext: branchContext, visitor: visitor)

            case .forEachLoop(_, _, let body, _):
                walkNodes(body, branchContext: branchContext, visitor: visitor)

            case .functionDeclaration(_, let body, _):
                walkNodes(body, branchContext: branchContext, visitor: visitor)

            default:
                break
            }
        }
    }

    static func composeContext(_ existing: String?, _ new: String) -> String {
        if let existing {
            return "\(existing), \(new)"
        }
        return new
    }

    static func describeCondition(_ condition: Condition) -> String {
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

    static func describeExpr(_ expr: Expression) -> String {
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
