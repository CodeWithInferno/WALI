/// Installation-local display identity.
public struct DisplayIdentity: Codable, Sendable, Hashable {
    /// Installation that owns the local identifier.
    public let deviceID: DeviceInstallationID

    /// Display identity meaningful only within the installation.
    public let localID: LocalDisplayID

    /// Creates an installation-local display identity.
    public init(deviceID: DeviceInstallationID, localID: LocalDisplayID) {
        self.deviceID = deviceID
        self.localID = localID
    }
}

/// Lifetime over which a display alias may be treated as stable.
public enum DisplayAliasLifetime: String, Codable, Sendable, Hashable {
    /// Valid only for one login or observation session.
    case session

    /// Valid only within one WALI installation.
    case installation

    /// Derived from hardware identity expected to survive installation changes.
    case hardware
}

/// Canonical inert alias used as evidence during later display reconciliation.
public struct DisplayAlias: Codable, Sendable, Hashable {
    /// Maximum fingerprint length measured in UTF-8 bytes.
    public static let maximumFingerprintUTF8Length = fingerprintMaximumUTF8Length

    /// Open alias-kind tag.
    public let kind: DisplayAliasKindID

    /// Normalized lowercase ASCII fingerprint.
    public let fingerprint: String

    /// Declared alias lifetime.
    public let lifetime: DisplayAliasLifetime

    /// Creates a validated display alias.
    public init(
        kind: DisplayAliasKindID,
        fingerprint: String,
        lifetime: DisplayAliasLifetime
    ) throws {
        try validateFingerprint(fingerprint, field: "displayAlias.fingerprint")
        self.kind = kind
        self.fingerprint = fingerprint
        self.lifetime = lifetime
    }

    /// Decodes and validates a display alias.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(DisplayAliasKindID.self, forKey: .kind),
            fingerprint: container.decode(String.self, forKey: .fingerprint),
            lifetime: container.decode(DisplayAliasLifetime.self, forKey: .lifetime)
        )
    }
}

/// Persistable device-local display record.
public struct DisplayRecord: Codable, Sendable, Hashable {
    /// Maximum aliases accepted in one encoded record.
    public static let maximumAliasCount = 16

    /// Maximum user-label length measured in UTF-8 bytes.
    public static let maximumUserLabelUTF8Length = 80

    /// Logical record schema.
    public let schema: RecordSchemaVersion

    /// Installation-local identity.
    public let identity: DisplayIdentity

    /// Nonempty, deduplicated, canonically ordered aliases.
    public let aliases: [DisplayAlias]

    /// Optional bounded nonblank label.
    public let userLabel: String?

    /// Creates a validated display record.
    public init(
        schema: RecordSchemaVersion,
        identity: DisplayIdentity,
        aliases: [DisplayAlias],
        userLabel: String?
    ) throws {
        try schema.requireSupported(field: "displayRecord.schema")
        guard !aliases.isEmpty else {
            throw modelViolation(.emptyCollection, field: "displayRecord.aliases")
        }
        guard aliases.count <= Self.maximumAliasCount else {
            throw modelViolation(.invalidNumber, field: "displayRecord.aliases")
        }
        if let userLabel {
            try validateBoundedNonblankText(
                userLabel,
                maximumUTF8Length: Self.maximumUserLabelUTF8Length,
                field: "displayRecord.userLabel"
            )
        }

        var seen: Set<DisplayAlias> = []
        var deduplicated: [DisplayAlias] = []
        for alias in aliases where seen.insert(alias).inserted {
            deduplicated.append(alias)
        }
        deduplicated.sort {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            if $0.fingerprint != $1.fingerprint {
                return $0.fingerprint < $1.fingerprint
            }
            return $0.lifetime.rawValue < $1.lifetime.rawValue
        }

        self.schema = schema
        self.identity = identity
        self.aliases = deduplicated
        self.userLabel = userLabel
    }

    /// Decodes, validates, deduplicates, and canonicalizes a display record.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            identity: container.decode(DisplayIdentity.self, forKey: .identity),
            aliases: container.decode([DisplayAlias].self, forKey: .aliases),
            userLabel: container.decodeIfPresent(String.self, forKey: .userLabel)
        )
    }
}

/// Confidence attached to one computed display match, never to a stored alias.
public enum DisplayMatchConfidence: String, Codable, Sendable, Hashable {
    /// All required stable evidence matched.
    case exact

    /// Strong but not complete evidence matched.
    case high

    /// Evidence is sufficient only for tentative policy.
    case tentative

    /// Multiple records remain equally plausible.
    case ambiguous
}

/// One candidate result produced by later display reconciliation.
public struct DisplayMatchCandidate: Codable, Sendable, Hashable {
    /// Candidate display identity.
    public let identity: DisplayIdentity

    /// Confidence for this particular match.
    public let confidence: DisplayMatchConfidence

    /// Creates a display match candidate.
    public init(identity: DisplayIdentity, confidence: DisplayMatchConfidence) {
        self.identity = identity
        self.confidence = confidence
    }
}
