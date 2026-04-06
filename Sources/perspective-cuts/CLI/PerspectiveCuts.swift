import ArgumentParser
import Foundation

@main
struct PerspectiveCuts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "perspective",
        abstract: "Perspective Cuts — A text-based Apple Shortcuts compiler",
        version: "0.1.0",
        subcommands: [Compile.self, Validate.self, Actions.self, Discover.self, Detail.self]
    )
}

// MARK: - Compile

struct Compile: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compile a .perspective file to a .shortcut file"
    )

    @Argument(help: "The .perspective file to compile")
    var file: String

    @Option(name: .shortAndLong, help: "Output path for the compiled .shortcut file")
    var output: String?

    @Flag(name: .long, help: "Sign the shortcut for import")
    var sign: Bool = false

    @Flag(name: .long, help: "Install directly to Shortcuts app (bypasses import, preserves all enum values)")
    var install: Bool = false

    func run() throws {
        let source = try readSource(file)
        let tokens = try Lexer(source: source).tokenize()
        let nodes = try Parser(tokens: tokens).parse()
        let registry = try ActionRegistry.load()
        let toolKitReader = try? Self.openToolKitDB()
        let plist = try Compiler(registry: registry, toolKitReader: toolKitReader).compile(nodes: nodes)

        // Determine output path
        let inputURL = URL(fileURLWithPath: file)
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let outputPath = output ?? "\(baseName).shortcut"
        let outputURL = URL(fileURLWithPath: outputPath)

        // Extract actions and name for install mode
        let actions = plist["WFWorkflowActions"] as? [[String: Any]] ?? []
        let shortcutName = plist["WFWorkflowName"] as? String ?? baseName

        // Serialize to binary plist
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: outputURL)

        if install {
            try installToShortcuts(name: shortcutName, actions: actions)
        } else if sign {
            let signedPath = outputURL.deletingPathExtension().path + "-signed.shortcut"
            let signedURL = URL(fileURLWithPath: signedPath)
            try Signer.sign(input: outputURL, output: signedURL)
            // Replace unsigned with signed
            try FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: signedURL, to: outputURL)
            FileHandle.standardError.write(Data("Compiled and signed: \(outputURL.path)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("Compiled: \(outputURL.path)\n".utf8))
            FileHandle.standardError.write(Data("Note: Run with --sign to create an importable shortcut.\n".utf8))
        }
    }

    private func installToShortcuts(name: String, actions: [[String: Any]]) throws {
        let dbPath = NSHomeDirectory() + "/Library/Shortcuts/Shortcuts.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ValidationError("Shortcuts database not found at \(dbPath)")
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else {
            throw ValidationError("Cannot open Shortcuts database")
        }
        defer { sqlite3_close(db) }

        // Serialize actions array to binary plist
        let actionsData = try PropertyListSerialization.data(
            fromPropertyList: actions,
            format: .binary,
            options: 0
        )

        // Check if shortcut with this name already exists
        var checkStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT Z_PK FROM ZSHORTCUT WHERE ZNAME = ?", -1, &checkStmt, nil)
        sqlite3_bind_text(checkStmt, 1, name, -1, nil)

        if sqlite3_step(checkStmt) == SQLITE_ROW {
            // Update existing shortcut's actions
            let existingPK = sqlite3_column_int64(checkStmt, 0)
            sqlite3_finalize(checkStmt)

            var updateStmt: OpaquePointer?
            sqlite3_prepare_v2(db, "UPDATE ZSHORTCUTACTIONS SET ZDATA = ? WHERE ZSHORTCUT = ?", -1, &updateStmt, nil)
            sqlite3_bind_blob(updateStmt, 1, (actionsData as NSData).bytes, Int32(actionsData.count), nil)
            sqlite3_bind_int64(updateStmt, 2, existingPK)

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                sqlite3_finalize(updateStmt)
                throw ValidationError("Failed to update shortcut actions")
            }
            sqlite3_finalize(updateStmt)
            FileHandle.standardError.write(Data("Updated '\(name)' in Shortcuts app (PK=\(existingPK)). Restart Shortcuts to see changes.\n".utf8))
        } else {
            sqlite3_finalize(checkStmt)
            FileHandle.standardError.write(Data("Shortcut '\(name)' not found. Import with --sign first, then use --install to update.\n".utf8))
        }
    }

    static func openToolKitDB() throws -> ToolKitReader {
        let base = NSHomeDirectory() + "/Library/Shortcuts/ToolKit"
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: base) else {
            throw ValidationError("ToolKit directory not found at \(base)")
        }
        guard let dbFile = contents.first(where: { $0.hasPrefix("Tools-prod") && $0.hasSuffix(".sqlite") }) else {
            throw ValidationError("No ToolKit database found in \(base)")
        }
        return try ToolKitReader(path: base + "/" + dbFile)
    }

    private func readSource(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File not found: \(path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Validate

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a .perspective file for syntax errors without compiling"
    )

    @Argument(help: "The .perspective file to validate")
    var file: String

    func run() throws {
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("File not found: \(file)")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let tokens = try Lexer(source: source).tokenize()
        let nodes = try Parser(tokens: tokens).parse()

        // Validate action names against registry
        let registry = try ActionRegistry.load()
        for node in nodes {
            try validateNode(node, registry: registry)
        }

        print("Valid. \(nodes.count) statements parsed.")
    }

    private func validateNode(_ node: ASTNode, registry: ActionRegistry) throws {
        switch node {
        case .actionCall(let name, _, _, let location):
            // Dotted names are raw 3rd party identifiers — always valid
            if registry.actions[name] == nil && !name.contains(".") {
                var msg = "Unknown action: '\(name)'"
                if let suggestion = registry.findClosestAction(to: name) {
                    msg += ". Did you mean '\(suggestion)'?"
                }
                throw ValidationError("\(location): \(msg)")
            }
        case .ifStatement(_, let thenBody, let elseBody, _):
            for child in thenBody { try validateNode(child, registry: registry) }
            if let elseBody { for child in elseBody { try validateNode(child, registry: registry) } }
        case .repeatLoop(_, let body, _), .forEachLoop(_, _, let body, _):
            for child in body { try validateNode(child, registry: registry) }
        case .menu(_, let cases, _):
            for c in cases { for child in c.body { try validateNode(child, registry: registry) } }
        case .functionDeclaration(_, let body, _):
            for child in body { try validateNode(child, registry: registry) }
        default: break
        }
    }
}

// MARK: - Actions

struct Actions: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List available actions"
    )

    @Argument(help: "Optional search term to filter actions")
    var search: String?

    func run() throws {
        let registry = try ActionRegistry.load()
        var results = registry.actions.sorted(by: { $0.key < $1.key })

        if let search = search?.lowercased() {
            results = results.filter {
                $0.key.lowercased().contains(search) ||
                $0.value.description.lowercased().contains(search)
            }
        }

        if results.isEmpty {
            print("No actions found.")
            return
        }

        print("\(results.count) actions:")
        print("")
        for (name, def) in results {
            print("  \(name)")
            print("    \(def.description)")
            print("    Identifier: \(def.identifier)")
            if !def.parameters.isEmpty {
                let paramNames = def.parameters.keys.sorted().joined(separator: ", ")
                print("    Parameters: \(paramNames)")
            }
            print("")
        }
    }
}

// MARK: - Discover

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Discover actions from installed apps via the Shortcuts ToolKit database"
    )

    @Argument(help: "Search term to filter by app name or action identifier")
    var search: String?

    @Flag(name: .long, help: "Show only 3rd party apps (exclude Apple and built-in actions)")
    var thirdParty: Bool = false

    func run() throws {
        let db = try Compile.openToolKitDB()
        let actions = try db.discoverActions(search: search, thirdPartyOnly: thirdParty)

        if actions.isEmpty {
            print("No actions found.")
            return
        }

        // Group by app
        var grouped: [(String, [(id: String, name: String, params: [String])])] = []
        var currentApp = ""
        var currentActions: [(id: String, name: String, params: [String])] = []

        for action in actions {
            let app = appName(from: action.id)
            if app != currentApp {
                if !currentActions.isEmpty {
                    grouped.append((currentApp, currentActions))
                }
                currentApp = app
                currentActions = []
            }
            currentActions.append(action)
        }
        if !currentActions.isEmpty {
            grouped.append((currentApp, currentActions))
        }

        print("\(actions.count) actions from \(grouped.count) apps:\n")
        for (app, appActions) in grouped {
            print("  \(app)")
            for action in appActions {
                let paramStr = action.params.isEmpty ? "" : "(\(action.params.joined(separator: ", ")))"
                print("    \(action.id)\(paramStr)")
                if !action.name.isEmpty && action.name != action.id.split(separator: ".").last.map(String.init) ?? "" {
                    print("      \"\(action.name)\"")
                }
            }
            print("")
        }

        print("Use any identifier directly in .perspective files:")
        print("  \(actions.first?.id ?? "com.example.app.Action")(param: \"value\") -> result")
    }

    private func appName(from identifier: String) -> String {
        let parts = identifier.split(separator: ".")
        if parts.count >= 3 {
            return parts.prefix(3).joined(separator: ".")
        }
        return identifier
    }
}

// MARK: - Detail

struct Detail: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show detailed parameter info for an action from the ToolKit database"
    )

    @Argument(help: "Action identifier (e.g. app.techopolis.Perspective-Actions.UseLocalModelIntent)")
    var identifier: String

    func run() throws {
        let reader = try Compile.openToolKitDB()

        // Try exact match first, then search
        guard let detail = reader.getActionDetail(identifier: identifier) else {
            // Try partial match
            let matches = try reader.discoverActions(search: identifier, thirdPartyOnly: false)
            if matches.isEmpty {
                throw ValidationError("Action '\(identifier)' not found in ToolKit database.")
            }
            print("Action '\(identifier)' not found. Did you mean one of these?")
            for m in matches.prefix(10) {
                print("  \(m.id)")
            }
            return
        }

        // Header
        print(detail.identifier)
        if !detail.displayName.isEmpty {
            print("  \"\(detail.displayName)\"")
        }
        if let ret = detail.returnType {
            print("  Returns: \(ret)")
        }
        print("")

        // Parameters
        if detail.parameters.isEmpty {
            print("  No parameters")
        } else {
            print("  Parameters:")
            let maxKeyLen = detail.parameters.map(\.key.count).max() ?? 0
            let maxTypeLen = detail.parameters.map(\.typeLabel.count).max() ?? 0

            for param in detail.parameters {
                let paddedKey = param.key.padding(toLength: maxKeyLen + 2, withPad: " ", startingAt: 0)
                let paddedType = param.typeLabel.padding(toLength: maxTypeLen + 2, withPad: " ", startingAt: 0)
                let display = param.displayName.map { "\"\($0)\"" } ?? ""
                print("    \(paddedKey)\(paddedType)\(display)")

                if param.isDynamicEntity {
                    print("      [dynamic entity — app provides values at runtime]")
                }
                if !param.enumCases.isEmpty {
                    let caseList = param.enumCases.map { c in
                        c.title.isEmpty || c.title == c.id ? c.id : "\(c.id) (\(c.title))"
                    }.joined(separator: ", ")
                    print("      Values: \(caseList)")
                }
                if let desc = param.description, !desc.isEmpty {
                    print("      \(desc)")
                }
            }
        }

        // Usage hint
        print("")
        let exampleParams = detail.parameters.prefix(3).map { p -> String in
            if p.typeId == "int" || p.typeId == "number" {
                return "\(p.key): 0"
            } else if p.typeId == "bool" {
                return "\(p.key): true"
            } else {
                return "\(p.key): \"value\""
            }
        }.joined(separator: ", ")
        print("  Usage: \(detail.identifier)(\(exampleParams)) -> result")
    }
}

// MARK: - ToolKit Database Reader

import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ToolKitParameterDetail {
    let key: String
    let displayName: String?
    let description: String?
    let typeId: String       // "string", "int", "bool", "file", or entity/enum type ID
    let typeKind: Int        // 1=primitive, 2=entity, 3=enum, 4=scoped enum, 6=query
    let isDynamicEntity: Bool
    let enumCases: [(id: String, title: String)]
    let sortOrder: Int

    var typeLabel: String {
        if isDynamicEntity { return "entity" }
        switch typeKind {
        case 2: return "entity"
        case 3, 4: return "enum"
        case 6: return "query"
        default: return typeId
        }
    }
}

struct ToolKitActionDetail {
    let identifier: String
    let displayName: String
    let returnType: String?
    let parameters: [ToolKitParameterDetail]
}

// @unchecked Sendable: db is opened read-only and used synchronously within each command.
final class ToolKitReader: @unchecked Sendable {
    let db: OpaquePointer

    init(path: String) throws {
        var dbPointer: OpaquePointer?
        guard sqlite3_open_v2(path, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = dbPointer else {
            throw ValidationError("Cannot open ToolKit database at \(path)")
        }
        self.db = db
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Action Detail

    func getActionDetail(identifier: String) -> ToolKitActionDetail? {
        // Look up tool by identifier
        var stmt: OpaquePointer?
        let query = "SELECT rowId, id FROM Tools WHERE id = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, identifier, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let toolId = Int(sqlite3_column_int64(stmt, 0))
        guard let idCStr = sqlite3_column_text(stmt, 1) else { return nil }
        let actionId = String(cString: idCStr)

        let displayName = getLocalization(toolId: toolId)
        let returnType = getOutputType(toolId: toolId)
        let parameters = getParameterDetails(toolId: toolId, actionIdentifier: actionId)

        return ToolKitActionDetail(
            identifier: actionId,
            displayName: displayName,
            returnType: returnType,
            parameters: parameters
        )
    }

    /// Look up parameter details for a 3rd-party action by identifier.
    /// Returns nil if the action is not found in the ToolKit DB.
    func getParameterInfo(actionIdentifier: String) -> [String: ToolKitParameterDetail]? {
        guard let detail = getActionDetail(identifier: actionIdentifier) else { return nil }
        var map: [String: ToolKitParameterDetail] = [:]
        for p in detail.parameters {
            map[p.key] = p
        }
        return map
    }

    // MARK: - Discover (existing)

    func discoverActions(search: String?, thirdPartyOnly: Bool) throws -> [(id: String, name: String, params: [String])] {
        var results: [(id: String, name: String, params: [String])] = []

        var query = "SELECT t.rowId, t.id FROM Tools t"
        if thirdPartyOnly {
            query += " WHERE t.id NOT LIKE 'is.workflow.actions.%' AND t.id NOT LIKE 'com.apple.%'"
        }
        query += " ORDER BY t.id"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            guard let idCStr = sqlite3_column_text(stmt, 1) else { continue }
            let toolId = String(cString: idCStr)

            if let search = search?.lowercased() {
                guard toolId.lowercased().contains(search) else { continue }
            }

            let name = getLocalization(toolId: Int(rowId))
            let params = getParameterKeys(toolId: Int(rowId))
            results.append((id: toolId, name: name, params: params))
        }

        return results
    }

    // MARK: - Private Helpers

    private func getLocalization(toolId: Int) -> String {
        var stmt: OpaquePointer?
        let query = "SELECT name FROM ToolLocalizations WHERE toolId = ? AND locale = 'en' LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(toolId))
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return ""
    }

    private func getParameterKeys(toolId: Int) -> [String] {
        var params: [String] = []
        var stmt: OpaquePointer?
        let query = "SELECT key FROM Parameters WHERE toolId = ? ORDER BY sortOrder"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return params }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(toolId))
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                params.append(String(cString: cstr))
            }
        }
        return params
    }

    private func getOutputType(toolId: Int) -> String? {
        var stmt: OpaquePointer?
        let query = "SELECT typeIdentifier FROM ToolOutputTypes WHERE toolId = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(toolId))
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    private func getParameterDetails(toolId: Int, actionIdentifier: String) -> [ToolKitParameterDetail] {
        var results: [ToolKitParameterDetail] = []

        // Get parameters with their types and localizations
        var stmt: OpaquePointer?
        let query = """
            SELECT p.key, p.sortOrder, p.typeInstance,
                   pl.name, pl.description,
                   tpt.typeId
            FROM Parameters p
            LEFT JOIN ParameterLocalizations pl ON pl.toolId = p.toolId AND pl.key = p.key AND pl.locale = 'en'
            LEFT JOIN ToolParameterTypes tpt ON tpt.toolId = p.toolId AND tpt.key = p.key
            WHERE p.toolId = ?
            ORDER BY p.sortOrder
            """
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(toolId))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let key: String = {
                guard let cstr = sqlite3_column_text(stmt, 0) else { return "" }
                return String(cString: cstr)
            }()
            let sortOrder = Int(sqlite3_column_int64(stmt, 1))

            // Detect dynamic entity params by checking the typeInstance protobuf blob.
            // When an App Intent parameter is backed by a dynamic entity query, Apple embeds
            // the full action identifier (e.g. "app.techopolis.Perspective-Actions.UseLocalModelIntent")
            // in the blob. We match the full identifier to avoid false positives on short names.
            let isDynamic: Bool = {
                let blobLen = sqlite3_column_bytes(stmt, 2)
                guard blobLen > 50, let blobPtr = sqlite3_column_blob(stmt, 2) else { return false }
                let data = Data(bytes: blobPtr, count: Int(blobLen))
                return data.range(of: Data(actionIdentifier.utf8)) != nil
            }()

            let displayName: String? = {
                guard let cstr = sqlite3_column_text(stmt, 3) else { return nil }
                return String(cString: cstr)
            }()
            let description: String? = {
                guard let cstr = sqlite3_column_text(stmt, 4) else { return nil }
                return String(cString: cstr)
            }()
            let typeId: String = {
                guard let cstr = sqlite3_column_text(stmt, 5) else { return "string" }
                return String(cString: cstr)
            }()

            // Get type kind from Types table
            let typeKind = getTypeKind(typeId: typeId)

            // Get enum cases if applicable
            let enumCases: [(id: String, title: String)] = (typeKind == 3 || typeKind == 4)
                ? getEnumCases(typeId: typeId) : []

            results.append(ToolKitParameterDetail(
                key: key,
                displayName: displayName,
                description: description,
                typeId: typeId,
                typeKind: typeKind,
                isDynamicEntity: isDynamic,
                enumCases: enumCases,
                sortOrder: sortOrder
            ))
        }

        return results
    }

    private func getTypeKind(typeId: String) -> Int {
        // Note: Types.rowId is TEXT PRIMARY KEY in Apple's ToolKit schema (not the implicit integer rowid).
        // Values are type identifiers like "string", "bool", "com.example.MyEntity", etc.
        var stmt: OpaquePointer?
        let query = "SELECT kind FROM Types WHERE rowId = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return 1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, typeId, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 1
    }

    private func getEnumCases(typeId: String) -> [(id: String, title: String)] {
        var cases: [(id: String, title: String)] = []
        var stmt: OpaquePointer?
        let query = "SELECT id, title FROM EnumerationCases WHERE typeId = ? AND locale = 'en' ORDER BY id"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return cases }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, typeId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id: String = {
                guard let cstr = sqlite3_column_text(stmt, 0) else { return "" }
                return String(cString: cstr)
            }()
            let title: String = {
                guard let cstr = sqlite3_column_text(stmt, 1) else { return "" }
                return String(cString: cstr)
            }()
            cases.append((id: id, title: title))
        }
        return cases
    }
}
