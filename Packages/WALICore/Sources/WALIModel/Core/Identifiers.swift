/// Stable identity of a logical asset across immutable releases.
public struct AssetID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates an asset identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "assetID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Stable identity of an immutable asset release.
public struct AssetReleaseID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates a release identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "assetReleaseID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Stable identity of one release variant.
public struct AssetVariantID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates a variant identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "assetVariantID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Stable identity of a user-visible library snapshot.
public struct LibraryItemID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates a library-item identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "libraryItemID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Stable identity of one WALI installation on a device.
public struct DeviceInstallationID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates an installation identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "deviceInstallationID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Installation-local identity of a display record.
public struct LocalDisplayID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates a local display identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "localDisplayID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Stable identity of a device-local presentation assignment.
public struct PresentationAssignmentID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates an assignment identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "presentationAssignmentID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Stable identity of a durable job.
public struct JobID: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates a job identifier from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "jobID")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

/// Stable key used to collapse repeated job intentions.
public struct IdempotencyKey: Codable, Sendable, Hashable {
    /// Canonical lowercase UUID string.
    public let rawValue: String

    /// Creates an idempotency key from a canonical lowercase UUID string.
    public init(_ rawValue: String) throws {
        try validateCanonicalUUIDString(rawValue, field: "idempotencyKey")
        self.rawValue = rawValue
    }

    /// Decodes and validates a single canonical string.
    public init(from decoder: any Decoder) throws {
        try self.init(decodeString(from: decoder))
    }

    /// Encodes the identifier as one canonical string.
    public func encode(to encoder: any Encoder) throws {
        try encodeString(rawValue, to: encoder)
    }
}

private func decodeString(from decoder: any Decoder) throws -> String {
    let container = try decoder.singleValueContainer()
    return try container.decode(String.self)
}

private func encodeString(_ value: String, to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
}
