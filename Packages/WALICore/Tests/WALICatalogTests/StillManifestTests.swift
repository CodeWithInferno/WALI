import CryptoKit
import Foundation
import Testing
@testable import WALICatalog

@Suite("Signed still catalog manifests")
struct StillManifestTests {
    private let wallpaper = "11111111-1111-4111-8111-111111111111"
    private let release = "22222222-2222-4222-8222-222222222222"
    private let digest = String(repeating: "e", count: 64)

    @Test("Still primary bytes verify with explicit kind and no video roles")
    func acceptsStill() throws {
        let result = try verify(body())
        #expect(result.manifest.mediaKind == .still)
        #expect(result.manifest.primaryArtifact.role == .imageDefault)
        #expect(result.manifest.primaryArtifact.durationMilliseconds == 0)
        #expect(result.manifest.artifacts.map(\.role) == [.thumbnail, .poster, .imageDefault])
    }

    @Test("Missing, false, unknown or wrong-order kind cannot cross the signed contract")
    func rejectsKindSubstitution() throws {
        let value = body()
        for wrong in [
            value.replacingOccurrences(of: #","media_kind":"still""#, with: ""),
            value.replacingOccurrences(of: #""still""#, with: #""video""#),
            value.replacingOccurrences(of: #""still""#, with: #""future""#),
            value.replacingOccurrences(of: #""epoch":2"#, with: #""epoch":1"#),
            value.replacingOccurrences(of: #""revision":0"#, with: #""revision":1"#)
        ] {
            #expect(throws: (any Error).self) { try verify(wrong) }
        }
    }

    @Test("A still cannot substitute a motion role, MIME or fabricated timing")
    func rejectsMotion() throws {
        for (old, new) in [
            (#""image_default""#, #""video_default""#),
            (#""image/png""#, #""video/mp4""#),
            (#""duration_ms":0"#, #""duration_ms":1"#),
            (#""byte_count":8192"#, #""byte_count":134217729"#),
            (#""height":2160"#, #""height":7681"#)
        ] {
            #expect(throws: (any Error).self) { try verify(body().replacingOccurrences(of: old, with: new)) }
        }
    }

    @Test("Still JPEG roles enforce the decoder byte budget independently")
    func boundsStillJPEGs() throws {
        for role in ["thumbnail", "poster"] {
            #expect(throws: (any Error).self) {
                try verify(body(byteOverride: (role, 16 * 1_024 * 1_024 + 1)))
            }
            _ = try verify(body(byteOverride: (role, 16 * 1_024 * 1_024)))
        }
    }

    @Test("Still signature, host and release binding are checked")
    func rejectsTrustSubstitution() throws {
        #expect(throws: (any Error).self) { try verify(body().replacingOccurrences(of: "cdn.wali.example", with: "other.example")) }
        #expect(throws: (any Error).self) { try verify(body().replacingOccurrences(of: release, with: wallpaper)) }
        #expect(throws: (any Error).self) { try verify(body(), sign: body().replacingOccurrences(of: "8192", with: "8193")) }
    }

    private func body(byteOverride: (String, Int)? = nil) -> String {
        let artifact = { (role: String, mime: String, width: Int, height: Int) in
            let bytes = byteOverride?.0 == role ? byteOverride!.1 : 8192
            return #"{"role":"\#(role)","url":"https://cdn.wali.example/\#(role)","sha256":"\#(String(repeating: "a", count: 64))","byte_count":\#(bytes),"media_type":"\#(mime)","width":\#(width),"height":\#(height),"duration_ms":0}"#
        }
        return #"{"schema":{"epoch":2,"revision":0},"media_kind":"still","key_id":"still-test","wallpaper_id":"\#(wallpaper)","release_id":"\#(release)","edition":1,"issued_at":"2026-09-01T12:00:00Z","artifacts":["#
            + [artifact("thumbnail", "image/jpeg", 512, 512), artifact("poster", "image/jpeg", 1920, 1080), artifact("image_default", "image/png", 3840, 2160)].joined(separator: ",")
            + #"],"metadata_digest":"\#(digest)"}"#
    }
    private func verify(_ text: String, sign: String? = nil) throws -> VerifiedCatalogManifest {
        let key = Curve25519.Signing.PrivateKey()
        let issued = try parseCatalogTimestamp("2026-09-01T12:00:00Z")
        let trusted = try TrustedCatalogSigningKey(id: CatalogKeyID("still-test"), publicKey: key.publicKey.rawRepresentation,
            validFrom: issued.addingTimeInterval(-60), validUntil: issued.addingTimeInterval(60), status: .active)
        let verifier = try ManifestVerifier(trustedKeys: [trusted], approvedCDNHosts: ["cdn.wali.example"])
        let signature = try key.signature(for: Data((sign ?? text).utf8)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try verifier.verify(manifestData: Data(text.utf8), signatureBase64URL: signature,
            context: CatalogVerificationContext(wallpaperID: wallpaper, releaseID: release, metadataDigest: digest))
    }
}
