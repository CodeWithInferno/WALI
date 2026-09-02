/// Initial closed set of library-item origins.
public enum LibraryItemOrigin: String, Codable, Sendable, Hashable {
    /// Imported from media explicitly chosen by the user.
    case localImport = "local_import"

    /// Shipped as part of the WALI product.
    case bundled

    /// Installed from an immutable signed WALI catalog release.
    case catalog
}

/// Immutable provenance captured when a signed catalog release is installed.
///
/// This snapshot contains no network location or mutable authorization. It is
/// sufficient to explain who published the item and which signed manifest was
/// trusted while keeping local playback independent from the marketplace.
public struct CatalogLibraryOriginSnapshot: Codable, Sendable, Hashable {
    public static let maximumCreatorNameUTF8Length = 160
    public static let maximumCreatorHandleUTF8Length = 64
    public static let maximumAttributionUTF8Length = 1_000
    public static let maximumRightsHolderUTF8Length = 160

    public let schema: RecordSchemaVersion
    public let wallpaperID: String
    public let releaseID: String
    public let edition: UInt64
    public let creatorName: String
    public let creatorHandle: String
    public let attributionText: String?
    public let rightsHolder: String
    public let manifestDigest: ContentDigest

    public init(
        schema: RecordSchemaVersion = .current,
        wallpaperID: String,
        releaseID: String,
        edition: UInt64,
        creatorName: String,
        creatorHandle: String,
        attributionText: String?,
        rightsHolder: String,
        manifestDigest: ContentDigest
    ) throws {
        try schema.requireSupported(field: "catalogOrigin.schema")
        guard Self.isCanonicalUUID(wallpaperID),
              Self.isCanonicalUUID(releaseID),
              (1...2_147_483_647).contains(edition)
        else {
            throw modelViolation(.invalidIdentifier, field: "catalogOrigin")
        }
        try validateBoundedNonblankText(
            creatorName,
            maximumUTF8Length: Self.maximumCreatorNameUTF8Length,
            field: "catalogOrigin.creatorName"
        )
        try validateBoundedNonblankText(
            creatorHandle,
            maximumUTF8Length: Self.maximumCreatorHandleUTF8Length,
            field: "catalogOrigin.creatorHandle"
        )
        if let attributionText {
            try validateBoundedNonblankText(
                attributionText,
                maximumUTF8Length: Self.maximumAttributionUTF8Length,
                field: "catalogOrigin.attributionText"
            )
        }
        try validateBoundedNonblankText(
            rightsHolder,
            maximumUTF8Length: Self.maximumRightsHolderUTF8Length,
            field: "catalogOrigin.rightsHolder"
        )
        self.schema = schema
        self.wallpaperID = wallpaperID
        self.releaseID = releaseID
        self.edition = edition
        self.creatorName = creatorName
        self.creatorHandle = creatorHandle
        self.attributionText = attributionText
        self.rightsHolder = rightsHolder
        self.manifestDigest = manifestDigest
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: values.decode(RecordSchemaVersion.self, forKey: .schema),
            wallpaperID: values.decode(String.self, forKey: .wallpaperID),
            releaseID: values.decode(String.self, forKey: .releaseID),
            edition: values.decode(UInt64.self, forKey: .edition),
            creatorName: values.decode(String.self, forKey: .creatorName),
            creatorHandle: values.decode(String.self, forKey: .creatorHandle),
            attributionText: values.decodeIfPresent(String.self, forKey: .attributionText),
            rightsHolder: values.decode(String.self, forKey: .rightsHolder),
            manifestDigest: values.decode(ContentDigest.self, forKey: .manifestDigest)
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        let hyphens = Set([8, 13, 18, 23])
        return bytes.indices.allSatisfy { index in
            if hyphens.contains(index) { return bytes[index] == 45 }
            return (48...57).contains(bytes[index]) || (97...102).contains(bytes[index])
        }
    }
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

    /// Present only for signed catalog-origin items.
    public let catalogOrigin: CatalogLibraryOriginSnapshot?

    /// Creates a validated immutable library snapshot.
    public init(
        schema: RecordSchemaVersion,
        id: LibraryItemID,
        releaseID: AssetReleaseID,
        displayName: String,
        origin: LibraryItemOrigin,
        catalogOrigin: CatalogLibraryOriginSnapshot? = nil
    ) throws {
        try schema.requireSupported(field: "libraryItem.schema")
        try validateBoundedNonblankText(
            displayName,
            maximumUTF8Length: Self.maximumDisplayNameUTF8Length,
            field: "libraryItem.displayName"
        )
        guard (origin == .catalog) == (catalogOrigin != nil) else {
            throw modelViolation(.invalidCombination, field: "libraryItem.catalogOrigin")
        }
        self.schema = schema
        self.id = id
        self.releaseID = releaseID
        self.displayName = displayName
        self.origin = origin
        self.catalogOrigin = catalogOrigin
    }

    /// Returns a replacement snapshot with the same identity and release.
    public func renamed(to displayName: String) throws -> LibraryItem {
        try LibraryItem(
            schema: schema,
            id: id,
            releaseID: releaseID,
            displayName: displayName,
            origin: origin,
            catalogOrigin: catalogOrigin
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
            origin: container.decode(LibraryItemOrigin.self, forKey: .origin),
            catalogOrigin: container.decodeIfPresent(
                CatalogLibraryOriginSnapshot.self,
                forKey: .catalogOrigin
            )
        )
    }
}
