import Foundation
@testable import WALICatalogRuntime
import XCTest

final class CreatorContractTests: XCTestCase {
    func testReportRequestBindsCanonicalReleaseAndRejectsPrivateControlText() throws {
        let wallpaperID = "11111111-1111-4111-8111-111111111111"
        let releaseID = "22222222-2222-4222-8222-222222222222"
        let request = try CatalogReportRequest(
            wallpaperID: wallpaperID,
            releaseID: releaseID,
            kind: .misleadingMetadata,
            detail: "The title does not match the visible content.",
            idempotencyKey: "report-wallpaper-0001"
        )

        XCTAssertEqual(request.wallpaperID, wallpaperID)
        XCTAssertEqual(request.releaseID, releaseID)
        XCTAssertEqual(request.kind, .misleadingMetadata)
        XCTAssertThrowsError(try CatalogReportRequest(
            wallpaperID: wallpaperID.uppercased(),
            releaseID: releaseID,
            kind: .other,
            detail: "Contains a control\u{0007}character.",
            idempotencyKey: "report-wallpaper-0002"
        ))
        XCTAssertThrowsError(try CatalogReportRequest(
            wallpaperID: wallpaperID,
            releaseID: releaseID,
            kind: .other,
            detail: "   \n\t",
            idempotencyKey: "report-wallpaper-0003"
        ))
        XCTAssertThrowsError(try CatalogReportRequest(
            wallpaperID: wallpaperID,
            releaseID: releaseID,
            kind: .other,
            detail: String(repeating: "👨‍👩‍👧‍👦", count: 500),
            idempotencyKey: "report-wallpaper-0004"
        ))
    }

    func testRightsValidationUsesServerRequirementsAndRequiresExplicitAttestation() throws {
        let licenseID = UUID()
        let requirements = CreatorRightsRequirements(
            requiresSourceURL: true,
            requiresAttribution: true,
            requiresProof: true
        )

        XCTAssertThrowsError(try CreatorRightsDeclaration(
            basis: .licensed,
            rightsHolder: "Example Artist",
            licenseID: licenseID,
            sourceURL: nil,
            attributionText: nil,
            proofObjectIDs: [],
            attestsRights: false,
            requirements: requirements
        ))

        let declaration = try CreatorRightsDeclaration(
            basis: .licensed,
            rightsHolder: "Example Artist",
            licenseID: licenseID,
            sourceURL: XCTUnwrap(URL(string: "https://example.test/source")),
            attributionText: "Artwork by Example Artist",
            proofObjectIDs: [UUID()],
            attestsRights: true,
            requirements: requirements
        )
        XCTAssertTrue(declaration.attestsRights)
    }

    func testSubmitRequestBindsRevisionGenerationAndCurrentTerms() throws {
        let submissionID = UUID()
        let request = try CreatorSubmitRequest(
            submissionID: submissionID,
            expectedRevision: 4,
            expectedGeneration: 2,
            acceptedCreatorTermsVersion: "2026-09-01",
            currentCreatorTermsVersion: "2026-09-01",
            idempotencyKey: "creator-submit-0001"
        )
        XCTAssertEqual(request.submissionID, submissionID)
        XCTAssertEqual(request.expectedRevision, 4)
        XCTAssertEqual(request.expectedGeneration, 2)

        XCTAssertThrowsError(try CreatorSubmitRequest(
            submissionID: submissionID,
            expectedRevision: 4,
            expectedGeneration: 1,
            acceptedCreatorTermsVersion: "2026-01-01",
            currentCreatorTermsVersion: "2026-09-01",
            idempotencyKey: "creator-submit-0002"
        ))
    }

    func testModerationAccessRequiresLiveServerGrantAndAAL2() {
        let now = Date(timeIntervalSince1970: 1_000)
        let base = CreatorAuthorizationSnapshot(
            subjectID: "11111111-1111-4111-8111-111111111111",
            accountIsActive: true,
            sessionExpiresAt: now.addingTimeInterval(300),
            creatorGrantRevision: 2,
            acceptedCreatorTermsVersion: "2026-09-01",
            currentCreatorTermsVersion: "2026-09-01",
            moderatorGrantRevision: 7,
            assuranceLevel: .aal2
        )

        XCTAssertTrue(base.canAccessCreatorStudio(at: now))
        XCTAssertTrue(base.canAccessModeration(at: now))
        XCTAssertFalse(base.removingModeratorGrant().canAccessModeration(at: now))
        XCTAssertFalse(base.withAssuranceLevel(.aal1).canAccessModeration(at: now))
        XCTAssertFalse(base.canAccessModeration(at: now.addingTimeInterval(301)))
    }

    func testModeratorPreviewAcceptsOnlyCanonicalArtifacts() throws {
        let policy = try CatalogRemoteURLPolicy(
            supabaseURL: XCTUnwrap(URL(string: "https://project.supabase.co")),
            approvedCDNHosts: ["cdn.example.test"]
        )
        let canonical = try CreatorCanonicalArtifact(
            role: .preview,
            url: XCTUnwrap(URL(string: "https://cdn.example.test/canonical/preview.mp4")),
            sha256: String(repeating: "a", count: 64),
            byteCount: 1_024,
            mediaType: "video/mp4",
            width: 1920,
            height: 1080,
            durationMilliseconds: 5_000,
            remoteURLPolicy: policy
        )
        XCTAssertEqual(canonical.role, .preview)
        XCTAssertEqual(canonical.sha256, String(repeating: "a", count: 64))

        XCTAssertThrowsError(try CreatorCanonicalArtifact(
            role: .preview,
            url: XCTUnwrap(URL(string: "https://uploads.example.test/raw/source.mov")),
            sha256: String(repeating: "a", count: 64),
            byteCount: 1_024,
            mediaType: "video/mp4",
            width: 1920,
            height: 1080,
            durationMilliseconds: 5_000,
            remoteURLPolicy: policy
        ))

        XCTAssertThrowsError(try CreatorCanonicalArtifact(
            role: .poster,
            url: XCTUnwrap(URL(string: "https://cdn.example.test/canonical/poster.jpg")),
            sha256: String(repeating: "g", count: 64),
            byteCount: 1_024,
            mediaType: "image/jpeg",
            width: 1920,
            height: 1080,
            durationMilliseconds: 0,
            remoteURLPolicy: policy
        ))
    }
}
