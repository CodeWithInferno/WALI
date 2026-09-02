import CryptoKit
import Foundation
import Testing
@testable import WALICatalog

@Suite("Signed catalog manifests")
struct ManifestVerifierTests {
    private let wallpaperID = "11111111-1111-1111-1111-111111111111"
    private let releaseID = "22222222-2222-2222-2222-222222222222"
    private let digest = String(repeating: "a", count: 64)

    @Test("Verifies an exact canonical Ed25519 manifest")
    func verifiesManifest() throws {
        let fixture = try makeFixture()
        let verified = try fixture.verifier.verify(
            manifestData: fixture.data,
            signatureBase64URL: fixture.signature,
            context: fixture.context
        )
        #expect(verified.manifest.wallpaperID == wallpaperID)
        #expect(verified.manifest.artifacts.count == 4)
        #expect(verified.signedBytes == fixture.data)
    }

    @Test("Verifies the repository golden fixture byte for byte")
    func verifiesGoldenFixture() throws {
        let root = repositoryRoot()
        let data = try Data(contentsOf: root.appending(path: "Fixtures/Catalog/manifest-v1.json"))
        let signature = try String(
            contentsOf: root.appending(path: "Fixtures/Catalog/manifest-v1.signature"),
            encoding: .utf8
        )
        let publicKey = try #require(
            Data(hex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        )
        let issuedAt = try parseCatalogTimestamp("2026-09-01T16:00:00Z")
        let key = try TrustedCatalogSigningKey(
            id: CatalogKeyID("catalog-test-2026-01"),
            publicKey: publicKey,
            validFrom: issuedAt.addingTimeInterval(-1),
            validUntil: issuedAt.addingTimeInterval(1),
            status: .active
        )
        let verifier = try ManifestVerifier(
            trustedKeys: [key],
            approvedCDNHosts: ["catalog.wali.example"]
        )
        let verified = try verifier.verify(
            manifestData: data,
            signatureBase64URL: signature,
            context: CatalogVerificationContext(
                wallpaperID: "11111111-1111-4111-8111-111111111111",
                releaseID: "22222222-2222-4222-8222-222222222222",
                metadataDigest: String(repeating: "e", count: 64)
            )
        )
        #expect(verified.signedBytes == data)
    }

    @Test("Rejects tampering and cross-release replay")
    func rejectsTamperAndReplay() throws {
        let fixture = try makeFixture()
        var tampered = fixture.data
        let range = try #require(tampered.range(of: Data("1080".utf8)))
        tampered.replaceSubrange(range, with: Data("1081".utf8))
        expectCatalogError(.invalidSignature) {
            _ = try fixture.verifier.verify(
                manifestData: tampered,
                signatureBase64URL: fixture.signature,
                context: fixture.context
            )
        }

        let replayContext = try CatalogVerificationContext(
            wallpaperID: "33333333-3333-3333-3333-333333333333",
            releaseID: releaseID,
            metadataDigest: digest
        )
        expectCatalogError(.metadataMismatch) {
            _ = try fixture.verifier.verify(
                manifestData: fixture.data,
                signatureBase64URL: fixture.signature,
                context: replayContext
            )
        }
    }

    @Test("Rejects an unapproved artifact host")
    func rejectsHostSubstitution() throws {
        let fixture = try makeFixture(host: "evil.example")
        expectCatalogError(.unapprovedHost) {
            _ = try fixture.verifier.verify(
                manifestData: fixture.data,
                signatureBase64URL: fixture.signature,
                context: fixture.context
            )
        }

        let explicitDefaultPort = try makeFixture(host: "cdn.wali.example:443")
        expectCatalogError(.invalidArtifact) {
            _ = try explicitDefaultPort.verifier.verify(
                manifestData: explicitDefaultPort.data,
                signatureBase64URL: explicitDefaultPort.signature,
                context: explicitDefaultPort.context
            )
        }
    }

    @Test("Rejects expired or compromised keys")
    func rejectsInactiveKeys() throws {
        let fixture = try makeFixture(keyStatus: .compromised)
        expectCatalogError(.inactiveSigningKey) {
            _ = try fixture.verifier.verify(
                manifestData: fixture.data,
                signatureBase64URL: fixture.signature,
                context: fixture.context
            )
        }
    }

    @Test("Rejects unknown fields and wrong schema ordering")
    func rejectsShapeDrift() throws {
        let fixture = try makeFixture()
        let value = String(decoding: fixture.data, as: UTF8.self)
        let reordered = value.replacingOccurrences(
            of: #"{"schema":{"epoch":1,"revision":0},"key_id""#,
            with: #"{"key_id":"catalog-test-2026-01","schema":{"epoch":1,"revision":0},"ignored""#
        )
        expectCatalogError(.invalidCanonicalJSON) {
            _ = try fixture.verifier.verify(
                manifestData: Data(reordered.utf8),
                signatureBase64URL: fixture.signature,
                context: fixture.context
            )
        }
    }

    @Test("Enforces a signed critical revocation")
    func rejectsRevokedRelease() throws {
        let fixture = try makeFixture()
        let firstDigest = try #require(
            try JSONDecoder().decode(CatalogManifest.self, from: fixture.data).artifacts.first?.sha256
        )
        let date = try parseCatalogTimestamp("2026-09-01T12:00:00Z")
        let revocation = try CatalogRevocation(
            releaseID: releaseID,
            artifactSHA256: firstDigest,
            reason: .criticalSecurity,
            issuedAt: date
        )
        let list = try CatalogRevocationList(
            schema: .current,
            keyID: try CatalogKeyID("catalog-test-2026-01"),
            revision: 1,
            issuedAt: date,
            revocations: [revocation]
        )
        expectCatalogError(.revokedRelease) {
            _ = try fixture.verifier.verify(
                manifestData: fixture.data,
                signatureBase64URL: fixture.signature,
                context: fixture.context,
                revocations: list
            )
        }
    }

    private func makeFixture(
        host: String = "cdn.wali.example",
        keyStatus: CatalogSigningKeyStatus = .active
    ) throws -> (
        data: Data,
        signature: String,
        verifier: ManifestVerifier,
        context: CatalogVerificationContext
    ) {
        let seed = try #require(Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let data = Data(manifest(host: host).utf8)
        let signature = try privateKey.signature(for: data).base64URLEncodedString()
        let issuedAt = try parseCatalogTimestamp("2026-09-01T12:00:00Z")
        let key = try TrustedCatalogSigningKey(
            id: CatalogKeyID("catalog-test-2026-01"),
            publicKey: privateKey.publicKey.rawRepresentation,
            validFrom: issuedAt.addingTimeInterval(-86_400),
            validUntil: issuedAt.addingTimeInterval(86_400),
            status: keyStatus
        )
        return (
            data,
            signature,
            try ManifestVerifier(trustedKeys: [key], approvedCDNHosts: ["cdn.wali.example"]),
            try CatalogVerificationContext(
                wallpaperID: wallpaperID,
                releaseID: releaseID,
                metadataDigest: digest
            )
        )
    }

    private func manifest(host: String) -> String {
        let imageDigest = String(repeating: "1", count: 64)
        let posterDigest = String(repeating: "2", count: 64)
        let previewDigest = String(repeating: "3", count: 64)
        let videoDigest = String(repeating: "4", count: 64)
        let prefix = #"{"schema":{"epoch":1,"revision":0},"key_id":"catalog-test-2026-01","wallpaper_id":"\#(wallpaperID)","release_id":"\#(releaseID)","edition":1,"issued_at":"2026-09-01T12:00:00Z","artifacts":["#
        let thumbnail = #"{"role":"thumbnail","url":"https://\#(host)/thumbnail.jpg","sha256":"\#(imageDigest)","byte_count":1024,"media_type":"image/jpeg","width":640,"height":360,"duration_ms":0}"#
        let poster = #"{"role":"poster","url":"https://\#(host)/poster.jpg","sha256":"\#(posterDigest)","byte_count":2048,"media_type":"image/jpeg","width":1920,"height":1080,"duration_ms":0}"#
        let preview = #"{"role":"preview","url":"https://\#(host)/preview.mp4","sha256":"\#(previewDigest)","byte_count":4096,"media_type":"video/mp4","width":1280,"height":720,"duration_ms":15000}"#
        let video = #"{"role":"video_default","url":"https://\#(host)/video.mp4","sha256":"\#(videoDigest)","byte_count":8192,"media_type":"video/mp4","width":1920,"height":1080,"duration_ms":30000}"#
        return prefix + [thumbnail, poster, preview, video].joined(separator: ",")
            + #"],"metadata_digest":"\#(digest)"}"#
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@Suite("Signed catalog install metadata")
struct CatalogInstallMetadataTests {
    private let wallpaperID = "11111111-1111-1111-1111-111111111111"
    private let releaseID = "22222222-2222-2222-2222-222222222222"

    @Test("Binds persisted provenance to the exact canonical metadata bytes")
    func verifiesExactMetadata() throws {
        let data = Data(metadata().utf8)
        let verifier = try makeVerifier(metadataDigest: SHA256.hash(data: data).hexString)
        let signed = signedManifest()
        let verified = try verifier.verifyMetadata(
            data,
            for: verifier.verify(
                manifestData: signed.data,
                signatureBase64URL: signed.signature,
                context: CatalogVerificationContext(
                    wallpaperID: wallpaperID,
                    releaseID: releaseID,
                    metadataDigest: SHA256.hash(data: data).hexString
                )
            )
        )

        #expect(verified.metadata.title == "Night Sky")
        #expect(verified.metadata.creatorName == "Ari Example")
        #expect(verified.metadata.creatorHandle == "@ari")
        #expect(verified.metadata.attributionText == "Original animation")
        #expect(verified.metadata.rightsHolder == "Ari Example")
        #expect(verified.canonicalBytes == data)
    }

    @Test("Rejects digest tampering and cross-release metadata replay")
    func rejectsTamperingAndReplay() throws {
        let data = Data(metadata().utf8)
        let digest = SHA256.hash(data: data).hexString
        let verifier = try makeVerifier(metadataDigest: digest)
        let signed = signedManifest()
        let verifiedManifest = try verifier.verify(
            manifestData: signed.data,
            signatureBase64URL: signed.signature,
            context: try CatalogVerificationContext(
                wallpaperID: wallpaperID,
                releaseID: releaseID,
                metadataDigest: digest
            )
        )

        var tampered = data
        let range = try #require(tampered.range(of: Data("Night Sky".utf8)))
        tampered.replaceSubrange(range, with: Data("Night Spy".utf8))
        expectCatalogError(.metadataMismatch) {
            _ = try verifier.verifyMetadata(tampered, for: verifiedManifest)
        }

        let replay = Data(metadata(releaseID: "33333333-3333-3333-3333-333333333333").utf8)
        expectCatalogError(.metadataMismatch) {
            _ = try verifier.verifyMetadata(replay, for: verifiedManifest)
        }
    }

    @Test("Rejects unknown fields, noncanonical bytes, and oversized attribution")
    func rejectsMalformedMetadata() throws {
        let data = Data(metadata().utf8)
        let digest = SHA256.hash(data: data).hexString
        let verifier = try makeVerifier(metadataDigest: digest)
        let signed = signedManifest()
        let manifest = try verifier.verify(
            manifestData: signed.data,
            signatureBase64URL: signed.signature,
            context: try CatalogVerificationContext(
                wallpaperID: wallpaperID,
                releaseID: releaseID,
                metadataDigest: digest
            )
        )

        expectCatalogError(.invalidCanonicalJSON) {
            _ = try verifier.verifyMetadata(data + Data("\n".utf8), for: manifest)
        }
        let unknown = Data(metadata().replacingOccurrences(
            of: #"{"schema""#,
            with: #"{"extra":true,"schema""#
        ).utf8)
        expectCatalogError(.invalidCanonicalJSON) {
            _ = try verifier.verifyMetadata(unknown, for: manifest)
        }
        let oversized = Data(metadata(attribution: String(repeating: "a", count: 2_049)).utf8)
        expectCatalogError(.stringTooLarge) {
            _ = try verifier.verifyMetadata(oversized, for: manifest)
        }
    }

    private func metadata(
        releaseID: String? = nil,
        attribution: String = "Original animation"
    ) -> String {
        #"{"schema":"wali.catalog.install-metadata.v1","wallpaper_id":"\#(wallpaperID)","release_id":"\#(releaseID ?? self.releaseID)","edition":1,"title":"Night Sky","creator_name":"Ari Example","creator_handle":"@ari","attribution_text":"\#(attribution)","rights_holder":"Ari Example"}"#
    }

    private func makeVerifier(metadataDigest: String) throws -> ManifestVerifier {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!
        )
        let issuedAt = try parseCatalogTimestamp("2026-09-01T12:00:00Z")
        return try ManifestVerifier(
            trustedKeys: [
                TrustedCatalogSigningKey(
                    id: CatalogKeyID("catalog-test-2026-01"),
                    publicKey: privateKey.publicKey.rawRepresentation,
                    validFrom: issuedAt.addingTimeInterval(-86_400),
                    validUntil: issuedAt.addingTimeInterval(86_400),
                    status: .active
                )
            ],
            approvedCDNHosts: ["cdn.wali.example"]
        )
    }

    private func signedManifest() -> (data: Data, signature: String) {
        let metadataData = Data(metadata().utf8)
        let digest = SHA256.hash(data: metadataData).hexString
        let artifact = { (role: String, path: String, hash: Character, type: String, duration: Int) in
            #"{"role":"\#(role)","url":"https://cdn.wali.example/\#(path)","sha256":"\#(String(repeating: hash, count: 64))","byte_count":1024,"media_type":"\#(type)","width":1920,"height":1080,"duration_ms":\#(duration)}"#
        }
        let body = #"{"schema":{"epoch":1,"revision":0},"key_id":"catalog-test-2026-01","wallpaper_id":"\#(wallpaperID)","release_id":"\#(releaseID)","edition":1,"issued_at":"2026-09-01T12:00:00Z","artifacts":["#
            + [
                artifact("thumbnail", "thumbnail.jpg", "1", "image/jpeg", 0),
                artifact("poster", "poster.jpg", "2", "image/jpeg", 0),
                artifact("preview", "preview.mp4", "3", "video/mp4", 1_000),
                artifact("video_default", "video.mp4", "4", "video/mp4", 2_000)
            ].joined(separator: ",")
            + #"],"metadata_digest":"\#(digest)"}"#
        let data = Data(body.utf8)
        let key = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!
        )
        return (data, try! key.signature(for: data).base64URLEncodedString())
    }
}

@Suite("Catalog trust transitions")
struct CatalogTrustTransitionTests {
    @Test("Accepts a cumulative transition signed by a compiled anchor")
    func acceptsAnchoredTransition() throws {
        let fixture = try makeFixture(revision: 2, operationalStatus: "retired")
        let verified = try fixture.verifier.verify(
            data: fixture.data,
            signatureBase64URL: fixture.signature,
            signingKeyID: CatalogKeyID("catalog-root-2026")
        )

        #expect(verified.transition.revision == 2)
        #expect(verified.trustedKeys.count == 2)
        #expect(verified.trustedKeys.first?.status == .retired)
        #expect(verified.canonicalBytes == fixture.data)
    }

    @Test("Rejects signatures by dynamically introduced keys")
    func rejectsUnanchoredSigner() throws {
        let fixture = try makeFixture(revision: 2)
        let operational = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 7, count: 32)
        )
        let signature = try operational.signature(for: fixture.data).base64URLEncodedString()

        expectCatalogError(.unknownSigningKey) {
            _ = try fixture.verifier.verify(
                data: fixture.data,
                signatureBase64URL: signature,
                signingKeyID: CatalogKeyID("catalog-operational-2026")
            )
        }
    }

    @Test("Rejects modified compiled anchors and invalid status recovery")
    func rejectsInvalidKeyState() throws {
        let fixture = try makeFixture(revision: 2)
        let modifiedRoot = Data(fixture.body(publicKeyOverride: Data(repeating: 9, count: 32)).utf8)
        let modifiedSignature = try fixture.root.signature(for: modifiedRoot).base64URLEncodedString()
        expectCatalogError(.invalidTrustTransition) {
            _ = try fixture.verifier.verify(
                data: modifiedRoot,
                signatureBase64URL: modifiedSignature,
                signingKeyID: CatalogKeyID("catalog-root-2026")
            )
        }

        let compromised = try fixture.verifier.verify(
            data: fixture.data,
            signatureBase64URL: fixture.signature,
            signingKeyID: CatalogKeyID("catalog-root-2026")
        )
        let recoveryData = Data(fixture.body(revision: 3, operationalStatus: "active").utf8)
        let recoverySignature = try fixture.root.signature(for: recoveryData).base64URLEncodedString()
        expectCatalogError(.invalidTrustTransition) {
            _ = try fixture.verifier.verifySuccessor(
                data: recoveryData,
                signatureBase64URL: recoverySignature,
                signingKeyID: CatalogKeyID("catalog-root-2026"),
                previous: compromised
            )
        }
    }

    @Test("Treats an equal revision as idempotent only for identical canonical bytes")
    func rejectsEqualRevisionEquivocation() throws {
        let fixture = try makeFixture(revision: 2)
        let previous = try fixture.verifier.verify(
            data: fixture.data,
            signatureBase64URL: fixture.signature,
            signingKeyID: CatalogKeyID("catalog-root-2026")
        )
        let same = try fixture.verifier.verifySuccessor(
            data: fixture.data,
            signatureBase64URL: fixture.signature,
            signingKeyID: CatalogKeyID("catalog-root-2026"),
            previous: previous
        )
        #expect(same == previous)

        let different = Data(fixture.body(operationalStatus: "retired").utf8)
        let differentSignature = try fixture.root.signature(for: different).base64URLEncodedString()
        expectCatalogError(.trustTransitionEquivocation) {
            _ = try fixture.verifier.verifySuccessor(
                data: different,
                signatureBase64URL: differentSignature,
                signingKeyID: CatalogKeyID("catalog-root-2026"),
                previous: previous
            )
        }
    }

    private func makeFixture(
        revision: UInt64,
        operationalStatus: String = "compromised"
    ) throws -> TrustFixture {
        let root = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")!
        )
        let anchor = try TrustedCatalogSigningKey(
            id: CatalogKeyID("catalog-root-2026"),
            publicKey: root.publicKey.rawRepresentation,
            validFrom: parseCatalogTimestamp("2026-01-01T00:00:00Z"),
            validUntil: parseCatalogTimestamp("2030-01-01T00:00:00Z"),
            status: .active
        )
        return TrustFixture(
            root: root,
            revision: revision,
            operationalStatus: operationalStatus,
            verifier: try CatalogTrustTransitionVerifier(compiledAnchors: [anchor])
        )
    }

    private struct TrustFixture {
        let root: Curve25519.Signing.PrivateKey
        let revision: UInt64
        let operationalStatus: String
        let verifier: CatalogTrustTransitionVerifier

        var data: Data { Data(body().utf8) }
        var signature: String { try! root.signature(for: data).base64URLEncodedString() }

        func body(
            revision: UInt64? = nil,
            operationalStatus: String? = nil,
            publicKeyOverride: Data? = nil
        ) -> String {
            let rootKey = (publicKeyOverride ?? root.publicKey.rawRepresentation)
                .base64URLEncodedString()
            let operational = try! Curve25519.Signing.PrivateKey(
                rawRepresentation: Data(repeating: 7, count: 32)
            )
            return #"{"schema":"wali.catalog.trust-transition.v1","revision":\#(revision ?? self.revision),"issued_at":"2026-09-01T12:00:00Z","keys":[{"key_id":"catalog-operational-2026","public_key":"\#(operational.publicKey.rawRepresentation.base64URLEncodedString())","valid_from":"2026-01-01T00:00:00Z","valid_until":"2030-01-01T00:00:00Z","status":"\#(operationalStatus ?? self.operationalStatus)"},{"key_id":"catalog-root-2026","public_key":"\#(rootKey)","valid_from":"2026-01-01T00:00:00Z","valid_until":"2030-01-01T00:00:00Z","status":"active"}]}"#
        }
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
