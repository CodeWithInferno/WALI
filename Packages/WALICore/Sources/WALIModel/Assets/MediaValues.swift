/// Positive integral pixel dimensions.
public struct PixelSize: Codable, Sendable, Hashable {
    /// Width in pixels.
    public let width: UInt32

    /// Height in pixels.
    public let height: UInt32

    /// Creates positive pixel dimensions.
    public init(width: UInt32, height: UInt32) throws {
        guard width > 0, height > 0 else {
            throw modelViolation(.invalidNumber, field: "pixelSize")
        }
        self.width = width
        self.height = height
    }

    /// Decodes and validates pixel dimensions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: container.decode(UInt32.self, forKey: .width),
            height: container.decode(UInt32.self, forKey: .height)
        )
    }
}

/// Exact non-floating-point rational media value.
public struct MediaRational: Codable, Sendable, Hashable {
    /// Unsigned numerator.
    public let numerator: UInt64

    /// Positive denominator.
    public let denominator: UInt64

    /// Creates an exact rational value.
    public init(numerator: UInt64, denominator: UInt64) throws {
        guard denominator > 0 else {
            throw modelViolation(.invalidNumber, field: "mediaRational")
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Decodes and validates a rational value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            numerator: container.decode(UInt64.self, forKey: .numerator),
            denominator: container.decode(UInt64.self, forKey: .denominator)
        )
    }
}

/// Closed dynamic-range classes used by immutable media metadata.
public enum MediaDynamicRange: String, Codable, Sendable, Hashable {
    /// Standard dynamic range.
    case sdr

    /// High dynamic range without naming a framework-specific transfer function.
    case hdr
}

/// Closed quality tiers available in an immutable release.
public enum QualityTier: String, Codable, Sendable, Hashable {
    /// Small preview-oriented representation.
    case preview

    /// Balanced default representation.
    case balanced

    /// Highest available quality representation.
    case high
}

/// Exact, transport-neutral media characteristics.
public struct MediaCharacteristics: Codable, Sendable, Hashable {
    /// Integral pixel dimensions.
    public let pixelSize: PixelSize

    /// Optional exact duration in seconds.
    public let duration: MediaRational?

    /// Optional exact frame rate.
    public let frameRate: MediaRational?

    /// Optional positive bit depth.
    public let bitDepth: UInt16?

    /// Optional dynamic-range classification.
    public let dynamicRange: MediaDynamicRange?

    /// Creates validated media characteristics.
    public init(
        pixelSize: PixelSize,
        duration: MediaRational? = nil,
        frameRate: MediaRational? = nil,
        bitDepth: UInt16? = nil,
        dynamicRange: MediaDynamicRange? = nil
    ) throws {
        if let duration, duration.numerator == 0 {
            throw modelViolation(.invalidNumber, field: "mediaDuration")
        }
        if let frameRate, frameRate.numerator == 0 {
            throw modelViolation(.invalidNumber, field: "mediaFrameRate")
        }
        if let bitDepth, bitDepth == 0 || bitDepth > 64 {
            throw modelViolation(.invalidNumber, field: "mediaBitDepth")
        }
        self.pixelSize = pixelSize
        self.duration = duration
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.dynamicRange = dynamicRange
    }

    /// Decodes and validates media characteristics.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pixelSize: container.decode(PixelSize.self, forKey: .pixelSize),
            duration: container.decodeIfPresent(MediaRational.self, forKey: .duration),
            frameRate: container.decodeIfPresent(MediaRational.self, forKey: .frameRate),
            bitDepth: container.decodeIfPresent(UInt16.self, forKey: .bitDepth),
            dynamicRange: container.decodeIfPresent(MediaDynamicRange.self, forKey: .dynamicRange)
        )
    }
}
