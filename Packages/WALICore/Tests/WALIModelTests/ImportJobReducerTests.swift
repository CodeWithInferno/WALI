import Foundation
import Testing
@testable import WALIModel

@Suite("Durable import job reducer")
struct ImportJobReducerTests {
    @Test("Reducer allocates attempt generations monotonically")
    func generationAllocation() throws {
        var transition = try ImportJobReducer.reduce(makeImportJob(), .beginAttempt)
        #expect(transition.disposition == .applied)
        #expect(transition.state.attempts.map(\.generation.rawValue) == [1])
        #expect(transition.state.header.attemptGeneration == (try AttemptGeneration(1)))
        #expect(transition.state.attempts.last?.state == .created)

        transition = try ImportJobReducer.reduce(
            transition.state,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .failed)
        )
        transition = try ImportJobReducer.reduce(transition.state, .beginAttempt)
        #expect(transition.state.attempts.map(\.generation.rawValue) == [1, 2])
        #expect(transition.state.header.attemptGeneration == (try AttemptGeneration(2)))
    }

    @Test("Persisted cancellation marker is the linearization point")
    func durableCancellation() throws {
        var job = try ImportJobReducer.reduce(makeImportJob(), .beginAttempt).state
        job = try ImportJobReducer.reduce(
            job,
            .markDispatched(generation: try AttemptGeneration(1))
        ).state
        let transition = try ImportJobReducer.reduce(
            job,
            .requestCancellation(acceptedRevision: EngineRevision(rawValue: 8))
        )

        #expect(transition.state.header.cancellationMarker?.acceptedRevision == EngineRevision(rawValue: 8))
        #expect(transition.state.header.terminalOutcome == .cancelled)
        #expect(transition.state.attempts.last?.state == .cancellationRequested)

        let duplicate = try ImportJobReducer.reduce(
            transition.state,
            .requestCancellation(acceptedRevision: EngineRevision(rawValue: 8))
        )
        #expect(duplicate.disposition == .duplicate)

        let recovered = try ImportJobReducer.reduce(
            transition.state,
            .recoverAfterCrash
        )
        #expect(recovered.state.attempts.last?.state == .terminal(.interrupted))
        #expect(recovered.state.header.terminalOutcome == .cancelled)
    }

    @Test("Success after cancellation is cleanup-only and can never install")
    func successAfterCancellation() throws {
        var job = try activeImportJob()
        job = try ImportJobReducer.reduce(
            job,
            .requestCancellation(acceptedRevision: EngineRevision(rawValue: 8))
        ).state
        let completion = try ImportJobReducer.reduce(
            job,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .succeeded)
        )

        #expect(completion.disposition == .completionAfterCancellationCleanupOnly)
        #expect(completion.state.attempts.last?.state == .terminal(.succeeded))
        #expect(completion.state.header.terminalOutcome == .cancelled)
        #expect(completion.state.committedResult == nil)

        expectViolation(.terminalJob) {
            _ = try ImportJobReducer.reduce(
                completion.state,
                .installationCommitted(
                    generation: try AttemptGeneration(1),
                    result: importResult()
                )
            )
        }
    }

    @Test("Old completion is stale cleanup-only and future completion throws")
    func staleAndFutureCompletion() throws {
        var job = try activeImportJob()
        job = try ImportJobReducer.reduce(job, .recoverAfterCrash).state
        job = try ImportJobReducer.reduce(job, .beginAttempt).state

        let stale = try ImportJobReducer.reduce(
            job,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .succeeded)
        )
        #expect(stale.disposition == .staleCompletionCleanupOnly)
        #expect(stale.state == job)

        let cleanup = try ImportJobReducer.reduce(
            stale.state,
            .beginCleanup(generation: try AttemptGeneration(1))
        )
        #expect(cleanup.disposition == .applied)
        #expect(cleanup.state.attempts.first?.state == .cleanupPending(.interrupted))

        expectViolation(.futureGeneration) {
            _ = try ImportJobReducer.reduce(
                job,
                .finishAttempt(generation: try AttemptGeneration(3), outcome: .succeeded)
            )
        }
    }

    @Test("Exact terminal duplicate is idempotent and conflict throws")
    func duplicateAndConflictingTerminal() throws {
        var job = try activeImportJob()
        job = try ImportJobReducer.reduce(
            job,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .failed)
        ).state

        let duplicate = try ImportJobReducer.reduce(
            job,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .failed)
        )
        #expect(duplicate.disposition == .duplicate)
        #expect(duplicate.state == job)

        expectViolation(.conflictingTerminalOutcome) {
            _ = try ImportJobReducer.reduce(
                job,
                .finishAttempt(generation: try AttemptGeneration(1), outcome: .succeeded)
            )
        }
    }

    @Test("Crash recovery records interrupted, never cancelled or succeeded")
    func interruptedRecovery() throws {
        let transition = try ImportJobReducer.reduce(try activeImportJob(), .recoverAfterCrash)
        #expect(transition.disposition == .applied)
        #expect(transition.state.attempts.last?.state == .terminal(.interrupted))
        #expect(transition.state.header.terminalOutcome == nil)
        #expect(transition.state.committedResult == nil)
    }

    @Test("Cleanup states retain the attempt terminal outcome")
    func cleanupRetention() throws {
        var job = try activeImportJob()
        job = try ImportJobReducer.reduce(
            job,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .failed)
        ).state
        job = try ImportJobReducer.reduce(
            job,
            .beginCleanup(generation: try AttemptGeneration(1))
        ).state
        #expect(job.attempts.last?.state == .cleanupPending(.failed))

        job = try ImportJobReducer.reduce(
            job,
            .finishCleanup(generation: try AttemptGeneration(1))
        ).state
        #expect(job.attempts.last?.state == .cleaned(.failed))
    }

    @Test("Retry requires a prior terminal attempt and no cancellation")
    func retryGates() throws {
        let active = try activeImportJob()
        expectViolation(.invalidTransition) {
            _ = try ImportJobReducer.reduce(active, .beginAttempt)
        }

        var retryable = try ImportJobReducer.reduce(
            active,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .interrupted)
        ).state
        retryable = try ImportJobReducer.reduce(retryable, .beginAttempt).state
        #expect(retryable.attempts.last?.generation == (try AttemptGeneration(2)))

        var cancelled = try activeImportJob()
        cancelled = try ImportJobReducer.reduce(
            cancelled,
            .requestCancellation(acceptedRevision: EngineRevision(rawValue: 8))
        ).state
        expectViolation(.terminalJob) {
            _ = try ImportJobReducer.reduce(cancelled, .beginAttempt)
        }
    }

    @Test("Worker success is not job success until installation commits")
    func successRequiresInstallation() throws {
        var job = try activeImportJob()
        job = try ImportJobReducer.reduce(
            job,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .succeeded)
        ).state

        #expect(job.header.phase == .awaitingInstallation)
        #expect(job.header.terminalOutcome == nil)
        #expect(job.committedResult == nil)

        job = try ImportJobReducer.reduce(
            job,
            .installationCommitted(
                generation: try AttemptGeneration(1),
                result: importResult()
            )
        ).state
        #expect(job.header.phase == .terminal)
        #expect(job.header.terminalOutcome == .succeeded)
        #expect(job.committedResult == (try importResult()))
    }

    @Test("Terminal job never reopens or changes outcome")
    func immutableTerminal() throws {
        var job = try activeImportJob()
        job = try ImportJobReducer.reduce(
            job,
            .finishAttempt(generation: try AttemptGeneration(1), outcome: .succeeded)
        ).state
        job = try ImportJobReducer.reduce(
            job,
            .installationCommitted(
                generation: try AttemptGeneration(1),
                result: importResult()
            )
        ).state

        let duplicate = try ImportJobReducer.reduce(
            job,
            .installationCommitted(
                generation: try AttemptGeneration(1),
                result: importResult()
            )
        )
        #expect(duplicate.disposition == .duplicate)

        expectViolation(.terminalJob) {
            _ = try ImportJobReducer.reduce(job, .beginAttempt)
        }
        expectViolation(.terminalJob) {
            _ = try ImportJobReducer.reduce(job, .failPermanently)
        }
    }

    @Test("Associated job lifecycle values use explicit stable tags")
    func stableJobTags() throws {
        #expect(
            try logicalJSON(ImportAttemptState.cleanupPending(.interrupted))
                == "{\"outcome\":\"interrupted\",\"tag\":\"cleanup_pending\"}"
        )
        #expect(
            try logicalJSON(
                ImportJobInput.finishAttempt(
                    generation: try AttemptGeneration(4),
                    outcome: .cancelled
                )
            )
                == "{\"generation\":4,\"outcome\":\"cancelled\",\"tag\":\"finish_attempt\"}"
        )
    }

    @Test("Malformed state combinations fail closed while decoding")
    func malformedDecoding() throws {
        let object = try #require(
            JSONSerialization.jsonObject(
                with: fixtureData(named: "model-records-invalid-v1")
            ) as? [String: Any]
        )
        let succeededWithoutResult = try JSONSerialization.data(
            withJSONObject: try #require(object["succeededJobWithoutResult"])
        )
        expectViolation(.invalidCombination) {
            _ = try JSONDecoder().decode(ImportJob.self, from: succeededWithoutResult)
        }

        let cleanupWithoutOutcome = try JSONSerialization.data(
            withJSONObject: try #require(object["cleanupStateWithoutOutcome"])
        )
        expectViolation(.invalidCombination) {
            _ = try JSONDecoder().decode(ImportAttemptState.self, from: cleanupWithoutOutcome)
        }

        let invalidInput = try JSONSerialization.data(
            withJSONObject: try #require(object["invalidImportJobInput"])
        )
        expectViolation(.invalidCombination) {
            _ = try JSONDecoder().decode(ImportJobInput.self, from: invalidInput)
        }

        let invalidHeader = try JSONSerialization.data(
            withJSONObject: try #require(object["activeHeaderWithoutGeneration"])
        )
        expectViolation(.invalidCombination) {
            _ = try JSONDecoder().decode(DurableJob.self, from: invalidHeader)
        }
    }

    @Test("Golden import job fixture round trips")
    func importJobFixture() throws {
        let fixture = try JSONDecoder().decode(
            ImportJobFixture.self,
            from: fixtureData(named: "model-records-v1")
        )
        let decoded = try JSONDecoder().decode(
            ImportJob.self,
            from: JSONEncoder().encode(fixture.importJob)
        )
        #expect(decoded == fixture.importJob)
        #expect(decoded.schema == .current)
        #expect(decoded.header.schema == .current)
    }
}

private struct ImportJobFixture: Decodable {
    let importJob: ImportJob
}

private func makeImportJob() throws -> ImportJob {
    try ImportJob.pending(
        id: JobID(jobIDText),
        idempotencyKey: IdempotencyKey(idempotencyKeyText),
        expectedEngineRevision: EngineRevision(rawValue: 7)
    )
}

private func activeImportJob() throws -> ImportJob {
    var job = try ImportJobReducer.reduce(makeImportJob(), .beginAttempt).state
    job = try ImportJobReducer.reduce(
        job,
        .markDispatched(generation: try AttemptGeneration(1))
    ).state
    return job
}

private func importResult() throws -> ImportResult {
    try ImportResult(
        libraryItemID: LibraryItemID(libraryItemIDText),
        releaseID: AssetReleaseID(releaseIDText)
    )
}
