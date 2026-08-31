/// Closed content fitting policies independent of a rendering framework.
public enum PresentationContentFit: String, Codable, Sendable, Hashable {
    /// Fill the display while preserving aspect ratio and allowing crop.
    case fill

    /// Fit the whole image while preserving aspect ratio.
    case fit

    /// Fill the display without preserving the source aspect ratio.
    case stretch

    /// Keep the source at or below its native pixel size and center it.
    case center
}

/// Fixed-point coordinate in the inclusive range zero through ten thousand.
public struct NormalizedCoordinate: Codable, Sendable, Hashable {
    /// Fixed denominator used by normalized presentation coordinates.
    public static let denominator: UInt16 = 10_000

    /// Fixed-point numerator.
    public let rawValue: UInt16

    /// Creates a validated normalized coordinate.
    public init(rawValue: UInt16) throws {
        guard rawValue <= Self.denominator else {
            throw modelViolation(.invalidNumber, field: "normalizedCoordinate")
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates one integer coordinate.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(UInt16.self))
    }

    /// Encodes the coordinate as one integer.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private init(unchecked rawValue: UInt16) {
        self.rawValue = rawValue
    }

    package static let midpoint = NormalizedCoordinate(unchecked: 5_000)
}

/// Fixed-point focal point used for content cropping.
public struct NormalizedFocalPoint: Codable, Sendable, Hashable {
    /// Centered focal-point default.
    public static let center = NormalizedFocalPoint(
        x: .midpoint,
        y: .midpoint
    )

    /// Horizontal normalized coordinate.
    public let x: NormalizedCoordinate

    /// Vertical normalized coordinate.
    public let y: NormalizedCoordinate

    /// Creates a normalized focal point.
    public init(x: NormalizedCoordinate, y: NormalizedCoordinate) {
        self.x = x
        self.y = y
    }
}

/// User quality intent independent from concrete release tiers.
public enum PresentationQualityIntent: String, Codable, Sendable, Hashable {
    /// Let policy choose among available variants.
    case automatic

    /// Prefer reduced resource use.
    case efficiency

    /// Prefer visual quality.
    case quality
}

/// Closed response to Low Power Mode.
public enum PresentationLowPowerResponse: String, Codable, Sendable, Hashable {
    /// Continue using the selected quality intent.
    case `continue`

    /// Prefer an efficient variant while continuing.
    case reduceQuality = "reduce_quality"

    /// Pause playback while retaining the active preparation.
    case pause
}

/// Immutable presentation policy embedded in an assignment.
public struct PresentationPolicy: Codable, Sendable, Hashable {
    /// Content fitting policy.
    public let contentFit: PresentationContentFit

    /// Fixed-point focal point.
    public let focalPoint: NormalizedFocalPoint

    /// User quality intent.
    public let qualityIntent: PresentationQualityIntent

    /// Low-power response.
    public let lowPowerResponse: PresentationLowPowerResponse

    /// Creates a policy with useful centered, automatic, pause-on-low-power defaults.
    public init(
        contentFit: PresentationContentFit = .fill,
        focalPoint: NormalizedFocalPoint = .center,
        qualityIntent: PresentationQualityIntent = .automatic,
        lowPowerResponse: PresentationLowPowerResponse = .pause
    ) {
        self.contentFit = contentFit
        self.focalPoint = focalPoint
        self.qualityIntent = qualityIntent
        self.lowPowerResponse = lowPowerResponse
    }
}

/// Device-local assignment pinned directly to an immutable release.
public struct DeviceLocalPresentationAssignment: Codable, Sendable, Hashable {
    /// Logical record schema.
    public let schema: RecordSchemaVersion

    /// Stable assignment identity.
    public let id: PresentationAssignmentID

    /// Installation-local target display.
    public let displayIdentity: DisplayIdentity

    /// Immutable release pin.
    public let releaseID: AssetReleaseID

    /// Embedded presentation policy.
    public let policy: PresentationPolicy

    /// Creates a validated assignment.
    public init(
        schema: RecordSchemaVersion,
        id: PresentationAssignmentID,
        displayIdentity: DisplayIdentity,
        releaseID: AssetReleaseID,
        policy: PresentationPolicy
    ) throws {
        try schema.requireSupported(field: "presentationAssignment.schema")
        self.schema = schema
        self.id = id
        self.displayIdentity = displayIdentity
        self.releaseID = releaseID
        self.policy = policy
    }

    /// Decodes and validates an assignment.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            id: container.decode(PresentationAssignmentID.self, forKey: .id),
            displayIdentity: container.decode(DisplayIdentity.self, forKey: .displayIdentity),
            releaseID: container.decode(AssetReleaseID.self, forKey: .releaseID),
            policy: container.decode(PresentationPolicy.self, forKey: .policy)
        )
    }
}
