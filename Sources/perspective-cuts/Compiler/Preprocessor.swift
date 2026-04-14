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
    /// parsing, and inlining the referenced files. Strips `importStatement`
    /// and `metadata` nodes from included content.
    ///
    /// Errors if:
    /// - A `#fragment` file is being compiled as the top-level source
    /// - An included file cannot be found or parsed
    func preprocess(nodes: [ASTNode], isTopLevel: Bool = true) throws -> [ASTNode] {
        // Top-level fragment check
        if isTopLevel && nodes.contains(where: { if case .fragmentMarker = $0 { return true } else { return false } }) {
            throw PreprocessorError(
                message: "Cannot compile a #fragment file directly — it must be #included from another file",
                location: nodes.first(where: { if case .fragmentMarker = $0 { return true } else { return false } })
                    .flatMap { if case .fragmentMarker(let loc) = $0 { return loc } else { return nil } }
            )
        }

        var result: [ASTNode] = []
        for node in nodes {
            switch node {
            case .includeDirective(let path, let location):
                let included = try resolveInclude(path: path, location: location)
                result.append(contentsOf: included)
            case .fragmentMarker:
                // Strip #fragment markers — they're metadata for the preprocessor only
                break
            default:
                result.append(node)
            }
        }
        return result
    }

    private func resolveInclude(path: String, location: SourceLocation) throws -> [ASTNode] {
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

        // Strip import statements, metadata, and fragment markers from included content
        let filtered = fragmentNodes.filter { node in
            switch node {
            case .importStatement: return false
            case .metadata: return false
            case .fragmentMarker: return false
            default: return true
            }
        }

        return filtered
    }
}
