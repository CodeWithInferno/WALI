/// Initial closed set of library-item origins.
public enum LibraryItemOrigin: String, Codable, Sendable, Hashable {
    /// Imported from media explicitly chosen by the user.
    case localImport = "local_import"

    /// Shipped as part of the WALI product.
    case bundled
}

/// Immutable user-facing library snapshot pinned to one release.
public struct LibraryItem: Codable, Sendable, Hashable {
    /// Maximum display-name length measured in UTF-8 bytes.
    public static let maximumDisplayNameUTF8Length = 160

    /// Logical record schema.
    public let schema: RecordSchemaVersion

    /// Stable library-item identity.
    public let id: LibraryItemID

    /// Immutable release selected by this snapshot.
    public let releaseID: AssetReleaseID

    /// Bounded nonblank user-facing name.
    public let displayName: String

    /// Closed origin classification.
    public let origin: LibraryItemOrigin

    /// Creates a validated immutable library snapshot.
    public init(
        schema: RecordSchemaVersion,
        id: LibraryItemID,
        releaseID: AssetReleaseID,
        displayName: String,
        origin: LibraryItemOrigin
    ) throws {
        try schema.requireSupported(field: "libraryItem.schema")
        try validateBoundedNonblankText(
            displayName,
            maximumUTF8Length: Self.maximumDisplayNameUTF8Length,
            field: "libraryItem.displayName"
        )
        self.schema = schema
        self.id = id
        self.releaseID = releaseID
        self.displayName = displayName
        self.origin = origin
    }

    /// Returns a replacement snapshot with the same identity and release.
    public func renamed(to displayName: String) throws -> LibraryItem {
        try LibraryItem(
            schema: schema,
            id: id,
            releaseID: releaseID,
            displayName: displayName,
            origin: origin
        )
    }

    /// Decodes and validates a library snapshot.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            id: container.decode(LibraryItemID.self, forKey: .id),
            releaseID: container.decode(AssetReleaseID.self, forKey: .releaseID),
            displayName: container.decode(String.self, forKey: .displayName),
            origin: container.decode(LibraryItemOrigin.self, forKey: .origin)
        )
    }
}
