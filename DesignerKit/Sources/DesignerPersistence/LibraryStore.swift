import Foundation
import DesignerModel

/// Metadata for one reusable library entry. The clip payload (a `Board`)
/// lives beside it in the same package.
public struct LibraryEntry: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var tags: [String]
    public var createdAt: Date
    public var modifiedAt: Date
    /// Element count of the clip — cheap to show without loading the payload.
    public var elementCount: Int

    public init(
        id: UUID = UUID(),
        name: String,
        tags: [String] = [],
        createdAt: Date = Date().millisecondRounded,
        modifiedAt: Date? = nil,
        elementCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.tags = tags
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.elementCount = elementCount
    }
}

extension LibraryEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, tags, createdAt, modifiedAt, elementCount
    }
}

/// A folder-backed library (D10): the root is any user-chosen directory, so
/// it can live inside iCloud/Dropbox/a git repo for free. Each entry is a
/// package directory:
///
///     <root>/<uuid>.designerclip/
///     ├── entry.json      metadata
///     ├── board.json      the clip payload (canonical board JSON)
///     └── thumbnail.png   optional preview
public final class LibraryStore {
    public static let packageExtension = "designerclip"
    private static let entryFileName = "entry.json"
    private static let boardFileName = "board.json"
    private static let thumbnailFileName = "thumbnail.png"

    public let rootURL: URL
    private let fileManager = FileManager.default

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// The default library location under Application Support.
    public static func defaultRootURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return base.appendingPathComponent("Designer/Library", isDirectory: true)
    }

    public func ensureRootExists() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: Listing

    /// All entries, newest first. Skips unreadable packages rather than
    /// failing the whole listing (NFR R4).
    public func list() throws -> [LibraryEntry] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let packages = try fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == Self.packageExtension }

        let decoder = CanonicalJSON.makeDecoder()
        var entries: [LibraryEntry] = []
        for package in packages {
            let entryURL = package.appendingPathComponent(Self.entryFileName)
            guard let data = try? Data(contentsOf: entryURL),
                  let entry = try? decoder.decode(LibraryEntry.self, from: data) else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Entries whose name or tags match `query` (case-insensitive substring).
    public func search(_ query: String) throws -> [LibraryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return try list() }
        return try list().filter { entry in
            entry.name.lowercased().contains(trimmed)
                || entry.tags.contains { $0.lowercased().contains(trimmed) }
        }
    }

    // MARK: CRUD

    /// Saves a clip and its metadata atomically. Returns the stored entry
    /// (with element count filled in).
    @discardableResult
    public func save(_ board: Board, as entry: LibraryEntry, thumbnailPNG: Data? = nil) throws -> LibraryEntry {
        try ensureRootExists()
        var entry = entry
        entry.elementCount = board.elements.count
        entry.modifiedAt = Date().millisecondRounded

        let encoder = CanonicalJSON.makeEncoder()
        let entryData = try encoder.encode(entry)
        let boardData = try BoardSerialization.data(from: board)

        let destination = packageURL(for: entry.id)
        let staging = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: rootURL, create: true
        )
        defer { try? fileManager.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
        try entryData.write(to: staged.appendingPathComponent(Self.entryFileName))
        try boardData.write(to: staged.appendingPathComponent(Self.boardFileName))
        if let thumbnailPNG {
            try thumbnailPNG.write(to: staged.appendingPathComponent(Self.thumbnailFileName))
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        return entry
    }

    /// Loads a clip's payload board.
    public func loadBoard(_ id: UUID) throws -> Board {
        let boardURL = packageURL(for: id).appendingPathComponent(Self.boardFileName)
        return try BoardSerialization.board(from: try Data(contentsOf: boardURL))
    }

    public func loadThumbnail(_ id: UUID) -> Data? {
        try? Data(contentsOf: packageURL(for: id).appendingPathComponent(Self.thumbnailFileName))
    }

    /// Updates metadata (rename, retag) without touching the payload.
    public func update(_ entry: LibraryEntry) throws {
        let entryURL = packageURL(for: entry.id).appendingPathComponent(Self.entryFileName)
        guard fileManager.fileExists(atPath: entryURL.path) else {
            throw LibraryError.entryNotFound(entry.id)
        }
        var updated = entry
        updated.modifiedAt = Date().millisecondRounded
        try CanonicalJSON.makeEncoder().encode(updated).write(to: entryURL, options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        let package = packageURL(for: id)
        if fileManager.fileExists(atPath: package.path) {
            try fileManager.removeItem(at: package)
        }
    }

    // MARK: Helpers

    private func packageURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent("\(id.uuidString).\(Self.packageExtension)", isDirectory: true)
    }
}

public enum LibraryError: Error, LocalizedError {
    case entryNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .entryNotFound(let id): return "No library entry with id \(id)."
        }
    }
}
