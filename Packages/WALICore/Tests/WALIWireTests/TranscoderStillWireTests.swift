import Foundation
import Testing
import WALIWire

@Test("Private preparation requires explicit media kind on the wire")
func transcoderStillWireRequiresExplicitKind() throws {
    let request = TranscoderRequest(jobID: UUID(), attemptGeneration: 1,
        sourceBookmark: Data([1]), sourceURL: URL(fileURLWithPath: "/source.png"),
        stagingDirectoryURL: URL(fileURLWithPath: "/staging"))
    let bytes = try TranscoderWireCodec.encodeRequest(request)
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object.removeValue(forKey: "media_kind")
    let missing = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try TranscoderWireCodec.decodeRequest(from: missing) }
}

@Test("Still claims round-trip without video fields and require their exact roles")
func transcoderStillWireUsesTypedClaims() throws {
    let output = stillOutput()
    let bytes = try TranscoderWireCodec.encodeOutput(output)
    #expect(try TranscoderWireCodec.decodeOutput(from: bytes) == output)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let source = try #require(object["sourceMedia"] as? [String: Any])
    #expect(source["kind"] as? String == "still")
    #expect(source["has_alpha"] as? Bool == true)
    #expect(source["duration_seconds"] == nil)
    #expect(source["nominal_frame_rate"] == nil)
    #expect(source["has_audio"] == nil)
    #expect(object["media_kind"] as? String == "still")
    for invalid in [Array(output.artifacts.prefix(1)), output.artifacts + [output.artifacts[0]]] {
        let changed = TranscoderOutput(jobID: output.jobID, attemptGeneration: 1,
            displayName: "Still", completedAt: Date(), sourceDigest: output.sourceDigest,
            sourceMedia: output.sourceMedia, artifacts: invalid)
        #expect(throws: (any Error).self) { try TranscoderWireCodec.encodeOutput(changed) }
    }
}

@Test("Still payloads reject cross-kind fields, missing tags and old worker protocols")
func transcoderStillWireRejectsAmbiguity() throws {
    let bytes = try TranscoderWireCodec.encodeOutput(stillOutput())
    let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    for field in ["duration_seconds", "nominal_frame_rate", "has_audio", "codec"] {
        var changed = original
        var source = try #require(changed["sourceMedia"] as? [String: Any])
        source[field] = 1
        changed["sourceMedia"] = source
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) { try TranscoderWireCodec.decodeOutput(from: data) }
    }
    for tag in ["video", "unknown", "missing"] {
        var changed = original
        if tag == "missing" { changed.removeValue(forKey: "media_kind") }
        else { changed["media_kind"] = tag }
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) { try TranscoderWireCodec.decodeOutput(from: data) }
    }
    var old = original; old["protocolVersion"] = 2
    #expect(throws: (any Error).self) {
        try TranscoderWireCodec.decodeOutput(from: JSONSerialization.data(withJSONObject: old))
    }
}

@Test("Canonical image claims reject alpha, color, depth and oversized source limits")
func transcoderStillWireChecksCanonicalBounds() throws {
    let output = stillOutput()
    let bytes = try TranscoderWireCodec.encodeOutput(output)
    let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    for (field, value) in [("has_alpha", true as Any), ("color_space", "display_p3"),
                            ("bits_per_component", 16), ("frame_count", 2), ("byte_count", 101)] {
        var changed = original
        var artifacts = try #require(changed["artifacts"] as? [[String: Any]])
        var media = try #require(artifacts[0]["media"] as? [String: Any])
        media[field] = value; artifacts[0]["media"] = media; changed["artifacts"] = artifacts
        let data = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: (any Error).self) { try TranscoderWireCodec.decodeOutput(from: data) }
    }
    let request = TranscoderRequest(jobID: UUID(), attemptGeneration: 1,
        sourceBookmark: Data([1]), sourceURL: URL(fileURLWithPath: "/source.png"),
        stagingDirectoryURL: URL(fileURLWithPath: "/staging"), mediaKind: .still)
    #expect(request.sourceByteLimit == 128 * 1_024 * 1_024)
    let invalid = TranscoderRequest(jobID: request.jobID, attemptGeneration: 1,
        sourceBookmark: request.sourceBookmark, sourceURL: request.sourceURL,
        stagingDirectoryURL: request.stagingDirectoryURL,
        sourceByteLimit: request.sourceByteLimit + 1, mediaKind: .still)
    #expect(throws: (any Error).self) { try TranscoderWireCodec.encodeRequest(invalid) }
}

@Test("Video convenience initializers retain exact video artifact requirements")
func transcoderStillWirePreservesVideo() throws {
    let media = TranscoderMediaClaim(byteCount: 100, pixelWidth: 12, pixelHeight: 8,
        duration: 1, nominalFrameRate: 30, hasAudio: false, isHDR: false, videoCodec: "hvc1")
    let artifacts: [TranscoderArtifactClaim] = [.masterVideo, .previewVideo, .posterImage].map { kind in
        .init(kind: kind, stagedURL: URL(fileURLWithPath: "/staging/\(kind.rawValue)"),
            digest: String(repeating: "a", count: 64), byteCount: 100,
            media: kind == .posterImage ? nil : media)
    }
    let output = TranscoderOutput(jobID: UUID(), attemptGeneration: 1, displayName: "Video",
        completedAt: Date(timeIntervalSince1970: 1), sourceDigest: String(repeating: "b", count: 64),
        sourceMedia: media, artifacts: artifacts)
    #expect(output.mediaKind == .video)
    #expect(try TranscoderWireCodec.decodeOutput(from: TranscoderWireCodec.encodeOutput(output)) == output)
}

private func stillOutput() -> TranscoderOutput {
    let source = TranscoderMediaClaim.still(.init(byteCount: 100, pixelWidth: 12, pixelHeight: 8,
        frameCount: 1, bitsPerComponent: 8, colorSpace: "display_p3", hasAlpha: true))
    let canonical = TranscoderMediaClaim.still(.init(byteCount: 100, pixelWidth: 12, pixelHeight: 8,
        frameCount: 1, bitsPerComponent: 8, colorSpace: "srgb", hasAlpha: false))
    let artifacts: [TranscoderArtifactClaim] = [.masterImage, .posterImage].map { kind in
        .init(kind: kind, stagedURL: URL(fileURLWithPath: "/staging/\(kind.rawValue)"),
            digest: String(repeating: "a", count: 64), byteCount: 100, media: canonical)
    }
    return .init(jobID: UUID(), attemptGeneration: 1, displayName: "Still",
        completedAt: Date(timeIntervalSince1970: 1), sourceDigest: String(repeating: "b", count: 64),
        sourceMedia: source, artifacts: artifacts)
}
