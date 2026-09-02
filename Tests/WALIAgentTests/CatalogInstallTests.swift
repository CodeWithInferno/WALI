import Darwin
import CryptoKit
import Foundation
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
                return Self.engineItem(for: fixture.request)
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
                return Self.engineItem(for: fixture.request)
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
                return Self.engineItem(for: request)
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
    let privateKey: Curve25519.Signing.PrivateKey
    let trustStore: CatalogTrustStore
    let source: Data
    let manifest: Data
    let metadata: Data
    let signature: String
    let request: AgentCatalogInstallRequest

    init(source: Data = Data("catalog-source".utf8), reference: UUID = UUID()) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        self.privateKey = privateKey
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
            metadataDigest: Self.sha256(metadata)
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
            signatureBase64URL: Self.base64URL(try privateKey.signature(for: body)),
            keyID: "catalog-test"
        )
    }

    func signedTrustTransition(
        revision: UInt64 = 1,
        status: String = "active"
    ) throws -> AgentCatalogTrustTransitionUpdate {
        let body = Data(
            #"{"schema":"wali.catalog.trust-transition.v1","revision":\#(revision),"issued_at":"2026-09-01T16:00:00Z","keys":[{"key_id":"catalog-test","public_key":"\#(Self.base64URL(privateKey.publicKey.rawRepresentation))","valid_from":"1970-01-01T00:00:00Z","valid_until":"2100-01-01T00:00:00Z","status":"\#(status)"}]}"#.utf8
        )
        return AgentCatalogTrustTransitionUpdate(
            revision: revision,
            canonicalBody: body,
            signatureBase64URL: Self.base64URL(try privateKey.signature(for: body)),
            keyID: "catalog-test"
        )
    }

    private static let metadataJSON = #"{"schema":"wali.catalog.install-metadata.v1","wallpaper_id":"11111111-1111-4111-8111-111111111111","release_id":"22222222-2222-4222-8222-222222222222","edition":1,"title":"Catalog Test","creator_name":"WALI Artist","creator_handle":"wali-artist","attribution_text":"Artwork by WALI Artist","rights_holder":"WALI Artist"}"#

    private static func manifestJSON(
        sourceDigest: String,
        sourceByteCount: Int,
        metadataDigest: String
    ) -> String {
        "{\"schema\":{\"epoch\":1,\"revision\":0},\"key_id\":\"catalog-test\","
            + "\"wallpaper_id\":\"11111111-1111-4111-8111-111111111111\","
            + "\"release_id\":\"22222222-2222-4222-8222-222222222222\",\"edition\":1,"
            + "\"issued_at\":\"2026-09-01T16:00:00Z\",\"artifacts\":["
            + artifact(role: "thumbnail", digest: String(repeating: "a", count: 64), bytes: 1, type: "image/png", duration: 0)
            + "," + artifact(role: "poster", digest: String(repeating: "b", count: 64), bytes: 1, type: "image/jpeg", duration: 0)
            + "," + artifact(role: "preview", digest: String(repeating: "c", count: 64), bytes: 1, type: "video/mp4", duration: 1_000)
            + "," + artifact(role: "video_default", digest: sourceDigest, bytes: sourceByteCount, type: "video/mp4", duration: 1_000)
            + "],\"metadata_digest\":\"\(metadataDigest)\"}"
    }

    private static func artifact(
        role: String,
        digest: String,
        bytes: Int,
        type: String,
        duration: Int
    ) -> String {
        let suffix = role.replacingOccurrences(of: "_", with: "-")
        return "{\"role\":\"\(role)\",\"url\":\"https://catalog.wali.example/\(suffix)\","
            + "\"sha256\":\"\(digest)\",\"byte_count\":\(bytes),\"media_type\":\"\(type)\","
            + "\"width\":1,\"height\":1,\"duration_ms\":\(duration)}"
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
                publicKey: fixture.privateKey.publicKey.rawRepresentation,
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
                try fixture.privateKey.signature(for: changedBody)
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
            publicKey: fixture.privateKey.publicKey.rawRepresentation,
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
