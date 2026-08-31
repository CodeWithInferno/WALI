import Foundation
import Testing
@testable import WALIModel

let assetIDText = "00000000-0000-0000-0000-000000000001"
let releaseIDText = "00000000-0000-0000-0000-000000000002"
let alternateReleaseIDText = "00000000-0000-0000-0000-000000000003"
let variantIDText = "00000000-0000-0000-0000-000000000004"
let alternateVariantIDText = "00000000-0000-0000-0000-000000000005"
let libraryItemIDText = "00000000-0000-0000-0000-000000000006"
let installationIDText = "00000000-0000-0000-0000-000000000007"
let localDisplayIDText = "00000000-0000-0000-0000-000000000008"
let assignmentIDText = "00000000-0000-0000-0000-000000000009"
let jobIDText = "00000000-0000-0000-0000-00000000000a"
let idempotencyKeyText = "00000000-0000-0000-0000-00000000000b"

let videoDigestText = String(repeating: "a", count: 64)
let posterDigestText = String(repeating: "b", count: 64)
let alternateDigestText = String(repeating: "c", count: 64)

func logicalJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func fixtureData(named name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

func expectViolation(
    _ expectedCode: ModelViolation.Code,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("expected ModelViolation", sourceLocation: sourceLocation)
    } catch let violation as ModelViolation {
        #expect(violation.code == expectedCode, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error type", sourceLocation: sourceLocation)
    }
}

func makeCharacteristics(
    width: UInt32 = 3840,
    height: UInt32 = 2160,
    bitDepth: UInt16? = 10
) throws -> MediaCharacteristics {
    try MediaCharacteristics(
        pixelSize: PixelSize(width: width, height: height),
        duration: MediaRational(numerator: 30, denominator: 1),
        frameRate: MediaRational(numerator: 60_000, denominator: 1_001),
        bitDepth: bitDepth,
        dynamicRange: .hdr
    )
}

func makeArtifact(
    digest: String = videoDigestText,
    byteCount: UInt64 = 4_096,
    mediaType: MediaTypeID = .waliVideoH264,
    width: UInt32 = 3840
) throws -> Artifact {
    try Artifact(
        schema: .current,
        contentID: ContentDigest(algorithm: .sha256, value: digest),
        byteCount: byteCount,
        mediaType: mediaType,
        characteristics: makeCharacteristics(width: width)
    )
}

func makePosterArtifact() throws -> Artifact {
    try Artifact(
        schema: .current,
        contentID: ContentDigest(algorithm: .sha256, value: posterDigestText),
        byteCount: 1_024,
        mediaType: .waliImageHEIC,
        characteristics: MediaCharacteristics(
            pixelSize: PixelSize(width: 1920, height: 1080),
            dynamicRange: .sdr
        )
    )
}

func makeVariant(
    id: String = variantIDText,
    artifactDigest: String = videoDigestText,
    qualityTier: QualityTier = .balanced
) throws -> AssetVariant {
    try AssetVariant(
        id: AssetVariantID(id),
        qualityTier: qualityTier,
        rendererRequirement: RendererRequirement(rendererID: .waliVideo),
        bindings: [
            ArtifactBinding(
                role: .waliPlayback,
                artifactID: ContentDigest(algorithm: .sha256, value: artifactDigest)
            )
        ]
    )
}

func makeRelease() throws -> AssetRelease {
    try AssetRelease(
        schema: .current,
        id: AssetReleaseID(releaseIDText),
        assetID: AssetID(assetIDText),
        edition: 1,
        artifacts: [makePosterArtifact(), makeArtifact()],
        posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
        variants: [makeVariant()],
        defaultVariantID: AssetVariantID(variantIDText)
    )
}

func makeDisplayIdentity() throws -> DisplayIdentity {
    try DisplayIdentity(
        deviceID: DeviceInstallationID(installationIDText),
        localID: LocalDisplayID(localDisplayIDText)
    )
}
