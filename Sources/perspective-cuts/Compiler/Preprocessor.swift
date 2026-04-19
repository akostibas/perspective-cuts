import Foundation

struct PreprocessorError: Error, CustomStringConvertible {
    let message: String
    let location: SourceLocation?
    let includeChain: [(file: String, line: Int)]

    init(message: String, location: SourceLocation?, includeChain: [(file: String, line: Int)] = []) {
        self.message = message
        self.location = location
        self.includeChain = includeChain
    }

    var description: String {
        var desc = "Preprocessor error"
        if let loc = location {
            desc += " at \(loc)"
        }
        desc += ": \(message)"
        for site in includeChain {
            desc += "\n  included from \(site.file):\(site.line)"
        }
        return desc
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
    func preprocess(nodes: [ASTNode], isTopLevel: Bool = true, includeStack: Set<String> = []) throws -> [ASTNode] {
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
        // Track variables assigned since the last #include, used to validate
        // `#requires fresh:` — those variables must be (re-)set before each include.
        var recentlyAssigned: Set<String> = []

        var result: [ASTNode] = []
        for node in nodes {
            switch node {
            case .includeDirective(let path, let location):
                let included = try resolveInclude(
                    path: path,
                    location: location,
                    scopedVariables: &scopedVariables,
                    allProvided: &allProvided,
                    recentlyAssigned: &recentlyAssigned,
                    includeStack: includeStack
                )
                result.append(contentsOf: included)
            case .fragmentMarker, .providesDeclaration, .requiresDeclaration:
                // Strip preprocessor-only directives from top-level file
                break
            case .variableDeclaration(let name, _, _, _):
                scopedVariables.insert(name)
                recentlyAssigned.insert(name)
                result.append(node)
            case .actionCall(_, _, let output, _):
                if let output {
                    scopedVariables.insert(output)
                    recentlyAssigned.insert(output)
                }
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
        allProvided: inout [String: String],
        recentlyAssigned: inout Set<String>,
        includeStack: Set<String>
    ) throws -> [ASTNode] {
        let fileURL = sourceDirectory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PreprocessorError(
                message: "Included file not found: \(path) (resolved to \(fileURL.path))",
                location: location
            )
        }

        // Cycle detection: check if this file is already being processed
        let canonicalPath = fileURL.standardizedFileURL.path
        guard !includeStack.contains(canonicalPath) else {
            throw PreprocessorError(
                message: "Circular include detected: '\(path)' is already being processed",
                location: location
            )
        }

        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let tokens = try Lexer(source: source).tokenize()
        let fragmentNodes = try Parser(tokens: tokens).parse()

        // Extract #provides and #requires from the fragment
        var provides: Set<String> = []
        var requires: Set<String> = []
        var freshRequires: Set<String> = []
        for node in fragmentNodes {
            if case .providesDeclaration(let vars, _) = node {
                for v in vars { provides.insert(v) }
            }
            if case .requiresDeclaration(let vars, let isFresh, _) = node {
                for v in vars {
                    requires.insert(v)
                    if isFresh { freshRequires.insert(v) }
                }
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

        // Validate #requires fresh: variables were (re-)assigned since the last #include
        for req in freshRequires {
            if !recentlyAssigned.contains(req) {
                throw PreprocessorError(
                    message: "Fragment '\(path)' requires fresh variable '\(req)' which was not assigned before this include site",
                    location: location
                )
            }
        }

        // Clear recentlyAssigned after each include so the next include
        // of a fragment with fresh requires must have fresh assignments.
        recentlyAssigned.removeAll()

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

        // Resolve nested #include directives before auto-prefixing.
        // Use a child preprocessor with the included file's directory for
        // correct relative path resolution.
        let childStack = includeStack.union([canonicalPath])
        let fragmentDir = fileURL.deletingLastPathComponent()
        let childPreprocessor = Preprocessor(sourceDirectory: fragmentDir)
        // Track which variable names are introduced by nested includes so we
        // can exempt them from the parent fragment's auto-prefixing.
        let ownVarNames = Self.collectDeclaredVarNames(actionNodes)
        var nestedVars: Set<String> = []
        let resolvedNodes = try childPreprocessor.resolveNestedIncludes(
            nodes: actionNodes,
            scopedVariables: &scopedVariables,
            allProvided: &allProvided,
            recentlyAssigned: &recentlyAssigned,
            includeStack: childStack
        )
        nestedVars = Self.collectDeclaredVarNames(resolvedNodes).subtracting(ownVarNames)

        // Auto-prefix internal variables if fragment has #provides declarations.
        // Variables NOT in #provides and NOT in #requires are internal.
        let hasContracts = !provides.isEmpty || !requires.isEmpty
        let prefixedNodes: [ASTNode]
        if hasContracts {
            let prefix = fragmentPrefix(from: path)
            let exempt = provides.union(requires)
            // Also exempt variables introduced by resolved nested includes
            // to prevent double-prefixing.
            prefixedNodes = prefixNodes(resolvedNodes, prefix: prefix, exempt: exempt.union(nestedVars))
        } else {
            prefixedNodes = resolvedNodes
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

        // Stamp the fragment's file path onto all SourceLocations so error
        // messages identify which file the code came from.
        return setFileOnNodes(prefixedNodes, file: path)
    }

    /// Walks a node list and resolves any `#include` directives, passing
    /// through all other nodes unchanged.
    private func resolveNestedIncludes(
        nodes: [ASTNode],
        scopedVariables: inout Set<String>,
        allProvided: inout [String: String],
        recentlyAssigned: inout Set<String>,
        includeStack: Set<String>
    ) throws -> [ASTNode] {
        var result: [ASTNode] = []
        for node in nodes {
            switch node {
            case .includeDirective(let path, let location):
                let included = try resolveInclude(
                    path: path,
                    location: location,
                    scopedVariables: &scopedVariables,
                    allProvided: &allProvided,
                    recentlyAssigned: &recentlyAssigned,
                    includeStack: includeStack
                )
                result.append(contentsOf: included)
            case .variableDeclaration(let name, _, _, _):
                scopedVariables.insert(name)
                recentlyAssigned.insert(name)
                result.append(node)
            case .actionCall(_, _, let output, _):
                if let output {
                    scopedVariables.insert(output)
                    recentlyAssigned.insert(output)
                }
                result.append(node)
            default:
                result.append(node)
            }
        }
        return result
    }

    /// Collects all variable names declared at the top level of the given nodes.
    /// Used to build the exempt set for auto-prefixing so that nested fragment
    /// variables are not double-prefixed by a parent fragment.
    private static func collectDeclaredVarNames(_ nodes: [ASTNode]) -> Set<String> {
        var names: Set<String> = []
        for node in nodes {
            switch node {
            case .variableDeclaration(let name, _, _, _):
                names.insert(name)
            case .actionCall(_, _, let output, _):
                if let output { names.insert(output) }
            default: break
            }
        }
        return names
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
    /// Built-in variable names that must never be prefixed.
    private static let builtInVariables: Set<String> = [Compiler.shortcutInputName]

    private func prefixNodes(_ nodes: [ASTNode], prefix: String, exempt: Set<String>) -> [ASTNode] {
        // First pass: collect all for-each loop variable names so they're exempt
        var loopVars: Set<String> = []
        collectLoopVars(nodes, into: &loopVars)
        let allExempt = exempt.union(loopVars).union(Self.builtInVariables)

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

    // MARK: - Source File Stamping

    /// Rewrites the `SourceLocation.file` on all nodes to the given path,
    /// unless the node already has a file set (from a deeper nested include).
    private func setFileOnNodes(_ nodes: [ASTNode], file: String) -> [ASTNode] {
        nodes.map { setFileOnNode($0, file: file) }
    }

    private func stamp(_ loc: SourceLocation, file: String) -> SourceLocation {
        // Don't overwrite if already set by a deeper nested include
        if loc.file != nil { return loc }
        return SourceLocation(line: loc.line, column: loc.column, file: file)
    }

    private func setFileOnNode(_ node: ASTNode, file: String) -> ASTNode {
        switch node {
        case .importStatement(let module, let loc):
            return .importStatement(module: module, location: stamp(loc, file: file))
        case .metadata(let key, let value, let loc):
            return .metadata(key: key, value: value, location: stamp(loc, file: file))
        case .comment(let text, let loc):
            return .comment(text: text, location: stamp(loc, file: file))
        case .variableDeclaration(let name, let value, let isConstant, let loc):
            return .variableDeclaration(name: name, value: value, isConstant: isConstant, location: stamp(loc, file: file))
        case .actionCall(let name, let arguments, let output, let loc):
            return .actionCall(name: name, arguments: arguments, output: output, location: stamp(loc, file: file))
        case .ifStatement(let condition, let thenBody, let elseBody, let loc):
            return .ifStatement(
                condition: condition,
                thenBody: setFileOnNodes(thenBody, file: file),
                elseBody: elseBody.map { setFileOnNodes($0, file: file) },
                location: stamp(loc, file: file)
            )
        case .repeatLoop(let count, let body, let loc):
            return .repeatLoop(count: count, body: setFileOnNodes(body, file: file), location: stamp(loc, file: file))
        case .forEachLoop(let itemName, let collection, let body, let loc):
            return .forEachLoop(itemName: itemName, collection: collection, body: setFileOnNodes(body, file: file), location: stamp(loc, file: file))
        case .menu(let title, let cases, let loc):
            let stamped = cases.map { (label: $0.label, body: setFileOnNodes($0.body, file: file)) }
            return .menu(title: title, cases: stamped, location: stamp(loc, file: file))
        case .functionDeclaration(let name, let body, let loc):
            return .functionDeclaration(name: name, body: setFileOnNodes(body, file: file), location: stamp(loc, file: file))
        case .returnStatement(let value, let loc):
            return .returnStatement(value: value, location: stamp(loc, file: file))
        case .includeDirective(let path, let loc):
            return .includeDirective(path: path, location: stamp(loc, file: file))
        case .fragmentMarker(let loc):
            return .fragmentMarker(location: stamp(loc, file: file))
        case .providesDeclaration(let vars, let loc):
            return .providesDeclaration(variables: vars, location: stamp(loc, file: file))
        case .requiresDeclaration(let vars, let fresh, let loc):
            return .requiresDeclaration(variables: vars, fresh: fresh, location: stamp(loc, file: file))
        }
    }
}
