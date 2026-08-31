/// Concrete durable import aggregate with ordered attempts and an optional committed result.
public struct ImportJob: Codable, Sendable, Hashable {
    /// Maximum retained attempts in one logical record.
    public static let maximumAttemptCount = 1_024

    /// Logical aggregate schema.
    public let schema: RecordSchemaVersion

    /// Durable job header.
    public let header: DurableJob

    /// Immutable generation-ordered attempt history.
    public let attempts: [ImportAttempt]

    /// Trusted identities committed only after installation succeeds.
    public let committedResult: ImportResult?

    /// Creates and validates a complete import aggregate.
    public init(
        schema: RecordSchemaVersion,
        header: DurableJob,
        attempts: [ImportAttempt],
        committedResult: ImportResult?
    ) throws {
        try schema.requireSupported(field: "importJob.schema")
        guard header.schema == schema else {
            throw modelViolation(.invalidCombination, field: "importJob.header.schema")
        }
        guard header.kind == .waliImport else {
            throw modelViolation(.invalidCombination, field: "importJob.header.kind")
        }
        guard attempts.count <= Self.maximumAttemptCount else {
            throw modelViolation(.invalidNumber, field: "importJob.attempts")
        }

        for (index, attempt) in attempts.enumerated() {
            guard attempt.jobID == header.id else {
                throw modelViolation(.invalidCombination, field: "importJob.attempt.jobID")
            }
            let expected = UInt64(index) + 1
            guard attempt.generation.rawValue == expected else {
                throw modelViolation(
                    .invalidCombination,
                    field: "importJob.attempt.generation",
                    generation: attempt.generation.rawValue,
                    expectedGeneration: expected
                )
            }
            if index < attempts.count - 1, attempt.state.terminalOutcome == nil {
                throw modelViolation(.invalidCombination, field: "importJob.attempt.order")
            }
        }

        if let last = attempts.last {
            guard header.attemptGeneration == last.generation else {
                throw modelViolation(.invalidCombination, field: "importJob.header.attemptGeneration")
            }
        } else if header.attemptGeneration != nil {
            throw modelViolation(.invalidCombination, field: "importJob.header.attemptGeneration")
        }

        if committedResult != nil, header.terminalOutcome != .succeeded {
            throw modelViolation(.invalidCombination, field: "importJob.committedResult")
        }
        if header.terminalOutcome == .succeeded, committedResult == nil {
            throw modelViolation(.invalidCombination, field: "importJob.committedResult")
        }
        if header.cancellationMarker != nil, committedResult != nil {
            throw modelViolation(.invalidCombination, field: "importJob.cancellationMarker")
        }

        try Self.validatePhase(header: header, attempts: attempts)
        self.schema = schema
        self.header = header
        self.attempts = attempts
        self.committedResult = committedResult
    }

    /// Creates an initial pending import job without generating IDs or revisions.
    public static func pending(
        id: JobID,
        idempotencyKey: IdempotencyKey,
        expectedEngineRevision: EngineRevision
    ) throws -> ImportJob {
        let header = try DurableJob(
            schema: .current,
            id: id,
            kind: .waliImport,
            idempotencyKey: idempotencyKey,
            expectedEngineRevision: expectedEngineRevision,
            phase: .pending,
            attemptGeneration: nil,
            cancellationMarker: nil,
            terminalOutcome: nil
        )
        return try ImportJob(
            schema: .current,
            header: header,
            attempts: [],
            committedResult: nil
        )
    }

    /// Decodes and validates a complete import aggregate.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schema: container.decode(RecordSchemaVersion.self, forKey: .schema),
            header: container.decode(DurableJob.self, forKey: .header),
            attempts: container.decode([ImportAttempt].self, forKey: .attempts),
            committedResult: container.decodeIfPresent(
                ImportResult.self,
                forKey: .committedResult
            )
        )
    }

    private static func validatePhase(
        header: DurableJob,
        attempts: [ImportAttempt]
    ) throws {
        if header.terminalOutcome != nil {
            guard header.phase == .terminal else {
                throw modelViolation(.invalidCombination, field: "importJob.header.phase")
            }
            if header.terminalOutcome == .succeeded {
                guard attempts.last?.state.terminalOutcome == .succeeded else {
                    throw modelViolation(.invalidCombination, field: "importJob.attempt.state")
                }
            }
            if header.terminalOutcome == .cancelled,
               let state = attempts.last?.state {
                switch state {
                case .created, .dispatched:
                    throw modelViolation(.invalidCombination, field: "importJob.attempt.state")
                case .cancellationRequested, .terminal, .cleanupPending, .cleaned:
                    break
                }
            }
            return
        }

        guard let state = attempts.last?.state else {
            guard header.phase == .pending else {
                throw modelViolation(.invalidCombination, field: "importJob.header.phase")
            }
            return
        }

        let expectedPhase: DurableJobPhase
        switch state {
        case .created, .dispatched:
            expectedPhase = .attemptActive
        case .cancellationRequested:
            throw modelViolation(.invalidCombination, field: "importJob.cancellationMarker")
        case .terminal(.succeeded):
            expectedPhase = .awaitingInstallation
        case .terminal, .cleanupPending, .cleaned:
            expectedPhase = .attemptTerminal
        }
        guard header.phase == expectedPhase else {
            throw modelViolation(.invalidCombination, field: "importJob.header.phase")
        }
    }
}
