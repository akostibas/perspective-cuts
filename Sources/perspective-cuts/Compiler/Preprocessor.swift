import Foundation

struct PreprocessorError: Error, CustomStringConvertible {
    let message: String
    let location: SourceLocation?

    var description: String {
        if let loc = location {
            return "Preprocessor error at \(loc): \(message)"
        }
        return "Preprocessor error: \(message)"
    }
}

struct Preprocessor: Sendable {
    /// Directory of the source file being preprocessed, used to resolve
    /// relative include paths.
    let sourceDirectory: URL

    /// Resolves all `#include` directives in the given AST by reading,
    /// parsing, and inlining the referenced files. Validates `#requires`
    /// dependencies and auto-prefixes internal fragment variables.
    ///
    /// Errors if:
    /// - A `#fragment` file is being compiled as the top-level source
    /// - An included file cannot be found or parsed
    /// - A `#requires` variable is not in scope at the include site
    /// - Two fragments both `#provides` the same variable
    func preprocess(nodes: [ASTNode], isTopLevel: Bool = true) throws -> [ASTNode] {
        // Top-level fragment check
        if isTopLevel && nodes.contains(where: { if case .fragmentMarker = $0 { return true } else { return false } }) {
            throw PreprocessorError(
                message: "Cannot compile a #fragment file directly — it must be #included from another file",
                location: nodes.first(where: { if case .fragmentMarker = $0 { return true } else { return false } })
                    .flatMap { if case .fragmentMarker(let loc) = $0 { return loc } else { return nil } }
            )
        }

        // Track all variables in scope at each point during processing.
        // This includes variables from the main file (var declarations, -> captures)
        // and #provides from earlier fragments.
        var scopedVariables: Set<String> = []
        // Track all provided variable names globally to detect duplicates.
        var allProvided: [String: String] = [:] // varName -> fragment path that provided it

        var result: [ASTNode] = []
        for node in nodes {
            switch node {
            case .includeDirective(let path, let location):
                let included = try resolveInclude(
                    path: path,
                    location: location,
                    scopedVariables: &scopedVariables,
                    allProvided: &allProvided
                )
                result.append(contentsOf: included)
            case .fragmentMarker, .providesDeclaration, .requiresDeclaration:
                // Strip preprocessor-only directives from top-level file
                break
            case .variableDeclaration(let name, _, _, _):
                scopedVariables.insert(name)
                result.append(node)
            case .actionCall(_, _, let output, _):
                if let output { scopedVariables.insert(output) }
                result.append(node)
            default:
                result.append(node)
            }
        }
        return result
    }

    private func resolveInclude(
        path: String,
        location: SourceLocation,
        scopedVariables: inout Set<String>,
        allProvided: inout [String: String]
    ) throws -> [ASTNode] {
        let fileURL = sourceDirectory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PreprocessorError(
                message: "Included file not found: \(path) (resolved to \(fileURL.path))",
                location: location
            )
        }

        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let tokens = try Lexer(source: source).tokenize()
        let fragmentNodes = try Parser(tokens: tokens).parse()

        // Extract #provides and #requires from the fragment
        var provides: Set<String> = []
        var requires: Set<String> = []
        for node in fragmentNodes {
            if case .providesDeclaration(let vars, _) = node {
                for v in vars { provides.insert(v) }
            }
            if case .requiresDeclaration(let vars, _) = node {
                for v in vars { requires.insert(v) }
            }
        }

        // Validate #requires are satisfied by variables in scope
        for req in requires {
            if !scopedVariables.contains(req) {
                throw PreprocessorError(
                    message: "Fragment '\(path)' requires variable '\(req)' which is not in scope at the include site. Available: \(scopedVariables.sorted().joined(separator: ", "))",
                    location: location
                )
            }
        }

        // Check for duplicate #provides
        for prov in provides {
            if let existingSource = allProvided[prov] {
                throw PreprocessorError(
                    message: "Variable '\(prov)' is provided by both '\(existingSource)' and '\(path)'",
                    location: location
                )
            }
            allProvided[prov] = path
        }

        // Strip import, metadata, fragment markers, provides, requires
        let actionNodes = fragmentNodes.filter { node in
            switch node {
            case .importStatement, .metadata, .fragmentMarker,
                 .providesDeclaration, .requiresDeclaration:
                return false
            default:
                return true
            }
        }

        // Auto-prefix internal variables if fragment has #provides declarations.
        // Variables NOT in #provides and NOT in #requires are internal.
        let hasContracts = !provides.isEmpty || !requires.isEmpty
        let prefixedNodes: [ASTNode]
        if hasContracts {
            let prefix = fragmentPrefix(from: path)
            let exempt = provides.union(requires)
            prefixedNodes = prefixNodes(actionNodes, prefix: prefix, exempt: exempt)
        } else {
            prefixedNodes = actionNodes
        }

        // Register provided variables in scope for subsequent fragments
        for prov in provides {
            scopedVariables.insert(prov)
        }
        // Also register any unprefixed variables declared in fragments without contracts
        if !hasContracts {
            for node in prefixedNodes {
                switch node {
                case .variableDeclaration(let name, _, _, _):
                    scopedVariables.insert(name)
                case .actionCall(_, _, let output, _):
                    if let output { scopedVariables.insert(output) }
                default: break
                }
            }
        }

        return prefixedNodes
    }

    // MARK: - Fragment Name Prefix

    /// Derives a camelCase prefix from a file path.
    /// e.g. "fragments/config-loader.perspective" → "configLoader__"
    static func fragmentPrefix(from path: String) -> String {
        let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = filename.split(whereSeparator: { $0 == "-" || $0 == "_" })
        let camelCased = parts.enumerated().map { i, part in
            i == 0 ? part.lowercased() : part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }.joined()
        return camelCased + "__"
    }

    private func fragmentPrefix(from path: String) -> String {
        Self.fragmentPrefix(from: path)
    }

    // MARK: - Variable Auto-Prefixing

    /// Walks the AST and renames all variables that are NOT in the exempt set.
    /// Loop iterator variables (for-each item names) are collected during traversal
    /// and also exempted since they map to Shortcuts "Repeat Item" at runtime.
    private func prefixNodes(_ nodes: [ASTNode], prefix: String, exempt: Set<String>) -> [ASTNode] {
        // First pass: collect all for-each loop variable names so they're exempt
        var loopVars: Set<String> = []
        collectLoopVars(nodes, into: &loopVars)
        let allExempt = exempt.union(loopVars)

        return nodes.map { prefixNode($0, prefix: prefix, exempt: allExempt) }
    }

    private func collectLoopVars(_ nodes: [ASTNode], into vars: inout Set<String>) {
        for node in nodes {
            switch node {
            case .forEachLoop(let itemName, _, let body, _):
                vars.insert(itemName)
                collectLoopVars(body, into: &vars)
            case .ifStatement(_, let thenBody, let elseBody, _):
                collectLoopVars(thenBody, into: &vars)
                if let elseBody { collectLoopVars(elseBody, into: &vars) }
            case .repeatLoop(_, let body, _):
                collectLoopVars(body, into: &vars)
            case .menu(_, let cases, _):
                for c in cases { collectLoopVars(c.body, into: &vars) }
            case .functionDeclaration(_, let body, _):
                collectLoopVars(body, into: &vars)
            default: break
            }
        }
    }

    private func prefixNode(_ node: ASTNode, prefix: String, exempt: Set<String>) -> ASTNode {
        func rename(_ name: String) -> String {
            exempt.contains(name) ? name : prefix + name
        }

        switch node {
        case .variableDeclaration(let name, let value, let isConstant, let loc):
            return .variableDeclaration(
                name: rename(name),
                value: prefixExpression(value, prefix: prefix, exempt: exempt),
                isConstant: isConstant,
                location: loc
            )
        case .actionCall(let name, let arguments, let output, let loc):
            let prefixedArgs = arguments.map { (label: $0.label, value: prefixExpression($0.value, prefix: prefix, exempt: exempt)) }
            return .actionCall(
                name: name, // action names are NOT renamed
                arguments: prefixedArgs,
                output: output.map { rename($0) },
                location: loc
            )
        case .ifStatement(let condition, let thenBody, let elseBody, let loc):
            return .ifStatement(
                condition: prefixCondition(condition, prefix: prefix, exempt: exempt),
                thenBody: thenBody.map { prefixNode($0, prefix: prefix, exempt: exempt) },
                elseBody: elseBody?.map { prefixNode($0, prefix: prefix, exempt: exempt) },
                location: loc
            )
        case .repeatLoop(let count, let body, let loc):
            return .repeatLoop(
                count: prefixExpression(count, prefix: prefix, exempt: exempt),
                body: body.map { prefixNode($0, prefix: prefix, exempt: exempt) },
                location: loc
            )
        case .forEachLoop(let itemName, let collection, let body, let loc):
            // itemName is exempt (collected in loopVars), but still rename collection refs
            return .forEachLoop(
                itemName: itemName, // never prefixed — maps to "Repeat Item"
                collection: prefixExpression(collection, prefix: prefix, exempt: exempt),
                body: body.map { prefixNode($0, prefix: prefix, exempt: exempt) },
                location: loc
            )
        case .menu(let title, let cases, let loc):
            let prefixedCases = cases.map { c in
                (label: c.label, body: c.body.map { prefixNode($0, prefix: prefix, exempt: exempt) })
            }
            return .menu(title: title, cases: prefixedCases, location: loc)
        case .functionDeclaration(let name, let body, let loc):
            return .functionDeclaration(
                name: rename(name),
                body: body.map { prefixNode($0, prefix: prefix, exempt: exempt) },
                location: loc
            )
        case .returnStatement(let value, let loc):
            return .returnStatement(
                value: value.map { prefixExpression($0, prefix: prefix, exempt: exempt) },
                location: loc
            )
        case .comment, .importStatement, .metadata, .includeDirective,
             .fragmentMarker, .providesDeclaration, .requiresDeclaration:
            return node
        }
    }

    private func prefixExpression(_ expr: Expression, prefix: String, exempt: Set<String>) -> Expression {
        func rename(_ name: String) -> String {
            exempt.contains(name) ? name : prefix + name
        }

        switch expr {
        case .variableReference(let name):
            return .variableReference(rename(name))
        case .interpolatedString(let parts):
            let prefixed = parts.map { part -> StringPart in
                if case .variable(let name) = part {
                    return .variable(rename(name))
                }
                return part
            }
            return .interpolatedString(parts: prefixed)
        case .dictionaryLiteral(let entries):
            let prefixed = entries.map { entry in
                DictionaryEntry(
                    key: prefixExpression(entry.key, prefix: prefix, exempt: exempt),
                    value: prefixExpression(entry.value, prefix: prefix, exempt: exempt)
                )
            }
            return .dictionaryLiteral(prefixed)
        case .stringLiteral, .numberLiteral, .boolLiteral:
            return expr
        }
    }

    private func prefixCondition(_ condition: Condition, prefix: String, exempt: Set<String>) -> Condition {
        func px(_ expr: Expression) -> Expression {
            prefixExpression(expr, prefix: prefix, exempt: exempt)
        }
        switch condition {
        case .equals(let l, let r): return .equals(left: px(l), right: px(r))
        case .notEquals(let l, let r): return .notEquals(left: px(l), right: px(r))
        case .contains(let l, let r): return .contains(left: px(l), right: px(r))
        case .greaterThan(let l, let r): return .greaterThan(left: px(l), right: px(r))
        case .lessThan(let l, let r): return .lessThan(left: px(l), right: px(r))
        }
    }
}
