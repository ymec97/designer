import Foundation
import DesignerModel

/// Transforms a raw document tree from `fromVersion` to `fromVersion + 1`.
/// Migrations run on the untyped JSON tree *before* typed decoding, so old
/// files never need old model types to stay openable (NFR R2).
public struct Migration: Sendable {
    public let fromVersion: Int
    public let transform: @Sendable (JSONValue) throws -> JSONValue

    public init(fromVersion: Int, transform: @escaping @Sendable (JSONValue) throws -> JSONValue) {
        self.fromVersion = fromVersion
        self.transform = transform
    }
}

public struct Migrator: Sendable {
    /// Migrations for shipped schema versions. Empty at v1; every future
    /// schema bump adds exactly one entry here plus a fixture test.
    public static let standard = Migrator(migrations: [])

    private let migrations: [Int: Migration]

    public init(migrations: [Migration]) {
        self.migrations = Dictionary(uniqueKeysWithValues: migrations.map { ($0.fromVersion, $0) })
    }

    /// Runs the chain from `version` up to `targetVersion`, bumping the tree's
    /// `schemaVersion` field at each step.
    public func migrate(_ tree: JSONValue, from version: Int, to targetVersion: Int) throws -> JSONValue {
        var tree = tree
        var version = version
        while version < targetVersion {
            guard let migration = migrations[version] else {
                throw BoardSerializationError.missingMigration(from: version)
            }
            tree = try migration.transform(tree)
            tree["schemaVersion"] = .int(Int64(version + 1))
            version += 1
        }
        return tree
    }
}
