/// Open inert identifier for a renderer family.
public struct RendererID: Codable, Sendable, Hashable {
    /// Maximum encoded UTF-8 length.
    public static let maximumUTF8Length = openTagMaximumUTF8Length

    /// Validated lowercase namespaced tag.
    public let rawValue: String

    /// Creates a renderer tag without loading or resolving executable code.
    public init(_ rawValue: String) throws {
        try validateOpenTag(rawValue, field: "rendererID")
        self.rawValue = rawValue
    }

    /// WALI's native video renderer tag.
    public static let waliVideo = RendererID(unchecked: "wali.video")

    /// Decodes and validates a single tag string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    /// Encodes the tag as one string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Open inert identifier for a media type.
public struct MediaTypeID: Codable, Sendable, Hashable {
    /// Maximum encoded UTF-8 length.
    public static let maximumUTF8Length = openTagMaximumUTF8Length

    /// Validated lowercase namespaced tag.
    public let rawValue: String

    /// Creates a media-type tag.
    public init(_ rawValue: String) throws {
        try validateOpenTag(rawValue, field: "mediaTypeID")
        self.rawValue = rawValue
    }

    /// WALI's H.264 video media tag.
    public static let waliVideoH264 = MediaTypeID(unchecked: "wali.video.h264")

    /// WALI's HEVC video media tag.
    public static let waliVideoHEVC = MediaTypeID(unchecked: "wali.video.hevc")

    /// WALI's HEIC image media tag.
    public static let waliImageHEIC = MediaTypeID(unchecked: "wali.image.heic")

    /// Decodes and validates a single tag string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    /// Encodes the tag as one string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Open inert identifier for the role of an artifact within a variant.
public struct ArtifactRoleID: Codable, Sendable, Hashable {
    /// Maximum encoded UTF-8 length.
    public static let maximumUTF8Length = openTagMaximumUTF8Length

    /// Validated lowercase namespaced tag.
    public let rawValue: String

    /// Creates an artifact-role tag.
    public init(_ rawValue: String) throws {
        try validateOpenTag(rawValue, field: "artifactRoleID")
        self.rawValue = rawValue
    }

    /// WALI's primary playback role.
    public static let waliPlayback = ArtifactRoleID(unchecked: "wali.playback")

    /// WALI's poster role.
    public static let waliPoster = ArtifactRoleID(unchecked: "wali.poster")

    /// Decodes and validates a single tag string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    /// Encodes the tag as one string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Open inert identifier for a durable job kind.
public struct JobKindID: Codable, Sendable, Hashable {
    /// Maximum encoded UTF-8 length.
    public static let maximumUTF8Length = openTagMaximumUTF8Length

    /// Validated lowercase namespaced tag.
    public let rawValue: String

    /// Creates a job-kind tag.
    public init(_ rawValue: String) throws {
        try validateOpenTag(rawValue, field: "jobKindID")
        self.rawValue = rawValue
    }

    /// WALI's import job kind.
    public static let waliImport = JobKindID(unchecked: "wali.import")

    /// Decodes and validates a single tag string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    /// Encodes the tag as one string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Open inert identifier describing the source of a display alias.
public struct DisplayAliasKindID: Codable, Sendable, Hashable {
    /// Maximum encoded UTF-8 length.
    public static let maximumUTF8Length = openTagMaximumUTF8Length

    /// Validated lowercase namespaced tag.
    public let rawValue: String

    /// Creates an alias-kind tag.
    public init(_ rawValue: String) throws {
        try validateOpenTag(rawValue, field: "displayAliasKindID")
        self.rawValue = rawValue
    }

    /// WALI's EDID-derived alias kind.
    public static let waliEDID = DisplayAliasKindID(unchecked: "wali.edid")

    /// WALI's session-scoped alias kind.
    public static let waliSession = DisplayAliasKindID(unchecked: "wali.session")

    /// Decodes and validates a single tag string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    /// Encodes the tag as one string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Open inert reason for an automatic playback pause.
public struct AutomaticPauseReasonID: Codable, Sendable, Hashable {
    /// Maximum encoded UTF-8 length.
    public static let maximumUTF8Length = openTagMaximumUTF8Length

    /// Validated lowercase namespaced tag.
    public let rawValue: String

    /// Creates an automatic pause reason.
    public init(_ rawValue: String) throws {
        try validateOpenTag(rawValue, field: "automaticPauseReasonID")
        self.rawValue = rawValue
    }

    /// The current user session is locked.
    public static let sessionLocked = AutomaticPauseReasonID(unchecked: "wali.session-locked")

    /// The system is sleeping.
    public static let systemSleep = AutomaticPauseReasonID(unchecked: "wali.system-sleep")

    /// The assigned display is asleep.
    public static let displayAsleep = AutomaticPauseReasonID(unchecked: "wali.display-asleep")

    /// The wallpaper window is not visible.
    public static let windowOccluded = AutomaticPauseReasonID(unchecked: "wali.window-occluded")

    /// Low-power policy requests a pause.
    public static let lowPower = AutomaticPauseReasonID(unchecked: "wali.low-power")

    /// Thermal policy requests a pause.
    public static let thermalPressure = AutomaticPauseReasonID(unchecked: "wali.thermal-pressure")

    /// Decodes and validates a single tag string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    /// Encodes the tag as one string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }
}
