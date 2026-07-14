import Foundation
import DesignerModel

/// F3 — Confluence-style version history, stored INSIDE the board package so
/// history travels with the file:
///
///     MyBoard.designerboard/
///     └── versions/
///         ├── index.json        [VersionMeta], newest first
///         ├── <id>.json         full board snapshot per version
///         └── <id>.png          optional thumbnail
///
/// The archive lives in memory on the document and serializes to a
/// FileWrapper alongside board.json — NSDocument's atomic save machinery
/// covers it. Boards without a versions/ directory load as an empty archive
/// (full back-compat both ways: old apps ignore the extra directory).
public struct VersionArchive {
    public static let directoryName = "versions"
    private static let indexFileName = "index.json"

    public struct VersionMeta: Codable, Identifiable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// User pressed "Save Version".
            case manual
            /// Captured automatically (before accepting an agent proposal,
            /// before restoring a version).
            case auto
        }

        public let id: UUID
        public var name: String
        public let createdAt: Date
        public let kind: Kind
        public let elementCount: Int

        public init(id: UUID = UUID(), name: String, createdAt: Date = Date().millisecondRounded,
                    kind: Kind, elementCount: Int) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
            self.kind = kind
            self.elementCount = elementCount
        }
    }

    /// Newest first — the order the panel shows.
    public private(set) var metas: [VersionMeta] = []
    private var boardData: [UUID: Data] = [:]
    private var thumbnailData: [UUID: Data] = [:]

    public init() {}

    public var isEmpty: Bool { metas.isEmpty }

    // MARK: Mutations

    @discardableResult
    public mutating func add(
        _ board: Board, name: String, kind: VersionMeta.Kind, thumbnail: Data? = nil
    ) throws -> VersionMeta {
        let meta = VersionMeta(name: name, kind: kind, elementCount: board.elements.count)
        boardData[meta.id] = try BoardSerialization.data(from: board)
        thumbnailData[meta.id] = thumbnail
        metas.insert(meta, at: 0)
        return meta
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let index = metas.firstIndex(where: { $0.id == id }) else { return }
        metas[index].name = name
    }

    public mutating func delete(_ id: UUID) {
        metas.removeAll { $0.id == id }
        boardData[id] = nil
        thumbnailData[id] = nil
    }

    /// Keeps at most `limit` automatic versions (manual ones never expire):
    /// the safety-net snapshots shouldn't grow the file without bound.
    public mutating func pruneAutoVersions(keeping limit: Int) {
        let autos = metas.filter { $0.kind == .auto }
        guard autos.count > limit else { return }
        for meta in autos.suffix(autos.count - limit) { delete(meta.id) }
    }

    // MARK: Reads

    public func board(for id: UUID) throws -> Board? {
        guard let data = boardData[id] else { return nil }
        return try BoardSerialization.board(from: data)
    }

    public func thumbnail(for id: UUID) -> Data? { thumbnailData[id] }

    // MARK: FileWrapper round trip

    public init(wrapper: FileWrapper?) {
        guard let children = wrapper?.fileWrappers else { return }
        guard let indexData = children[Self.indexFileName]?.regularFileContents,
              let index = try? JSONDecoder.versionArchive.decode([VersionMeta].self, from: indexData)
        else { return }
        var loaded: [VersionMeta] = []
        for meta in index {
            guard let data = children["\(meta.id.uuidString).json"]?.regularFileContents else { continue }
            boardData[meta.id] = data
            thumbnailData[meta.id] = children["\(meta.id.uuidString).png"]?.regularFileContents
            loaded.append(meta)
        }
        metas = loaded
    }

    public func fileWrapper() throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        let indexData = try JSONEncoder.versionArchive.encode(metas)
        children[Self.indexFileName] = FileWrapper(regularFileWithContents: indexData)
        for meta in metas {
            if let data = boardData[meta.id] {
                children["\(meta.id.uuidString).json"] = FileWrapper(regularFileWithContents: data)
            }
            if let thumb = thumbnailData[meta.id] {
                children["\(meta.id.uuidString).png"] = FileWrapper(regularFileWithContents: thumb)
            }
        }
        let wrapper = FileWrapper(directoryWithFileWrappers: children)
        wrapper.preferredFilename = Self.directoryName
        return wrapper
    }
}

private extension JSONEncoder {
    static var versionArchive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var versionArchive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
