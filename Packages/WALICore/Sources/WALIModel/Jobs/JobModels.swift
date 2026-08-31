/// Monotonic Engine revision accepted with a model intention.
public struct EngineRevision: Codable, Sendable, Hashable {
    /// Revision value; zero represents the initial Engine snapshot.
    public let rawValue: UInt64

    /// Creates an Engine revision.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Decodes one integer revision.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt64.self))
    }

    /// Encodes the revision as one integer.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Positive generation of one concrete import attempt.
public struct AttemptGeneration: Codable, Sendable, Hashable {
    /// Positive generation value.
    public let rawValue: UInt64

    /// Creates a positive attempt generation.
    public init(_ rawValue: UInt64) throws {
        guard rawValue > 0 else {
            throw modelViolation(
                .invalidGeneration,
                field: "attemptGeneration",
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

/// Durable marker proving cancellation was accepted at an Engine revision.
public struct CancellationMarker: Codable, Sendable, Hashable {
    /// Revision at which cancellation became linearized.
    public let acceptedRevision: EngineRevision

    /// Creates a cancellation marker.
    public init(acceptedRevision: EngineRevision) {
        self.acceptedRevision = acceptedRevision
    }
}

/// Closed durable-job phase tags.
public enum DurableJobPhase: String, Codable, Sendable, Hashable {
    /// No attempt has started.
    case pending

    /// Current attempt is created, dispatched, or awaiting cancellation completion.
    case attemptActive = "attempt_active"

    /// Current attempt ended without an installable success.
    case attemptTerminal = "attempt_terminal"

    /// Current attempt succeeded and may be installed.
    case awaitingInstallation = "awaiting_installation"

    /// Job has one immutable terminal outcome.
    case terminal
}

/// Write-once terminal outcome of a durable job.
public enum JobTerminalOutcome: String, Codable, Sendable, Hashable {
    /// Installation committed.
    case succeeded

    /// Cancellation crossed its durable linearization point.
    case cancelled

    /// Job failed permanently.
    case failed
}

/// Concrete durable-job header shared by the import aggregate.
public struct DurableJob: Codable, Sendable, Hashable {
    /// Logical record schema.
    public let schema: RecordSchemaVersion

    /// Stable job identity.
    public let id: JobID

    /// Open inert job-kind tag.
    public let kind: JobKindID

    /// Stable idempotency key for the originating intention.
    public let idempotencyKey: IdempotencyKey

    /// Engine revision expected by the originating intention.
    public let expectedEngineRevision: EngineRevision

    /// Durable lifecycle phase.
    public let phase: DurableJobPhase

    /// Current or most recently allocated attempt generation.
    public let attemptGeneration: AttemptGeneration?

    /// Persisted cancellation linearization marker.
    public let cancellationMarker: CancellationMarker?

    /// Write-once terminal job outcome.
    public let terminalOutcome: JobTerminalOutcome?

    /// Creates and validates a durable-job header.
    public init(
        schema: RecordSchemaVersion,
        id: JobID,
        kind: JobKindID,
        idempotencyKey: IdempotencyKey,
        expectedEngineRevision: EngineRevision,
        phase: DurableJobPhase,
        attemptGeneration: AttemptGeneration?,
        cancellationMarker: CancellationMarker?,
        terminalOutcome: JobTerminalOutcome?
    ) throws {
        try schema.requireSupported(field: "durableJob.schema")
        switch phase {
        case .pending:
            guard attemptGeneration == nil,
                  cancellationMarker == nil,
                  terminalOutcome == nil
            else {
                throw modelViolation(.invalidCombination, field: "durableJob.phase")
            }
        case .attemptActive, .attemptTerminal, .awaitingInstallation:
            guard attemptGeneration != nil,
                  cancellationMarker == nil,
                  terminalOutcome == nil
            else {
                throw modelViolation(.invalidCombination, field: "durableJob.attemptGeneration")
            }
        case .terminal:
            guard let terminalOutcome else {
                throw modelViolation(.invalidCombination, field: "durableJob.phase")
            }
            if terminalOutcome == .succeeded, attemptGeneration == nil {
                throw modelViolation(.invalidCombination, field: "durableJob.attemptGeneration")
            }
            if terminalOutcome == .cancelled {
                guard cancellationMarker != nil else {
                    throw modelViolation(.invalidCombination, field: "durableJob.cancellationMarker")
                }
            } else if cancellationMarker != nil {
                throw modelViolation(.invalidCombination, field: "durableJob.cancellationMarker")
            }
        }

        self.schema = schema
        self.id = id
        self.kind = kind
        self.idempotencyKey = idempotencyKey
        self.expectedEngineRevision = expectedEngineRevision
        self.phase = phase
        self.attemptGeneration = attemptGeneration
        self.cancellationMarker = cancellationMarker
        self.terminalOutcome = terminalOutcome
    }

    /// Decodes and validates a durable-job header.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            id: container.decode(JobID.self, forKey: .id),
            kind: container.decode(JobKindID.self, forKey: .kind),
            idempotencyKey: container.decode(IdempotencyKey.self, forKey: .idempotencyKey),
            expectedEngineRevision: container.decode(
                EngineRevision.self,
                forKey: .expectedEngineRevision
            ),
            phase: container.decode(DurableJobPhase.self, forKey: .phase),
            attemptGeneration: container.decodeIfPresent(
                AttemptGeneration.self,
                forKey: .attemptGeneration
            ),
            cancellationMarker: container.decodeIfPresent(
                CancellationMarker.self,
                forKey: .cancellationMarker
            ),
            terminalOutcome: container.decodeIfPresent(
                JobTerminalOutcome.self,
                forKey: .terminalOutcome
            )
        )
    }
}

/// Terminal outcome retained by an import attempt through cleanup.
public enum ImportAttemptTerminalKind: String, Codable, Sendable, Hashable {
    /// Worker work completed; output remains untrusted until later verification.
    case succeeded

    /// Worker acknowledged cancellation.
    case cancelled

    /// Worker work failed.
    case failed

    /// Connection loss or crash interrupted the attempt.
    case interrupted
}

/// Durable lifecycle of one concrete import attempt.
public enum ImportAttemptState: Codable, Sendable, Hashable {
    /// Durable intent exists but dispatch has not occurred.
    case created

    /// Worker dispatch occurred.
    case dispatched

    /// Durable cancellation marker was persisted.
    case cancellationRequested

    /// Worker attempt reached a terminal outcome.
    case terminal(ImportAttemptTerminalKind)

    /// Cleanup is durably pending while retaining the terminal outcome.
    case cleanupPending(ImportAttemptTerminalKind)

    /// Cleanup finished while retaining the terminal outcome.
    case cleaned(ImportAttemptTerminalKind)

    /// Retained terminal outcome, when present.
    public var terminalOutcome: ImportAttemptTerminalKind? {
        switch self {
        case .created, .dispatched, .cancellationRequested:
            nil
        case let .terminal(outcome), let .cleanupPending(outcome), let .cleaned(outcome):
            outcome
        }
    }

    package var permitsRetry: Bool {
        switch self {
        case .terminal, .cleaned:
            true
        case .created, .dispatched, .cancellationRequested, .cleanupPending:
            false
        }
    }

    /// Decodes a strict stable tagged attempt state.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        let outcome = try container.decodeIfPresent(
            ImportAttemptTerminalKind.self,
            forKey: .outcome
        )
        switch (tag, outcome) {
        case ("created", nil):
            self = .created
        case ("dispatched", nil):
            self = .dispatched
        case ("cancellation_requested", nil):
            self = .cancellationRequested
        case let ("terminal", outcome?):
            self = .terminal(outcome)
        case let ("cleanup_pending", outcome?):
            self = .cleanupPending(outcome)
        case let ("cleaned", outcome?):
            self = .cleaned(outcome)
        default:
            throw modelViolation(.invalidCombination, field: "importAttempt.state")
        }
    }

    /// Encodes a stable tagged attempt state.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .created:
            try container.encode("created", forKey: .tag)
        case .dispatched:
            try container.encode("dispatched", forKey: .tag)
        case .cancellationRequested:
            try container.encode("cancellation_requested", forKey: .tag)
        case let .terminal(outcome):
            try container.encode("terminal", forKey: .tag)
            try container.encode(outcome, forKey: .outcome)
        case let .cleanupPending(outcome):
            try container.encode("cleanup_pending", forKey: .tag)
            try container.encode(outcome, forKey: .outcome)
        case let .cleaned(outcome):
            try container.encode("cleaned", forKey: .tag)
            try container.encode(outcome, forKey: .outcome)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case outcome
    }
}

/// Immutable record of one import attempt.
public struct ImportAttempt: Codable, Sendable, Hashable {
    /// Owning job identity.
    public let jobID: JobID

    /// Positive monotonically increasing generation.
    public let generation: AttemptGeneration

    /// Durable attempt lifecycle.
    public let state: ImportAttemptState

    /// Creates an import attempt.
    public init(jobID: JobID, generation: AttemptGeneration, state: ImportAttemptState) {
        self.jobID = jobID
        self.generation = generation
        self.state = state
    }
}

/// IDs committed after a successful import installation.
public struct ImportResult: Codable, Sendable, Hashable {
    /// Installed library item.
    public let libraryItemID: LibraryItemID

    /// Installed immutable release.
    public let releaseID: AssetReleaseID

    /// Creates an import result containing only trusted committed identities.
    public init(libraryItemID: LibraryItemID, releaseID: AssetReleaseID) {
        self.libraryItemID = libraryItemID
        self.releaseID = releaseID
    }
}

/// Expected race disposition returned by the import-job reducer.
public enum ImportJobDisposition: String, Codable, Sendable, Hashable {
    /// Input changed durable model state.
    case applied

    /// Input exactly repeated an already represented transition.
    case duplicate

    /// Completion belongs to an older attempt and is cleanup-only.
    case staleCompletionCleanupOnly = "stale_completion_cleanup_only"

    /// Completion arrived after durable cancellation and is cleanup-only.
    case completionAfterCancellationCleanupOnly = "completion_after_cancellation_cleanup_only"
}

/// Inputs accepted by the concrete import-job reducer.
public enum ImportJobInput: Codable, Sendable, Hashable {
    /// Allocate the first or next attempt generation.
    case beginAttempt

    /// Mark one current generation as dispatched.
    case markDispatched(generation: AttemptGeneration)

    /// Persist cancellation at the accepted Engine revision.
    case requestCancellation(acceptedRevision: EngineRevision)

    /// Finish worker work for one generation.
    case finishAttempt(generation: AttemptGeneration, outcome: ImportAttemptTerminalKind)

    /// Record trusted installation commit for the current successful generation.
    case installationCommitted(generation: AttemptGeneration, result: ImportResult)

    /// Begin cleanup while retaining the attempt outcome.
    case beginCleanup(generation: AttemptGeneration)

    /// Finish cleanup while retaining the attempt outcome.
    case finishCleanup(generation: AttemptGeneration)

    /// Write a permanent job failure.
    case failPermanently

    /// Convert an in-flight attempt to interrupted after recovery.
    case recoverAfterCrash

    package var operationTag: String {
        switch self {
        case .beginAttempt:
            "begin_attempt"
        case .markDispatched:
            "mark_dispatched"
        case .requestCancellation:
            "request_cancellation"
        case .finishAttempt:
            "finish_attempt"
        case .installationCommitted:
            "installation_committed"
        case .beginCleanup:
            "begin_cleanup"
        case .finishCleanup:
            "finish_cleanup"
        case .failPermanently:
            "fail_permanently"
        case .recoverAfterCrash:
            "recover_after_crash"
        }
    }

    /// Decodes a strict stable tagged import-job input.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .tag)
        let generation = try container.decodeIfPresent(AttemptGeneration.self, forKey: .generation)
        let outcome = try container.decodeIfPresent(
            ImportAttemptTerminalKind.self,
            forKey: .outcome
        )
        let revision = try container.decodeIfPresent(EngineRevision.self, forKey: .acceptedRevision)
        let result = try container.decodeIfPresent(ImportResult.self, forKey: .result)

        switch (tag, generation, outcome, revision, result) {
        case ("begin_attempt", nil, nil, nil, nil):
            self = .beginAttempt
        case let ("mark_dispatched", generation?, nil, nil, nil):
            self = .markDispatched(generation: generation)
        case let ("request_cancellation", nil, nil, revision?, nil):
            self = .requestCancellation(acceptedRevision: revision)
        case let ("finish_attempt", generation?, outcome?, nil, nil):
            self = .finishAttempt(generation: generation, outcome: outcome)
        case let ("installation_committed", generation?, nil, nil, result?):
            self = .installationCommitted(generation: generation, result: result)
        case let ("begin_cleanup", generation?, nil, nil, nil):
            self = .beginCleanup(generation: generation)
        case let ("finish_cleanup", generation?, nil, nil, nil):
            self = .finishCleanup(generation: generation)
        case ("fail_permanently", nil, nil, nil, nil):
            self = .failPermanently
        case ("recover_after_crash", nil, nil, nil, nil):
            self = .recoverAfterCrash
        default:
            throw modelViolation(.invalidCombination, field: "importJobInput")
        }
    }

    /// Encodes a stable tagged import-job input.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationTag, forKey: .tag)
        switch self {
        case .beginAttempt, .failPermanently, .recoverAfterCrash:
            break
        case let .markDispatched(generation),
             let .beginCleanup(generation),
             let .finishCleanup(generation):
            try container.encode(generation, forKey: .generation)
        case let .requestCancellation(revision):
            try container.encode(revision, forKey: .acceptedRevision)
        case let .finishAttempt(generation, outcome):
            try container.encode(generation, forKey: .generation)
            try container.encode(outcome, forKey: .outcome)
        case let .installationCommitted(generation, result):
            try container.encode(generation, forKey: .generation)
            try container.encode(result, forKey: .result)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case generation
        case outcome
        case acceptedRevision
        case result
    }
}

/// Immutable result returned by the import-job reducer.
public struct ImportJobTransition: Codable, Sendable, Hashable {
    /// Resulting aggregate.
    public let state: ImportJob

    /// Applied or expected-race disposition.
    public let disposition: ImportJobDisposition

    /// Creates an import-job transition.
    public init(state: ImportJob, disposition: ImportJobDisposition) {
        self.state = state
        self.disposition = disposition
    }
}
