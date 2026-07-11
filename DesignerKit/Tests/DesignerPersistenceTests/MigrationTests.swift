import XCTest
import DesignerModel
@testable import DesignerPersistence

final class MigrationTests: XCTestCase {
    /// Simulates opening a v1 file in a future app whose schema renamed a
    /// field — proves the migration chain runs, bumps versions, and the
    /// result decodes. (At schema v1 the standard migrator is empty; this
    /// exercises the machinery itself.)
    func testMigrationChainRunsAndBumpsVersion() throws {
        var tree = try JSONDecoder().decode(
            JSONValue.self,
            from: try BoardSerialization.data(from: Fixtures.sampleBoard())
        )
        tree["schemaVersion"] = .int(0)
        tree["legacyTitle"] = tree["title"]
        tree["title"] = nil

        let migrator = Migrator(migrations: [
            Migration(fromVersion: 0) { tree in
                var tree = tree
                tree["title"] = tree["legacyTitle"] ?? .string("Untitled")
                if var object = tree.objectValue {
                    object.removeValue(forKey: "legacyTitle")
                    tree = .object(object)
                }
                return tree
            }
        ])

        let data = try JSONEncoder().encode(tree)
        let board = try BoardSerialization.board(from: data, migrator: migrator)
        XCTAssertEqual(board.title, "Sample System")
        XCTAssertEqual(board.schemaVersion, Board.currentSchemaVersion)
    }

    func testMissingMigrationIsAnExplicitError() throws {
        var tree = try JSONDecoder().decode(
            JSONValue.self,
            from: try BoardSerialization.data(from: Fixtures.sampleBoard())
        )
        tree["schemaVersion"] = .int(0)
        let data = try JSONEncoder().encode(tree)

        XCTAssertThrowsError(try BoardSerialization.board(from: data, migrator: .standard)) { error in
            XCTAssertEqual(error as? BoardSerializationError, .missingMigration(from: 0))
        }
    }

    func testNewerVersionIsRejectedWithClearMessage() throws {
        var tree = try JSONDecoder().decode(
            JSONValue.self,
            from: try BoardSerialization.data(from: Fixtures.sampleBoard())
        )
        tree["schemaVersion"] = .int(99)
        let data = try JSONEncoder().encode(tree)

        XCTAssertThrowsError(try BoardSerialization.board(from: data)) { error in
            XCTAssertEqual(
                error as? BoardSerializationError,
                .unsupportedVersion(found: 99, supported: Board.currentSchemaVersion)
            )
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }
}
