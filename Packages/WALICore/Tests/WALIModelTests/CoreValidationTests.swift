import Foundation
import Testing
@testable import WALIModel

@Suite("Core value validation")
struct CoreValidationTests {
    @Test("Typed UUID identifiers validate and encode as strings")
    func typedIdentifiers() throws {
        #expect(try AssetID(assetIDText).rawValue == assetIDText)
        #expect(try AssetReleaseID(releaseIDText).rawValue == releaseIDText)
        #expect(try AssetVariantID(variantIDText).rawValue == variantIDText)
        #expect(try LibraryItemID(libraryItemIDText).rawValue == libraryItemIDText)
        #expect(try DeviceInstallationID(installationIDText).rawValue == installationIDText)
        #expect(try LocalDisplayID(localDisplayIDText).rawValue == localDisplayIDText)
        #expect(try PresentationAssignmentID(assignmentIDText).rawValue == assignmentIDText)
        #expect(try JobID(jobIDText).rawValue == jobIDText)
        #expect(try IdempotencyKey(idempotencyKeyText).rawValue == idempotencyKeyText)

        #expect(try logicalJSON(AssetID(assetIDText)) == "\"\(assetIDText)\"")
        let decoded = try JSONDecoder().decode(AssetID.self, from: Data("\"\(assetIDText)\"".utf8))
        #expect(decoded == (try AssetID(assetIDText)))
    }

    @Test("Typed UUID identifiers reject noncanonical spellings")
    func invalidIdentifiers() {
        for invalid in [
            "00000000-0000-0000-0000-00000000001",
            "00000000-0000-0000-0000-00000000000A",
            "{00000000-0000-0000-0000-000000000001}",
            "000000000000-0000-0000-000000000001"
        ] {
            expectViolation(.invalidIdentifier) {
                _ = try AssetID(invalid)
            }
        }
    }

    @Test("Open tags validate a bounded namespaced ASCII grammar")
    func openTags() throws {
        let renderer = try RendererID("vendor.renderer-2")
        let mediaType = try MediaTypeID("vendor.video.h265")
        let role = try ArtifactRoleID("vendor.poster")
        let jobKind = try JobKindID("vendor.import")

        #expect(renderer.rawValue == "vendor.renderer-2")
        #expect(mediaType.rawValue == "vendor.video.h265")
        #expect(role.rawValue == "vendor.poster")
        #expect(jobKind.rawValue == "vendor.import")
        #expect(try logicalJSON(renderer) == "\"vendor.renderer-2\"")
        #expect(RendererID.waliVideo.rawValue == "wali.video")
        #expect(MediaTypeID.waliVideoH264.rawValue == "wali.video.h264")
        #expect(ArtifactRoleID.waliPlayback.rawValue == "wali.playback")
        #expect(JobKindID.waliImport.rawValue == "wali.import")
        #expect(
            try JSONDecoder().decode(
                RendererID.self,
                from: JSONEncoder().encode(renderer)
            ) == renderer
        )
    }

    @Test("Open tags reject malformed or oversized values")
    func invalidOpenTags() {
        for invalid in [
            "renderer",
            "Vendor.renderer",
            ".vendor.renderer",
            "vendor..renderer",
            "vendor/renderer",
            "v." + String(repeating: "a", count: 63)
        ] {
            expectViolation(.invalidTag) {
                _ = try RendererID(invalid)
            }
        }
    }

    @Test("SHA-256 digest has an explicit algorithm and lowercase hex")
    func digestValidation() throws {
        let digest = try ContentDigest(algorithm: .sha256, value: videoDigestText)
        #expect(digest.algorithm == .sha256)
        #expect(digest.value == videoDigestText)
        #expect(
            try logicalJSON(digest)
                == "{\"algorithm\":\"sha256\",\"value\":\"\(videoDigestText)\"}"
        )
        #expect(
            try JSONDecoder().decode(
                ContentDigest.self,
                from: JSONEncoder().encode(digest)
            ) == digest
        )

        expectViolation(.invalidDigest) {
            _ = try ContentDigest(algorithm: .sha256, value: String(repeating: "A", count: 64))
        }
        expectViolation(.invalidDigest) {
            _ = try ContentDigest(algorithm: .sha256, value: String(repeating: "a", count: 63))
        }
    }

    @Test("Schema versions validate epoch and aggregates reject unsupported versions")
    func schemaValidation() throws {
        #expect(RecordSchemaVersion.current == (try RecordSchemaVersion(epoch: 1, revision: 0)))
        #expect(
            try JSONDecoder().decode(
                RecordSchemaVersion.self,
                from: JSONEncoder().encode(RecordSchemaVersion.current)
            ) == .current
        )
        expectViolation(.invalidSchema) {
            _ = try RecordSchemaVersion(epoch: 0, revision: 0)
        }

        let unsupported = try RecordSchemaVersion(epoch: 2, revision: 0)
        expectViolation(.unsupportedSchema) {
            _ = try Artifact(
                schema: unsupported,
                contentID: ContentDigest(algorithm: .sha256, value: videoDigestText),
                byteCount: 1,
                mediaType: .waliVideoH264,
                characteristics: makeCharacteristics()
            )
        }
    }

    @Test("Text is bounded and nonblank and rename preserves identity")
    func boundedTextAndRename() throws {
        let item = try LibraryItem(
            schema: .current,
            id: LibraryItemID(libraryItemIDText),
            releaseID: AssetReleaseID(releaseIDText),
            displayName: "Aurora",
            origin: .localImport
        )
        let renamed = try item.renamed(to: "Night Aurora")

        #expect(renamed.id == item.id)
        #expect(renamed.releaseID == item.releaseID)
        #expect(renamed.displayName == "Night Aurora")
        #expect(renamed.origin == .localImport)

        expectViolation(.blankText) {
            _ = try item.renamed(to: " \n\t ")
        }
        expectViolation(.textTooLong) {
            _ = try item.renamed(to: String(repeating: "a", count: LibraryItem.maximumDisplayNameUTF8Length + 1))
        }
    }

    @Test("Integer and rational media values reject invalid numbers")
    func numericValidation() throws {
        #expect(try PixelSize(width: 3840, height: 2160).width == 3840)
        #expect(try MediaRational(numerator: 60_000, denominator: 1_001).denominator == 1_001)
        #expect(try NormalizedCoordinate(rawValue: 10_000).rawValue == 10_000)

        expectViolation(.invalidNumber) {
            _ = try PixelSize(width: 0, height: 2160)
        }
        expectViolation(.invalidNumber) {
            _ = try MediaRational(numerator: 1, denominator: 0)
        }
        expectViolation(.invalidNumber) {
            _ = try NormalizedCoordinate(rawValue: 10_001)
        }
        expectViolation(.invalidNumber) {
            _ = try MediaCharacteristics(
                pixelSize: PixelSize(width: 1, height: 1),
                bitDepth: 0
            )
        }
    }

    @Test("Model violations expose stable codes and structured context")
    func structuredViolation() throws {
        do {
            _ = try PlaybackGeneration(0)
            Issue.record("expected ModelViolation")
        } catch let violation as ModelViolation {
            #expect(violation.code == .invalidGeneration)
            #expect(violation.context.field == "playbackGeneration")
            #expect(violation.context.generation == 0)
            #expect(violation.context.expectedGeneration == nil)
            #expect(violation.context.operation == nil)
            #expect(violation.code.rawValue == "invalid_generation")
        }
    }

    @Test("Library fixture proves stable logical keys and tags")
    func libraryFixture() throws {
        let data = try fixtureData(named: "model-records-v1")
        let fixture = try JSONDecoder().decode(ModelRecordsFixture.self, from: data)
        let roundTrip = try JSONDecoder().decode(
            LibraryItem.self,
            from: JSONEncoder().encode(fixture.libraryItem)
        )

        #expect(roundTrip == fixture.libraryItem)
        #expect(fixture.libraryItem.origin == .localImport)
        #expect(fixture.libraryItem.schema == .current)

        let invalidFixture = try #require(
            JSONSerialization.jsonObject(
                with: fixtureData(named: "model-records-invalid-v1")
            ) as? [String: Any]
        )
        let unsupported = try JSONSerialization.data(
            withJSONObject: try #require(invalidFixture["unsupportedLibraryItem"])
        )
        expectViolation(.unsupportedSchema) {
            _ = try JSONDecoder().decode(LibraryItem.self, from: unsupported)
        }
    }
}

private struct ModelRecordsFixture: Decodable {
    let libraryItem: LibraryItem
}
