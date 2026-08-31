/// Positive generation used to reject stale asynchronous playback callbacks.
public struct PlaybackGeneration: Codable, Sendable, Hashable {
    /// Positive generation value.
    public let rawValue: UInt64

    /// Creates a positive playback generation.
    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else {
            throw modelViolation(
                .invalidGeneration,
                field: "playbackGeneration",
                generation: rawValue
            )
        }
        self.rawValue = rawValue
    }

    /// Decodes and validates one integer generation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(UInt64.self))
    }

    /// Encodes the generation as one integer.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Immutable release and variant selected for playback preparation.
public struct PlaybackSelection: Codable, Sendable, Hashable {
    /// Selected immutable release.
    public let releaseID: AssetReleaseID

    /// Selected variant within the release.
    public let variantID: AssetVariantID

    /// Creates a playback selection.
    public init(releaseID: AssetReleaseID, variantID: AssetVariantID) {
        self.releaseID = releaseID
        self.variantID = variantID
    }
}

/// Prepared playback candidate that may be active or awaiting commit.
public struct PreparedPlayback: Codable, Sendable, Hashable {
    /// Generation that produced the preparation.
    public let generation: PlaybackGeneration

    /// Immutable release and variant selection.
    public let selection: PlaybackSelection

    /// Creates prepared playback state.
    public init(generation: PlaybackGeneration, selection: PlaybackSelection) {
        self.generation = generation
        self.selection = selection
    }
}

/// Replacement preparation lifecycle, separate from active playback.
public enum ReplacementPreparation: Codable, Sendable, Hashable {
    /// Replacement was requested but adapter work has not started.
    case requested(generation: PlaybackGeneration, selection: PlaybackSelection)

    /// Adapter preparation has started.
    case preparing(generation: PlaybackGeneration, selection: PlaybackSelection)

    /// Adapter reports ready; explicit commit is still required.
    case ready(PreparedPlayback)

    /// Generation associated with this replacement.
    public var generation: PlaybackGeneration {
        switch self {
        case let .requested(generation, _), let .preparing(generation, _):
            generation
        case let .ready(playback):
            playback.generation
        }
    }

    /// Selection associated with this replacement.
    public var selection: PlaybackSelection {
        switch self {
        case let .requested(_, selection), let .preparing(_, selection):
            selection
        case let .ready(playback):
            playback.selection
        }
    }

    /// Decodes a stable tagged replacement lifecycle value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        guard let generation = try container.decodeIfPresent(
            PlaybackGeneration.self,
            forKey: .generation
        ), let selection = try container.decodeIfPresent(
            PlaybackSelection.self,
            forKey: .selection
        ) else {
            throw modelViolation(.invalidCombination, field: "replacementPreparation")
        }
        switch tag {
        case "requested":
            self = .requested(generation: generation, selection: selection)
        case "preparing":
            self = .preparing(generation: generation, selection: selection)
        case "ready":
            self = .ready(PreparedPlayback(generation: generation, selection: selection))
        default:
            throw modelViolation(.invalidCombination, field: "replacementPreparation.tag")
        }
    }

    /// Encodes a stable tagged replacement lifecycle value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .requested(generation, selection):
            try container.encode("requested", forKey: .tag)
            try container.encode(generation, forKey: .generation)
            try container.encode(selection, forKey: .selection)
        case let .preparing(generation, selection):
            try container.encode("preparing", forKey: .tag)
            try container.encode(generation, forKey: .generation)
            try container.encode(selection, forKey: .selection)
        case let .ready(playback):
            try container.encode("ready", forKey: .tag)
            try container.encode(playback.generation, forKey: .generation)
            try container.encode(playback.selection, forKey: .selection)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case generation
        case selection
    }
}

/// Scope of a current-generation playback preparation failure.
public enum PlaybackFailureScope: String, Codable, Sendable, Hashable {
    /// No active playback exists, so the failure blocks effective playback.
    case blocking

    /// An older active playback remains available.
    case replacementOnly = "replacement_only"
}

/// Current-generation preparation failure.
public struct PlaybackFailure: Codable, Sendable, Hashable {
    /// Failed generation.
    public let generation: PlaybackGeneration

    /// Whether an older active playback remains available.
    public let scope: PlaybackFailureScope

    /// Creates playback failure state.
    public init(generation: PlaybackGeneration, scope: PlaybackFailureScope) {
        self.generation = generation
        self.scope = scope
    }
}

/// Effective playback mode derived from orthogonal state axes.
public enum PlaybackEffectiveMode: String, Codable, Sendable, Hashable {
    /// Playback is not desired.
    case stopped

    /// No active preparation exists and current preparation failed.
    case blockingFailure = "blocking_failure"

    /// No active playback exists yet.
    case preparing

    /// User pause takes precedence over automatic pause reasons.
    case userPaused = "user_paused"

    /// At least one automatic pause reason is present.
    case automaticallyPaused = "automatically_paused"

    /// Active prepared playback may run.
    case playing
}

/// Derived replacement status exposed independently from effective mode.
public enum PlaybackReplacementStatus: Codable, Sendable, Hashable {
    /// No replacement is pending and no replacement-only failure is current.
    case none

    /// Replacement is requested.
    case requested(PlaybackGeneration)

    /// Replacement preparation is active.
    case preparing(PlaybackGeneration)

    /// Replacement is ready for explicit commit.
    case ready(PlaybackGeneration)

    /// Replacement failed while an older active playback remains available.
    case failed(PlaybackGeneration)

    /// Decodes a stable tagged replacement status.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        let generation = try container.decodeIfPresent(PlaybackGeneration.self, forKey: .generation)
        switch (tag, generation) {
        case ("none", nil):
            self = .none
        case let ("requested", generation?):
            self = .requested(generation)
        case let ("preparing", generation?):
            self = .preparing(generation)
        case let ("ready", generation?):
            self = .ready(generation)
        case let ("failed", generation?):
            self = .failed(generation)
        default:
            throw modelViolation(.invalidCombination, field: "playbackReplacementStatus")
        }
    }

    /// Encodes a stable tagged replacement status.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .tag)
        case let .requested(generation):
            try container.encode("requested", forKey: .tag)
            try container.encode(generation, forKey: .generation)
        case let .preparing(generation):
            try container.encode("preparing", forKey: .tag)
            try container.encode(generation, forKey: .generation)
        case let .ready(generation):
            try container.encode("ready", forKey: .tag)
            try container.encode(generation, forKey: .generation)
        case let .failed(generation):
            try container.encode("failed", forKey: .tag)
            try container.encode(generation, forKey: .generation)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case generation
    }
}

/// Immutable playback reducer state.
public struct PlaybackState: Codable, Sendable, Hashable {
    /// Maximum automatic pause reasons in one logical record.
    public static let maximumAutomaticPauseReasonCount = 32

    /// Logical record schema.
    public let schema: RecordSchemaVersion

    /// Whether playback is desired at all.
    public let desiredRunning: Bool

    /// Independent user pause axis.
    public let userPaused: Bool

    /// Canonically ordered semantic set of automatic pause reasons.
    public let automaticPauseReasons: [AutomaticPauseReasonID]

    /// Selected quality tier.
    public let selectedQuality: QualityTier

    /// Active prepared playback, retained while replacements prepare or fail.
    public let activePlayback: PreparedPlayback?

    /// Optional replacement lifecycle.
    public let replacementPreparation: ReplacementPreparation?

    /// Optional current-generation failure.
    public let failure: PlaybackFailure?

    /// Effective mode derived using the documented precedence.
    public var effectiveMode: PlaybackEffectiveMode {
        if !desiredRunning {
            return .stopped
        }
        if failure?.scope == .blocking {
            return .blockingFailure
        }
        guard activePlayback != nil else {
            return .preparing
        }
        if userPaused {
            return .userPaused
        }
        if !automaticPauseReasons.isEmpty {
            return .automaticallyPaused
        }
        return .playing
    }

    /// Replacement status independent from effective playback mode.
    public var replacementStatus: PlaybackReplacementStatus {
        switch replacementPreparation {
        case let .requested(generation, _):
            return .requested(generation)
        case let .preparing(generation, _):
            return .preparing(generation)
        case let .ready(playback):
            return .ready(playback.generation)
        case nil:
            if let failure, failure.scope == .replacementOnly {
                return .failed(failure.generation)
            }
            return .none
        }
    }

    /// Creates validated playback state and canonicalizes pause reasons.
    public init(
        schema: RecordSchemaVersion,
        desiredRunning: Bool,
        userPaused: Bool,
        automaticPauseReasons: [AutomaticPauseReasonID],
        selectedQuality: QualityTier,
        activePlayback: PreparedPlayback?,
        replacementPreparation: ReplacementPreparation?,
        failure: PlaybackFailure?
    ) throws {
        try self.init(
            schema: schema,
            desiredRunning: desiredRunning,
            userPaused: userPaused,
            automaticPauseReasons: automaticPauseReasons,
            selectedQuality: selectedQuality,
            activePlayback: activePlayback,
            replacementPreparation: replacementPreparation,
            failure: failure,
            rejectDuplicateReasons: false
        )
    }

    /// Decodes, validates, and rejects duplicate elements in the encoded semantic set.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            desiredRunning: container.decode(Bool.self, forKey: .desiredRunning),
            userPaused: container.decode(Bool.self, forKey: .userPaused),
            automaticPauseReasons: container.decode(
                [AutomaticPauseReasonID].self,
                forKey: .automaticPauseReasons
            ),
            selectedQuality: container.decode(QualityTier.self, forKey: .selectedQuality),
            activePlayback: container.decodeIfPresent(
                PreparedPlayback.self,
                forKey: .activePlayback
            ),
            replacementPreparation: container.decodeIfPresent(
                ReplacementPreparation.self,
                forKey: .replacementPreparation
            ),
            failure: container.decodeIfPresent(PlaybackFailure.self, forKey: .failure),
            rejectDuplicateReasons: true
        )
    }

    /// Encodes pause reasons in canonical order.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(desiredRunning, forKey: .desiredRunning)
        try container.encode(userPaused, forKey: .userPaused)
        try container.encode(automaticPauseReasons, forKey: .automaticPauseReasons)
        try container.encode(selectedQuality, forKey: .selectedQuality)
        try container.encodeIfPresent(activePlayback, forKey: .activePlayback)
        try container.encodeIfPresent(replacementPreparation, forKey: .replacementPreparation)
        try container.encodeIfPresent(failure, forKey: .failure)
    }

    package var latestGeneration: PlaybackGeneration? {
        let values = [
            activePlayback?.generation,
            replacementPreparation?.generation,
            failure?.generation
        ].compactMap { $0 }
        return values.max { $0.rawValue < $1.rawValue }
    }

    private init(
        schema: RecordSchemaVersion,
        desiredRunning: Bool,
        userPaused: Bool,
        automaticPauseReasons: [AutomaticPauseReasonID],
        selectedQuality: QualityTier,
        activePlayback: PreparedPlayback?,
        replacementPreparation: ReplacementPreparation?,
        failure: PlaybackFailure?,
        rejectDuplicateReasons: Bool
    ) throws {
        try schema.requireSupported(field: "playbackState.schema")
        guard automaticPauseReasons.count <= Self.maximumAutomaticPauseReasonCount else {
            throw modelViolation(.invalidNumber, field: "playbackState.automaticPauseReasons")
        }

        var seen: Set<AutomaticPauseReasonID> = []
        for reason in automaticPauseReasons {
            if !seen.insert(reason).inserted, rejectDuplicateReasons {
                throw modelViolation(
                    .duplicateEncodedElement,
                    field: "playbackState.automaticPauseReasons"
                )
            }
        }
        if replacementPreparation != nil, failure != nil {
            throw modelViolation(.invalidCombination, field: "playbackState.replacementFailure")
        }
        if let failure {
            let expectedScope: PlaybackFailureScope =
                activePlayback == nil ? .blocking : .replacementOnly
            guard failure.scope == expectedScope else {
                throw modelViolation(.invalidCombination, field: "playbackState.failure.scope")
            }
        }
        if let activePlayback, let replacementPreparation {
            guard replacementPreparation.generation.rawValue == activePlayback.generation.rawValue + 1
            else {
                throw modelViolation(
                    .invalidCombination,
                    field: "playbackState.replacementPreparation"
                )
            }
        }

        self.schema = schema
        self.desiredRunning = desiredRunning
        self.userPaused = userPaused
        self.automaticPauseReasons = seen.sorted { $0.rawValue < $1.rawValue }
        self.selectedQuality = selectedQuality
        self.activePlayback = activePlayback
        self.replacementPreparation = replacementPreparation
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case desiredRunning
        case userPaused
        case automaticPauseReasons
        case selectedQuality
        case activePlayback
        case replacementPreparation
        case failure
    }
}

/// Inputs accepted by the pure playback reducer.
public enum PlaybackInput: Codable, Sendable, Hashable {
    /// Begin a replacement at the exact next generation.
    case beginReplacement(generation: PlaybackGeneration, selection: PlaybackSelection)

    /// Record that adapter preparation started.
    case preparationStarted(generation: PlaybackGeneration)

    /// Record that preparation is ready but not yet active.
    case preparationReady(generation: PlaybackGeneration)

    /// Commit a ready replacement after the first-frame gate.
    case commitReplacement(generation: PlaybackGeneration)

    /// Record a failed replacement preparation.
    case preparationFailed(generation: PlaybackGeneration)

    /// Change whether playback is desired.
    case setDesiredRunning(Bool)

    /// Change the independent user pause axis.
    case setUserPause(Bool)

    /// Insert or remove one automatic pause reason.
    case setAutomaticReason(AutomaticPauseReasonID, present: Bool)

    package var operationTag: String {
        switch self {
        case .beginReplacement:
            "begin_replacement"
        case .preparationStarted:
            "preparation_started"
        case .preparationReady:
            "preparation_ready"
        case .commitReplacement:
            "commit_replacement"
        case .preparationFailed:
            "preparation_failed"
        case .setDesiredRunning:
            "set_desired_running"
        case .setUserPause:
            "set_user_pause"
        case .setAutomaticReason:
            "set_automatic_reason"
        }
    }

    /// Decodes a stable tagged reducer input.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        let generation = try container.decodeIfPresent(PlaybackGeneration.self, forKey: .generation)
        let selection = try container.decodeIfPresent(PlaybackSelection.self, forKey: .selection)
        let value = try container.decodeIfPresent(Bool.self, forKey: .value)
        let reason = try container.decodeIfPresent(AutomaticPauseReasonID.self, forKey: .reason)
        let present = try container.decodeIfPresent(Bool.self, forKey: .present)

        switch (tag, generation, selection, value, reason, present) {
        case let ("begin_replacement", generation?, selection?, nil, nil, nil):
            self = .beginReplacement(generation: generation, selection: selection)
        case let ("preparation_started", generation?, nil, nil, nil, nil):
            self = .preparationStarted(generation: generation)
        case let ("preparation_ready", generation?, nil, nil, nil, nil):
            self = .preparationReady(generation: generation)
        case let ("commit_replacement", generation?, nil, nil, nil, nil):
            self = .commitReplacement(generation: generation)
        case let ("preparation_failed", generation?, nil, nil, nil, nil):
            self = .preparationFailed(generation: generation)
        case let ("set_desired_running", nil, nil, value?, nil, nil):
            self = .setDesiredRunning(value)
        case let ("set_user_pause", nil, nil, value?, nil, nil):
            self = .setUserPause(value)
        case let ("set_automatic_reason", nil, nil, nil, reason?, present?):
            self = .setAutomaticReason(reason, present: present)
        default:
            throw modelViolation(.invalidCombination, field: "playbackInput")
        }
    }

    /// Encodes a stable tagged reducer input.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationTag, forKey: .tag)
        switch self {
        case let .beginReplacement(generation, selection):
            try container.encode(generation, forKey: .generation)
            try container.encode(selection, forKey: .selection)
        case let .preparationStarted(generation),
             let .preparationReady(generation),
             let .commitReplacement(generation),
             let .preparationFailed(generation):
            try container.encode(generation, forKey: .generation)
        case let .setDesiredRunning(value), let .setUserPause(value):
            try container.encode(value, forKey: .value)
        case let .setAutomaticReason(reason, present):
            try container.encode(reason, forKey: .reason)
            try container.encode(present, forKey: .present)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case generation
        case selection
        case value
        case reason
        case present
    }
}

/// Expected playback reducer disposition.
public enum PlaybackInputDisposition: String, Codable, Sendable, Hashable {
    /// Input changed state.
    case applied

    /// Input exactly repeated an already represented event or value.
    case duplicate

    /// Asynchronous callback belongs to an older generation.
    case stale
}

/// Immutable result returned by the playback reducer.
public struct PlaybackTransition: Codable, Sendable, Hashable {
    /// Resulting state.
    public let state: PlaybackState

    /// Expected race disposition.
    public let disposition: PlaybackInputDisposition

    /// Creates a playback transition result.
    public init(state: PlaybackState, disposition: PlaybackInputDisposition) {
        self.state = state
        self.disposition = disposition
    }
}
