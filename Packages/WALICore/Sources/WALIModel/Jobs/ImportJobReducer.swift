/// Pure package-scoped reducer for concrete durable import jobs.
package enum ImportJobReducer {
    /// Applies one import-job input or returns an expected race disposition.
    package static func reduce(
        _ job: ImportJob,
        _ input: ImportJobInput
    ) throws -> ImportJobTransition {
        switch input {
        case .beginAttempt:
            return try beginAttempt(job)
        case let .markDispatched(generation):
            return try markDispatched(job, generation: generation)
        case let .requestCancellation(acceptedRevision):
            return try requestCancellation(job, acceptedRevision: acceptedRevision)
        case let .finishAttempt(generation, outcome):
            return try finishAttempt(job, generation: generation, outcome: outcome)
        case let .installationCommitted(generation, result):
            return try installationCommitted(job, generation: generation, result: result)
        case let .beginCleanup(generation):
            return try beginCleanup(job, generation: generation)
        case let .finishCleanup(generation):
            return try finishCleanup(job, generation: generation)
        case .failPermanently:
            return try failPermanently(job)
        case .recoverAfterCrash:
            return try recoverAfterCrash(job)
        }
    }

    private static func beginAttempt(_ job: ImportJob) throws -> ImportJobTransition {
        try requireNonterminal(job, input: .beginAttempt)
        if let last = job.attempts.last, !last.state.permitsRetry {
            throw violation(
                .invalidTransition,
                field: "importJob.attempt.state",
                input: .beginAttempt,
                generation: last.generation
            )
        }
        guard job.attempts.count < ImportJob.maximumAttemptCount,
              job.attempts.count < Int.max
        else {
            throw modelViolation(.invalidNumber, field: "importJob.attempts")
        }

        let rawGeneration = UInt64(job.attempts.count) + 1
        let generation = try AttemptGeneration(rawGeneration)
        var attempts = job.attempts
        attempts.append(
            ImportAttempt(jobID: job.header.id, generation: generation, state: .created)
        )
        let header = try makeHeader(
            job,
            phase: .attemptActive,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: nil
        )
        return try transition(
            job,
            header: header,
            attempts: attempts,
            committedResult: nil,
            disposition: .applied
        )
    }

    private static func markDispatched(
        _ job: ImportJob,
        generation: AttemptGeneration
    ) throws -> ImportJobTransition {
        try requireNonterminal(job, input: .markDispatched(generation: generation))
        let index = try currentAttemptIndex(
            job,
            generation: generation,
            input: .markDispatched(generation: generation)
        )
        switch job.attempts[index].state {
        case .created:
            var attempts = job.attempts
            attempts[index] = ImportAttempt(
                jobID: job.header.id,
                generation: generation,
                state: .dispatched
            )
            return try transition(
                job,
                header: job.header,
                attempts: attempts,
                committedResult: job.committedResult,
                disposition: .applied
            )
        case .dispatched:
            return ImportJobTransition(state: job, disposition: .duplicate)
        case .cancellationRequested, .terminal, .cleanupPending, .cleaned:
            throw violation(
                .invalidTransition,
                field: "importJob.attempt.state",
                input: .markDispatched(generation: generation),
                generation: generation
            )
        }
    }

    private static func requestCancellation(
        _ job: ImportJob,
        acceptedRevision: EngineRevision
    ) throws -> ImportJobTransition {
        if let terminal = job.header.terminalOutcome {
            if terminal == .cancelled,
               job.header.cancellationMarker?.acceptedRevision == acceptedRevision {
                return ImportJobTransition(state: job, disposition: .duplicate)
            }
            throw terminalViolation(job, input: .requestCancellation(acceptedRevision: acceptedRevision))
        }

        let marker = CancellationMarker(acceptedRevision: acceptedRevision)
        var attempts = job.attempts
        if let index = attempts.indices.last {
            let attempt = attempts[index]
            switch attempt.state {
            case .created, .dispatched:
                attempts[index] = ImportAttempt(
                    jobID: attempt.jobID,
                    generation: attempt.generation,
                    state: .cancellationRequested
                )
            case .cancellationRequested:
                break
            case .terminal, .cleanupPending, .cleaned:
                break
            }
        }

        let header = try makeHeader(
            job,
            phase: .terminal,
            attemptGeneration: job.header.attemptGeneration,
            cancellationMarker: marker,
            terminalOutcome: .cancelled
        )
        return try transition(
            job,
            header: header,
            attempts: attempts,
            committedResult: nil,
            disposition: .applied
        )
    }

    private static func finishAttempt(
        _ job: ImportJob,
        generation: AttemptGeneration,
        outcome: ImportAttemptTerminalKind
    ) throws -> ImportJobTransition {
        guard let latest = job.attempts.last?.generation else {
            throw violation(
                .futureGeneration,
                field: "importJob.attempt.generation",
                input: .finishAttempt(generation: generation, outcome: outcome),
                generation: generation,
                expected: nil
            )
        }
        if generation.rawValue > latest.rawValue {
            throw violation(
                .futureGeneration,
                field: "importJob.attempt.generation",
                input: .finishAttempt(generation: generation, outcome: outcome),
                generation: generation,
                expected: latest.rawValue
            )
        }
        let index = Int(generation.rawValue - 1)
        let attempt = job.attempts[index]
        if generation != latest {
            if attempt.state.terminalOutcome == outcome {
                return ImportJobTransition(state: job, disposition: .duplicate)
            }
            return ImportJobTransition(
                state: job,
                disposition: .staleCompletionCleanupOnly
            )
        }

        if let existing = attempt.state.terminalOutcome {
            guard existing == outcome else {
                throw violation(
                    .conflictingTerminalOutcome,
                    field: "importJob.attempt.state",
                    input: .finishAttempt(generation: generation, outcome: outcome),
                    generation: generation,
                    expected: generation.rawValue
                )
            }
            return ImportJobTransition(state: job, disposition: .duplicate)
        }
        if job.header.terminalOutcome != nil, job.header.terminalOutcome != .cancelled {
            throw terminalViolation(
                job,
                input: .finishAttempt(generation: generation, outcome: outcome)
            )
        }

        var attempts = job.attempts
        attempts[index] = ImportAttempt(
            jobID: attempt.jobID,
            generation: generation,
            state: .terminal(outcome)
        )

        if job.header.cancellationMarker != nil {
            return try transition(
                job,
                header: job.header,
                attempts: attempts,
                committedResult: nil,
                disposition: .completionAfterCancellationCleanupOnly
            )
        }

        let phase: DurableJobPhase =
            outcome == .succeeded ? .awaitingInstallation : .attemptTerminal
        let header = try makeHeader(
            job,
            phase: phase,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: nil
        )
        return try transition(
            job,
            header: header,
            attempts: attempts,
            committedResult: nil,
            disposition: .applied
        )
    }

    private static func installationCommitted(
        _ job: ImportJob,
        generation: AttemptGeneration,
        result: ImportResult
    ) throws -> ImportJobTransition {
        if let terminal = job.header.terminalOutcome {
            if terminal == .succeeded,
               job.header.attemptGeneration == generation,
               job.committedResult == result {
                return ImportJobTransition(state: job, disposition: .duplicate)
            }
            throw terminalViolation(
                job,
                input: .installationCommitted(generation: generation, result: result)
            )
        }
        let index = try currentAttemptIndex(
            job,
            generation: generation,
            input: .installationCommitted(generation: generation, result: result)
        )
        guard job.header.cancellationMarker == nil,
              job.attempts[index].state == .terminal(.succeeded)
        else {
            throw violation(
                .invalidTransition,
                field: "importJob.installation",
                input: .installationCommitted(generation: generation, result: result),
                generation: generation
            )
        }

        let header = try makeHeader(
            job,
            phase: .terminal,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: .succeeded
        )
        return try transition(
            job,
            header: header,
            attempts: job.attempts,
            committedResult: result,
            disposition: .applied
        )
    }

    private static func beginCleanup(
        _ job: ImportJob,
        generation: AttemptGeneration
    ) throws -> ImportJobTransition {
        let index = try existingAttemptIndex(
            job,
            generation: generation,
            input: .beginCleanup(generation: generation)
        )
        let attempt = job.attempts[index]
        let nextState: ImportAttemptState
        switch attempt.state {
        case let .terminal(outcome):
            nextState = .cleanupPending(outcome)
        case .cleanupPending, .cleaned:
            return ImportJobTransition(state: job, disposition: .duplicate)
        case .created, .dispatched, .cancellationRequested:
            throw violation(
                .invalidTransition,
                field: "importJob.attempt.state",
                input: .beginCleanup(generation: generation),
                generation: generation
            )
        }
        var attempts = job.attempts
        attempts[index] = ImportAttempt(
            jobID: attempt.jobID,
            generation: generation,
            state: nextState
        )
        let header = try cleanupHeader(job, generation: generation)
        return try transition(
            job,
            header: header,
            attempts: attempts,
            committedResult: job.committedResult,
            disposition: .applied
        )
    }

    private static func finishCleanup(
        _ job: ImportJob,
        generation: AttemptGeneration
    ) throws -> ImportJobTransition {
        let index = try existingAttemptIndex(
            job,
            generation: generation,
            input: .finishCleanup(generation: generation)
        )
        let attempt = job.attempts[index]
        let nextState: ImportAttemptState
        switch attempt.state {
        case let .cleanupPending(outcome):
            nextState = .cleaned(outcome)
        case .cleaned:
            return ImportJobTransition(state: job, disposition: .duplicate)
        case .created, .dispatched, .cancellationRequested, .terminal:
            throw violation(
                .invalidTransition,
                field: "importJob.attempt.state",
                input: .finishCleanup(generation: generation),
                generation: generation
            )
        }
        var attempts = job.attempts
        attempts[index] = ImportAttempt(
            jobID: attempt.jobID,
            generation: generation,
            state: nextState
        )
        let header = try cleanupHeader(job, generation: generation)
        return try transition(
            job,
            header: header,
            attempts: attempts,
            committedResult: job.committedResult,
            disposition: .applied
        )
    }

    private static func failPermanently(_ job: ImportJob) throws -> ImportJobTransition {
        if let terminal = job.header.terminalOutcome {
            if terminal == .failed {
                return ImportJobTransition(state: job, disposition: .duplicate)
            }
            throw terminalViolation(job, input: .failPermanently)
        }
        let header = try makeHeader(
            job,
            phase: .terminal,
            attemptGeneration: job.header.attemptGeneration,
            cancellationMarker: nil,
            terminalOutcome: .failed
        )
        return try transition(
            job,
            header: header,
            attempts: job.attempts,
            committedResult: nil,
            disposition: .applied
        )
    }

    private static func recoverAfterCrash(_ job: ImportJob) throws -> ImportJobTransition {
        guard let index = job.attempts.indices.last else {
            return ImportJobTransition(state: job, disposition: .duplicate)
        }
        let attempt = job.attempts[index]
        switch attempt.state {
        case .created, .dispatched, .cancellationRequested:
            if let terminal = job.header.terminalOutcome,
               terminal != .cancelled {
                throw terminalViolation(job, input: .recoverAfterCrash)
            }
            var attempts = job.attempts
            attempts[index] = ImportAttempt(
                jobID: attempt.jobID,
                generation: attempt.generation,
                state: .terminal(.interrupted)
            )
            let header: DurableJob
            if job.header.terminalOutcome == .cancelled {
                header = job.header
            } else {
                header = try makeHeader(
                    job,
                    phase: .attemptTerminal,
                    attemptGeneration: attempt.generation,
                    cancellationMarker: nil,
                    terminalOutcome: nil
                )
            }
            return try transition(
                job,
                header: header,
                attempts: attempts,
                committedResult: nil,
                disposition: .applied
            )
        case .terminal, .cleanupPending, .cleaned:
            return ImportJobTransition(state: job, disposition: .duplicate)
        }
    }

    private static func cleanupHeader(
        _ job: ImportJob,
        generation: AttemptGeneration
    ) throws -> DurableJob {
        guard job.header.terminalOutcome == nil,
              job.header.attemptGeneration == generation
        else {
            return job.header
        }
        return try makeHeader(
            job,
            phase: .attemptTerminal,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: nil
        )
    }

    private static func currentAttemptIndex(
        _ job: ImportJob,
        generation: AttemptGeneration,
        input: ImportJobInput
    ) throws -> Int {
        guard let latest = job.attempts.last?.generation else {
            throw violation(
                .futureGeneration,
                field: "importJob.attempt.generation",
                input: input,
                generation: generation
            )
        }
        if generation.rawValue > latest.rawValue {
            throw violation(
                .futureGeneration,
                field: "importJob.attempt.generation",
                input: input,
                generation: generation,
                expected: latest.rawValue
            )
        }
        guard generation == latest else {
            throw violation(
                .invalidTransition,
                field: "importJob.attempt.generation",
                input: input,
                generation: generation,
                expected: latest.rawValue
            )
        }
        return job.attempts.count - 1
    }

    private static func existingAttemptIndex(
        _ job: ImportJob,
        generation: AttemptGeneration,
        input: ImportJobInput
    ) throws -> Int {
        guard let latest = job.attempts.last?.generation else {
            throw violation(
                .futureGeneration,
                field: "importJob.attempt.generation",
                input: input,
                generation: generation
            )
        }
        guard generation.rawValue <= latest.rawValue else {
            throw violation(
                .futureGeneration,
                field: "importJob.attempt.generation",
                input: input,
                generation: generation,
                expected: latest.rawValue
            )
        }
        return Int(generation.rawValue - 1)
    }

    private static func requireNonterminal(
        _ job: ImportJob,
        input: ImportJobInput
    ) throws {
        guard job.header.terminalOutcome == nil else {
            throw terminalViolation(job, input: input)
        }
    }

    private static func makeHeader(
        _ job: ImportJob,
        phase: DurableJobPhase,
        attemptGeneration: AttemptGeneration?,
        cancellationMarker: CancellationMarker?,
        terminalOutcome: JobTerminalOutcome?
    ) throws -> DurableJob {
        try DurableJob(
            schema: job.header.schema,
            id: job.header.id,
            kind: job.header.kind,
            idempotencyKey: job.header.idempotencyKey,
            expectedEngineRevision: job.header.expectedEngineRevision,
            phase: phase,
            attemptGeneration: attemptGeneration,
            cancellationMarker: cancellationMarker,
            terminalOutcome: terminalOutcome
        )
    }

    private static func transition(
        _ job: ImportJob,
        header: DurableJob,
        attempts: [ImportAttempt],
        committedResult: ImportResult?,
        disposition: ImportJobDisposition
    ) throws -> ImportJobTransition {
        ImportJobTransition(
            state: try ImportJob(
                schema: job.schema,
                header: header,
                attempts: attempts,
                committedResult: committedResult
            ),
            disposition: disposition
        )
    }

    private static func terminalViolation(
        _ job: ImportJob,
        input: ImportJobInput
    ) -> ModelViolation {
        modelViolation(
            .terminalJob,
            field: "importJob.header.terminalOutcome",
            operation: input.operationTag,
            generation: job.header.attemptGeneration?.rawValue
        )
    }

    private static func violation(
        _ code: ModelViolation.Code,
        field: String,
        input: ImportJobInput,
        generation: AttemptGeneration,
        expected: UInt64? = nil
    ) -> ModelViolation {
        modelViolation(
            code,
            field: field,
            operation: input.operationTag,
            generation: generation.rawValue,
            expectedGeneration: expected
        )
    }
}
