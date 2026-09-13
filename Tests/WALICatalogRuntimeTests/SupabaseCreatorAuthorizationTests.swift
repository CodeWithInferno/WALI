import Foundation
import Supabase
import Synchronization
import XCTest
@testable import WALICatalogRuntime

final class SupabaseCreatorAuthorizationTests: XCTestCase {
    func testCreatorUploadFormatsDefaultToVideoWhenAbsentOrNull() async throws {
        for formats: Any? in [nil, NSNull()] {
            let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", rpcBody: capabilityMetadata(formats))
            defer { fixture.close() }
            let metadata = try await fixture.gateway.creatorMetadata()
            XCTAssertEqual(metadata.supportedUploadMediaTypes, [.mp4, .quickTime])
        }
    }

    func testCreatorUploadFormatsHonorExplicitStillEmptyAndUnknownValues() async throws {
        let cases: [([String], Set<CreatorUploadMediaType>)] = [
            (["image/jpeg", "image/png"], [.jpeg, .png]), (["video/mp4"], [.mp4]),
            ([], []), (["image/webp"], []), (["video/mp4", "image/avif"], [.mp4]),
        ]
        for (advertised, expected) in cases {
            let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", rpcBody: capabilityMetadata(advertised))
            defer { fixture.close() }
            let formats = try await fixture.gateway.supportedUploadMediaTypes()
            XCTAssertEqual(formats, expected, "Explicit capability must not invent additional formats")
            XCTAssertEqual(fixture.paths, ["/rest/v1/rpc/creator_metadata_v1"])
        }
    }

    func testCreatorUploadFormatsRejectMalformedCapabilities() async throws {
        let cases: [Any] = [true, "image/png", ["image/png", "image/png"],
            Array(repeating: "image/webp", count: 9), [""], ["image/png\n"], ["é"],
            [String(repeating: "a", count: 65)], [12]]
        for advertised in cases {
            let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", rpcBody: capabilityMetadata(advertised))
            defer { fixture.close() }
            do { _ = try await fixture.gateway.creatorMetadata(); XCTFail("Malformed upload capability accepted: \(advertised)") }
            catch {}
        }
    }

    private func capabilityMetadata(_ formats: Any?) throws -> Data {
        var response: [String: Any] = [
            "categories": [["id": UUID().uuidString.lowercased(), "name": "Nature", "slug": "nature"]],
            "tags": [], "current_creator_terms_version": "2026-09-12",
            "licenses": [["id": UUID().uuidString.lowercased(), "name": "Wallpaper Use", "code": "wallpaper-use",
                "requirements": ["requires_source_url": false, "requires_attribution": true, "requires_proof": false]]],
        ]
        if let formats { response["supported_upload_media_types"] = formats }
        return try JSONSerialization.data(withJSONObject: response)
    }

    func testEffectiveTermsAllowOrdinaryAAL1Creator() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", accepted: "2026-09-12", staffGrant: false)
        defer { fixture.close() }
        let value = try await fixture.gateway.authorizationSnapshot()
        XCTAssertTrue(value.canAccessCreatorStudio())
        XCTAssertFalse(value.canAccessModeration())
    }

    func testCreatorLicenseTermsLinkIsAvailableAndRejectsUnsafeURLs() async throws {
        for link in ["https://legal.example.test/wallpaper-use/2026-09-12", "http://legal.example.test/terms"] {
            let response: [String: Any] = [
                "categories": [["id": UUID().uuidString.lowercased(), "name": "Nature", "slug": "nature"]],
                "tags": [], "current_creator_terms_version": "2026-09-12",
                "licenses": [["id": UUID().uuidString.lowercased(), "name": "Wallpaper Use", "code": "wallpaper-use",
                              "terms_url": link,
                              "requirements": ["requires_source_url": false, "requires_attribution": true, "requires_proof": false]]],
            ]
            let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", rpcBody: JSONSerialization.data(withJSONObject: response))
            defer { fixture.close() }
            if link.hasPrefix("https:") {
                let metadata = try await fixture.gateway.creatorMetadata()
                XCTAssertEqual(metadata.licenses.first?.termsURL?.absoluteString, link)
            } else {
                do { _ = try await fixture.gateway.creatorMetadata(); XCTFail("Unsafe license link was accepted") }
                catch {}
            }
        }
    }

    func testCompleteUploadSendsAdmissionMetadataWithExplicitNullOptionals() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", accepted: "2026-09-12", staffGrant: false)
        defer { fixture.close() }
        let rights = try CreatorRightsDeclaration(
            basis: .original, rightsHolder: "Original artist", licenseID: UUID(), sourceURL: nil,
            attributionText: "Art by Original artist", proofObjectIDs: [], attestsRights: true,
            requirements: .init(requiresSourceURL: false, requiresAttribution: true, requiresProof: false)
        )
        let draft = try CreatorDraft(title: "Ocean", description: "A calm loop", primaryCategoryID: UUID(),
                                    suggestedTagIDs: [], contentWarning: nil, rights: rights)
        let request = try CreatorCompleteUploadRequest(uploadSessionID: UUID(), expectedSessionRevision: 2,
                                                      draft: draft, creatorTermsVersion: "2026-09-12", idempotencyKey: "complete-upload-fixture")
        // The fixture captures the real SDK request; its authorization response is intentionally not a mutation response.
        _ = try? await fixture.gateway.completeUpload(request)
        let body = try XCTUnwrap(fixture.requestBodies.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fixture.paths, ["/functions/v1/complete-upload"])
        XCTAssertEqual(json["api_version"] as? String, "creator.v1")
        XCTAssertEqual(json["upload_session_id"] as? String, request.uploadSessionID.uuidString.lowercased())
        let admission = try XCTUnwrap(json["draft"] as? [String: Any])
        XCTAssertEqual(Set(admission.keys), ["title", "description", "primary_category_id", "suggested_tag_ids",
                                           "content_warning", "rights_basis", "rights_holder", "license_id", "source_url",
                                           "attribution_text", "proof_object_ids", "attests_rights", "creator_terms_version"])
        XCTAssertEqual(admission["rights_holder"] as? String, "Original artist")
        XCTAssertEqual(admission["creator_terms_version"] as? String, "2026-09-12")
        XCTAssertEqual(admission["attests_rights"] as? Bool, true)
        XCTAssertTrue(admission["source_url"] is NSNull)
        XCTAssertTrue(admission["content_warning"] is NSNull)
        XCTAssertEqual(admission["proof_object_ids"] as? [String], [])
    }

    func testRetryProcessingSendsOnlyBoundSubmissionRevision() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", accepted: "2026-09-12", staffGrant: false)
        defer { fixture.close() }
        let request = try CreatorRetryProcessingRequest(submissionID: UUID(), expectedRevision: 9,
                                                       idempotencyKey: "retry-processing-fixture")
        _ = try? await fixture.gateway.retryProcessing(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture.requestBodies.last)) as? [String: Any])
        XCTAssertEqual(fixture.paths, ["/functions/v1/creator-command"])
        XCTAssertEqual(json["action"] as? String, "retry_processing")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["submission_id", "expected_revision"])
        XCTAssertEqual(payload["submission_id"] as? String, request.submissionID.uuidString.lowercased())
        XCTAssertEqual(payload["expected_revision"] as? Int, 9)
        XCTAssertThrowsError(try CreatorRetryProcessingRequest(submissionID: UUID(), expectedRevision: 0,
                                                             idempotencyKey: "retry-processing-fixture"))
    }

    func testRetryPublicationSendsOnlyBoundSubmissionRevision() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: "2026-09-12", accepted: "2026-09-12", staffGrant: false)
        defer { fixture.close() }
        let request = try CreatorRetryPublicationRequest(submissionID: UUID(), expectedRevision: 7,
                                                        idempotencyKey: "retry-publication-fixture")
        _ = try? await fixture.gateway.retryPublication(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture.requestBodies.last)) as? [String: Any])
        XCTAssertEqual(fixture.paths, ["/functions/v1/creator-command"])
        XCTAssertEqual(json["action"] as? String, "retry_publication")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["submission_id", "expected_revision"])
        XCTAssertEqual(payload["submission_id"] as? String, request.submissionID.uuidString.lowercased())
        XCTAssertEqual(payload["expected_revision"] as? Int, 7)
    }

    func testNullTermsPreserveStaffGrantWithoutCreatorOrAAL1ReviewAccess() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: NSNull())
        defer { fixture.close() }
        let value = try await fixture.gateway.authorizationSnapshot()
        XCTAssertEqual(value.subjectID, CreatorAuthorizationFixture.subject.uuidString.lowercased())
        XCTAssertEqual(value.currentCreatorTermsVersion, "")
        XCTAssertEqual(value.moderatorGrantRevision, 7)
        XCTAssertFalse(value.canAccessCreatorStudio())
        XCTAssertFalse(value.canAccessModeration())
        XCTAssertEqual(fixture.paths, ["/rest/v1/rpc/creator_authorization_v1"])
    }

    func testNullTermsAllowOnlyActiveAAL2StaffReview() async throws {
        for (active, grant, expected) in [(true, true, true), (false, true, false), (true, false, false)] {
            let fixture = try CreatorAuthorizationFixture(terms: NSNull(), assurance: "aal2", active: active, staffGrant: grant)
            defer { fixture.close() }
            let value = try await fixture.gateway.authorizationSnapshot()
            XCTAssertEqual(value.canAccessModeration(), expected)
            XCTAssertFalse(value.canAccessCreatorStudio())
        }
    }

    func testPresentTermsRetainExactAcceptanceRequirement() async throws {
        for accepted in ["2026-09-01", "2026-08-01"] {
            let fixture = try CreatorAuthorizationFixture(terms: "2026-09-01", accepted: accepted)
            defer { fixture.close() }
            let value = try await fixture.gateway.authorizationSnapshot()
            XCTAssertEqual(value.currentCreatorTermsVersion, "2026-09-01")
            XCTAssertEqual(value.canAccessCreatorStudio(), accepted == "2026-09-01")
        }
    }

    func testPresentEmptyMalformedAndWrongTypeTermsStillFail() async throws {
        let invalid: [Any] = ["", "terms version", "\u{0000}", String(repeating: "x", count: 65), 42, true, ["2026-09-01"]]
        for terms in invalid {
            let fixture = try CreatorAuthorizationFixture(terms: terms)
            defer { fixture.close() }
            do {
                _ = try await fixture.gateway.authorizationSnapshot()
                XCTFail("Invalid present terms were accepted")
            } catch {}
        }
    }

    func testOmittedTermsFieldRemainsMalformed() async throws {
        let fixture = try CreatorAuthorizationFixture(terms: NSNull(), omitTerms: true)
        defer { fixture.close() }
        do {
            _ = try await fixture.gateway.authorizationSnapshot()
            XCTFail("Missing terms field was accepted as an explicit null")
        } catch {}
    }
}

private struct CreatorAuthorizationFixture {
    static let subject = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let gateway: SupabaseCatalogGateway
    private let auth: AuthClient
    private let transport: URLSession
    private let host: String

    init(terms: Any, accepted: String? = nil, assurance: String = "aal1", active: Bool = true, staffGrant: Bool = true,
         omitTerms: Bool = false, rpcBody: Data? = nil) throws {
        host = "creator-" + UUID().uuidString.lowercased() + ".example.test"
        let environment = try CatalogEnvironment(
            supabaseURL: URL(string: "https://" + host)!, publishableKey: "sb_publishable_unit_fixture",
            approvedCDNHosts: [host], signingKeyID: "fixture", signingPublicKey: Data(repeating: 1, count: 32),
            authenticationMethod: .emailOTP
        )
        func segment(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        // Synthetic unsigned session; every HTTP request is intercepted below.
        let jwt = segment("{\"alg\":\"HS256\"}") + "." + segment("{\"exp\":4000000000,\"sub\":\"\(Self.subject.uuidString.lowercased())\"}") + ".fixture"
        let session = Session(accessToken: jwt, tokenType: "bearer", expiresIn: 3600, expiresAt: 4_000_000_000,
                              refreshToken: "fixture-refresh", user: User(id: Self.subject, appMetadata: [:], userMetadata: [:],
                              aud: "authenticated", createdAt: .distantPast, updatedAt: .distantPast))
        let base = CatalogMemoryAuthStorage()
        try base.store(key: CatalogCheckedAuthStorage.sessionKey, value: JSONEncoder().encode(session))
        let storage = CatalogCheckedAuthStorage(underlying: base)
        auth = SupabaseSharedAuth.makeClient(environment: environment, storage: storage) { _ in
            throw URLError(.unsupportedURL)
        }
        let authStore = AuthSessionStore(auth: auth, storage: storage, environment: environment)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreatorAuthorizationProtocol.self]
        transport = URLSession(configuration: configuration)
        var body: [String: Any] = [
            "account_is_active": active,
            "session_expires_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: session.expiresAt)),
            "creator_grant_revision": 3,
            "accepted_creator_terms_version": accepted as Any? ?? NSNull(),
            "current_creator_terms_version": terms,
            "moderator_grant_revision": staffGrant ? 7 : NSNull(),
            "assurance_level": assurance,
        ]
        if omitTerms { body.removeValue(forKey: "current_creator_terms_version") }
        CreatorAuthorizationProtocol.install(try rpcBody ?? JSONSerialization.data(withJSONObject: body), host: host)
        gateway = try SupabaseCatalogGateway(environment: environment, authSessionStore: authStore, session: transport)
    }

    var paths: [String] { CreatorAuthorizationProtocol.paths(host: host) }
    var requestBodies: [Data] { CreatorAuthorizationProtocol.requestBodies(host: host) }
    func close() {
        transport.invalidateAndCancel()
        CreatorAuthorizationProtocol.remove(host: host)
        Task { await auth.stopAutoRefresh() }
    }
}

// Foundation invokes URLProtocol callbacks; all shared fixture data is protected by Mutex.
private final class CreatorAuthorizationProtocol: URLProtocol, @unchecked Sendable {
    private struct Entry: Sendable { let body: Data; var paths: [String] = []; var requestBodies: [Data] = [] }
    private static let entries = Mutex<[String: Entry]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let requestBody: Data?
        if let body = request.httpBody { requestBody = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, data.count <= 65536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            requestBody = data
        } else { requestBody = nil }
        let body = Self.entries.withLock { entries -> Data? in
            guard let host = request.url?.host, var entry = entries[host] else { return nil }
            entry.paths.append(request.url?.path ?? "")
            if let requestBody { entry.requestBodies.append(requestBody) }
            entries[host] = entry
            return entry.body
        }
        guard let body, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func install(_ body: Data, host: String) { entries.withLock { $0[host] = Entry(body: body) } }
    static func paths(host: String) -> [String] { entries.withLock { $0[host]?.paths ?? [] } }
    static func requestBodies(host: String) -> [Data] { entries.withLock { $0[host]?.requestBodies ?? [] } }
    static func remove(host: String) { entries.withLock { _ = $0.removeValue(forKey: host) } }
}
