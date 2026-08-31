/// Immutable, renderer-neutral release manifest for one logical asset.
public struct AssetRelease: Codable, Sendable, Hashable {
    /// Logical record schema.
    public let schema: RecordSchemaVersion

    /// Stable release identity.
    public let id: AssetReleaseID

    /// Logical asset identity shared across editions.
    public let assetID: AssetID

    /// Positive immutable edition number.
    public let edition: UInt64

    /// Canonically ordered content-addressed artifacts.
    public let artifacts: [Artifact]

    /// Content identity of the contained poster artifact.
    public let posterArtifactID: ContentDigest

    /// Canonically ordered, nonempty variants.
    public let variants: [AssetVariant]

    /// Identity of the contained default variant.
    public let defaultVariantID: AssetVariantID

    /// Creates and cross-validates an immutable release.
    public init(
        schema: RecordSchemaVersion,
        id: AssetReleaseID,
        assetID: AssetID,
        edition: UInt64,
        artifacts: [Artifact],
        posterArtifactID: ContentDigest,
        variants: [AssetVariant],
        defaultVariantID: AssetVariantID
    ) throws {
        try schema.requireSupported(field: "assetRelease.schema")
        guard edition > 0 else {
            throw modelViolation(.invalidNumber, field: "assetRelease.edition")
        }
        guard !artifacts.isEmpty else {
            throw modelViolation(.emptyCollection, field: "assetRelease.artifacts")
        }
        guard !variants.isEmpty else {
            throw modelViolation(.emptyCollection, field: "assetRelease.variants")
        }

        var artifactsByID: [ContentDigest: Artifact] = [:]
        for artifact in artifacts {
            if let existing = artifactsByID[artifact.contentID] {
                let code: ModelViolation.Code =
                    existing == artifact ? .duplicateArtifactID : .conflictingArtifactMetadata
                throw modelViolation(code, field: "assetRelease.artifacts")
            }
            artifactsByID[artifact.contentID] = artifact
        }
        guard artifactsByID[posterArtifactID] != nil else {
            throw modelViolation(.missingReference, field: "assetRelease.posterArtifactID")
        }

        var variantIDs: Set<AssetVariantID> = []
        for variant in variants {
            guard variantIDs.insert(variant.id).inserted else {
                throw modelViolation(.duplicateVariantID, field: "assetRelease.variants")
            }
            for binding in variant.bindings where artifactsByID[binding.artifactID] == nil {
                throw modelViolation(.missingReference, field: "assetVariant.bindings")
            }
        }
        guard variantIDs.contains(defaultVariantID) else {
            throw modelViolation(.missingReference, field: "assetRelease.defaultVariantID")
        }

        self.schema = schema
        self.id = id
        self.assetID = assetID
        self.edition = edition
        self.artifacts = artifacts.sorted {
            if $0.contentID.algorithm.rawValue == $1.contentID.algorithm.rawValue {
                return $0.contentID.value < $1.contentID.value
            }
            return $0.contentID.algorithm.rawValue < $1.contentID.algorithm.rawValue
        }
        self.posterArtifactID = posterArtifactID
        self.variants = variants.sorted { $0.id.rawValue < $1.id.rawValue }
        self.defaultVariantID = defaultVariantID
    }

    /// Decodes and cross-validates an immutable release.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            id: container.decode(AssetReleaseID.self, forKey: .id),
            assetID: container.decode(AssetID.self, forKey: .assetID),
            edition: container.decode(UInt64.self, forKey: .edition),
            artifacts: container.decode([Artifact].self, forKey: .artifacts),
            posterArtifactID: container.decode(ContentDigest.self, forKey: .posterArtifactID),
            variants: container.decode([AssetVariant].self, forKey: .variants),
            defaultVariantID: container.decode(AssetVariantID.self, forKey: .defaultVariantID)
        )
    }
}
