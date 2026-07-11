import Foundation
import DesignerModel

/// Errors are deliberately specific: malformed input must always produce a
/// precise, user-presentable message, never a crash or silent partial load (NFR R4).
public enum BoardSerializationError: Error, LocalizedError, Equatable {
    case notJSON(detail: String)
    case notABoardDocument(detail: String)
    case missingSchemaVersion
    case unsupportedVersion(found: Int, supported: Int)
    case missingMigration(from: Int)
    case decodingFailed(detail: String)

    public var errorDescription: String? {
        switch self {
        case .notJSON(let detail):
            return "The file is not valid JSON: \(detail)"
        case .notABoardDocument(let detail):
            return "The file is valid JSON but not a board document: \(detail)"
        case .missingSchemaVersion:
            return "The document has no 'schemaVersion' field."
        case .unsupportedVersion(let found, let supported):
            return "The document uses schema version \(found), but this app supports up to version \(supported). Update the app to open it."
        case .missingMigration(let from):
            return "No migration is registered from schema version \(from). This is an app bug."
        case .decodingFailed(let detail):
            return "The document could not be read: \(detail)"
        }
    }
}

public enum BoardSerialization {
    /// Board → canonical JSON bytes.
    public static func data(from board: Board) throws -> Data {
        var board = board
        board.schemaVersion = Board.currentSchemaVersion
        return try CanonicalJSON.makeEncoder().encode(board)
    }

    /// JSON bytes → Board, migrating older schema versions on the way in.
    public static func board(from data: Data, migrator: Migrator = .standard) throws -> Board {
        let tree: JSONValue
        do {
            tree = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw BoardSerializationError.notJSON(detail: shortDescription(of: error))
        }

        guard tree.objectValue != nil else {
            throw BoardSerializationError.notABoardDocument(detail: "top-level value is not an object")
        }
        guard let versionValue = tree["schemaVersion"] else {
            throw BoardSerializationError.missingSchemaVersion
        }
        guard let version = versionValue.intValue.map(Int.init) else {
            throw BoardSerializationError.notABoardDocument(detail: "'schemaVersion' is not an integer")
        }
        guard version <= Board.currentSchemaVersion else {
            throw BoardSerializationError.unsupportedVersion(
                found: version, supported: Board.currentSchemaVersion
            )
        }

        var migratedData = data
        if version < Board.currentSchemaVersion {
            let migrated = try migrator.migrate(tree, from: version, to: Board.currentSchemaVersion)
            migratedData = try CanonicalJSON.makeEncoder().encode(migrated)
        }

        do {
            return try CanonicalJSON.makeDecoder().decode(Board.self, from: migratedData)
        } catch let error as DecodingError {
            throw BoardSerializationError.decodingFailed(detail: describe(error))
        } catch {
            throw BoardSerializationError.decodingFailed(detail: shortDescription(of: error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map(\.stringValue).joined(separator: ".")
            return joined.isEmpty ? "(root)" : joined
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing required field '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(_, let context):
            return "wrong type at \(path(context)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "null where a value is required at \(path(context))"
        case .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func shortDescription(of error: Error) -> String {
        (error as NSError).localizedDescription
    }
}
