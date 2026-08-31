import Foundation
import Testing
@testable import WALIModel

@Suite("Artifacts and releases")
struct AssetReleaseTests {
    @Test("Valid release canonicalizes semantic sets and round trips")
    func releaseRoundTrip() throws {
        let alternate = try makeVariant(
            id: alternateVariantIDText,
            artifactDigest: videoDigestText,
            qualityTier: .high
        )
        let release = try AssetRelease(
            schema: .current,
            id: AssetReleaseID(releaseIDText),
            assetID: AssetID(assetIDText),
            edition: 3,
            artifacts: [makePosterArtifact(), makeArtifact()],
            posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
            variants: [alternate, makeVariant()],
            defaultVariantID: AssetVariantID(variantIDText)
        )

        #expect(release.artifacts.map(\.contentID.value) == [videoDigestText, posterDigestText])
        #expect(release.variants.map(\.id.rawValue) == [variantIDText, alternateVariantIDText])

        let encoded = try JSONEncoder().encode(release)
        let decoded = try JSONDecoder().decode(AssetRelease.self, from: encoded)
        #expect(decoded == release)
    }

    @Test("Golden release fixture proves stable logical record keys")
    func releaseFixture() throws {
        let fixture = try JSONDecoder().decode(
            ReleaseFixture.self,
            from: fixtureData(named: "model-records-v1")
        )
        #expect(fixture.release == (try makeRelease()))
        #expect(try logicalJSON(fixture.release) == logicalJSON(makeRelease()))
    }

    @Test("Release rejects zero edition and empty variants")
    func releaseCardinality() throws {
        expectViolation(.invalidNumber) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 0,
                artifacts: [makePosterArtifact(), makeArtifact()],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [makeVariant()],
                defaultVariantID: AssetVariantID(variantIDText)
            )
        }
        expectViolation(.emptyCollection) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 1,
                artifacts: [makePosterArtifact(), makeArtifact()],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [],
                defaultVariantID: AssetVariantID(variantIDText)
            )
        }
    }

    @Test("Release rejects duplicate artifact identities")
    func duplicateArtifacts() throws {
        let artifact = try makeArtifact()
        expectViolation(.duplicateArtifactID) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 1,
                artifacts: [artifact, artifact, makePosterArtifact()],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [makeVariant()],
                defaultVariantID: AssetVariantID(variantIDText)
            )
        }
    }

    @Test("Release distinguishes conflicting metadata for the same digest")
    func conflictingArtifactMetadata() throws {
        expectViolation(.conflictingArtifactMetadata) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 1,
                artifacts: [
                    makeArtifact(byteCount: 4_096),
                    makeArtifact(byteCount: 8_192),
                    makePosterArtifact()
                ],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [makeVariant()],
                defaultVariantID: AssetVariantID(variantIDText)
            )
        }
    }

    @Test("Poster must reference a contained artifact")
    func posterReference() throws {
        expectViolation(.missingReference) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 1,
                artifacts: [makeArtifact()],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [makeVariant()],
                defaultVariantID: AssetVariantID(variantIDText)
            )
        }
    }

    @Test("Variant binding roles are unique")
    func duplicateBindingRoles() throws {
        let contentID = try ContentDigest(algorithm: .sha256, value: videoDigestText)
        expectViolation(.duplicateArtifactRole) {
            _ = try AssetVariant(
                id: AssetVariantID(variantIDText),
                qualityTier: .balanced,
                rendererRequirement: RendererRequirement(rendererID: .waliVideo),
                bindings: [
                    ArtifactBinding(role: .waliPlayback, artifactID: contentID),
                    ArtifactBinding(role: .waliPlayback, artifactID: contentID)
                ]
            )
        }
    }

    @Test("Every binding must reference a contained artifact")
    func danglingBinding() throws {
        let dangling = try makeVariant(artifactDigest: alternateDigestText)
        expectViolation(.missingReference) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 1,
                artifacts: [makeArtifact(), makePosterArtifact()],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [dangling],
                defaultVariantID: AssetVariantID(variantIDText)
            )
        }
    }

    @Test("Variant identities are unique and default variant must exist")
    func variantIdentityAndDefault() throws {
        let variant = try makeVariant()
        expectViolation(.duplicateVariantID) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 1,
                artifacts: [makeArtifact(), makePosterArtifact()],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [variant, variant],
                defaultVariantID: AssetVariantID(variantIDText)
            )
        }
        expectViolation(.missingReference) {
            _ = try AssetRelease(
                schema: .current,
                id: AssetReleaseID(releaseIDText),
                assetID: AssetID(assetIDText),
                edition: 1,
                artifacts: [makeArtifact(), makePosterArtifact()],
                posterArtifactID: ContentDigest(algorithm: .sha256, value: posterDigestText),
                variants: [variant],
                defaultVariantID: AssetVariantID(alternateVariantIDText)
            )
        }
    }

    @Test("Artifact byte count is nonzero")
    func artifactByteCount() throws {
        expectViolation(.invalidNumber) {
            _ = try makeArtifact(byteCount: 0)
        }
    }
}

private struct ReleaseFixture: Decodable {
    let release: AssetRelease
}
