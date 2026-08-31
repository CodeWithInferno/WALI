import Foundation
import Testing
@testable import WALIModel

@Suite("Device-local displays and presentation")
struct DisplayPresentationTests {
    @Test("Display identity makes installation locality explicit")
    func displayIdentity() throws {
        let identity = try makeDisplayIdentity()
        #expect(identity.deviceID.rawValue == installationIDText)
        #expect(identity.localID.rawValue == localDisplayIDText)
    }

    @Test("Display aliases validate normalized fingerprints")
    func normalizedAlias() throws {
        let alias = try DisplayAlias(
            kind: DisplayAliasKindID("wali.edid"),
            fingerprint: "acme:1234:5678:serial-9",
            lifetime: .hardware
        )
        #expect(alias.fingerprint == "acme:1234:5678:serial-9")

        for invalid in ["", "ACME:1234", "acme display", "acme/1234"] {
            expectViolation(.invalidFingerprint) {
                _ = try DisplayAlias(
                    kind: DisplayAliasKindID("wali.edid"),
                    fingerprint: invalid,
                    lifetime: .hardware
                )
            }
        }
    }

    @Test("Display record canonicalizes and deduplicates aliases")
    func aliasCanonicalization() throws {
        let hardware = try DisplayAlias(
            kind: DisplayAliasKindID("wali.edid"),
            fingerprint: "acme:display-1",
            lifetime: .hardware
        )
        let session = try DisplayAlias(
            kind: DisplayAliasKindID("wali.session"),
            fingerprint: "session:9",
            lifetime: .session
        )
        let record = try DisplayRecord(
            schema: .current,
            identity: makeDisplayIdentity(),
            aliases: [session, hardware, session],
            userLabel: "Studio Display"
        )

        #expect(record.aliases == [hardware, session])
        #expect(record.userLabel == "Studio Display")
        let decoded = try JSONDecoder().decode(
            DisplayRecord.self,
            from: JSONEncoder().encode(record)
        )
        #expect(decoded == record)
    }

    @Test("Display record requires aliases and bounds user labels")
    func displayRecordBounds() throws {
        expectViolation(.emptyCollection) {
            _ = try DisplayRecord(
                schema: .current,
                identity: makeDisplayIdentity(),
                aliases: [],
                userLabel: nil
            )
        }
        expectViolation(.blankText) {
            _ = try DisplayRecord(
                schema: .current,
                identity: makeDisplayIdentity(),
                aliases: [
                    DisplayAlias(
                        kind: DisplayAliasKindID("wali.edid"),
                        fingerprint: "acme:1",
                        lifetime: .hardware
                    )
                ],
                userLabel: "   "
            )
        }
    }

    @Test("Match confidence belongs to a candidate and is not persisted on aliases")
    func confidenceIsTransientMatchData() throws {
        let alias = try DisplayAlias(
            kind: DisplayAliasKindID("wali.edid"),
            fingerprint: "acme:display-1",
            lifetime: .hardware
        )
        let candidate = try DisplayMatchCandidate(
            identity: makeDisplayIdentity(),
            confidence: .exact
        )

        #expect(candidate.confidence == .exact)
        #expect(
            try logicalJSON(alias)
                == "{\"fingerprint\":\"acme:display-1\",\"kind\":\"wali.edid\",\"lifetime\":\"hardware\"}"
        )
    }

    @Test("Presentation policy has centered fixed-point defaults")
    func presentationDefaults() throws {
        let policy = PresentationPolicy()
        #expect(policy.contentFit == .fill)
        #expect(policy.focalPoint == .center)
        #expect(policy.focalPoint.x.rawValue == 5_000)
        #expect(policy.focalPoint.y.rawValue == 5_000)
        #expect(policy.qualityIntent == .automatic)
        #expect(policy.lowPowerResponse == .pause)
    }

    @Test("Assignment pins an immutable release without library or sync state")
    func assignmentReleasePinning() throws {
        let assignment = try DeviceLocalPresentationAssignment(
            schema: .current,
            id: PresentationAssignmentID(assignmentIDText),
            displayIdentity: makeDisplayIdentity(),
            releaseID: AssetReleaseID(releaseIDText),
            policy: PresentationPolicy()
        )
        let decoded = try JSONDecoder().decode(
            DeviceLocalPresentationAssignment.self,
            from: JSONEncoder().encode(assignment)
        )

        #expect(decoded == assignment)
        #expect(decoded.releaseID.rawValue == releaseIDText)
        let json = try logicalJSON(decoded)
        #expect(!json.contains("libraryItem"))
        #expect(!json.contains("sync"))
    }

    @Test("Golden display and assignment fixtures round trip")
    func displayFixture() throws {
        let fixture = try JSONDecoder().decode(
            DisplayFixture.self,
            from: fixtureData(named: "model-records-v1")
        )
        #expect(fixture.displayRecord.schema == .current)
        #expect(fixture.assignment.schema == .current)
        #expect(
            try JSONDecoder().decode(
                DisplayRecord.self,
                from: JSONEncoder().encode(fixture.displayRecord)
            ) == fixture.displayRecord
        )
        #expect(
            try JSONDecoder().decode(
                DeviceLocalPresentationAssignment.self,
                from: JSONEncoder().encode(fixture.assignment)
            ) == fixture.assignment
        )
    }
}

private struct DisplayFixture: Decodable {
    let displayRecord: DisplayRecord
    let assignment: DeviceLocalPresentationAssignment
}
