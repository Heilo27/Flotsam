import FlotsamBase
import FlotsamStorage
import Foundation

/// The MCP protocol over one approved connection (FR-010-07 to FR-010-10): JSON-RPC 2.0, newline-delimited, a read-only
/// tool surface. It owns no connection and no approval; the caller has already admitted the client through `MCPGate`
/// and re-checks approval before every call.
///
/// Two tools only, both read-only: `search_history` and `get_item`. Nothing here can paste, write, change or delete, so
/// "read-only" is a property of what exists, not of a flag that could be flipped.
///
/// The text sent to the client (tool descriptions, error messages) is protocol text for a program, not user-facing UI
/// text, so it lives in `MCPText` here rather than in the String Catalogue.
public struct MCPHandler: Sendable {
    private let database: FlotsamDatabase
    private let serverVersion: String

    public init(database: FlotsamDatabase, serverVersion: String) {
        self.database = database
        self.serverVersion = serverVersion
    }

    /// One request line in, one response line out (no trailing newline). Nil when the message is a notification, which
    /// JSON-RPC says is never answered.
    public func respond(to line: Data) async -> Data? {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: line)
        } catch {
            return Self.encode(Self.failure(id: NSNull(), code: JSONRPCCode.parseError, message: MCPText.parseError))
        }
        guard let message = parsed as? [String: Any], let method = message["method"] as? String else {
            return Self.encode(Self.failure(id: NSNull(), code: JSONRPCCode.invalidRequest, message: MCPText.invalidRequest))
        }
        // No `id`: a notification (`notifications/initialized`, `notifications/cancelled`). Never answered.
        guard let id = message["id"], id is String || id is NSNumber else { return nil }

        switch method {
        case "initialize":
            return Self.encode(Self.success(id: id, result: initializeResult()))
        case "ping":
            return Self.encode(Self.success(id: id, result: [:]))
        case "tools/list":
            return Self.encode(Self.success(id: id, result: ["tools": Self.toolDefinitions()]))
        case "tools/call":
            switch await callTool(message["params"] as? [String: Any]) {
            case .result(let result): return Self.encode(Self.success(id: id, result: result))
            case .failure(let code, let text): return Self.encode(Self.failure(id: id, code: code, message: text))
            }
        default:
            return Self.encode(Self.failure(id: id, code: JSONRPCCode.methodNotFound, message: MCPText.methodNotFound))
        }
    }

    // MARK: Protocol

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": MCPWire.protocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": MCPText.serverName, "version": serverVersion],
            "instructions": MCPText.instructions,
        ]
    }

    private enum Outcome {
        case result([String: Any])
        case failure(code: Int, message: String)
    }

    private func callTool(_ params: [String: Any]?) async -> Outcome {
        guard let params, let name = params["name"] as? String else {
            return .failure(code: JSONRPCCode.invalidParams, message: MCPText.invalidParams)
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case MCPText.searchTool: return await searchHistory(arguments)
        case MCPText.getItemTool: return await getItem(arguments)
        default: return .failure(code: JSONRPCCode.invalidParams, message: MCPText.unknownTool)
        }
    }

    // MARK: Tools

    private func searchHistory(_ arguments: [String: Any]) async -> Outcome {
        let query = arguments["query"] as? String ?? ""
        guard query.count <= Self.maxQueryCharacters else {
            return .failure(code: JSONRPCCode.invalidParams, message: MCPText.invalidParams)
        }
        var kind: ItemKind?
        if let raw = arguments["kind"] {
            guard let text = raw as? String, let parsed = ItemKind(rawValue: text) else {
                return .failure(code: JSONRPCCode.invalidParams, message: MCPText.invalidParams)
            }
            kind = parsed
        }
        var limit = ExposureLimits.defaultResults
        if let raw = arguments["limit"] {
            guard let value = raw as? Int, (1...ExposureLimits.maxResults).contains(value) else {
                return .failure(code: JSONRPCCode.invalidParams, message: MCPText.invalidParams)
            }
            limit = value
        }
        switch await database.exposedItems(
            matching: query, kind: kind, limit: limit, textLimit: ExposureLimits.previewCharacters)
        {
        case .success(let items):
            return .result(Self.toolResult(["count": items.count, "items": items.map(Self.json)]))
        case .failure(let error):
            FlotsamLog.log(error)
            return .result(Self.toolError(MCPText.readFailed))
        }
    }

    private func getItem(_ arguments: [String: Any]) async -> Outcome {
        guard let raw = arguments["id"] as? String, let id = UUID(uuidString: raw) else {
            return .failure(code: JSONRPCCode.invalidParams, message: MCPText.invalidParams)
        }
        switch await database.exposedItem(id: id, textLimit: ExposureLimits.fullTextCharacters) {
        case .success(let item?):
            return .result(Self.toolResult(["item": Self.json(item)]))
        case .success(nil):
            // A missing id and one the gate hides answer identically (FR-010-08).
            return .result(Self.toolError(MCPText.notFound))
        case .failure(let error):
            FlotsamLog.log(error)
            return .result(Self.toolError(MCPText.readFailed))
        }
    }

    private static let maxQueryCharacters = 500

    // MARK: Rendering

    private static func json(_ item: ExposedItem) -> [String: Any] {
        var object: [String: Any] = [
            "id": item.id.uuidString,
            "kind": item.kind.rawValue,
            "lastCopiedAt": item.lastCopiedAt.formatted(.iso8601),
            "copyCount": item.copyCount,
            "byteSize": item.byteSize,
            "tags": item.tags,
        ]
        if let text = item.text {
            object["text"] = text
            object["textTruncated"] = item.isTextTruncated
        }
        if let note = item.note, !note.isEmpty { object["note"] = note }
        if let source = item.sourceName, !source.isEmpty { object["source"] = source }
        if !item.fileNames.isEmpty { object["fileNames"] = item.fileNames }
        return object
    }

    /// An MCP tool result: the payload as one JSON text block.
    private static func toolResult(_ payload: [String: Any]) -> [String: Any] {
        let text = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? MCPText.readFailed
        return ["content": [["type": "text", "text": text]], "isError": false]
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private static func toolDefinitions() -> [[String: Any]] {
        let kinds = ItemKind.allCases.map(\.rawValue)
        return [
            [
                "name": MCPText.searchTool,
                "description": MCPText.searchDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": MCPText.queryDescription, "maxLength": maxQueryCharacters],
                        "kind": ["type": "string", "enum": kinds, "description": MCPText.kindDescription],
                        "limit": [
                            "type": "integer", "minimum": 1, "maximum": ExposureLimits.maxResults,
                            "default": ExposureLimits.defaultResults,
                        ],
                    ],
                ],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
            ],
            [
                "name": MCPText.getItemTool,
                "description": MCPText.getItemDescription,
                "inputSchema": [
                    "type": "object",
                    "properties": ["id": ["type": "string", "description": MCPText.idDescription]],
                    "required": ["id"],
                ],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
            ],
        ]
    }

    // MARK: JSON-RPC

    private enum JSONRPCCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
    }

    private static func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ object: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            return Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
        }
    }
}

/// The words Flotsam sends an MCP client. One home (FR-010-07); never shown in the app's own UI.
enum MCPText {
    static let serverName = "Flotsam"
    static let searchTool = "search_history"
    static let getItemTool = "get_item"
    static let instructions =
        "Read-only access to the user's Flotsam clipboard history. Secure items and items from apps the user ignores are never available."
    static let searchDescription =
        "Search the clipboard history, newest first. Returns text previews and metadata. Leave query empty to list the most recent items."
    static let getItemDescription = "Get one history item by id, with its text up to 20,000 characters."
    static let queryDescription = "Text to look for; matches the item's text, note, tags, source app and the file names it lists."
    static let kindDescription = "Only items of this kind."
    static let idDescription = "The id of an item, as returned by search_history."
    static let notFound = "No such item."
    static let readFailed = "Flotsam could not read its history."
    static let parseError = "Parse error"
    static let invalidRequest = "Invalid request"
    static let methodNotFound = "Method not found"
    static let invalidParams = "Invalid params"
    static let unknownTool = "Unknown tool"
}
