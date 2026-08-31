/// Immutable metadata for one content-addressed artifact.
public struct Artifact: Codable, Sendable, Hashable {
    /// Logical record schema.
    public let schema: RecordSchemaVersion

    /// Agent-verifiable content identity.
    public let contentID: ContentDigest

    /// Positive encoded byte count.
    public let byteCount: UInt64

    /// Inert media-type tag.
    public let mediaType: MediaTypeID

    /// Exact media characteristics.
    public let characteristics: MediaCharacteristics

    /// Creates validated immutable artifact metadata.
    public init(
        schema: RecordSchemaVersion,
        contentID: ContentDigest,
        byteCount: UInt64,
        mediaType: MediaTypeID,
        characteristics: MediaCharacteristics
    ) throws {
        try schema.requireSupported(field: "artifact.schema")
        guard byteCount > 0 else {
            throw modelViolation(.invalidNumber, field: "artifact.byteCount")
        }
        self.schema = schema
        self.contentID = contentID
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.characteristics = characteristics
    }

    /// Decodes and validates artifact metadata.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            contentID: container.decode(ContentDigest.self, forKey: .contentID),
            byteCount: container.decode(UInt64.self, forKey: .byteCount),
            mediaType: container.decode(MediaTypeID.self, forKey: .mediaType),
            characteristics: container.decode(MediaCharacteristics.self, forKey: .characteristics)
        )
    }
}

/// Inert renderer requirement for an asset variant.
public struct RendererRequirement: Codable, Sendable, Hashable {
    /// Required renderer family.
    public let rendererID: RendererID

    /// Creates a renderer requirement.
    public init(rendererID: RendererID) {
        self.rendererID = rendererID
    }
}

/// A role-to-artifact reference within one asset variant.
public struct ArtifactBinding: Codable, Sendable, Hashable {
    /// Semantic role of the artifact.
    public let role: ArtifactRoleID

    /// Referenced content identity.
    public let artifactID: ContentDigest

    /// Creates an artifact binding.
    public init(role: ArtifactRoleID, artifactID: ContentDigest) {
        self.role = role
        self.artifactID = artifactID
    }
}

/// Renderer-neutral selection of bound artifacts at one quality tier.
public struct AssetVariant: Codable, Sendable, Hashable {
    /// Stable variant identity.
    public let id: AssetVariantID

    /// Variant quality tier.
    public let qualityTier: QualityTier

    /// Inert renderer requirement.
    public let rendererRequirement: RendererRequirement

    /// Canonically ordered role bindings.
    public let bindings: [ArtifactBinding]

    /// Creates a validated variant.
    public init(
        id: AssetVariantID,
        qualityTier: QualityTier,
        rendererRequirement: RendererRequirement,
        bindings: [ArtifactBinding]
    ) throws {
        guard !bindings.isEmpty else {
            throw modelViolation(.emptyCollection, field: "assetVariant.bindings")
        }
        var seenRoles: Set<ArtifactRoleID> = []
        for binding in bindings {
            guard seenRoles.insert(binding.role).inserted else {
                throw modelViolation(.duplicateArtifactRole, field: "assetVariant.bindings")
            }
        }
        self.id = id
        self.qualityTier = qualityTier
        self.rendererRequirement = rendererRequirement
        self.bindings = bindings.sorted {
            if $0.role.rawValue == $1.role.rawValue {
                return $0.artifactID.value < $1.artifactID.value
            }
            return $0.role.rawValue < $1.role.rawValue
        }
    }

    /// Decodes and validates a variant.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(AssetVariantID.self, forKey: .id),
            qualityTier: container.decode(QualityTier.self, forKey: .qualityTier),
            rendererRequirement: container.decode(
                RendererRequirement.self,
                forKey: .rendererRequirement
            ),
            bindings: container.decode([ArtifactBinding].self, forKey: .bindings)
        )
    }
}
