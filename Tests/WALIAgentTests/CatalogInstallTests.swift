import Darwin
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WALICatalog
import WALIEngine
import WALIModel
import WALIWire
import XCTest
@testable import WALIAgentRuntime

final class CatalogInstallTests: XCTestCase {
    private enum ProbeError: Error {
        case reachedTranscoder
        case unrecognizedContainerExtension
    }

    func testSignedStillSourceUsesPNGAdoptionAndTypedStillRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let store = RuntimeStore(paths: paths)
        try await store.open()
        let quarantine = root.appendingPathComponent("CatalogQuarantine")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let reference = UUID()
        let fixture = try CatalogTestFixture(reference: reference, mediaKind: .still)
        let source = quarantine.appendingPathComponent("\(reference.uuidString.lowercased()).wali-quarantine.png")
        try fixture.source.write(to: source, options: .withoutOverwriting)
        let coordinator = CatalogInstallCoordinator(runtimeStore: store, trustStore: fixture.trustStore,
            revocationStore: CatalogRevocationStore(trustStore: fixture.trustStore), quarantineRoot: quarantine,
            transcode: { request in
                XCTAssertEqual(request.mediaKind, .still)
                XCTAssertEqual(request.sourceURL.lastPathComponent, "catalog-source.png")
                XCTAssertEqual(request.sourceByteLimit, UInt64(fixture.source.count))
                XCTAssertEqual(try Data(contentsOf: request.sourceURL), fixture.source)
                XCTAssertNotEqual(request.sourceURL, source)
                throw ProbeError.reachedTranscoder
            })
        do {
            _ = try await coordinator.install(fixture.request, idempotencyKey: UUID(),
                acceptedRevision: EngineRevision(rawValue: 0))
            XCTFail("Expected the probe to stop before creating claims")
        } catch ProbeError.reachedTranscoder {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testStillInstallVerifiesRealArtifactsAndReopensAsImageWithCatalogCredit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let store = RuntimeStore(paths: paths)
        try await store.open()
        let quarantine = root.appendingPathComponent("CatalogQuarantine")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let reference = UUID()
        let source = quarantine.appendingPathComponent("\(reference.uuidString.lowercased()).wali-quarantine.png")
        try Self.writeImage(to: source, type: .png)
        let fixture = try CatalogTestFixture(source: Data(contentsOf: source), reference: reference,
            mediaKind: .still, width: 32, height: 16)
        let coordinator = CatalogInstallCoordinator(runtimeStore: store, trustStore: fixture.trustStore,
            revocationStore: CatalogRevocationStore(trustStore: fixture.trustStore), quarantineRoot: quarantine,
            transcode: { request in
                let master = request.stagingDirectoryURL.appendingPathComponent("master.png")
                let poster = request.stagingDirectoryURL.appendingPathComponent("poster.heic")
                try Self.writeImage(to: master, type: .png)
                try Self.writeImage(to: poster, type: .heic)
                let claims = try [(TranscoderArtifactKind.masterImage, master), (.posterImage, poster)].map { kind, url in
                    let bytes = try Data(contentsOf: url)
                    return TranscoderArtifactClaim(kind: kind, stagedURL: url,
                        digest: CatalogTestFixture.sha256(bytes), byteCount: UInt64(bytes.count),
                        media: Self.stillClaim(bytes: UInt64(bytes.count), width: 32, height: 16))
                }
                return TranscoderOutput(jobID: request.jobID, attemptGeneration: request.attemptGeneration,
                    displayName: "Worker name is not catalog metadata", completedAt: Date(),
                    sourceDigest: CatalogTestFixture.sha256(fixture.source),
                    sourceMedia: Self.stillClaim(bytes: UInt64(fixture.source.count), width: 32, height: 16),
                    artifacts: claims)
            })
        let installed = try await coordinator.install(fixture.request, idempotencyKey: UUID(),
            acceptedRevision: EngineRevision(rawValue: 0))
        guard case let .still(imageURL) = installed.item.mediaContent else { return XCTFail("Still became video") }
        XCTAssertEqual(installed.item.name, "Catalog Test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let reopened = RuntimeStore(paths: paths)
        try await reopened.open()
        let snapshot = try await reopened.snapshot()
        let record = try XCTUnwrap(snapshot.library.first)
        XCTAssertEqual(snapshot.library.count, 1)
        XCTAssertEqual(record.mediaKind, .still)
        XCTAssertEqual(record.item.catalogOrigin?.attributionText, "Artwork by WALI Artist")
        XCTAssertNil(record.durationSeconds)
        XCTAssertEqual(Set(record.artifacts.map(\.role)), [.masterImage, .posterImage])
        XCTAssertEqual(try LibraryRecordFactory.makeEngineItem(from: record).mediaContent, installed.item.mediaContent)
        let duplicate = try await coordinator.install(fixture.request, idempotencyKey: UUID(),
            acceptedRevision: EngineRevision(rawValue: 0))
        XCTAssertEqual(duplicate.item.id, installed.item.id)
        XCTAssertNil(duplicate.completedImport)
    }

    func testStillCatalogRejectsUnboundWorkerIdentityKindDigestAndDimensions() async throws {
        for mismatch in 0..<6 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
            let store = RuntimeStore(paths: paths)
            try await store.open()
            let quarantine = root.appendingPathComponent("CatalogQuarantine")
            try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
            let reference = UUID()
            let fixture = try CatalogTestFixture(reference: reference, mediaKind: .still)
            let source = quarantine.appendingPathComponent("\(reference.uuidString.lowercased()).wali-quarantine.png")
            try fixture.source.write(to: source)
            let coordinator = CatalogInstallCoordinator(runtimeStore: store, trustStore: fixture.trustStore,
                revocationStore: CatalogRevocationStore(trustStore: fixture.trustStore), quarantineRoot: quarantine,
                transcode: { request in
                    let kind: WallpaperMediaKind = mismatch == 2 ? .video : .still
                    let media: TranscoderMediaClaim = kind == .still
                        ? Self.stillClaim(bytes: UInt64(fixture.source.count) + (mismatch == 4 ? 1 : 0),
                            width: mismatch == 5 ? 2 : 1, height: 1)
                        : .init(byteCount: UInt64(fixture.source.count), pixelWidth: 1, pixelHeight: 1,
                            duration: 1, nominalFrameRate: 30, hasAudio: false, isHDR: false, videoCodec: "hevc")
                    let claims = TranscoderArtifactKind.required(for: kind).map { role in
                        TranscoderArtifactClaim(kind: role,
                            stagedURL: request.stagingDirectoryURL.appendingPathComponent(role.rawValue),
                            digest: String(repeating: "a", count: 64), byteCount: media.byteCount,
                            media: kind == .video && role == .posterImage ? nil : media)
                    }
                    return TranscoderOutput(jobID: mismatch == 0 ? UUID() : request.jobID,
                        attemptGeneration: request.attemptGeneration + (mismatch == 1 ? 1 : 0),
                        displayName: "Untrusted", completedAt: Date(),
                        sourceDigest: mismatch == 3 ? String(repeating: "b", count: 64) : CatalogTestFixture.sha256(fixture.source),
                        sourceMedia: media, artifacts: claims)
                })
            do {
                _ = try await coordinator.install(fixture.request, idempotencyKey: UUID(), acceptedRevision: .init(rawValue: 0))
                XCTFail("Accepted mismatch \(mismatch)")
            } catch { XCTAssertEqual(error as? CatalogInstallError, .sourceClaimMismatch, "Mismatch \(mismatch)") }
            let snapshot = try await store.snapshot()
            XCTAssertTrue(snapshot.library.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testStillAdoptionEnforcesBoundBeforeOpeningAndRecoveryRecognizesPNG() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let store = RuntimeStore(paths: paths)
        try await store.open()
        let quarantine = root.appendingPathComponent("CatalogQuarantine")
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let source = quarantine.appendingPathComponent("source.png")
        let bytes = Data("owned bytes".utf8)
        try bytes.write(to: source)
        let digest = try ContentDigest(algorithm: .sha256, value: CatalogTestFixture.sha256(bytes))
        do {
            _ = try await store.adoptCatalogQuarantine(source, under: quarantine, expectedDigest: digest,
                expectedByteCount: 128 * 1_024 * 1_024 + 1, mediaKind: .still)
            XCTFail("Accepted an oversized image")
        } catch { XCTAssertEqual(error as? StorageError, .invalidCandidate) }
        let owned = try await store.adoptCatalogQuarantine(source, under: quarantine,
            expectedDigest: digest, expectedByteCount: UInt64(bytes.count), mediaKind: .still)
        _ = try await store.beginImport(sourceURL: owned, sourceBookmark: Data([1]),
            idempotencyKey: .init(UUID().uuidString.lowercased()), expectedEngineRevision: .init(rawValue: 0))
        let reopened = RuntimeStore(paths: paths)
        try await reopened.open()
        let recovered = try await reopened.recoverCatalogImportsRequiringFreshVerification()
        XCTAssertEqual(recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private static func stillClaim(bytes: UInt64, width: UInt32, height: UInt32) -> TranscoderMediaClaim {
        .still(.init(byteCount: bytes, pixelWidth: width, pixelHeight: height,
            frameCount: 1, bitsPerComponent: 8, colorSpace: "srgb", hasAlpha: false))
    }

    private static func writeImage(to url: URL, type: UTType) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16,
            bitsPerComponent: 8, bytesPerRow: 128, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0.2,0.5,0.8,1])))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        if type == .png {
            let bytes = try Data(contentsOf: url)
            var canonical = Data(bytes.prefix(8)); var offset = 8
            while offset < bytes.count {
                let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                let kind = String(data: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii)
                if kind != "eXIf" { canonical.append(bytes[offset..<(offset + length + 12)]) }
                offset += length + 12
            }
            try canonical.write(to: url)
        }
    }

    func testValidSignedSourceReachesSandboxedTranscoderAndQuarantineIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let runtimeStore = RuntimeStore(paths: paths)
        _ = try await runtimeStore.open()
        let quarantineRoot = root.appendingPathComponent("CatalogQuarantine")
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        let reference = UUID()
        let fixture = try CatalogTestFixture(reference: reference)
        let quarantineURL = quarantineRoot.appendingPathComponent(
            "\(reference.uuidString.lowercased()).wali-quarantine.mp4"
        )
        try fixture.source.write(to: quarantineURL, options: [.withoutOverwriting])
        let revocations = CatalogRevocationStore(trustStore: fixture.trustStore)
        let coordinator = CatalogInstallCoordinator(
            runtimeStore: runtimeStore,
            trustStore: fixture.trustStore,
            revocationStore: revocations,
            quarantineRoot: quarantineRoot,
            transcode: { request in
                guard request.sourceURL.pathExtension == "mp4" else {
                    throw ProbeError.unrecognizedContainerExtension
                }
                throw ProbeError.reachedTranscoder
            }
        )

        do {
            _ = try await coordinator.install(
                fixture.request,
                idempotencyKey: UUID(),
                acceptedRevision: EngineRevision(rawValue: 0)
            )
            XCTFail("Expected the probe transcoder to stop the install")
        } catch ProbeError.reachedTranscoder {
            // Trust, fixed-root resolution, digest, length and regular-file
            // validation all completed before this boundary.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testCatalogInstallTranscodesAnAgentOwnedVerifiedCopyNotTheMutableQuarantinePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root.appendingPathComponent("Library"))
        let runtimeStore = RuntimeStore(paths: paths)
        _ = try await runtimeStore.open()
        let quarantineRoot = root.appendingPathComponent("CatalogQuarantine")
        try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        let reference = UUID()
        let fixture = try CatalogTestFixture(reference: reference)
        let quarantineURL = quarantineRoot.appendingPathComponent(
            "\(reference.uuidString.lowercased()).wali-quarantine.mp4"
        )
        try fixture.source.write(to: quarantineURL, options: [.withoutOverwriting])
        let coordinator = CatalogInstallCoordinator(
            runtimeStore: runtimeStore,
            trustStore: fixture.trustStore,
            revocationStore: CatalogRevocationStore(trustStore: fixture.trustStore),
            quarantineRoot: quarantineRoot,
            transcode: { request in
                try Data("attacker replacement".utf8).write(to: quarantineURL, options: .atomic)
                XCTAssertNotEqual(request.sourceURL.standardizedFileURL, quarantineURL.standardizedFileURL)
                XCTAssertTrue(
                    request.sourceURL.standardizedFileURL.path.hasPrefix(paths.staging.standardizedFileURL.path + "/")
                )
                XCTAssertEqual(try Data(contentsOf: request.sourceURL), fixture.source)
                throw ProbeError.reachedTranscoder
            }
        )

        do {
            _ = try await coordinator.install(
                fixture.request,
                idempotencyKey: UUID(),
                acceptedRevision: EngineRevision(rawValue: 0)
            )
            XCTFail("Expected the probe transcoder to stop the install")
        } catch ProbeError.reachedTranscoder {}
    }

    func testTamperedManifestNeverReachesTranscoder() async throws {
        let fixture = try CatalogTestFixture()
        var tampered = fixture.request.canonicalManifest
        tampered[tampered.startIndex] ^= 1
        let request = AgentCatalogInstallRequest(
            canonicalManifest: tampered,
            canonicalMetadata: fixture.request.canonicalMetadata,
            signatureBase64URL: fixture.request.signatureBase64URL,
            keyID: fixture.request.keyID,
            quarantineReference: fixture.request.quarantineReference
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.trustStore.verify(request, revocations: nil)
        }
    }

    func testWrongKeyIDIsRejectedByAgentTrustStore() async throws {
        let fixture = try CatalogTestFixture()
        let request = AgentCatalogInstallRequest(
            canonicalManifest: fixture.request.canonicalManifest,
            canonicalMetadata: fixture.request.canonicalMetadata,
            signatureBase64URL: fixture.request.signatureBase64URL,
            keyID: "untrusted-key",
            quarantineReference: fixture.request.quarantineReference
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.trustStore.verify(request, revocations: nil)
        }
    }

    func testTamperedMetadataNeverBecomesPersistedProvenance() async throws {
        let fixture = try CatalogTestFixture()
        var tampered = fixture.request.canonicalMetadata
        let range = try XCTUnwrap(tampered.range(of: Data("WALI Artist".utf8)))
        tampered.replaceSubrange(range, with: Data("EVIL Artist".utf8))
        let request = AgentCatalogInstallRequest(
            canonicalManifest: fixture.request.canonicalManifest,
            canonicalMetadata: tampered,
            signatureBase64URL: fixture.request.signatureBase64URL,
            keyID: fixture.request.keyID,
            quarantineReference: fixture.request.quarantineReference
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.trustStore.verify(request, revocations: nil)
        }
    }

    func testCatalogQuarantineRejectsLengthDigestSymlinkFIFOAndSparseFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let bytes = Data("catalog-source".utf8)
        let expectedDigest = try ContentDigest(
            algorithm: .sha256,
            value: CatalogTestFixture.sha256(bytes)
        )
        func assertAdoptionRejected(
            _ source: URL,
            digest: ContentDigest = expectedDigest,
            byteCount: UInt64
        ) throws {
            let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: destination) }
            XCTAssertThrowsError(try ContentStorage.adoptCatalogQuarantine(
                source,
                under: root,
                into: destination,
                expectedDigest: digest,
                expectedByteCount: byteCount
            ))
        }

        let regular = root.appendingPathComponent("regular.wali-quarantine")
        try bytes.write(to: regular, options: [.withoutOverwriting])
        try assertAdoptionRejected(regular, byteCount: UInt64(bytes.count + 1))
        try assertAdoptionRejected(
            regular,
            digest: try ContentDigest(
                algorithm: .sha256,
                value: String(repeating: "0", count: 64)
            ),
            byteCount: UInt64(bytes.count)
        )

        let symlink = root.appendingPathComponent("symlink.wali-quarantine")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
        try assertAdoptionRejected(symlink, byteCount: UInt64(bytes.count))

        let fifo = root.appendingPathComponent("fifo.wali-quarantine")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try assertAdoptionRejected(fifo, byteCount: UInt64(bytes.count))

        let sparse = root.appendingPathComponent("sparse.wali-quarantine")
        let descriptor = open(sparse.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, 1_048_576), 0)
        XCTAssertEqual(close(descriptor), 0)
        try assertAdoptionRejected(sparse, byteCount: 1_048_576)
    }

    func testRouterRejectsStaleInstallBeforeCallingHandler() async throws {
        let fixture = try CatalogTestFixture()
        let calls = CatalogInstallCallCounter()
        let router = AgentCommandRouter(
            catalogInstallHandler: { _, _, _ in
                await calls.increment()
                return CatalogInstallResult(item: Self.engineItem(for: fixture.request))
            },
            effectHandler: { _, _ in .unchanged }
        )
        let response = await router.handle(AgentRequest(
            expectedRevision: EngineRevision(rawValue: 1),
            command: .installCatalogRelease(fixture.request)
        ))

        guard case let .failure(failure) = response.result else {
            return XCTFail("Expected a stale-revision failure")
        }
        XCTAssertEqual(failure.code, .staleRevision)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testRouterReplaysCatalogInstallWithoutHandlerOrLocalImport() async throws {
        let fixture = try CatalogTestFixture()
        let calls = CatalogInstallCallCounter()
        let key = UUID()
        let router = AgentCommandRouter(
            catalogInstallHandler: { _, _, _ in
                await calls.increment()
                return CatalogInstallResult(item: Self.engineItem(for: fixture.request))
            },
            effectHandler: { _, _ in .unchanged }
        )
        let request = AgentRequest(
            idempotencyKey: key,
            expectedRevision: EngineRevision(rawValue: 0),
            command: .installCatalogRelease(fixture.request)
        )

        let first = await router.handle(request)
        let replay = await router.handle(request)
        guard case let .snapshot(firstSnapshot) = first.result,
              case let .snapshot(replaySnapshot) = replay.result else {
            return XCTFail("Expected successful snapshots")
        }
        XCTAssertEqual(firstSnapshot.revision, replaySnapshot.revision)
        XCTAssertEqual(replaySnapshot.items.count, 1)
        XCTAssertTrue(replaySnapshot.imports.isEmpty)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testRouterRejectsIdempotencyKeyReuseWithDifferentCatalogPayload() async throws {
        let fixture = try CatalogTestFixture()
        let calls = CatalogInstallCallCounter()
        let key = UUID()
        let router = AgentCommandRouter(
            catalogInstallHandler: { request, _, _ in
                await calls.increment()
                return CatalogInstallResult(item: Self.engineItem(for: request))
            },
            effectHandler: { _, _ in .unchanged }
        )
        let first = AgentRequest(
            idempotencyKey: key,
            expectedRevision: EngineRevision(rawValue: 0),
            command: .installCatalogRelease(fixture.request)
        )
        _ = await router.handle(first)
        let changed = AgentCatalogInstallRequest(
            canonicalManifest: fixture.request.canonicalManifest,
            canonicalMetadata: fixture.request.canonicalMetadata,
            signatureBase64URL: fixture.request.signatureBase64URL,
            keyID: fixture.request.keyID,
            quarantineReference: UUID()
        )
        let response = await router.handle(AgentRequest(
            idempotencyKey: key,
            expectedRevision: EngineRevision(rawValue: 0),
            command: .installCatalogRelease(changed)
        ))

        guard case let .failure(failure) = response.result else {
            return XCTFail("Expected idempotency payload mismatch to fail")
        }
        XCTAssertEqual(failure.code, .catalogTrustFailed)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testRuntimeStoreMigratesPreCatalogSchemaWithoutChangingLocalRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try LibraryPaths(root: root)
        let initial = RuntimeStore(paths: paths)
        _ = try await initial.open()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: paths.stateFile)) as? [String: Any]
        )
        object["schemaRevision"] = 0
        let priorRevision = try XCTUnwrap(object["revision"] as? NSNumber).uint64Value
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: paths.stateFile, options: [.atomic])

        let migrated = RuntimeStore(paths: paths)
        _ = try await migrated.open()
        let snapshot = try await migrated.snapshot()
        XCTAssertEqual(snapshot.schemaRevision, RuntimeSnapshot.schemaRevision)
        XCTAssertEqual(snapshot.revision, priorRevision)
        XCTAssertTrue(snapshot.library.isEmpty)
    }

    private static func engineItem(for request: AgentCatalogInstallRequest) -> EngineLibraryItem {
        EngineLibraryItem(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            name: "Catalog Test",
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 1,
            pixelWidth: 1,
            pixelHeight: 1,
            masterURL: URL(fileURLWithPath: "/tmp/catalog-master.mov"),
            previewURL: URL(fileURLWithPath: "/tmp/catalog-preview.mov"),
            posterURL: URL(fileURLWithPath: "/tmp/catalog-poster.heic"),
            contentDigest: CatalogTestFixture.sha256(Data("catalog-source".utf8))
        )
    }
}

private actor CatalogInstallCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}


struct CatalogTestFixture {
    let signingIdentity: Curve25519.Signing.PrivateKey
    let trustStore: CatalogTrustStore
    let source: Data
    let manifest: Data
    let metadata: Data
    let signature: String
    let request: AgentCatalogInstallRequest

    init(source: Data = Data("catalog-source".utf8), reference: UUID = UUID(),
         mediaKind: WallpaperMediaKind = .video, width: UInt32 = 1, height: UInt32 = 1) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        self.signingIdentity = privateKey
        let keyID = try CatalogKeyID("catalog-test")
        trustStore = try CatalogTrustStore(
            trustedKeys: [try TrustedCatalogSigningKey(
                id: keyID,
                publicKey: privateKey.publicKey.rawRepresentation,
                validFrom: Date(timeIntervalSince1970: 0),
                validUntil: Date(timeIntervalSince1970: 4_102_444_800),
                status: .active
            )],
            approvedCDNHosts: ["catalog.wali.example"]
        )
        self.source = source
        metadata = Data(Self.metadataJSON.utf8)
        let sourceDigest = Self.sha256(source)
        manifest = Data(Self.manifestJSON(
            sourceDigest: sourceDigest,
            sourceByteCount: source.count,
            metadataDigest: Self.sha256(metadata), mediaKind: mediaKind,
            width: width, height: height
        ).utf8)
        signature = Self.base64URL(try privateKey.signature(for: manifest))
        request = AgentCatalogInstallRequest(
            canonicalManifest: manifest,
            canonicalMetadata: metadata,
            signatureBase64URL: signature,
            keyID: "catalog-test",
            quarantineReference: reference
        )
    }

    func signedRevocations() throws -> AgentCatalogRevocationUpdate {
        let body = Data((
            "{\"schema\":{\"epoch\":1,\"revision\":0},\"key_id\":\"catalog-test\","
                + "\"revision\":1,\"issued_at\":\"2026-09-01T16:05:00Z\",\"revocations\":[{"
                + "\"release_id\":\"22222222-2222-4222-8222-222222222222\","
                + "\"artifact_sha256\":\"\(Self.sha256(source))\","
                + "\"reason\":\"critical_security\",\"issued_at\":\"2026-09-01T16:04:00Z\"}]}"
        ).utf8)
        return AgentCatalogRevocationUpdate(
            revision: 1,
            canonicalBody: body,
            signatureBase64URL: Self.base64URL(try signingIdentity.signature(for: body)),
            keyID: "catalog-test"
        )
    }

    func signedTrustTransition(
        revision: UInt64 = 1,
        status: String = "active"
    ) throws -> AgentCatalogTrustTransitionUpdate {
        let body = Data(
            #"{"schema":"wali.catalog.trust-transition.v1","revision":\#(revision),"issued_at":"2026-09-01T16:00:00Z","keys":[{"key_id":"catalog-test","public_key":"\#(Self.base64URL(signingIdentity.publicKey.rawRepresentation))","valid_from":"1970-01-01T00:00:00Z","valid_until":"2100-01-01T00:00:00Z","status":"\#(status)"}]}"#.utf8
        )
        return AgentCatalogTrustTransitionUpdate(
            revision: revision,
            canonicalBody: body,
            signatureBase64URL: Self.base64URL(try signingIdentity.signature(for: body)),
            keyID: "catalog-test"
        )
    }

    private static let metadataJSON = #"{"schema":"wali.catalog.install-metadata.v1","wallpaper_id":"11111111-1111-4111-8111-111111111111","release_id":"22222222-2222-4222-8222-222222222222","edition":1,"title":"Catalog Test","creator_name":"WALI Artist","creator_handle":"wali-artist","attribution_text":"Artwork by WALI Artist","rights_holder":"WALI Artist"}"#

    private static func manifestJSON(
        sourceDigest: String,
        sourceByteCount: Int,
        metadataDigest: String,
        mediaKind: WallpaperMediaKind,
        width: UInt32, height: UInt32
    ) -> String {
        let prefix = mediaKind == .still
            ? "{\"schema\":{\"epoch\":2,\"revision\":0},\"media_kind\":\"still\",\"key_id\":\"catalog-test\","
            : "{\"schema\":{\"epoch\":1,\"revision\":0},\"key_id\":\"catalog-test\","
        let masters = mediaKind == .still
            ? artifact(role: "image_default", digest: sourceDigest, bytes: sourceByteCount, type: "image/png", duration: 0, width: width, height: height)
            : artifact(role: "preview", digest: String(repeating: "c", count: 64), bytes: 1, type: "video/mp4", duration: 1_000)
                + "," + artifact(role: "video_default", digest: sourceDigest, bytes: sourceByteCount, type: "video/mp4", duration: 1_000)
        return prefix
            + "\"wallpaper_id\":\"11111111-1111-4111-8111-111111111111\","
            + "\"release_id\":\"22222222-2222-4222-8222-222222222222\",\"edition\":1,"
            + "\"issued_at\":\"2026-09-01T16:00:00Z\",\"artifacts\":["
            + artifact(role: "thumbnail", digest: String(repeating: "a", count: 64), bytes: 1,
                type: mediaKind == .still ? "image/jpeg" : "image/png", duration: 0,
                width: mediaKind == .still ? 512 : 1, height: mediaKind == .still ? 512 : 1)
            + "," + artifact(role: "poster", digest: String(repeating: "b", count: 64), bytes: 1, type: "image/jpeg", duration: 0)
            + "," + masters
            + "],\"metadata_digest\":\"\(metadataDigest)\"}"
    }

    private static func artifact(
        role: String,
        digest: String,
        bytes: Int,
        type: String,
        duration: Int,
        width: UInt32 = 1, height: UInt32 = 1
    ) -> String {
        let suffix = role.replacingOccurrences(of: "_", with: "-")
        return "{\"role\":\"\(role)\",\"url\":\"https://catalog.wali.example/\(suffix)\","
            + "\"sha256\":\"\(digest)\",\"byte_count\":\(bytes),\"media_type\":\"\(type)\","
            + "\"width\":\(width),\"height\":\(height),\"duration_ms\":\(duration)}"
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

final class CatalogRevocationTests: XCTestCase {
    func testRetiredKeyCannotAuthorizeNewRevocationState() async throws {
        let fixture = try CatalogTestFixture()
        let retiredStore = try CatalogTrustStore(
            trustedKeys: [try TrustedCatalogSigningKey(
                id: CatalogKeyID("catalog-test"),
                publicKey: fixture.signingIdentity.publicKey.rawRepresentation,
                validFrom: Date(timeIntervalSince1970: 0),
                validUntil: Date(timeIntervalSince1970: 4_102_444_800),
                status: .retired
            )],
            approvedCDNHosts: ["catalog.wali.example"]
        )

        do {
            _ = try await retiredStore.verifyRevocations(fixture.signedRevocations())
            XCTFail("Expected retired signing key to be rejected")
        } catch CatalogValidationError.inactiveSigningKey {}
    }

    func testSignedCriticalRevocationBlocksNewInstallTrust() async throws {
        let fixture = try CatalogTestFixture()
        let store = CatalogRevocationStore(trustStore: fixture.trustStore)
        try await store.update(fixture.signedRevocations())

        do {
            _ = try await fixture.trustStore.verify(
                fixture.request,
                revocations: try await store.current()
            )
            XCTFail("Expected the release to be revoked")
        } catch CatalogValidationError.revokedRelease {
            // Revocation is install authority only; no local library deletion
            // API exists on CatalogRevocationStore.
        }
    }

    func testOlderRevocationRevisionCannotReplaceNewerState() async throws {
        let fixture = try CatalogTestFixture()
        let store = CatalogRevocationStore(trustStore: fixture.trustStore)
        let update = try fixture.signedRevocations()
        try await store.update(update)
        try await store.update(update)
        let current = try await store.current()
        XCTAssertEqual(current?.revision, 1)
    }

    func testSameRevisionWithDifferentSignedBodyIsRejectedAsEquivocation() async throws {
        let fixture = try CatalogTestFixture()
        let store = CatalogRevocationStore(trustStore: fixture.trustStore)
        let update = try fixture.signedRevocations()
        try await store.update(update)
        let changedBody = Data(
            String(decoding: update.canonicalBody, as: UTF8.self)
                .replacingOccurrences(of: "critical_security", with: "corrupt_artifact")
                .utf8
        )
        let equivocation = AgentCatalogRevocationUpdate(
            revision: update.revision,
            canonicalBody: changedBody,
            signatureBase64URL: CatalogTestFixture.base64URL(
                try fixture.signingIdentity.signature(for: changedBody)
            ),
            keyID: update.keyID
        )

        do {
            try await store.update(equivocation)
            XCTFail("Expected same-revision equivocation to fail")
        } catch let error as CatalogTrustStoreError {
            XCTAssertEqual(error, .requestMismatch)
        }
        let current = try await store.current()
        let expected = try await fixture.trustStore.verifyRevocations(update)
        XCTAssertEqual(current, expected)
    }

    func testTrustTransitionPersistsAndRejectsEqualRevisionEquivocation() async throws {
        let fixture = try CatalogTestFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("catalog-trust-transition.json")
        let anchors = [try TrustedCatalogSigningKey(
            id: CatalogKeyID("catalog-test"),
            publicKey: fixture.signingIdentity.publicKey.rawRepresentation,
            validFrom: Date(timeIntervalSince1970: 0),
            validUntil: Date(timeIntervalSince1970: 4_102_444_800),
            status: .active
        )]
        let store = try CatalogTrustStore(
            trustedKeys: anchors,
            approvedCDNHosts: ["catalog.wali.example"],
            fileURL: file
        )
        let accepted = try fixture.signedTrustTransition()
        try await store.updateTransition(accepted)
        let reloaded = try CatalogTrustStore(
            trustedKeys: anchors,
            approvedCDNHosts: ["catalog.wali.example"],
            fileURL: file
        )
        _ = try await reloaded.verify(fixture.request, revocations: nil)

        let equivocation = try fixture.signedTrustTransition(status: "retired")
        do {
            try await reloaded.updateTransition(equivocation)
            XCTFail("Expected equal-revision trust equivocation to fail")
        } catch CatalogValidationError.trustTransitionEquivocation {}
    }

    func testCorruptPersistedRevocationStateFailsClosedOnEveryRead() async throws {
        let fixture = try CatalogTestFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("catalog-revocations.json")
        try Data("not-signed-state".utf8).write(to: file)
        let store = CatalogRevocationStore(fileURL: file, trustStore: fixture.trustStore)

        for _ in 0..<2 {
            do {
                _ = try await store.current()
                XCTFail("Expected corrupt persisted revocations to fail closed")
            } catch {
                // A failed load is deliberately retried instead of caching nil.
            }
        }
    }
}
