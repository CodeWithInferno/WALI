import Darwin
import Foundation
import WALIModel

/// The agent-owned, serialized authority for local library metadata and bytes.
public actor RuntimeStore {
    public let paths: LibraryPaths
    private var state: RuntimeSnapshot?
    private var isShuttingDown = false
    private var hasStartedImportWork = false

    public init(paths: LibraryPaths) {
        self.paths = paths
    }

    /// Opens or creates the store, then completes interrupted cleanup idempotently.
    @discardableResult
    public func open() async throws -> StorageRecoveryReport {
        try ContentStorage.bootstrap(paths)
        if FileManager.default.fileExists(atPath: paths.stateFile.path) {
            do {
                try ContentStorage.requireContainedRegularFile(paths.stateFile, under: paths.metadata)
                let data = try Data(contentsOf: paths.stateFile, options: [.mappedIfSafe])
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                state = try decoder.decode(RuntimeSnapshot.self, from: data)
            } catch let error as StorageError {
                throw error
            } catch {
                throw StorageError.corruptState(error.localizedDescription)
            }
            try validateLoadedState()
            try migrateLoadedStateIfNeeded()
        } else {
            state = RuntimeSnapshot()
            try persist()
        }
        return try await reconcileAfterCrash()
    }

    /// Stops all new import mutations before worker drain. A durable interrupted
    /// attempt can resume only in a newly opened store after process restart.
    /// Successful attempts retain their existing terminal result; the gate
    /// prevents their late claims from publishing while shutdown is in progress.
    public func interruptActiveImportsForShutdown() throws {
        isShuttingDown = true
        guard var current = state else { throw StorageError.stateNotOpened }
        for index in current.importJobs.indices {
            let persisted = current.importJobs[index]
            guard persisted.job.header.phase == .attemptActive,
                  let generation = persisted.job.header.attemptGeneration else { continue }
            var attempts = persisted.job.attempts
            attempts[attempts.count - 1] = .init(jobID: persisted.job.header.id, generation: generation, state: .terminal(.interrupted))
            let header = try DurableJob(
                schema: persisted.job.schema, id: persisted.job.header.id, kind: .waliImport,
                idempotencyKey: persisted.job.header.idempotencyKey,
                expectedEngineRevision: persisted.job.header.expectedEngineRevision,
                phase: .attemptTerminal, attemptGeneration: generation,
                cancellationMarker: nil, terminalOutcome: nil
            )
            let job = try ImportJob(schema: persisted.job.schema, header: header, attempts: attempts, committedResult: nil)
            current.importJobs[index] = try PersistedImportJob(
                job: job, sourceURL: persisted.sourceURL, sourceBookmark: persisted.sourceBookmark,
                stagingDirectoryName: persisted.stagingDirectoryName,
                createdAt: persisted.createdAt, updatedAt: Date()
            )
        }
        try commit(current)
        for persisted in current.importJobs where persisted.job.header.phase != .terminal {
            let directory = paths.staging.appendingPathComponent(persisted.stagingDirectoryName, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func requireAcceptingImports() throws {
        guard !isShuttingDown else { throw StorageError.jobNotInstallable }
        hasStartedImportWork = true
    }

    public func snapshot() throws -> RuntimeSnapshot {
        guard let state else { throw StorageError.stateNotOpened }
        return state
    }

    public func installedCatalogRecord(
        releaseID: String,
        manifestDigest: ContentDigest
    ) throws -> CommittedLibraryRecord? {
        guard let record = try snapshot().library.first(where: {
            $0.item.origin == .catalog && $0.item.catalogOrigin?.releaseID == releaseID
        }) else { return nil }
        guard record.item.catalogOrigin?.manifestDigest == manifestDigest else {
            throw StorageError.catalogInstallConflict
        }
        for artifact in record.artifacts {
            let expected = try paths.objectURL(
                forSHA256: artifact.digest.value,
                mediaKind: artifact.mediaKind
            )
            guard expected.standardizedFileURL == artifact.objectURL.standardizedFileURL else {
                throw StorageError.missingPublishedArtifact
            }
            try ContentStorage.requireContainedRegularFile(expected, under: paths.objects)
            guard try ContentStorage.sha256(of: expected) == artifact.digest else {
                throw StorageError.digestMismatch
            }
        }
        return record
    }

    public func updatePreferences(_ preferences: RuntimePreferences) throws {
        try mutate { state in state.preferences = preferences }
    }

    public func adoptCatalogQuarantine(
        _ sourceURL: URL,
        under quarantineRoot: URL,
        expectedDigest: ContentDigest,
        expectedByteCount: UInt64
    ) throws -> URL {
        try requireAcceptingImports()
        guard state != nil else { throw StorageError.stateNotOpened }
        let directoryName = "catalog-source-\(UUID().uuidString.lowercased())"
        let directory = paths.staging.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            return try ContentStorage.adoptCatalogQuarantine(
                sourceURL,
                under: quarantineRoot,
                into: directory,
                expectedDigest: expectedDigest,
                expectedByteCount: expectedByteCount
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Catalog provenance is not persisted with an unfinished local worker job.
    /// Startup therefore retires it visibly; a fresh marketplace request must
    /// re-establish current signature/revocation context before another attempt.
    public func recoverCatalogImportsRequiringFreshVerification() throws -> Int {
        guard !isShuttingDown, !hasStartedImportWork, var current = state else { throw StorageError.jobNotInstallable }
        let pending = current.importJobs.filter { $0.job.header.phase != .terminal && isAdoptedCatalogSource($0.sourceURL) }
        for persisted in pending { try retireCatalogJob(persisted, in: &current) }
        if !pending.isEmpty { try commit(current) }
        for source in Set(pending.map(\.sourceURL)) { try removeAdoptedCatalogSource(source) }
        return pending.count
    }

    public func failCatalogImportForFreshRetry(jobID: JobID) throws {
        try requireAcceptingImports()
        guard var current = state,
              let persisted = current.importJobs.first(where: { $0.job.header.id == jobID }),
              persisted.job.header.phase == .attemptTerminal, isAdoptedCatalogSource(persisted.sourceURL) else { return }
        try retireCatalogJob(persisted, in: &current)
        try commit(current)
        try removeAdoptedCatalogSource(persisted.sourceURL)
    }

    private func isAdoptedCatalogSource(_ source: URL) -> Bool {
        let directory = source.standardizedFileURL.deletingLastPathComponent()
        return directory.deletingLastPathComponent() == paths.staging.standardizedFileURL &&
            directory.lastPathComponent.hasPrefix("catalog-source-") && source.lastPathComponent == "catalog-source.mp4"
    }

    private func retireCatalogJob(_ persisted: PersistedImportJob, in current: inout RuntimeSnapshot) throws {
        var attempts = persisted.job.attempts
        if let last = attempts.last, last.state.terminalOutcome == nil {
            attempts[attempts.count - 1] = .init(jobID: last.jobID, generation: last.generation, state: .terminal(.interrupted))
        }
        let header = try DurableJob(schema: persisted.job.schema, id: persisted.job.header.id, kind: .waliImport,
            idempotencyKey: persisted.job.header.idempotencyKey, expectedEngineRevision: persisted.job.header.expectedEngineRevision,
            phase: .terminal, attemptGeneration: persisted.job.header.attemptGeneration, cancellationMarker: nil, terminalOutcome: .failed)
        let job = try ImportJob(schema: persisted.job.schema, header: header, attempts: attempts, committedResult: nil)
        guard let index = current.importJobs.firstIndex(where: { $0.job.header.id == job.header.id }) else { throw StorageError.missingJob }
        current.importJobs[index] = try PersistedImportJob(job: job, sourceURL: persisted.sourceURL,
            sourceBookmark: persisted.sourceBookmark, stagingDirectoryName: persisted.stagingDirectoryName,
            createdAt: persisted.createdAt, updatedAt: Date())
    }

    public func removeAdoptedCatalogSource(_ sourceURL: URL) throws {
        #if WALI_APP_STORE
        if try snapshot().importJobs.contains(where: {
            $0.sourceURL.standardizedFileURL == sourceURL.standardizedFileURL && $0.job.header.phase != .terminal
        }) { return }
        #endif
        let directory = sourceURL.standardizedFileURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent() == paths.staging.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("catalog-source-"),
              sourceURL.lastPathComponent == "catalog-source.mp4"
        else { throw StorageError.pathEscapesStore }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
            try ContentStorage.syncDirectory(paths.staging)
        }
    }

    public func replaceAssignments(_ assignments: [DeviceLocalPresentationAssignment]) throws {
        try mutate { state in state.assignments = assignments }
    }

    /// Happy-path orchestration starts here:
    /// 1. Call `beginImport`, then `markImportDispatched` immediately before XPC dispatch.
    /// 2. Pass the returned source/staging URLs and attempt IDs to the media worker.
    /// 3. On success call `finishImportAttempt(..., .succeeded)`, map its three
    ///    result claims to `StagedArtifactCandidate`, and install each candidate.
    /// 4. Build WALIModel `Artifact`/`AssetRelease`/`LibraryItem` values from the
    ///    returned `StoredArtifact`s, create `CommittedLibraryRecord`, then call
    ///    `commitImport(jobID:generation:record:)`.
    ///
    /// Source media is authorization-only and is never cleanup-owned.
    public func beginImport(
        sourceURL: URL,
        sourceBookmark: Data? = nil,
        idempotencyKey: IdempotencyKey,
        expectedEngineRevision: EngineRevision
    ) throws -> LocalImportContext {
        try requireAcceptingImports()
        guard sourceURL.isFileURL else { throw StorageError.invalidCandidate }
        guard let current = state else { throw StorageError.stateNotOpened }
        if let existing = current.importJobs.first(where: {
            $0.job.header.idempotencyKey == idempotencyKey
        }), let generation = existing.job.header.attemptGeneration {
            return LocalImportContext(
                jobID: existing.job.header.id,
                generation: generation,
                sourceURL: existing.sourceURL,
                stagingDirectoryURL: paths.staging.appendingPathComponent(
                    existing.stagingDirectoryName,
                    isDirectory: true
                )
            )
        }

        let jobID = try JobID(UUID().uuidString.lowercased())
        let generation = try AttemptGeneration(1)
        let header = try DurableJob(
            schema: .current,
            id: jobID,
            kind: .waliImport,
            idempotencyKey: idempotencyKey,
            expectedEngineRevision: expectedEngineRevision,
            phase: .attemptActive,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: nil
        )
        let job = try ImportJob(
            schema: .current,
            header: header,
            attempts: [.init(jobID: jobID, generation: generation, state: .created)],
            committedResult: nil
        )
        let directoryName = "\(jobID.rawValue)-\(generation.rawValue)"
        let stagingURL = paths.staging.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try saveImportJob(
                job,
                sourceURL: sourceURL,
                sourceBookmark: sourceBookmark,
                stagingDirectoryName: directoryName
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
        return LocalImportContext(
            jobID: jobID,
            generation: generation,
            sourceURL: sourceURL,
            stagingDirectoryURL: stagingURL
        )
    }

    public func markImportDispatched(jobID: JobID, generation: AttemptGeneration) throws {
        try requireAcceptingImports()
        let persisted = try persistedJob(jobID: jobID, generation: generation)
        guard persisted.job.attempts.last?.state == .created else {
            if persisted.job.attempts.last?.state == .dispatched { return }
            throw StorageError.jobNotInstallable
        }
        var attempts = persisted.job.attempts
        attempts[attempts.count - 1] = .init(
            jobID: jobID,
            generation: generation,
            state: .dispatched
        )
        let job = try ImportJob(
            schema: persisted.job.schema,
            header: persisted.job.header,
            attempts: attempts,
            committedResult: nil
        )
        try replacePersistedJob(persisted, with: job)
    }

    /// Starts the next durable worker generation after a terminal attempt. A
    /// successful attempt awaiting installation may also be retried explicitly
    /// after a restart; uncommitted objects remain invisible and are collected.
    public func retryImport(jobID: JobID) throws -> LocalImportContext {
        try requireAcceptingImports()
        guard let persisted = try snapshot().importJobs.first(where: {
            $0.job.header.id == jobID
        }), persisted.job.header.phase == .attemptTerminal ||
            persisted.job.header.phase == .awaitingInstallation,
            let last = persisted.job.attempts.last,
            last.state.terminalOutcome != nil,
            persisted.job.attempts.count < ImportJob.maximumAttemptCount
        else {
            throw StorageError.jobNotRetryable
        }

        let generation = try AttemptGeneration(UInt64(persisted.job.attempts.count) + 1)
        var attempts = persisted.job.attempts
        attempts.append(.init(jobID: jobID, generation: generation, state: .created))
        let header = try DurableJob(
            schema: persisted.job.schema,
            id: jobID,
            kind: .waliImport,
            idempotencyKey: persisted.job.header.idempotencyKey,
            expectedEngineRevision: persisted.job.header.expectedEngineRevision,
            phase: .attemptActive,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: nil
        )
        let job = try ImportJob(
            schema: persisted.job.schema,
            header: header,
            attempts: attempts,
            committedResult: nil
        )
        let directoryName = "\(jobID.rawValue)-\(generation.rawValue)"
        let stagingURL = paths.staging.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try saveImportJob(
                job,
                sourceURL: persisted.sourceURL,
                sourceBookmark: persisted.sourceBookmark,
                stagingDirectoryName: directoryName
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        try mutate { current in
            for index in current.installJournals.indices where
                current.installJournals[index].jobID == jobID &&
                current.installJournals[index].generation == last.generation &&
                current.installJournals[index].phase != .committed {
                current.installJournals[index].phase = .cleaned
                current.installJournals[index].updatedAt = Date()
            }
        }

        let previousStagingURL = paths.staging.appendingPathComponent(
            persisted.stagingDirectoryName,
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: previousStagingURL)
        return LocalImportContext(
            jobID: jobID,
            generation: generation,
            sourceURL: persisted.sourceURL,
            stagingDirectoryURL: stagingURL
        )
    }

    public func finishImportAttempt(
        jobID: JobID,
        generation: AttemptGeneration,
        outcome: ImportAttemptTerminalKind
    ) throws {
        try requireAcceptingImports()
        let persisted = try persistedJob(jobID: jobID, generation: generation)
        if persisted.job.attempts.last?.state == .terminal(outcome) { return }
        guard persisted.job.attempts.last?.state == .dispatched else {
            throw StorageError.jobNotInstallable
        }
        var attempts = persisted.job.attempts
        attempts[attempts.count - 1] = .init(
            jobID: jobID,
            generation: generation,
            state: .terminal(outcome)
        )
        let phase: DurableJobPhase = outcome == .succeeded ? .awaitingInstallation : .attemptTerminal
        let header = try DurableJob(
            schema: persisted.job.schema,
            id: jobID,
            kind: .waliImport,
            idempotencyKey: persisted.job.header.idempotencyKey,
            expectedEngineRevision: persisted.job.header.expectedEngineRevision,
            phase: phase,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: nil
        )
        let job = try ImportJob(
            schema: persisted.job.schema,
            header: header,
            attempts: attempts,
            committedResult: nil
        )
        try replacePersistedJob(persisted, with: job)
    }

    public func cancelImport(jobID: JobID, acceptedRevision: EngineRevision) throws {
        guard let persisted = try snapshot().importJobs.first(where: { $0.job.header.id == jobID }),
              let generation = persisted.job.header.attemptGeneration
        else {
            throw StorageError.missingJob
        }
        if persisted.job.header.terminalOutcome == .cancelled { return }
        guard persisted.job.header.phase == .attemptActive ||
                persisted.job.header.phase == .awaitingInstallation else {
            throw StorageError.jobNotInstallable
        }
        var attempts = persisted.job.attempts
        attempts[attempts.count - 1] = .init(
            jobID: jobID,
            generation: generation,
            state: .cancellationRequested
        )
        let marker = CancellationMarker(acceptedRevision: acceptedRevision)
        let header = try DurableJob(
            schema: persisted.job.schema,
            id: jobID,
            kind: .waliImport,
            idempotencyKey: persisted.job.header.idempotencyKey,
            expectedEngineRevision: persisted.job.header.expectedEngineRevision,
            phase: .terminal,
            attemptGeneration: generation,
            cancellationMarker: marker,
            terminalOutcome: .cancelled
        )
        let job = try ImportJob(
            schema: persisted.job.schema,
            header: header,
            attempts: attempts,
            committedResult: nil
        )
        try replacePersistedJob(persisted, with: job)
        let stagingURL = paths.staging.appendingPathComponent(
            persisted.stagingDirectoryName,
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: stagingURL)
        _ = try garbageCollect()
    }

    /// Persists intent and source authorization before worker dispatch.
    public func saveImportJob(
        _ job: ImportJob,
        sourceURL: URL,
        sourceBookmark: Data? = nil,
        stagingDirectoryName: String
    ) throws {
        try requireAcceptingImports()
        guard var current = state else { throw StorageError.stateNotOpened }
        let existing = current.importJobs.first { $0.job.header.id == job.header.id }
        let record = try PersistedImportJob(
            job: job,
            sourceURL: sourceURL,
            sourceBookmark: sourceBookmark,
            stagingDirectoryName: stagingDirectoryName,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
        current.importJobs.removeAll { $0.job.header.id == job.header.id }
        current.importJobs.append(record)
        current.importJobs.sort { $0.createdAt < $1.createdAt }
        try commit(current)
    }

    /// Copies worker staging into fresh agent-owned storage, verifies those new
    /// bytes, and atomically publishes or reuses the content-addressed object.
    public func installArtifact(_ candidate: StagedArtifactCandidate) async throws -> StoredArtifact {
        try requireInstallableJob(candidate)
        var journal = ArtifactInstallJournal(
            id: UUID(),
            jobID: candidate.jobID,
            generation: candidate.generation,
            role: candidate.role,
            mediaKind: candidate.mediaKind,
            stagedURL: candidate.stagedURL,
            phase: .intentRecorded,
            preparedFileName: nil,
            verifiedDigest: nil,
            publishedObjectURL: nil,
            updatedAt: Date()
        )
        try upsertJournal(journal)

        do {
            journal.phase = .verifying
            journal.updatedAt = Date()
            try upsertJournal(journal)
            let prepared = try ContentStorage.prepare(candidate: candidate, paths: paths)
            journal.preparedFileName = prepared.fileName
            journal.updatedAt = Date()
            try upsertJournal(journal)

            let media = try await ContentStorage.verifyMedia(at: prepared.url, kind: candidate.mediaKind)
            try requireStillCurrent(candidate)
            guard try ContentStorage.sha256(of: prepared.url) == prepared.digest else {
                throw StorageError.digestMismatch
            }

            journal.phase = .verified
            journal.verifiedDigest = prepared.digest
            journal.updatedAt = Date()
            try upsertJournal(journal)
            journal.phase = .prepared
            journal.updatedAt = Date()
            try upsertJournal(journal)

            let objectURL = try ContentStorage.publish(prepared, paths: paths)
            journal.phase = .published
            journal.publishedObjectURL = objectURL
            journal.updatedAt = Date()
            try upsertJournal(journal)
            return StoredArtifact(
                role: candidate.role,
                mediaKind: candidate.mediaKind,
                digest: prepared.digest,
                byteCount: prepared.byteCount,
                objectURL: objectURL,
                pixelSize: media.pixelSize,
                durationSeconds: media.durationSeconds
            )
        } catch {
            journal.phase = .cleanupPending
            journal.updatedAt = Date()
            try? upsertJournal(journal)
            if let fileName = journal.preparedFileName {
                let url = paths.prepared.appendingPathComponent(fileName, isDirectory: false)
                try? FileManager.default.removeItem(at: url)
            }
            journal.phase = .cleaned
            journal.updatedAt = Date()
            try? upsertJournal(journal)
            throw error
        }
    }

    /// Makes the release visible and the related journals terminal in one
    /// atomic metadata replacement.
    public func commitImport(
        job: ImportJob,
        record: CommittedLibraryRecord
    ) throws {
        try requireAcceptingImports()
        guard job.header.phase == .terminal,
              job.header.terminalOutcome == .succeeded,
              let generation = job.header.attemptGeneration
        else {
            throw StorageError.jobNotInstallable
        }
        guard var current = state else { throw StorageError.stateNotOpened }
        let published = current.installJournals.filter {
            $0.jobID == job.header.id &&
                $0.generation == generation &&
                $0.phase == .published
        }
        guard Set(published.map(\.role)) == Set(StoredArtifactRole.allCases),
              Set(published.compactMap(\.verifiedDigest)) == Set(record.artifacts.map(\.digest))
        else {
            throw StorageError.missingPublishedArtifact
        }
        for artifact in record.artifacts {
            let expected = try paths.objectURL(
                forSHA256: artifact.digest.value,
                mediaKind: artifact.mediaKind
            )
            guard expected.standardizedFileURL.path == artifact.objectURL.standardizedFileURL.path,
                  FileManager.default.fileExists(atPath: expected.path)
            else {
                throw StorageError.missingPublishedArtifact
            }
        }
        current.library.removeAll { $0.item.id == record.item.id }
        current.library.append(record)
        current.library.sort { $0.importedAt > $1.importedAt }
        current.installJournals = current.installJournals.map { existing in
            guard existing.jobID == job.header.id, existing.generation == generation else {
                return existing
            }
            var committed = existing
            committed.phase = .committed
            committed.updatedAt = Date()
            return committed
        }
        var cleanupDirectory: URL?
        if let persisted = current.importJobs.first(where: { $0.job.header.id == job.header.id }) {
            current.importJobs.removeAll { $0.job.header.id == job.header.id }
            current.importJobs.append(try PersistedImportJob(
                job: job,
                sourceURL: persisted.sourceURL,
                sourceBookmark: persisted.sourceBookmark,
                stagingDirectoryName: persisted.stagingDirectoryName,
                createdAt: persisted.createdAt,
                updatedAt: Date()
            ))
            cleanupDirectory = paths.staging.appendingPathComponent(
                persisted.stagingDirectoryName,
                isDirectory: true
            )
        }
        try commit(current)
        if let cleanupDirectory {
            try? FileManager.default.removeItem(at: cleanupDirectory)
        }
    }

    /// Finalizes the documented happy path without duplicating ImportJob state
    /// construction in an XPC adapter.
    public func commitImport(
        jobID: JobID,
        generation: AttemptGeneration,
        record: CommittedLibraryRecord
    ) throws {
        try requireAcceptingImports()
        let persisted = try persistedJob(jobID: jobID, generation: generation)
        guard persisted.job.header.phase == .awaitingInstallation,
              persisted.job.attempts.last?.state == .terminal(.succeeded)
        else {
            throw StorageError.jobNotInstallable
        }
        let result = ImportResult(libraryItemID: record.item.id, releaseID: record.release.id)
        let header = try DurableJob(
            schema: persisted.job.schema,
            id: jobID,
            kind: .waliImport,
            idempotencyKey: persisted.job.header.idempotencyKey,
            expectedEngineRevision: persisted.job.header.expectedEngineRevision,
            phase: .terminal,
            attemptGeneration: generation,
            cancellationMarker: nil,
            terminalOutcome: .succeeded
        )
        let job = try ImportJob(
            schema: persisted.job.schema,
            header: header,
            attempts: persisted.job.attempts,
            committedResult: result
        )
        try commitImport(job: job, record: record)
    }

    public func acquireLease(
        for digest: ContentDigest,
        holder: String,
        generation: UInt64,
        duration: Duration = .seconds(300)
    ) throws -> ArtifactLease {
        guard !holder.isEmpty, holder.utf8.count <= 160 else {
            throw StorageError.invalidCandidate
        }
        let seconds = min(max(duration.components.seconds, 1), 3_600)
        let lease = ArtifactLease(
            id: UUID(),
            digest: digest,
            holder: holder,
            generation: generation,
            expiresAt: Date().addingTimeInterval(TimeInterval(seconds))
        )
        try mutate { $0.leases.append(lease) }
        return lease
    }

    public func renewLease(_ id: UUID, generation: UInt64, duration: Duration = .seconds(300)) throws {
        guard var current = state else { throw StorageError.stateNotOpened }
        guard let index = current.leases.firstIndex(where: { $0.id == id }),
              current.leases[index].generation == generation
        else {
            throw StorageError.staleGeneration
        }
        let seconds = min(max(duration.components.seconds, 1), 3_600)
        current.leases[index].expiresAt = Date().addingTimeInterval(TimeInterval(seconds))
        try commit(current)
    }

    public func releaseLease(_ id: UUID) throws {
        try mutate { $0.leases.removeAll { $0.id == id } }
    }

    /// Removes library metadata first, then replayably collects unleased bytes.
    public func deleteLibraryItem(_ id: LibraryItemID) throws {
        guard var current = state else { throw StorageError.stateNotOpened }
        guard let record = current.library.first(where: { $0.item.id == id }) else { return }
        current.library.removeAll { $0.item.id == id }
        let remainingDigests = Set(current.library.flatMap { $0.artifacts.map(\.digest) })
        for digest in record.artifacts.map(\.digest) where !remainingDigests.contains(digest) {
            guard let artifact = record.artifacts.first(where: { $0.digest == digest }) else {
                continue
            }
            if !current.tombstones.contains(where: {
                $0.digest == digest && $0.mediaKind == artifact.mediaKind
            }) {
                current.tombstones.append(.init(
                    digest: digest,
                    mediaKind: artifact.mediaKind,
                    createdAt: Date()
                ))
            }
        }
        try commit(current)
        try collectTombstones()
    }

    @discardableResult
    public func garbageCollect() throws -> Int {
        guard var current = state else { throw StorageError.stateNotOpened }
        let now = Date()
        current.leases.removeAll { $0.expiresAt <= now }
        state = current
        let referenced = Set(current.library.flatMap { $0.artifacts.map(\.digest.value) })
        let leased = Set(current.leases.map(\.digest.value))
        // Publishing an artifact and committing its library record are separate
        // durable steps. Keep every live install journal's verified object alive
        // so an unrelated cancellation/GC cannot tear it out between those steps.
        let installing = Set(current.installJournals.lazy
            .filter { $0.phase != .committed && $0.phase != .cleaned }
            .compactMap { $0.verifiedDigest?.value })
        var removed = 0
        for url in try objectFiles() {
            let digest = url.deletingPathExtension().lastPathComponent
            guard !referenced.contains(digest),
                  !leased.contains(digest),
                  !installing.contains(digest)
            else { continue }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 { try ContentStorage.syncDirectory(paths.objects) }
        try persist()
        return removed
    }

    private func validateLoadedState() throws {
        guard let state else { throw StorageError.stateNotOpened }
        guard state.schemaEpoch == RuntimeSnapshot.schemaEpoch,
              state.schemaRevision >= RuntimeSnapshot.minimumReadableSchemaRevision,
              state.schemaRevision <= RuntimeSnapshot.schemaRevision
        else {
            throw StorageError.unsupportedSchema(
                epoch: state.schemaEpoch,
                revision: state.schemaRevision
            )
        }
        let libraryIDs = state.library.map(\.item.id)
        guard Set(libraryIDs).count == libraryIDs.count else {
            throw StorageError.corruptState("duplicate library item identity")
        }
    }

    private func migrateLoadedStateIfNeeded() throws {
        guard var current = state,
              current.schemaRevision < RuntimeSnapshot.schemaRevision else { return }
        current.schemaRevision = RuntimeSnapshot.schemaRevision
        state = current
        try persist()
    }

    private func requireInstallableJob(_ candidate: StagedArtifactCandidate) throws {
        try requireAcceptingImports()
        guard let persisted = try snapshot().importJobs.first(where: {
            $0.job.header.id == candidate.jobID
        }) else {
            throw StorageError.missingJob
        }
        guard persisted.job.header.attemptGeneration == candidate.generation else {
            throw StorageError.staleGeneration
        }
        guard persisted.job.header.phase == .awaitingInstallation,
              persisted.job.attempts.last?.state.terminalOutcome == .succeeded
        else {
            throw StorageError.jobNotInstallable
        }
    }

    private func persistedJob(
        jobID: JobID,
        generation: AttemptGeneration
    ) throws -> PersistedImportJob {
        guard let persisted = try snapshot().importJobs.first(where: {
            $0.job.header.id == jobID
        }) else {
            throw StorageError.missingJob
        }
        guard persisted.job.header.attemptGeneration == generation else {
            throw StorageError.staleGeneration
        }
        return persisted
    }

    private func replacePersistedJob(
        _ persisted: PersistedImportJob,
        with job: ImportJob
    ) throws {
        try saveImportJob(
            job,
            sourceURL: persisted.sourceURL,
            sourceBookmark: persisted.sourceBookmark,
            stagingDirectoryName: persisted.stagingDirectoryName
        )
    }

    private func requireStillCurrent(_ candidate: StagedArtifactCandidate) throws {
        try requireInstallableJob(candidate)
    }

    private func upsertJournal(_ journal: ArtifactInstallJournal) throws {
        try mutate { current in
            current.installJournals.removeAll { $0.id == journal.id }
            current.installJournals.append(journal)
        }
    }

    private func mutate(_ body: (inout RuntimeSnapshot) throws -> Void) throws {
        guard var current = state else { throw StorageError.stateNotOpened }
        try body(&current)
        try commit(current)
    }

    private func commit(_ next: RuntimeSnapshot) throws {
        var revised = next
        revised.revision &+= 1
        state = revised
        try persist()
    }

    private func persist() throws {
        guard let state else { throw StorageError.stateNotOpened }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        let temporary = paths.metadata.appendingPathComponent(
            ".runtime-state-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            try ContentStorage.syncFile(temporary)
            guard rename(temporary.path, paths.stateFile.path) == 0 else {
                throw StorageError.ioFailure(String(cString: strerror(errno)))
            }
            try ContentStorage.syncDirectory(paths.metadata)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func reconcileAfterCrash() async throws -> StorageRecoveryReport {
        guard var current = state else { throw StorageError.stateNotOpened }
        let now = Date()
        let expiredLeaseCount = current.leases.count(where: { $0.expiresAt <= now })
        current.leases.removeAll { $0.expiresAt <= now }
        let committedDigests = Set(current.library.flatMap { $0.artifacts.map(\.digest) })

        for record in current.library {
            for artifact in record.artifacts {
                let expected = try paths.objectURL(
                    forSHA256: artifact.digest.value,
                    mediaKind: artifact.mediaKind
                )
                guard expected.standardizedFileURL.path == artifact.objectURL.standardizedFileURL.path,
                      FileManager.default.fileExists(atPath: expected.path)
                else {
                    throw StorageError.missingPublishedArtifact
                }
                try ContentStorage.requireContainedRegularFile(expected, under: paths.objects)
            }
        }

        var abandonedPrepared = try removeAbandonedPreparedFiles()
        for index in current.installJournals.indices {
            guard current.installJournals[index].phase != .committed,
                  current.installJournals[index].phase != .cleaned
            else { continue }
            if let fileName = current.installJournals[index].preparedFileName {
                let url = paths.prepared.appendingPathComponent(fileName, isDirectory: false)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    abandonedPrepared += 1
                }
            }
            if let digest = current.installJournals[index].verifiedDigest,
               !committedDigests.contains(digest) {
                let url = try paths.objectURL(
                    forSHA256: digest.value,
                    mediaKind: current.installJournals[index].mediaKind
                )
                try? FileManager.default.removeItem(at: url)
            }
            current.installJournals[index].phase = .cleaned
            current.installJournals[index].updatedAt = now
        }
        for index in current.importJobs.indices {
            let persisted = current.importJobs[index]
            guard persisted.job.header.phase == .attemptActive,
                  persisted.job.attempts.last?.state == .dispatched,
                  let generation = persisted.job.header.attemptGeneration
            else { continue }
            var attempts = persisted.job.attempts
            attempts[attempts.count - 1] = .init(
                jobID: persisted.job.header.id,
                generation: generation,
                state: .terminal(.interrupted)
            )
            let header = try DurableJob(
                schema: persisted.job.schema,
                id: persisted.job.header.id,
                kind: .waliImport,
                idempotencyKey: persisted.job.header.idempotencyKey,
                expectedEngineRevision: persisted.job.header.expectedEngineRevision,
                phase: .attemptTerminal,
                attemptGeneration: generation,
                cancellationMarker: nil,
                terminalOutcome: nil
            )
            let recovered = try ImportJob(
                schema: persisted.job.schema,
                header: header,
                attempts: attempts,
                committedResult: nil
            )
            current.importJobs[index] = try PersistedImportJob(
                job: recovered,
                sourceURL: persisted.sourceURL,
                sourceBookmark: persisted.sourceBookmark,
                stagingDirectoryName: persisted.stagingDirectoryName,
                createdAt: persisted.createdAt,
                updatedAt: now
            )
        }
        for persisted in current.importJobs where persisted.job.header.phase == .terminal {
            let stagingURL = paths.staging.appendingPathComponent(
                persisted.stagingDirectoryName,
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try FileManager.default.removeItem(at: stagingURL)
            }
        }
        var retainedStagingNames = Set(current.importJobs.compactMap { persisted in
            switch persisted.job.header.phase {
            case .attemptActive, .awaitingInstallation:
                persisted.stagingDirectoryName
            case .pending, .attemptTerminal, .terminal:
                nil
            }
        })
        #if WALI_APP_STORE
        for persisted in current.importJobs where persisted.job.header.phase != .terminal && isAdoptedCatalogSource(persisted.sourceURL) {
            retainedStagingNames.insert(persisted.sourceURL.deletingLastPathComponent().lastPathComponent)
        }
        #endif
        let abandonedStaging = try removeAbandonedStagingDirectories(
            retaining: retainedStagingNames
        )
        let cleaned = current.installJournals
            .filter { $0.phase == .cleaned }
            .sorted { $0.updatedAt > $1.updatedAt }
        if cleaned.count > 512 {
            let retained = Set(cleaned.prefix(512).map(\.id))
            current.installJournals.removeAll {
                $0.phase == .cleaned && !retained.contains($0.id)
            }
        }
        state = current
        try persist()
        let completedTombstones = try collectTombstones()
        let removedObjects = try garbageCollect()
        return StorageRecoveryReport(
            abandonedPreparedFiles: abandonedPrepared,
            abandonedStagingDirectories: abandonedStaging,
            removedUnreferencedObjects: removedObjects,
            completedTombstones: completedTombstones,
            expiredLeases: expiredLeaseCount
        )
    }

    @discardableResult
    private func collectTombstones() throws -> Int {
        guard var current = state else { throw StorageError.stateNotOpened }
        let referenced = Set(current.library.flatMap { $0.artifacts.map(\.digest) })
        let leased = Set(current.leases.filter { $0.expiresAt > Date() }.map(\.digest))
        var completed: Set<ContentDigest> = []
        for tombstone in current.tombstones {
            guard !referenced.contains(tombstone.digest), !leased.contains(tombstone.digest) else {
                continue
            }
            let url = try paths.objectURL(
                forSHA256: tombstone.digest.value,
                mediaKind: tombstone.mediaKind
            )
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                try ContentStorage.syncDirectory(url.deletingLastPathComponent())
            }
            completed.insert(tombstone.digest)
        }
        current.tombstones.removeAll { completed.contains($0.digest) }
        state = current
        try persist()
        return completed.count
    }

    private func objectFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: paths.objects,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw StorageError.symbolicLinkRejected
            }
            if values.isRegularFile == true { files.append(url) }
        }
        return files
    }

    private func removeAbandonedPreparedFiles() throws -> Int {
        let entries = try FileManager.default.contentsOfDirectory(
            at: paths.prepared,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for url in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw StorageError.symbolicLinkRejected
            }
            guard values.isRegularFile == true else { throw StorageError.nonregularFile }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 { try ContentStorage.syncDirectory(paths.prepared) }
        return removed
    }

    private func removeAbandonedStagingDirectories(retaining names: Set<String>) throws -> Int {
        let entries = try FileManager.default.contentsOfDirectory(
            at: paths.staging,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for url in entries where !names.contains(url.lastPathComponent) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw StorageError.symbolicLinkRejected
            }
            guard values.isDirectory == true else { throw StorageError.invalidCandidate }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 { try ContentStorage.syncDirectory(paths.staging) }
        return removed
    }
}
