import Foundation
import OSLog
import Supabase
import WALICatalog

public actor SupabaseCatalogGateway:
    CatalogGateway,
    CatalogReportGateway,
    AccountPrivacyGateway,
    CreatorStudioGateway,
    CreatorAuthorizationGateway,
    ModerationGateway
{
    private static let logger = Logger(subsystem: "com.wali.catalog", category: "Gateway")
    private nonisolated let client: SupabaseClient
    private nonisolated let authSessionStore: AuthSessionStore
    private let mapper: CatalogMapper
    private let remoteURLPolicy: CatalogRemoteURLPolicy
    private let accountExportDownloader: AccountExportDownloader
    public init(environment: CatalogEnvironment) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        let session = CatalogURLSessionFactory.redirectRejecting(configuration: configuration)
        let keychainService = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            supabaseURL: environment.supabaseURL
        )
        let authStorage = CatalogCheckedAuthStorage(underlying: KeychainLocalStorage(service: keychainService))
        let auth = SupabaseSharedAuth.makeClient(environment: environment, storage: authStorage) {
            try await session.data(for: $0)
        }
        let authSessionStore = AuthSessionStore(auth: auth, storage: authStorage, environment: environment)
        self.authSessionStore = authSessionStore
        client = SupabaseSharedAuth.makeDataClient(
            environment: environment,
            authSessionStore: authSessionStore,
            session: session
        )
        let remoteURLPolicy = try CatalogRemoteURLPolicy(
            supabaseURL: environment.supabaseURL,
            approvedCDNHosts: environment.approvedCDNHosts
        )
        self.remoteURLPolicy = remoteURLPolicy
        mapper = CatalogMapper(remoteURLPolicy: remoteURLPolicy)
        accountExportDownloader = AccountExportDownloader(remoteURLPolicy: remoteURLPolicy)
    }

    /// Deterministic adapter composition uses the same API client and mapping path without
    /// opening Keychain or creating a network-backed AuthClient in tests.
    init(environment: CatalogEnvironment, authSessionStore: AuthSessionStore, session: URLSession) throws {
        self.authSessionStore = authSessionStore
        client = SupabaseSharedAuth.makeDataClient(environment: environment, authSessionStore: authSessionStore, session: session)
        let policy = try CatalogRemoteURLPolicy(supabaseURL: environment.supabaseURL, approvedCDNHosts: environment.approvedCDNHosts)
        remoteURLPolicy = policy
        mapper = CatalogMapper(remoteURLPolicy: policy)
        accountExportDownloader = AccountExportDownloader(remoteURLPolicy: policy)
    }

    public nonisolated func makeAuthSessionStore() -> AuthSessionStore {
        authSessionStore
    }

    public func home(locale: String, ratingCeiling: String) async throws -> CatalogHome {
        guard !locale.isEmpty,
              locale.utf8.count <= 35,
              ["everyone", "teen", "mature"].contains(ratingCeiling)
        else {
            throw CatalogRequestError.invalidRequest
        }
        struct Parameters: Encodable {
            let locale: String
            let ratingCeiling: String
            enum CodingKeys: String, CodingKey {
                case locale
                case ratingCeiling = "rating_ceiling"
            }
        }
        return try await safelyReading {
            let dto: CatalogHomeDTO = try await client
                .rpc(
                    "catalog_home_v1",
                    params: Parameters(locale: locale, ratingCeiling: ratingCeiling)
                )
                .execute()
                .value
            return try mapper.home(dto)
        }
    }

    public func browse(_ request: CatalogBrowseRequest) async throws -> CatalogPage {
        struct Parameters: Encodable {
            let category: String?
            let tags: [String]
            let sort: String
            let cursor: String?
            let limit: Int

            enum CodingKeys: String, CodingKey {
                case category, tags, sort, cursor, limit
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let category {
                    try container.encode(category, forKey: .category)
                } else {
                    try container.encodeNil(forKey: .category)
                }
                try container.encode(tags, forKey: .tags)
                try container.encode(sort, forKey: .sort)
                if let cursor {
                    try container.encode(cursor, forKey: .cursor)
                } else {
                    try container.encodeNil(forKey: .cursor)
                }
                try container.encode(limit, forKey: .limit)
            }
        }
        return try await safelyReading {
            let dto: CatalogPageDTO = try await client
                .rpc(
                    "catalog_browse_v1",
                    params: Parameters(
                        category: request.category,
                        tags: request.tags,
                        sort: request.sort.rawValue,
                        cursor: request.cursor,
                        limit: request.limit
                    )
                )
                .execute()
                .value
            return try mapper.page(dto)
        }
    }

    public func search(_ request: CatalogSearchRequest) async throws -> CatalogSearchPage {
        struct Filters: Encodable {
            let categorySlug: String?
            let tagSlugs: [String]
            let contentRatingCeiling: String
            let minimumDurationMilliseconds: UInt64?
            let maximumDurationMilliseconds: UInt64?

            enum CodingKeys: String, CodingKey {
                case categorySlug = "category_slug"
                case tagSlugs = "tag_slugs"
                case contentRatingCeiling = "content_rating_ceiling"
                case minimumDurationMilliseconds = "minimum_duration_ms"
                case maximumDurationMilliseconds = "maximum_duration_ms"
            }
        }
        struct Parameters: Encodable {
            let query: String
            let filters: Filters
            let cursor: String?
            let limit: Int

            enum CodingKeys: String, CodingKey {
                case query, filters, cursor, limit
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(query, forKey: .query)
                try container.encode(filters, forKey: .filters)
                if let cursor {
                    try container.encode(cursor, forKey: .cursor)
                } else {
                    try container.encodeNil(forKey: .cursor)
                }
                try container.encode(limit, forKey: .limit)
            }
        }
        return try await safelyReading {
            let dto: CatalogSearchPageDTO = try await client
                .rpc(
                    "catalog_search_v1",
                    params: Parameters(
                        query: request.query,
                        filters: Filters(
                            categorySlug: request.category,
                            tagSlugs: request.tags,
                            contentRatingCeiling: request.ratingCeiling,
                            minimumDurationMilliseconds: request.minimumDurationMilliseconds,
                            maximumDurationMilliseconds: request.maximumDurationMilliseconds
                        ),
                        cursor: request.cursor,
                        limit: request.limit
                    )
                )
                .execute()
                .value
            return try mapper.searchPage(dto)
        }
    }

    public func detail(wallpaperID: String) async throws -> CatalogWallpaperDetail {
        try validateUUID(wallpaperID)
        struct Parameters: Encodable {
            let wallpaperID: String
            enum CodingKeys: String, CodingKey { case wallpaperID = "wallpaper_id" }
        }
        return try await safelyReading {
            let dto: WallpaperDetailDTO = try await client
                .rpc("catalog_wallpaper_detail_v1", params: Parameters(wallpaperID: wallpaperID))
                .execute()
                .value
            return try mapper.detail(dto)
        }
    }

    public func setFavorite(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        try await setInteraction(
            function: "set_favorite_v1",
            targetName: "wallpaper_id",
            targetID: wallpaperID,
            desired: desired,
            expectedRevision: expectedRevision,
            idempotencyKey: idempotencyKey
        )
    }

    public func setSaved(
        wallpaperID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        try await setInteraction(
            function: "set_saved_v1",
            targetName: "wallpaper_id",
            targetID: wallpaperID,
            desired: desired,
            expectedRevision: expectedRevision,
            idempotencyKey: idempotencyKey
        )
    }

    public func requestInstall(
        wallpaperID: String,
        releaseID: String,
        expectedWallpaperRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInstallGrant {
        try validateUUID(wallpaperID)
        try validateUUID(releaseID)
        try validateRevision(expectedWallpaperRevision)
        try validateIdempotencyKey(idempotencyKey)
        let requestID = UUID().uuidString.lowercased()
        let request = InstallRequestDTO(
            apiVersion: "catalog.v1",
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            wallpaperID: wallpaperID,
            releaseID: releaseID,
            expectedWallpaperRevision: expectedWallpaperRevision
        )
        return try await safely {
            let envelope: CatalogFunctionEnvelope<InstallGrantDTO> = try await invokeFunction(
                "request-install",
                options: FunctionInvokeOptions(body: request)
            )
            let payload = try mapper.payload(
                envelope,
                apiVersion: "catalog.v1",
                expectedRequestID: requestID
            )
            guard payload.keyID.utf8.count <= 64,
                  payload.installReceipt.utf8.count <= 512,
                  payload.manifestBody.utf8.count <= 87_384,
                  payload.metadataBody.utf8.count <= 21_848,
                  payload.signature.utf8.count <= 86,
                  let manifest = Data(unpaddedBase64URL: payload.manifestBody),
                  manifest.count <= 65_536,
                  let metadata = Data(unpaddedBase64URL: payload.metadataBody),
                  metadata.count <= 16_384,
                  let expiresAt = try? exactTimestamp(payload.expiresAt)
            else {
                throw CatalogMappingError.invalidResponse
            }
            return CatalogInstallGrant(
                manifestBody: manifest,
                metadataBody: metadata,
                signatureBase64URL: payload.signature,
                keyID: payload.keyID,
                receipt: payload.installReceipt,
                expiresAt: expiresAt
            )
        }
    }

    public func securityState() async throws -> CatalogSecurityState {
        let requestID = UUID().uuidString.lowercased()
        let request = CatalogSecurityStateRequestDTO(
            apiVersion: "catalog.v1",
            requestID: requestID
        )
        return try await safelyReading {
            let envelope: CatalogFunctionEnvelope<CatalogSecurityStateDTO> = try await invokeFunction(
                "catalog-security-state",
                options: FunctionInvokeOptions(body: request)
            )
            let payload = try mapper.payload(
                envelope,
                apiVersion: "catalog.v1",
                expectedRequestID: requestID
            )
            return try payload.model()
        }
    }

    public func report(_ request: CatalogReportRequest) async throws -> CatalogReportReceipt {
        let requestID = UUID().uuidString.lowercased()
        let payload = ReportWallpaperRequestDTO(
            apiVersion: "catalog.v1",
            requestID: requestID,
            idempotencyKey: request.idempotencyKey,
            wallpaperID: request.wallpaperID,
            releaseID: request.releaseID,
            kind: request.kind.rawValue,
            detail: request.detail
        )
        return try await safely {
            let envelope: CatalogFunctionEnvelope<ReportWallpaperResponseDTO> = try await invokeFunction(
                "report-wallpaper",
                options: FunctionInvokeOptions(body: payload),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "catalog.v1",
                expectedRequestID: requestID
            )
            guard UUID(uuidString: response.reportID)?.uuidString.lowercased() == response.reportID,
                  response.status == "open"
            else {
                throw CatalogMappingError.invalidResponse
            }
            return CatalogReportReceipt(
                id: response.reportID,
                status: response.status,
                createdAt: try exactTimestamp(response.createdAt)
            )
        }
    }

    public func accountProfile() async throws -> MarketplaceAccountProfile {
        try await safelyReading {
            let dto: AccountProfileDTO = try await client
                .from("my_profile_v1")
                .select("id,handle,display_name,status,revision")
                .single()
                .execute()
                .value
            return try MarketplaceAccountProfile(
                id: dto.id,
                handle: dto.handle,
                displayName: dto.displayName,
                status: dto.status,
                revision: dto.revision
            )
        }
    }

    public func authorizationSnapshot() async throws -> CreatorAuthorizationSnapshot {
        try await safelyReading {
            let session = try requestSession()
            let subjectID = session.user.id.uuidString.lowercased()
            let dto: CreatorAuthorizationDTO = try await client
                .rpc("creator_authorization_v1", params: EmptyParameters())
                .execute()
                .value
            guard let assurance = CreatorAssuranceLevel(rawValue: dto.assuranceLevel),
                  let sessionExpiresAt = try? exactTimestamp(dto.sessionExpiresAt),
                  sessionExpiresAt > .now,
                  abs(sessionExpiresAt.timeIntervalSince1970 - session.expiresAt) < 60,
                  dto.creatorGrantRevision.map(isSafeRevision) ?? true,
                  dto.moderatorGrantRevision.map(isSafeRevision) ?? true,
                  dto.currentCreatorTermsVersion.map({
                      isBoundedCreatorToken($0, maximum: 64)
                  }) ?? true,
                  dto.acceptedCreatorTermsVersion.map({
                      isBoundedCreatorToken($0, maximum: 64)
                  }) ?? true
            else { throw CatalogMappingError.invalidResponse }
            return CreatorAuthorizationSnapshot(
                subjectID: subjectID,
                accountIsActive: dto.accountIsActive,
                sessionExpiresAt: sessionExpiresAt,
                creatorGrantRevision: dto.creatorGrantRevision,
                acceptedCreatorTermsVersion: dto.acceptedCreatorTermsVersion,
                currentCreatorTermsVersion: dto.currentCreatorTermsVersion ?? "",
                moderatorGrantRevision: dto.moderatorGrantRevision,
                assuranceLevel: assurance
            )
        }
    }

    public func creatorMetadata() async throws -> CreatorMetadata {
        try await safelyReading {
            let dto: CreatorMetadataDTO = try await client
                .rpc("creator_metadata_v1", params: EmptyParameters())
                .execute()
                .value
            let categories = try dto.categories.map(creatorTaxonomyOption)
            let tags = try dto.tags.map(creatorTaxonomyOption)
            let licenses = try dto.licenses.map { value -> CreatorLicenseOption in
                guard let id = UUID(uuidString: value.id),
                      id.uuidString.lowercased() == value.id,
                      isPlainCreatorText(value.name, maximum: 120),
                      isBoundedCreatorToken(value.code, maximum: 64)
                else { throw CatalogMappingError.invalidResponse }
                return CreatorLicenseOption(
                    id: id,
                    name: value.name,
                    code: value.code,
                    requirements: .init(
                        requiresSourceURL: value.requirements.requiresSourceURL,
                        requiresAttribution: value.requirements.requiresAttribution,
                        requiresProof: value.requirements.requiresProof
                    )
                )
            }
            return try CreatorMetadata(
                categories: categories,
                tags: tags,
                licenses: licenses,
                currentCreatorTermsVersion: dto.currentCreatorTermsVersion
            )
        }
    }

    public func acceptCreatorTerms(
        expectedSubjectID: String,
        version: String,
        idempotencyKey: String
    ) async throws -> CreatorAuthorizationSnapshot {
        guard canonicalUUID(expectedSubjectID) != nil,
              isBoundedCreatorToken(version, maximum: 64)
        else {
            throw CreatorContractError.invalidRequest
        }
        try validateIdempotencyKey(idempotencyKey)
        let requestID = UUID().uuidString.lowercased()
        let body = CreatorCommandRequestDTO(
            apiVersion: "creator.v1",
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            action: "accept_terms",
            payload: .acceptTerms(
                expectedSubjectID: expectedSubjectID,
                version: version
            )
        )
        try await safely {
            let sessionBefore = try requestSession()
            guard sessionBefore.user.id.uuidString.lowercased() == expectedSubjectID,
                  sessionBefore.expiresAt > Date.now.timeIntervalSince1970
            else { throw CatalogMappingError.invalidResponse }
            let envelope: CatalogFunctionEnvelope<CreatorEnrollmentResponseDTO> = try await invokeFunction(
                "creator-command",
                options: FunctionInvokeOptions(body: body),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "creator.v1",
                expectedRequestID: requestID
            )
            guard response.accountIsActive,
                  response.creatorEnrolled,
                  response.creatorGrantRevision > 0,
                  isSafeRevision(response.creatorGrantRevision),
                  response.acceptedCreatorTermsVersion == version,
                  response.currentCreatorTermsVersion == version
            else { throw CatalogMappingError.invalidResponse }
        }
        return try await authorizationSnapshot()
    }

    public func moderationMetadata() async throws -> ModerationMetadata {
        try await safelyReading {
            let dto: ModerationMetadataDTO = try await client
                .rpc("moderation_metadata_v1", params: EmptyParameters())
                .execute()
                .value
            guard isSafeRevision(dto.checklistRevision), dto.checklistRevision > 0 else {
                throw CatalogMappingError.invalidResponse
            }
            let options = try dto.reasonCodes.map { value -> ModerationReasonOption in
                guard isBoundedCreatorToken(value.code, maximum: 80),
                      isPlainCreatorText(value.label, maximum: 160),
                      !value.decisions.isEmpty,
                      value.decisions.count <= ModerationDecision.allCases.count
                else { throw CatalogMappingError.invalidResponse }
                let decisions = try value.decisions.map { raw -> ModerationDecision in
                    guard let decision = ModerationDecision(rawValue: raw) else {
                        throw CatalogMappingError.invalidResponse
                    }
                    return decision
                }
                guard Set(decisions).count == decisions.count else {
                    throw CatalogMappingError.invalidResponse
                }
                return try ModerationReasonOption(
                    code: value.code,
                    label: value.label,
                    decisions: Set(decisions)
                )
            }
            return try ModerationMetadata(
                checklistRevision: dto.checklistRevision,
                creatorNoteRequired: dto.creatorNoteRequired,
                reasonCodes: options
            )
        }
    }

    public func submissions(_ request: CreatorListRequest) async throws -> CreatorSubmissionPage {
        struct Parameters: Encodable {
            let cursor: String?
            let pageLimit: Int
            enum CodingKeys: String, CodingKey {
                case cursor
                case pageLimit = "page_limit"
            }
        }
        return try await safelyReading {
            let dto: CreatorSubmissionPageDTO = try await client
                .rpc(
                    "my_creator_submissions_v1",
                    params: Parameters(cursor: request.cursor, pageLimit: request.limit)
                )
                .execute()
                .value
            guard dto.items.count <= request.limit,
                  dto.nextCursor.map({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) ?? true
            else { throw CatalogMappingError.invalidResponse }
            return CreatorSubmissionPage(
                items: try dto.items.map(creatorSubmission),
                nextCursor: dto.nextCursor
            )
        }
    }

    public func processingStatus(
        submissionID: UUID,
        generation: UInt64
    ) async throws -> CreatorProcessingStatus {
        struct Parameters: Encodable {
            let submissionID: String
            let generation: UInt64
            enum CodingKeys: String, CodingKey {
                case generation
                case submissionID = "submission_id"
            }
        }
        guard generation > 0, isSafeRevision(generation) else {
            throw CreatorContractError.invalidRequest
        }
        return try await safelyReading {
            let dto: CreatorProcessingStatusDTO = try await client
                .rpc(
                    "creator_processing_status_v1",
                    params: Parameters(
                        submissionID: submissionID.uuidString.lowercased(),
                        generation: generation
                    )
                )
                .execute()
                .value
            let result = try creatorProcessingStatus(dto)
            guard result.submissionID == submissionID, result.generation == generation else {
                throw CatalogMappingError.invalidResponse
            }
            return result
        }
    }

    public func createUpload(_ request: CreatorUploadGrantRequest) async throws -> CreatorUploadSession {
        let requestID = UUID().uuidString.lowercased()
        let body = CreatorCreateUploadRequestDTO(requestID: requestID, request: request)
        return try await safely {
            let envelope: CatalogFunctionEnvelope<CreatorUploadSessionDTO> = try await invokeFunction(
                "create-upload",
                options: FunctionInvokeOptions(body: body)
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "creator.v1",
                expectedRequestID: requestID
            )
            guard let id = UUID(uuidString: response.uploadSessionID),
                  id.uuidString.lowercased() == response.uploadSessionID,
                  let endpoint = URL(string: response.uploadEndpoint),
                  remoteURLPolicy.allowsUpload(endpoint),
                  let expiresAt = try? exactTimestamp(response.expiresAt)
            else { throw CatalogMappingError.invalidResponse }
            return try CreatorUploadSession(
                id: id,
                revision: response.revision,
                endpoint: endpoint,
                requiredHeaders: response.requiredHeaders,
                scopedUploadToken: response.scopedUploadToken,
                expiresAt: expiresAt,
                declaredByteCount: request.declaredByteCount
            )
        }
    }

    public func completeUpload(_ request: CreatorCompleteUploadRequest) async throws -> CreatorMutationResult {
        let requestID = UUID().uuidString.lowercased()
        let body = CreatorCompleteUploadRequestDTO(requestID: requestID, request: request)
        return try await invokeCreatorMutation(function: "complete-upload", body: body, requestID: requestID)
    }

    public func saveDraft(_ request: CreatorSaveDraftRequest) async throws -> CreatorMutationResult {
        let requestID = UUID().uuidString.lowercased()
        let body = CreatorCommandRequestDTO(
            apiVersion: "creator.v1",
            requestID: requestID,
            idempotencyKey: request.idempotencyKey,
            action: "save_draft",
            payload: .saveDraft(request)
        )
        return try await invokeCreatorMutation(function: "creator-command", body: body, requestID: requestID)
    }

    public func submit(_ request: CreatorSubmitRequest) async throws -> CreatorMutationResult {
        let requestID = UUID().uuidString.lowercased()
        let body = CreatorSubmitRequestDTO(requestID: requestID, request: request)
        return try await invokeCreatorMutation(function: "submit-wallpaper", body: body, requestID: requestID)
    }

    public func withdraw(_ request: CreatorWithdrawRequest) async throws -> CreatorMutationResult {
        let requestID = UUID().uuidString.lowercased()
        let body = CreatorCommandRequestDTO(
            apiVersion: "creator.v1",
            requestID: requestID,
            idempotencyKey: request.idempotencyKey,
            action: "withdraw",
            payload: .withdraw(request)
        )
        return try await invokeCreatorMutation(function: "creator-command", body: body, requestID: requestID)
    }

    public func queue(_ request: ModerationQueueRequest) async throws -> ModerationQueuePage {
        let requestID = UUID().uuidString.lowercased()
        let body = ModerationReadRequestDTO(
            requestID: requestID, operation: "queue", status: request.status,
            sort: request.sort.rawValue, cursor: request.cursor, limit: request.limit
        )
        return try await safely {
            let envelope: CatalogFunctionEnvelope<ModerationQueuePageDTO> = try await invokeFunction(
                "moderate-submission", options: FunctionInvokeOptions(body: body), retryInterrupted: true
            )
            let dto = try mapper.payload(envelope, apiVersion: "moderation.v1", expectedRequestID: requestID)
            guard dto.items.count <= request.limit else { throw CatalogMappingError.invalidResponse }
            return ModerationQueuePage(
                items: try dto.items.map(moderationQueueItem),
                nextCursor: try canonicalOptionalCursor(dto.nextCursor)
            )
        }
    }

    public func reports(_ request: ModerationReportQueueRequest) async throws -> ModerationReportPage {
        let requestID = UUID().uuidString.lowercased()
        let body = ModerationReadRequestDTO(
            requestID: requestID, operation: "reports", status: nil,
            sort: nil, cursor: request.cursor, limit: request.limit
        )
        return try await safely {
            let envelope: CatalogFunctionEnvelope<ModerationReportPageDTO> = try await invokeFunction(
                "moderate-submission", options: FunctionInvokeOptions(body: body), retryInterrupted: true
            )
            let dto = try mapper.payload(envelope, apiVersion: "moderation.v1", expectedRequestID: requestID)
            guard dto.items.count <= request.limit else { throw CatalogMappingError.invalidResponse }
            let items = try dto.items.map { item -> ModerationReport in
                guard let id = canonicalUUID(item.reportID),
                      item.revision > 0, isSafeRevision(item.revision),
                      isBoundedCreatorToken(item.reasonCode, maximum: 96),
                      isPlainCreatorText(item.safeSummary, maximum: 2_000),
                      let status = ModerationReportStatus(rawValue: item.status), status != .closed,
                      let wallpaperID = canonicalUUID(item.wallpaperID),
                      item.wallpaperRevision > 0, isSafeRevision(item.wallpaperRevision),
                      isPlainCreatorText(item.wallpaperTitle, maximum: 120),
                      let wallpaperStatus = ModerationWallpaperStatus(rawValue: item.wallpaperStatus),
                      item.releaseID.map({ canonicalUUID($0) != nil }) ?? true,
                      (item.releaseID == nil) == (item.edition == nil),
                      item.edition.map({ $0 > 0 && isSafeRevision($0) }) ?? true,
                      item.canonicalArtifacts.count <= 3,
                      Set(item.canonicalArtifacts.map(\.role)).count == item.canonicalArtifacts.count
                else { throw CatalogMappingError.invalidResponse }
                return ModerationReport(
                    id: id,
                    revision: item.revision,
                    reasonCode: item.reasonCode,
                    safeSummary: item.safeSummary,
                    createdAt: try exactTimestamp(item.createdAt),
                    status: status, wallpaperID: wallpaperID, wallpaperRevision: item.wallpaperRevision,
                    wallpaperTitle: item.wallpaperTitle, wallpaperStatus: wallpaperStatus,
                    releaseID: item.releaseID.flatMap(canonicalUUID), edition: item.edition,
                    canonicalArtifacts: try item.canonicalArtifacts.map(moderationArtifact)
                )
            }
            return ModerationReportPage(items: items, nextCursor: try canonicalOptionalCursor(dto.nextCursor))
        }
    }

    public func resolveReport(_ request: ModerationReportResolutionRequest) async throws -> ModerationReportResolution {
        let requestID = UUID().uuidString.lowercased()
        let body = ResolveReportRequestDTO(requestID: requestID, request: request)
        return try await safely {
            let envelope: CatalogFunctionEnvelope<ResolveReportResponseDTO> = try await invokeFunction(
                "resolve-report", options: FunctionInvokeOptions(body: body), retryInterrupted: true
            )
            let dto = try mapper.payload(envelope, apiVersion: "moderation.v1", expectedRequestID: requestID)
            guard let reportID = canonicalUUID(dto.reportID), reportID == request.reportID,
                  dto.revision > request.expectedRevision, isSafeRevision(dto.revision),
                  dto.action == request.action.rawValue,
                  let status = ModerationReportStatus(rawValue: dto.status),
                  status == (request.action == .hidePendingReview ? .triaged : .closed),
                  let wallpaperID = canonicalUUID(dto.wallpaperID), wallpaperID == request.wallpaperID,
                  dto.wallpaperRevision >= request.expectedWallpaperRevision, isSafeRevision(dto.wallpaperRevision),
                  let wallpaperStatus = ModerationWallpaperStatus(rawValue: dto.wallpaperStatus),
                  request.action != .delist || wallpaperStatus == .removed,
                  request.action != .hidePendingReview || wallpaperStatus != .published
            else { throw CatalogMappingError.invalidResponse }
            return ModerationReportResolution(reportID: reportID, revision: dto.revision, status: status,
                action: request.action, wallpaperID: wallpaperID, wallpaperRevision: dto.wallpaperRevision,
                wallpaperStatus: wallpaperStatus)
        }
    }

    public func moderate(_ request: ModerationDecisionRequest) async throws -> ModerationDecisionResult {
        let requestID = UUID().uuidString.lowercased()
        let body = ModerateSubmissionRequestDTO(requestID: requestID, request: request)
        return try await safely {
            let envelope: CatalogFunctionEnvelope<ModerationDecisionResponseDTO> = try await invokeFunction(
                "moderate-submission",
                options: FunctionInvokeOptions(body: body),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "moderation.v1",
                expectedRequestID: requestID
            )
            guard let submissionID = canonicalUUID(response.submissionID),
                  submissionID == request.submissionID,
                  response.generation == request.expectedGeneration,
                  isSafeRevision(response.revision),
                  let state = CreatorSubmissionState(rawValue: response.state),
                  state == moderationState(for: request.decision),
                  response.decision == request.decision.rawValue
            else { throw CatalogMappingError.invalidResponse }
            return ModerationDecisionResult(
                submissionID: submissionID,
                revision: response.revision,
                generation: response.generation,
                state: state
            )
        }
    }

    public func publish(_ request: PublishReleaseRequest) async throws -> PublishedRelease {
        let requestID = UUID().uuidString.lowercased()
        let body = PublishReleaseRequestDTO(requestID: requestID, request: request)
        return try await safely {
            let envelope: CatalogFunctionEnvelope<PublishedReleaseDTO> = try await invokeFunction(
                "publish-release", options: FunctionInvokeOptions(body: body), retryInterrupted: true
            )
            let dto = try mapper.payload(envelope, apiVersion: "moderation.v1", expectedRequestID: requestID)
            guard let wallpaperID = canonicalUUID(dto.wallpaperID),
                  let releaseID = canonicalUUID(dto.releaseID),
                  dto.edition > 0, isSafeRevision(dto.edition),
                  dto.wallpaperRevision > request.expectedWallpaperRevision,
                  isSafeRevision(dto.wallpaperRevision),
                  dto.manifestDigest.utf8.count == 64,
                  dto.manifestDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  isBoundedCreatorToken(dto.keyID, maximum: 128)
            else { throw CatalogMappingError.invalidResponse }
            return PublishedRelease(wallpaperID: wallpaperID, releaseID: releaseID, edition: dto.edition,
                                    wallpaperRevision: dto.wallpaperRevision,
                                    publishedAt: try exactTimestamp(dto.publishedAt))
        }
    }

    public func requestAccountExport(idempotencyKey: String) async throws -> AccountExportSnapshot {
        try validateIdempotencyKey(idempotencyKey)
        let requestID = UUID().uuidString.lowercased()
        let request = AccountExportRequestDTO(
            apiVersion: "account.v1",
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            operation: nil,
            exportID: nil
        )
        return try await safely {
            let sessionBefore = try requestSession()
            let expectedSubjectID = sessionBefore.user.id.uuidString.lowercased()
            let envelope: CatalogFunctionEnvelope<AccountExportResponseDTO> = try await invokeFunction(
                "request-account-export",
                options: FunctionInvokeOptions(body: request),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "account.v1",
                expectedRequestID: requestID
            )
            let sessionAfter = try await authSessionStore.validatedSession()
            guard sessionAfter.user.id.uuidString.lowercased() == expectedSubjectID,
                  sessionAfter.expiresAt > Date.now.timeIntervalSince1970
            else { throw CatalogMappingError.invalidResponse }
            let snapshot = try accountExportSnapshot(response, expectedSubjectID: expectedSubjectID)
            return snapshot
        }
    }

    public func accountExportStatus(id: String, idempotencyKey: String) async throws -> AccountExportSnapshot {
        try validateUUID(id)
        try validateIdempotencyKey(idempotencyKey)
        let requestID = UUID().uuidString.lowercased()
        let request = AccountExportRequestDTO(
            apiVersion: "account.v1",
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            operation: "status",
            exportID: id
        )
        return try await safely {
            let sessionBefore = try requestSession()
            let expectedSubjectID = sessionBefore.user.id.uuidString.lowercased()
            let envelope: CatalogFunctionEnvelope<AccountExportResponseDTO> = try await invokeFunction(
                "request-account-export",
                options: FunctionInvokeOptions(body: request),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "account.v1",
                expectedRequestID: requestID
            )
            let sessionAfter = try await authSessionStore.validatedSession()
            guard sessionAfter.user.id.uuidString.lowercased() == expectedSubjectID,
                  sessionAfter.expiresAt > Date.now.timeIntervalSince1970
            else { throw CatalogMappingError.invalidResponse }
            let snapshot = try accountExportSnapshot(response, expectedSubjectID: expectedSubjectID)
            return snapshot
        }
    }

    public func accountOperationReferences() async throws -> AccountPrivacyOperationReferences? {
        struct ReferencesDTO: Decodable, Sendable {
            let subjectID: String
            let exportID: String?
            let deletionID: String?
            enum CodingKeys: String, CodingKey {
                case subjectID = "subject_id"
                case exportID = "export_id"
                case deletionID = "deletion_id"
            }
        }
        return try await safelyReading {
            let session = try requestSession()
            let subjectID = session.user.id.uuidString.lowercased()
            let dto: ReferencesDTO = try await client
                .rpc("account_operation_references_v1", params: EmptyParameters())
                .execute().value
            let currentSession = try await authSessionStore.validatedSession()
            guard dto.subjectID == subjectID,
                  currentSession.user.id.uuidString.lowercased() == subjectID
            else { throw CatalogMappingError.invalidResponse }
            return try AccountPrivacyOperationReferences(
                subjectID: dto.subjectID, exportID: dto.exportID, deletionID: dto.deletionID
            )
        }
    }

    public func saveAccountExport(_ snapshot: AccountExportSnapshot, to destination: URL) async throws {
        try await safely {
            try await accountExportDownloader.save(snapshot, to: destination)
        }
    }

    public func requestAccountDeletion(
        expectedProfileRevision: UInt64,
        confirmation: String,
        idempotencyKey: String
    ) async throws -> AccountDeletionSnapshot {
        try validateRevision(expectedProfileRevision)
        try validateIdempotencyKey(idempotencyKey)
        guard confirmation == "DELETE MY WALI" else { throw CatalogRequestError.invalidRequest }
        let requestID = UUID().uuidString.lowercased()
        let request = AccountDeletionRequestDTO(
            apiVersion: "account.v1",
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            operation: nil,
            deletionID: nil,
            expectedProfileRevision: expectedProfileRevision,
            confirmation: confirmation
        )
        return try await safely {
            let sessionBefore = try requestSession()
            let expectedSubjectID = sessionBefore.user.id.uuidString.lowercased()
            let envelope: CatalogFunctionEnvelope<AccountDeletionResponseDTO> = try await invokeFunction(
                "request-account-deletion",
                options: FunctionInvokeOptions(body: request),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "account.v1",
                expectedRequestID: requestID
            )
            let sessionAfter = try await authSessionStore.validatedSession()
            guard sessionAfter.user.id.uuidString.lowercased() == expectedSubjectID,
                  sessionAfter.expiresAt > Date.now.timeIntervalSince1970
            else { throw CatalogMappingError.invalidResponse }
            let snapshot = try accountDeletionSnapshot(
                response,
                expectedSubjectID: expectedSubjectID,
                usesProcessingStatus: true
            )
            return snapshot
        }
    }

    public func accountDeletionStatus(id: String, idempotencyKey: String) async throws -> AccountDeletionSnapshot {
        try validateUUID(id)
        try validateIdempotencyKey(idempotencyKey)
        let requestID = UUID().uuidString.lowercased()
        let request = AccountDeletionRequestDTO(
            apiVersion: "account.v1",
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            operation: "status",
            deletionID: id,
            expectedProfileRevision: nil,
            confirmation: nil
        )
        return try await safely {
            let sessionBefore = try requestSession()
            let expectedSubjectID = sessionBefore.user.id.uuidString.lowercased()
            let envelope: CatalogFunctionEnvelope<AccountDeletionResponseDTO> = try await invokeFunction(
                "request-account-deletion",
                options: FunctionInvokeOptions(body: request),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "account.v1",
                expectedRequestID: requestID
            )
            let sessionAfter = try await authSessionStore.validatedSession()
            guard sessionAfter.user.id.uuidString.lowercased() == expectedSubjectID,
                  sessionAfter.expiresAt > Date.now.timeIntervalSince1970
            else { throw CatalogMappingError.invalidResponse }
            let snapshot = try accountDeletionSnapshot(
                response,
                expectedSubjectID: expectedSubjectID,
                usesProcessingStatus: false
            )
            return snapshot
        }
    }

    public func recordInstall(
        receipt: String,
        manifestDigest: String,
        releaseID: String,
        idempotencyKey: String
    ) async throws {
        guard (1...512).contains(receipt.utf8.count),
              manifestDigest.utf8.count == 64,
              manifestDigest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              })
        else {
            throw CatalogRequestError.invalidRequest
        }
        try validateUUID(releaseID)
        try validateIdempotencyKey(idempotencyKey)
        let requestID = UUID().uuidString.lowercased()
        let request = RecordInstallRequestDTO(
            apiVersion: "catalog.v1",
            requestID: requestID,
            idempotencyKey: idempotencyKey,
            installReceipt: receipt,
            manifestDigest: manifestDigest,
            releaseID: releaseID,
            result: "verified_installed"
        )
        try await safely {
            let envelope: CatalogFunctionEnvelope<RecordInstallAcknowledgementDTO> = try await invokeFunction(
                "record-install",
                options: FunctionInvokeOptions(body: request)
            )
            let payload = try mapper.payload(
                envelope,
                apiVersion: "catalog.v1",
                expectedRequestID: requestID
            )
            guard payload.releaseID == releaseID,
                  payload.result == "verified_installed",
                  payload.recorded
            else {
                throw CatalogMappingError.invalidResponse
            }
        }
    }

    private func setInteraction(
        function: String,
        targetName: String,
        targetID: String,
        desired: Bool,
        expectedRevision: UInt64,
        idempotencyKey: String
    ) async throws -> CatalogInteractionResult {
        try validateUUID(targetID)
        try validateRevision(expectedRevision)
        try validateIdempotencyKey(idempotencyKey)
        let parameters = InteractionParameters(
            targetID: targetID,
            desired: desired,
            expectedRevision: expectedRevision,
            idempotencyKey: idempotencyKey
        )
        return try await safely {
            let response: InteractionResultDTO = try await client
                .rpc(function, params: parameters)
                .execute()
                .value
            return CatalogInteractionResult(
                desired: response.desired,
                revision: response.revision,
                aggregateCount: response.aggregateCount
            )
        }
    }

    private func accountExportSnapshot(
        _ response: AccountExportResponseDTO,
        expectedSubjectID: String
    ) throws -> AccountExportSnapshot {
        guard UUID(uuidString: response.exportID)?.uuidString.lowercased() == response.exportID else {
            throw CatalogMappingError.invalidResponse
        }
        let completedAt = try response.completedAt.map(exactTimestamp)
        let downloadURL: URL?
        if let rawURL = response.downloadURL {
            guard let value = URL(string: rawURL),
                  remoteURLPolicy.allowsSignedAccountExport(
                    value,
                    subjectID: expectedSubjectID,
                    exportID: response.exportID
                  )
            else {
                throw CatalogMappingError.invalidResponse
            }
            downloadURL = value
        } else {
            downloadURL = nil
        }
        guard let status = AccountExportStatus(rawValue: response.status),
              let expiresAt = try? exactTimestamp(response.expiresAt)
        else { throw CatalogMappingError.invalidResponse }
        let downloadExpiresAt = try response.downloadExpiresAt.map(exactTimestamp)
        return try AccountExportSnapshot(
            id: response.exportID,
            subjectID: expectedSubjectID,
            status: status,
            expiresAt: expiresAt,
            completedAt: completedAt,
            byteCount: response.byteCount,
            sha256: response.digest,
            downloadURL: downloadURL,
            downloadExpiresAt: downloadExpiresAt
        )
    }

    private func accountDeletionSnapshot(
        _ response: AccountDeletionResponseDTO,
        expectedSubjectID: String,
        usesProcessingStatus: Bool
    ) throws -> AccountDeletionSnapshot {
        let rawStatus = usesProcessingStatus ? response.processingStatus : response.status
        guard let rawStatus,
              let status = AccountDeletionStatus(rawValue: rawStatus),
              let identityStatus = AccountIdentityDeletionStatus(rawValue: response.authIdentityStatus),
              let requestedAt = try? exactTimestamp(response.requestedAt),
              let completedAt = try response.completedAt.map(exactTimestamp)
        else { throw CatalogMappingError.invalidResponse }
        return try AccountDeletionSnapshot(
            id: response.deletionID,
            subjectID: expectedSubjectID,
            status: status,
            identityStatus: identityStatus,
            revision: response.revision,
            requestedAt: requestedAt,
            completedAt: completedAt,
            held: response.held ?? (status == .held)
        )
    }

    private func invokeCreatorMutation<Body: Encodable & Sendable>(
        function: String,
        body: Body,
        requestID: String
    ) async throws -> CreatorMutationResult {
        try await safely {
            let envelope: CatalogFunctionEnvelope<CreatorMutationResponseDTO> = try await invokeFunction(
                function,
                options: FunctionInvokeOptions(body: body),
                retryInterrupted: true
            )
            let response = try mapper.payload(
                envelope,
                apiVersion: "creator.v1",
                expectedRequestID: requestID
            )
            guard let submissionID = canonicalUUID(response.submissionID),
                  isSafeRevision(response.revision),
                  response.generation > 0,
                  isSafeRevision(response.generation),
                  let state = CreatorSubmissionState(rawValue: response.state),
                  (response.fieldErrors ?? []).count <= 20
            else { throw CatalogMappingError.invalidResponse }
            let fieldErrors = try (response.fieldErrors ?? []).map { value -> CreatorFieldError in
                guard isBoundedCreatorToken(value.field, maximum: 80),
                      isBoundedCreatorToken(value.code, maximum: 80)
                else { throw CatalogMappingError.invalidResponse }
                return CreatorFieldError(field: value.field, code: value.code)
            }
            return CreatorMutationResult(
                submissionID: submissionID,
                revision: response.revision,
                generation: response.generation,
                state: state,
                fieldErrors: fieldErrors
            )
        }
    }

    private func creatorSubmission(_ value: CreatorSubmissionDTO) throws -> CreatorSubmission {
        let wallpaperID = try canonicalOptionalUUID(value.wallpaperID)
        let wallpaperStatus = try value.wallpaperStatus.map { raw in
            guard wallpaperID != nil, let status = ModerationWallpaperStatus(rawValue: raw) else {
                throw CatalogMappingError.invalidResponse
            }
            return status
        }
        guard let id = canonicalUUID(value.submissionID),
              isSafeRevision(value.revision),
              value.generation > 0,
              isSafeRevision(value.generation),
              let state = CreatorSubmissionState(rawValue: value.state),
              value.moderationReasonCodes.count <= 20,
              value.moderationReasonCodes.allSatisfy({ isBoundedCreatorToken($0, maximum: 96) }),
              Set(value.moderationReasonCodes).count == value.moderationReasonCodes.count,
              value.creatorFacingNote.map({ isPlainCreatorText($0, maximum: 2_000) }) ?? true
        else { throw CatalogMappingError.invalidResponse }
        let draft = try value.draft.map(creatorDraft)
        let processing = try value.processing.map(creatorProcessingStatus)
        if let processing,
           processing.submissionID != id || processing.generation != value.generation {
            throw CatalogMappingError.invalidResponse
        }
        return CreatorSubmission(
            id: id,
            wallpaperID: wallpaperID,
            revision: value.revision,
            generation: value.generation,
            state: state,
            draft: draft,
            processing: processing,
            moderationReasonCodes: value.moderationReasonCodes,
            creatorFacingNote: value.creatorFacingNote,
            createdAt: try exactTimestamp(value.createdAt),
            updatedAt: try exactTimestamp(value.updatedAt),
            wallpaperStatus: wallpaperStatus
        )
    }

    private func creatorDraft(_ value: CreatorDraftDTO) throws -> CreatorDraft {
        let sourceURL = try validatedOptionalHTTPSURL(value.rights.sourceURL)
        guard let categoryID = canonicalUUID(value.primaryCategoryID),
              let licenseID = canonicalUUID(value.rights.licenseID),
              let basis = CreatorRightsBasis(rawValue: value.rights.basis),
              value.suggestedTagIDs.count <= 20,
              let tagIDs = try? value.suggestedTagIDs.map(requiredCanonicalUUID),
              Set(tagIDs).count == tagIDs.count,
              value.rights.proofObjectIDs.count <= 5,
              let proofIDs = try? value.rights.proofObjectIDs.map(requiredCanonicalUUID),
              Set(proofIDs).count == proofIDs.count
        else { throw CatalogMappingError.invalidResponse }
        let requirements = CreatorRightsRequirements(
            requiresSourceURL: value.rights.requirements.requiresSourceURL,
            requiresAttribution: value.rights.requirements.requiresAttribution,
            requiresProof: value.rights.requirements.requiresProof
        )
        let rights = try CreatorRightsDeclaration(
            basis: basis,
            rightsHolder: value.rights.rightsHolder,
            licenseID: licenseID,
            sourceURL: sourceURL,
            attributionText: value.rights.attributionText,
            proofObjectIDs: proofIDs,
            attestsRights: value.rights.attestsRights,
            requirements: requirements
        )
        return try CreatorDraft(
            title: value.title,
            description: value.description,
            primaryCategoryID: categoryID,
            suggestedTagIDs: tagIDs,
            contentWarning: value.contentWarning,
            rights: rights
        )
    }

    private func creatorProcessingStatus(_ value: CreatorProcessingStatusDTO) throws -> CreatorProcessingStatus {
        guard let submissionID = canonicalUUID(value.submissionID),
              isSafeRevision(value.revision),
              value.generation > 0,
              isSafeRevision(value.generation),
              let state = CreatorSubmissionState(rawValue: value.state),
              value.progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              value.safeErrorCode.map({ isBoundedCreatorToken($0, maximum: 96) }) ?? true,
              value.generatedVariants.count <= 20,
              value.suggestions.count <= 100,
              value.findings.count <= 100
        else { throw CatalogMappingError.invalidResponse }
        let facts = try value.mediaFacts.map { facts in
            try CreatorMediaFacts(
                container: facts.container,
                codec: facts.codec,
                width: facts.width,
                height: facts.height,
                frameRate: facts.frameRate,
                durationMilliseconds: facts.durationMilliseconds
            )
        }
        let variants = try value.generatedVariants.map { item -> CreatorGeneratedVariant in
            guard isBoundedCreatorToken(item.role, maximum: 64),
                  (1...16_384).contains(item.width),
                  (1...16_384).contains(item.height)
            else { throw CatalogMappingError.invalidResponse }
            return CreatorGeneratedVariant(role: item.role, width: item.width, height: item.height)
        }
        let suggestions = try value.suggestions.map { item -> CreatorModelSuggestion in
            guard let kind = CreatorSuggestionKind(rawValue: item.kind),
                  isPlainCreatorText(item.value, maximum: 2_000),
                  item.confidence.isFinite,
                  (0...1).contains(item.confidence),
                  isBoundedCreatorToken(item.modelID, maximum: 128),
                  isBoundedCreatorToken(item.modelRevision, maximum: 128)
            else { throw CatalogMappingError.invalidResponse }
            return CreatorModelSuggestion(
                kind: kind,
                value: item.value,
                confidence: item.confidence,
                modelID: item.modelID,
                modelRevision: item.modelRevision
            )
        }
        let findings = try value.findings.map { item -> CreatorFinding in
            guard isBoundedCreatorToken(item.code, maximum: 96),
                  isPlainCreatorText(item.message, maximum: 500),
                  let severity = CreatorFindingSeverity(rawValue: item.severity)
            else { throw CatalogMappingError.invalidResponse }
            return CreatorFinding(code: item.code, message: item.message, severity: severity)
        }
        return CreatorProcessingStatus(
            submissionID: submissionID,
            revision: value.revision,
            generation: value.generation,
            state: state,
            progress: value.progress,
            safeErrorCode: value.safeErrorCode,
            mediaFacts: facts,
            generatedVariants: variants,
            duplicateWarning: value.duplicateWarning,
            suggestions: suggestions,
            findings: findings
        )
    }

    private func moderationArtifact(_ artifact: CreatorCanonicalArtifactDTO) throws -> CreatorCanonicalArtifact {
        guard let role = CreatorArtifactRole(rawValue: artifact.role),
              [.poster, .preview, .videoDefault].contains(role),
              let url = URL(string: artifact.url),
              remoteURLPolicy.allowsSignedModeratorArtifact(url)
        else { throw CatalogMappingError.invalidResponse }
        return try CreatorCanonicalArtifact(
            role: role, url: url, sha256: artifact.sha256, byteCount: artifact.byteCount,
            mediaType: artifact.mediaType, width: artifact.width, height: artifact.height,
            durationMilliseconds: artifact.durationMilliseconds, remoteURLPolicy: remoteURLPolicy
        )
    }

    private func moderationQueueItem(_ value: ModerationQueueItemDTO) throws -> ModerationQueueItem {
        let sourceURL = try validatedOptionalHTTPSURL(value.sourceURL)
        let state = value.state.flatMap(CreatorSubmissionState.init(rawValue:)) ?? .underReview
        let wallpaperID = value.wallpaperID.flatMap(canonicalUUID)
        guard value.state.map({ ["submitted", "under_review", "approved"].contains($0) }) ?? true,
              value.wallpaperID == nil || wallpaperID != nil,
              value.wallpaperRevision.map(isSafeRevision) ?? true,
              state != .approved || (wallpaperID != nil && value.wallpaperRevision != nil)
        else { throw CatalogMappingError.invalidResponse }
        guard let submissionID = canonicalUUID(value.submissionID),
              let creatorID = canonicalUUID(value.creator.id),
              isSafeRevision(value.revision),
              value.generation > 0,
              isSafeRevision(value.generation),
              isBoundedCreatorToken(value.creator.handle, maximum: 40),
              isPlainCreatorText(value.creator.displayName, maximum: 120),
              isPlainCreatorText(value.proposedTitle, maximum: 120),
              isPlainCreatorText(value.proposedDescription, maximum: 2_000),
              isPlainCreatorText(value.primaryCategoryName, maximum: 120),
              value.tagNames.count <= 20,
              value.tagNames.allSatisfy({ isPlainCreatorText($0, maximum: 80) }),
              ["everyone", "teen", "mature"].contains(value.contentRating),
              value.attributionText.map({ isPlainCreatorText($0, maximum: 1_000) }) ?? true,
              isPlainCreatorText(value.rightsSummary, maximum: 300),
              let proofStatus = CreatorProofStatus(rawValue: value.proofStatus),
              value.canonicalArtifacts.count <= 10,
              value.findings.count <= 100,
              value.modelSuggestions.count <= 100
        else { throw CatalogMappingError.invalidResponse }
        let artifacts = try value.canonicalArtifacts.map(moderationArtifact)
        let processing = CreatorProcessingStatusDTO(
            submissionID: value.submissionID,
            revision: value.revision,
            generation: value.generation,
            state: "under_review",
            progress: nil,
            safeErrorCode: nil,
            mediaFacts: value.mediaFacts,
            generatedVariants: [],
            duplicateWarning: false,
            suggestions: value.modelSuggestions,
            findings: value.findings
        )
        let mapped = try creatorProcessingStatus(processing)
        return ModerationQueueItem(
            submissionID: submissionID,
            revision: value.revision,
            generation: value.generation,
            creator: CreatorPublicIdentity(
                id: creatorID,
                handle: value.creator.handle,
                displayName: value.creator.displayName
            ),
            proposedTitle: value.proposedTitle,
            proposedDescription: value.proposedDescription,
            primaryCategoryName: value.primaryCategoryName,
            tagNames: value.tagNames,
            contentRating: value.contentRating,
            attributionText: value.attributionText,
            sourceURL: sourceURL,
            rightsSummary: value.rightsSummary,
            proofStatus: proofStatus,
            canonicalArtifacts: artifacts,
            mediaFacts: mapped.mediaFacts,
            findings: mapped.findings,
            modelSuggestions: mapped.suggestions,
            submittedAt: try exactTimestamp(value.submittedAt),
            state: state,
            wallpaperID: wallpaperID,
            wallpaperRevision: value.wallpaperRevision
        )
    }

    private func moderationState(for decision: ModerationDecision) -> CreatorSubmissionState {
        switch decision {
        case .approved: .approved
        case .changesRequested: .changesRequested
        case .rejected: .rejected
        }
    }

    private func invokeFunction<Payload: Decodable & Sendable>(
        _ name: String,
        options: FunctionInvokeOptions,
        retryInterrupted: Bool = false
    ) async throws -> CatalogFunctionEnvelope<Payload> {
        do {
            if retryInterrupted {
                // The caller opts in only for reads or server-deduplicated
                // commands. Reuse exactly the same body and idempotency key.
                return try await retryConnectionLoss {
                    try await client.functions.invoke(name, options: options)
                }
            }
            return try await client.functions.invoke(name, options: options)
        } catch let FunctionsError.httpError(status, body) {
            // The SDK throws before decoding non-2xx responses. Keep the same
            // envelope validation (including request ID and API version) at the
            // call site, without exposing arbitrary SDK errors or response text.
            guard (400...599).contains(status) else { throw CatalogMappingError.invalidResponse }
            if body.count <= 16_384,
               let envelope = try? JSONDecoder().decode(
                    CatalogFunctionEnvelope<Payload>.self, from: body
               ) {
                guard envelope.data == nil, envelope.error != nil else { throw CatalogMappingError.invalidResponse }
                return envelope
            }
            if body.count <= 16_384,
               let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
               fields["api_version"] != nil || fields["request_id"] != nil {
                throw CatalogMappingError.invalidResponse
            }
            // A gateway or proxy may return no WALI envelope at all. Preserve
            // retryability so temporary outages can use verified cached state.
            if status == 408 || status == 429 || (500...599).contains(status) {
                throw CatalogRemoteError(
                    code: status == 429 ? "rate_limited" : "temporarily_unavailable",
                    safeMessage: nil, retryable: true
                )
            }
            throw CatalogMappingError.invalidResponse
        }
    }

    /// These RPCs read state but travel as POST requests, so URLSession cannot
    /// infer that retrying a dropped connection is safe. Retry once only for
    /// explicitly read-only operations; mutations keep their own recovery rules.
    private func requestSession() throws -> Session {
        guard let snapshot = CatalogRequestAuthentication.snapshot,
              snapshot.ownerID == ObjectIdentifier(authSessionStore),
              snapshot.validAccessToken != nil, let session = snapshot.session else {
            throw CatalogRemoteError(code: "authentication_required", safeMessage: nil, retryable: false)
        }
        return session
    }

    private func safelyReading<Value: Sendable>(
        context: StaticString = #function,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        try await safely(context: context) {
            try await retryConnectionLoss(context: context, operation)
        }
    }

    private func retryConnectionLoss<Value: Sendable>(
        context: StaticString = #function,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as URLError where error.code == .networkConnectionLost {
            try Task.checkCancellation()
            Self.logger.notice("Retrying interrupted replay-safe request; operation=\(String(describing: context), privacy: .public)")
            try await Task.sleep(for: .milliseconds(250))
            return try await operation()
        }
    }

    private func safely<Value: Sendable>(
        context: StaticString = #function,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        do {
            let result = try await CatalogRequestAuthentication.withSnapshot(for: authSessionStore, operation)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            Self.logger.error("Catalog transport failed; operation=\(String(describing: context), privacy: .public) code=\(error.code.rawValue, privacy: .public)")
            throw CatalogRemoteError(
                code: error.code == .notConnectedToInternet ? "network_unavailable" : (error.code == .timedOut ? "request_timed_out" : "temporarily_unavailable"),
                safeMessage: nil, retryable: true
            )
        } catch let error as PostgrestError {
            let providerCode = error.code ?? "unknown"
            let safeCode = providerCode.utf8.count <= 16 && providerCode.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) ? providerCode : "unknown"
            Self.logger.error("Catalog RPC failed; operation=\(String(describing: context), privacy: .public) code=\(safeCode, privacy: .public)")
            if error.message.hasPrefix("WALI_") {
                let token = String(error.message.dropFirst(5))
                if (1...64).contains(token.utf8.count), token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || $0 == 95 }) {
                    throw CatalogRemoteError(code: token.lowercased(), safeMessage: nil, retryable: false)
                }
            }
            if providerCode == "PGRST301" || providerCode == "PGRST303" {
                throw CatalogRemoteError(code: "session_expired", safeMessage: nil, retryable: false)
            }
            throw CatalogRemoteError(code: "temporarily_unavailable", safeMessage: nil, retryable: true)
        } catch is DecodingError {
            Self.logger.error("Catalog response decoding failed; operation=\(String(describing: context), privacy: .public)")
            throw CatalogMappingError.invalidResponse
        } catch let error as CatalogRemoteError {
            throw error
        } catch let error as CatalogMappingError {
            Self.logger.error("Catalog response validation failed; operation=\(String(describing: context), privacy: .public)")
            throw error
        } catch let error as CatalogRequestError {
            throw error
        } catch {
            // Never surface SDK errors because request headers may contain session material.
            throw CatalogRemoteError(
                code: "temporarily_unavailable",
                safeMessage: nil,
                retryable: true
            )
        }
    }
}

private struct ModerationReadRequestDTO: Encodable {
    let requestID: String
    let operation: String
    let status: String?
    let sort: String?
    let cursor: String?
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case operation, status, sort, cursor, limit
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("moderation.v1", forKey: .apiVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(requestID, forKey: .idempotencyKey)
        try container.encode(operation, forKey: .operation)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(sort, forKey: .sort)
        if let cursor { try container.encode(cursor, forKey: .cursor) }
        else { try container.encodeNil(forKey: .cursor) }
        try container.encode(limit, forKey: .limit)
    }
}

private struct InteractionParameters: Encodable {
    let targetID: String
    let desired: Bool
    let expectedRevision: UInt64
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case desired
        case targetID = "wallpaper_id"
        case expectedRevision = "expected_revision"
        case idempotencyKey = "idempotency_key"
    }
}

private struct InteractionResultDTO: Decodable {
    let desired: Bool
    let revision: UInt64
    let aggregateCount: UInt64

    enum CodingKeys: String, CodingKey {
        case desired, revision
        case aggregateCount = "aggregate_count"
    }
}

private struct InstallRequestDTO: Encodable {
    let apiVersion: String
    let requestID: String
    let idempotencyKey: String
    let wallpaperID: String
    let releaseID: String
    let expectedWallpaperRevision: UInt64

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case wallpaperID = "wallpaper_id"
        case releaseID = "release_id"
        case expectedWallpaperRevision = "expected_wallpaper_revision"
    }
}

private struct InstallGrantDTO: Decodable, Sendable {
    let manifestBody: String
    let metadataBody: String
    let signature: String
    let keyID: String
    let installReceipt: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case signature
        case manifestBody = "manifest_body"
        case metadataBody = "metadata_body"
        case keyID = "key_id"
        case installReceipt = "install_receipt"
        case expiresAt = "expires_at"
    }
}

private struct CatalogSecurityStateRequestDTO: Encodable {
    let apiVersion: String
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case requestID = "request_id"
    }
}

private struct CatalogSignedDocumentDTO: Decodable, Sendable {
    let revision: UInt64
    let body: String
    let signature: String
    let keyID: String

    enum CodingKeys: String, CodingKey {
        case revision, body, signature
        case keyID = "key_id"
    }

    func model(maximumBodyBytes: Int) throws -> CatalogSignedDocument {
        guard revision > 0,
              revision <= 9_007_199_254_740_991,
              signature.utf8.count <= 86,
              keyID.utf8.count <= 64,
              body.utf8.count <= ((maximumBodyBytes + 2) / 3 * 4),
              let data = Data(unpaddedBase64URL: body),
              !data.isEmpty,
              data.count <= maximumBodyBytes
        else {
            throw CatalogMappingError.invalidResponse
        }
        return CatalogSignedDocument(
            revision: revision,
            canonicalBody: data,
            signatureBase64URL: signature,
            keyID: keyID
        )
    }
}

private struct CatalogSecurityStateDTO: Decodable, Sendable {
    let trustTransition: CatalogSignedDocumentDTO?
    let revocations: CatalogSignedDocumentDTO

    enum CodingKeys: String, CodingKey {
        case revocations
        case trustTransition = "trust_transition"
    }

    func model() throws -> CatalogSecurityState {
        try CatalogSecurityState(
            trustTransition: trustTransition?.model(maximumBodyBytes: 32_768),
            revocations: revocations.model(maximumBodyBytes: 1_048_576)
        )
    }
}

private struct RecordInstallRequestDTO: Encodable {
    let apiVersion: String
    let requestID: String
    let idempotencyKey: String
    let installReceipt: String
    let manifestDigest: String
    let releaseID: String
    let result: String

    enum CodingKeys: String, CodingKey {
        case result
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case installReceipt = "install_receipt"
        case manifestDigest = "manifest_digest"
        case releaseID = "release_id"
    }
}

private struct RecordInstallAcknowledgementDTO: Decodable, Sendable {
    let releaseID: String
    let result: String
    let recorded: Bool

    enum CodingKeys: String, CodingKey {
        case result, recorded
        case releaseID = "release_id"
    }
}

private struct ReportWallpaperRequestDTO: Encodable, Sendable {
    let apiVersion: String
    let requestID: String
    let idempotencyKey: String
    let wallpaperID: String
    let releaseID: String?
    let kind: String
    let detail: String

    enum CodingKeys: String, CodingKey {
        case kind, detail
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case wallpaperID = "wallpaper_id"
        case releaseID = "release_id"
    }
}

private struct ReportWallpaperResponseDTO: Decodable, Sendable {
    let reportID: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case status
        case reportID = "report_id"
        case createdAt = "created_at"
    }
}

private struct EmptyParameters: Encodable, Sendable {}

private struct CreatorAuthorizationDTO: Decodable, Sendable {
    let accountIsActive: Bool
    let sessionExpiresAt: String
    let creatorGrantRevision: UInt64?
    let acceptedCreatorTermsVersion: String?
    let currentCreatorTermsVersion: String?
    let moderatorGrantRevision: UInt64?
    let assuranceLevel: String

    enum CodingKeys: String, CodingKey {
        case accountIsActive = "account_is_active"
        case sessionExpiresAt = "session_expires_at"
        case creatorGrantRevision = "creator_grant_revision"
        case acceptedCreatorTermsVersion = "accepted_creator_terms_version"
        case currentCreatorTermsVersion = "current_creator_terms_version"
        case moderatorGrantRevision = "moderator_grant_revision"
        case assuranceLevel = "assurance_level"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountIsActive = try values.decode(Bool.self, forKey: .accountIsActive)
        sessionExpiresAt = try values.decode(String.self, forKey: .sessionExpiresAt)
        creatorGrantRevision = try values.decodeIfPresent(UInt64.self, forKey: .creatorGrantRevision)
        acceptedCreatorTermsVersion = try values.decodeIfPresent(String.self, forKey: .acceptedCreatorTermsVersion)
        // The RPC emits explicit null until creator terms are configured; a missing field
        // remains a malformed response rather than a second unavailable representation.
        currentCreatorTermsVersion = try values.decode(String?.self, forKey: .currentCreatorTermsVersion)
        moderatorGrantRevision = try values.decodeIfPresent(UInt64.self, forKey: .moderatorGrantRevision)
        assuranceLevel = try values.decode(String.self, forKey: .assuranceLevel)
    }
}

private struct CreatorMetadataDTO: Decodable, Sendable {
    let categories: [CreatorTaxonomyOptionDTO]
    let tags: [CreatorTaxonomyOptionDTO]
    let licenses: [CreatorLicenseOptionDTO]
    let currentCreatorTermsVersion: String

    enum CodingKeys: String, CodingKey {
        case categories, tags, licenses
        case currentCreatorTermsVersion = "current_creator_terms_version"
    }
}

private struct ModerationMetadataDTO: Decodable, Sendable {
    let checklistRevision: UInt64
    let creatorNoteRequired: Bool
    let reasonCodes: [ModerationReasonOptionDTO]

    enum CodingKeys: String, CodingKey {
        case checklistRevision = "checklist_revision"
        case creatorNoteRequired = "creator_note_required"
        case reasonCodes = "reason_codes"
    }
}

private struct ModerationReasonOptionDTO: Decodable, Sendable {
    let code: String
    let label: String
    let decisions: [String]
}

private struct CreatorTaxonomyOptionDTO: Decodable, Sendable {
    let id: String
    let name: String
    let slug: String
}

private struct CreatorLicenseOptionDTO: Decodable, Sendable {
    let id: String
    let name: String
    let code: String
    let requirements: CreatorRightsRequirementsDTO
}

private struct CreatorRightsRequirementsDTO: Codable, Sendable {
    let requiresSourceURL: Bool
    let requiresAttribution: Bool
    let requiresProof: Bool

    enum CodingKeys: String, CodingKey {
        case requiresSourceURL = "requires_source_url"
        case requiresAttribution = "requires_attribution"
        case requiresProof = "requires_proof"
    }
}

private struct CreatorEnrollmentResponseDTO: Decodable, Sendable {
    let accountIsActive: Bool
    let creatorEnrolled: Bool
    let creatorGrantRevision: UInt64
    let acceptedCreatorTermsVersion: String
    let currentCreatorTermsVersion: String

    enum CodingKeys: String, CodingKey {
        case accountIsActive = "account_is_active"
        case creatorEnrolled = "creator_enrolled"
        case creatorGrantRevision = "creator_grant_revision"
        case acceptedCreatorTermsVersion = "accepted_creator_terms_version"
        case currentCreatorTermsVersion = "current_creator_terms_version"
    }
}

private struct CreatorSubmissionPageDTO: Decodable, Sendable {
    let items: [CreatorSubmissionDTO]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

private struct CreatorSubmissionDTO: Decodable, Sendable {
    let submissionID: String
    let wallpaperID: String?
    let wallpaperStatus: String?
    let revision: UInt64
    let generation: UInt64
    let state: String
    let draft: CreatorDraftDTO?
    let processing: CreatorProcessingStatusDTO?
    let moderationReasonCodes: [String]
    let creatorFacingNote: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case revision, generation, state, draft, processing
        case submissionID = "submission_id"
        case wallpaperID = "wallpaper_id"
        case wallpaperStatus = "wallpaper_status"
        case moderationReasonCodes = "moderation_reason_codes"
        case creatorFacingNote = "creator_facing_note"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct CreatorDraftDTO: Decodable, Sendable {
    let title: String
    let description: String
    let primaryCategoryID: String
    let suggestedTagIDs: [String]
    let contentWarning: String?
    let rights: CreatorRightsDeclarationDTO

    enum CodingKeys: String, CodingKey {
        case title, description, rights
        case primaryCategoryID = "primary_category_id"
        case suggestedTagIDs = "suggested_tag_ids"
        case contentWarning = "content_warning"
    }
}

private struct CreatorRightsDeclarationDTO: Decodable, Sendable {
    let basis: String
    let rightsHolder: String
    let licenseID: String
    let sourceURL: String?
    let attributionText: String?
    let proofObjectIDs: [String]
    let attestsRights: Bool
    let requirements: CreatorRightsRequirementsDTO

    enum CodingKeys: String, CodingKey {
        case basis, requirements
        case rightsHolder = "rights_holder"
        case licenseID = "license_id"
        case sourceURL = "source_url"
        case attributionText = "attribution_text"
        case proofObjectIDs = "proof_object_ids"
        case attestsRights = "attests_rights"
    }
}

private struct CreatorProcessingStatusDTO: Decodable, Sendable {
    let submissionID: String
    let revision: UInt64
    let generation: UInt64
    let state: String
    let progress: Double?
    let safeErrorCode: String?
    let mediaFacts: CreatorMediaFactsDTO?
    let generatedVariants: [CreatorGeneratedVariantDTO]
    let duplicateWarning: Bool
    let suggestions: [CreatorModelSuggestionDTO]
    let findings: [CreatorFindingDTO]

    enum CodingKeys: String, CodingKey {
        case revision, generation, state, progress, suggestions, findings
        case submissionID = "submission_id"
        case safeErrorCode = "safe_error_code"
        case mediaFacts = "media_facts"
        case generatedVariants = "generated_variants"
        case duplicateWarning = "duplicate_warning"
    }
}

private struct CreatorMediaFactsDTO: Decodable, Sendable {
    let container: String
    let codec: String
    let width: Int
    let height: Int
    let frameRate: Double
    let durationMilliseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case container, codec, width, height
        case frameRate = "frame_rate"
        case durationMilliseconds = "duration_ms"
    }
}

private struct CreatorGeneratedVariantDTO: Decodable, Sendable {
    let role: String
    let width: Int
    let height: Int
}

private struct CreatorModelSuggestionDTO: Decodable, Sendable {
    let kind: String
    let value: String
    let confidence: Double
    let modelID: String
    let modelRevision: String

    enum CodingKeys: String, CodingKey {
        case kind, value, confidence
        case modelID = "model_id"
        case modelRevision = "model_revision"
    }
}

private struct CreatorFindingDTO: Decodable, Sendable {
    let code: String
    let message: String
    let severity: String
}

private struct CreatorMutationResponseDTO: Decodable, Sendable {
    let submissionID: String
    let revision: UInt64
    let generation: UInt64
    let state: String
    let fieldErrors: [CreatorFieldErrorDTO]?

    enum CodingKeys: String, CodingKey {
        case revision, generation, state
        case submissionID = "submission_id"
        case fieldErrors = "field_errors"
    }
}

private struct CreatorFieldErrorDTO: Decodable, Sendable {
    let field: String
    let code: String
}

private struct CreatorUploadSessionDTO: Decodable, Sendable {
    let uploadSessionID: String
    let revision: UInt64
    let expiresAt: String
    let uploadEndpoint: String
    let requiredHeaders: [String: String]
    let scopedUploadToken: String

    enum CodingKeys: String, CodingKey {
        case revision
        case uploadSessionID = "upload_session_id"
        case expiresAt = "expires_at"
        case uploadEndpoint = "upload_endpoint"
        case requiredHeaders = "required_headers"
        case scopedUploadToken = "scoped_upload_token"
    }
}

private struct CreatorCreateUploadRequestDTO: Encodable, Sendable {
    let requestID: String
    let request: CreatorUploadGrantRequest

    enum CodingKeys: String, CodingKey {
        case target
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case declaredByteCount = "declared_byte_count"
        case containerHint = "container_hint"
        case originalFilename = "original_filename"
    }

    enum TargetKeys: String, CodingKey {
        case kind
        case wallpaperID = "wallpaper_id"
        case expectedRevision = "expected_revision"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("creator.v1", forKey: .apiVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(request.idempotencyKey, forKey: .idempotencyKey)
        try container.encode(request.declaredByteCount, forKey: .declaredByteCount)
        try container.encode(request.containerHint, forKey: .containerHint)
        try container.encode(request.originalFilename, forKey: .originalFilename)
        var target = container.nestedContainer(keyedBy: TargetKeys.self, forKey: .target)
        switch request.target {
        case .new:
            try target.encode("new", forKey: .kind)
        case let .wallpaperUpdate(wallpaperID, expectedRevision):
            try target.encode("wallpaper_update", forKey: .kind)
            try target.encode(wallpaperID.uuidString.lowercased(), forKey: .wallpaperID)
            try target.encode(expectedRevision, forKey: .expectedRevision)
        }
    }
}

private struct CreatorCompleteUploadRequestDTO: Encodable, Sendable {
    let apiVersion = "creator.v1"
    let requestID: String
    let idempotencyKey: String
    let uploadSessionID: String
    let expectedSessionRevision: UInt64

    init(requestID: String, request: CreatorCompleteUploadRequest) {
        self.requestID = requestID
        idempotencyKey = request.idempotencyKey
        uploadSessionID = request.uploadSessionID.uuidString.lowercased()
        expectedSessionRevision = request.expectedSessionRevision
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case uploadSessionID = "upload_session_id"
        case expectedSessionRevision = "expected_session_revision"
    }
}

private struct CreatorSubmitRequestDTO: Encodable, Sendable {
    let apiVersion = "creator.v1"
    let requestID: String
    let idempotencyKey: String
    let submissionID: String
    let expectedRevision: UInt64
    let expectedGeneration: UInt64
    let creatorTermsVersion: String

    init(requestID: String, request: CreatorSubmitRequest) {
        self.requestID = requestID
        idempotencyKey = request.idempotencyKey
        submissionID = request.submissionID.uuidString.lowercased()
        expectedRevision = request.expectedRevision
        expectedGeneration = request.expectedGeneration
        creatorTermsVersion = request.creatorTermsVersion
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case submissionID = "submission_id"
        case expectedRevision = "expected_revision"
        case expectedGeneration = "expected_generation"
        case creatorTermsVersion = "creator_terms_version"
    }
}

private struct CreatorCommandRequestDTO: Encodable, Sendable {
    let apiVersion: String
    let requestID: String
    let idempotencyKey: String
    let action: String
    let payload: CreatorCommandPayloadDTO

    enum CodingKeys: String, CodingKey {
        case action, payload
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
    }
}

private enum CreatorCommandPayloadDTO: Encodable, Sendable {
    case acceptTerms(expectedSubjectID: String, version: String)
    case saveDraft(CreatorSaveDraftRequest)
    case withdraw(CreatorWithdrawRequest)

    enum CodingKeys: String, CodingKey {
        case title, description
        case expectedSubjectID = "expected_subject_id"
        case creatorTermsVersion = "creator_terms_version"
        case submissionID = "submission_id"
        case expectedRevision = "expected_revision"
        case primaryCategoryID = "primary_category_id"
        case suggestedTagIDs = "suggested_tag_ids"
        case contentWarning = "content_warning"
        case rightsBasis = "rights_basis"
        case rightsHolder = "rights_holder"
        case licenseID = "license_id"
        case sourceURL = "source_url"
        case attributionText = "attribution_text"
        case proofObjectIDs = "proof_object_ids"
        case attestsRights = "attests_rights"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .acceptTerms(expectedSubjectID, version):
            try container.encode(expectedSubjectID, forKey: .expectedSubjectID)
            try container.encode(version, forKey: .creatorTermsVersion)
        case let .withdraw(request):
            try container.encode(request.submissionID.uuidString.lowercased(), forKey: .submissionID)
            try container.encode(request.expectedRevision, forKey: .expectedRevision)
        case let .saveDraft(request):
            let draft = request.draft
            let rights = draft.rights
            try container.encode(request.submissionID.uuidString.lowercased(), forKey: .submissionID)
            try container.encode(request.expectedRevision, forKey: .expectedRevision)
            try container.encode(draft.title, forKey: .title)
            try container.encode(draft.description, forKey: .description)
            try container.encode(draft.primaryCategoryID.uuidString.lowercased(), forKey: .primaryCategoryID)
            try container.encode(draft.suggestedTagIDs.map { $0.uuidString.lowercased() }, forKey: .suggestedTagIDs)
            if let value = draft.contentWarning { try container.encode(value, forKey: .contentWarning) }
            else { try container.encodeNil(forKey: .contentWarning) }
            try container.encode(rights.basis.rawValue, forKey: .rightsBasis)
            try container.encode(rights.rightsHolder, forKey: .rightsHolder)
            try container.encode(rights.licenseID.uuidString.lowercased(), forKey: .licenseID)
            if let value = rights.sourceURL { try container.encode(value.absoluteString, forKey: .sourceURL) }
            else { try container.encodeNil(forKey: .sourceURL) }
            if let value = rights.attributionText { try container.encode(value, forKey: .attributionText) }
            else { try container.encodeNil(forKey: .attributionText) }
            try container.encode(rights.proofObjectIDs.map { $0.uuidString.lowercased() }, forKey: .proofObjectIDs)
            try container.encode(rights.attestsRights, forKey: .attestsRights)
            try container.encode(request.creatorTermsVersion, forKey: .creatorTermsVersion)
        }
    }
}

private struct ModerationQueuePageDTO: Decodable, Sendable {
    let items: [ModerationQueueItemDTO]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

private struct ModerationQueueItemDTO: Decodable, Sendable {
    let submissionID: String
    let revision: UInt64
    let generation: UInt64
    let state: String?
    let wallpaperID: String?
    let wallpaperRevision: UInt64?
    let creator: CreatorPublicIdentityDTO
    let proposedTitle: String
    let proposedDescription: String
    let primaryCategoryName: String
    let tagNames: [String]
    let contentRating: String
    let attributionText: String?
    let sourceURL: String?
    let rightsSummary: String
    let proofStatus: String
    let canonicalArtifacts: [CreatorCanonicalArtifactDTO]
    let mediaFacts: CreatorMediaFactsDTO?
    let findings: [CreatorFindingDTO]
    let modelSuggestions: [CreatorModelSuggestionDTO]
    let submittedAt: String

    enum CodingKeys: String, CodingKey {
        case revision, generation, creator, findings, state
        case wallpaperID = "wallpaper_id"
        case wallpaperRevision = "wallpaper_revision"
        case submissionID = "submission_id"
        case proposedTitle = "proposed_title"
        case proposedDescription = "proposed_description"
        case primaryCategoryName = "primary_category_name"
        case tagNames = "tag_names"
        case contentRating = "content_rating"
        case attributionText = "attribution_text"
        case sourceURL = "source_url"
        case rightsSummary = "rights_summary"
        case proofStatus = "proof_status"
        case canonicalArtifacts = "canonical_artifacts"
        case mediaFacts = "media_facts"
        case modelSuggestions = "model_suggestions"
        case submittedAt = "submitted_at"
    }
}

private struct CreatorPublicIdentityDTO: Decodable, Sendable {
    let id: String
    let handle: String
    let displayName: String
    enum CodingKeys: String, CodingKey {
        case id, handle
        case displayName = "display_name"
    }
}

private struct CreatorCanonicalArtifactDTO: Decodable, Sendable {
    let role: String
    let url: String
    let sha256: String
    let byteCount: UInt64
    let mediaType: String
    let width: Int
    let height: Int
    let durationMilliseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case role, url, sha256, width, height
        case byteCount = "byte_count"
        case mediaType = "media_type"
        case durationMilliseconds = "duration_ms"
    }
}

private struct ModerationReportPageDTO: Decodable, Sendable {
    let items: [ModerationReportDTO]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

private struct ModerationReportDTO: Decodable, Sendable {
    let reportID: String
    let revision: UInt64
    let reasonCode: String
    let safeSummary: String
    let createdAt: String
    let status: String
    let wallpaperID: String
    let wallpaperRevision: UInt64
    let wallpaperTitle: String
    let wallpaperStatus: String
    let releaseID: String?
    let edition: UInt64?
    let canonicalArtifacts: [CreatorCanonicalArtifactDTO]
    enum CodingKeys: String, CodingKey {
        case revision, status, edition
        case reportID = "report_id"
        case reasonCode = "reason_code"
        case safeSummary = "safe_summary"
        case createdAt = "created_at"
        case wallpaperID = "wallpaper_id"
        case wallpaperRevision = "wallpaper_revision"
        case wallpaperTitle = "wallpaper_title"
        case wallpaperStatus = "wallpaper_status"
        case releaseID = "release_id"
        case canonicalArtifacts = "canonical_artifacts"
    }
}

private struct ResolveReportRequestDTO: Encodable, Sendable {
    let apiVersion = "moderation.v1"
    let requestID: String
    let idempotencyKey: String
    let reportID: String
    let expectedRevision: UInt64
    let expectedWallpaperRevision: UInt64
    let action: String
    let reasonCode: String
    let privateNote: String

    init(requestID: String, request: ModerationReportResolutionRequest) {
        self.requestID = requestID
        idempotencyKey = request.idempotencyKey
        reportID = request.reportID.uuidString.lowercased()
        expectedRevision = request.expectedRevision
        expectedWallpaperRevision = request.expectedWallpaperRevision
        action = request.action.rawValue
        reasonCode = request.reasonCode
        privateNote = request.privateNote
    }

    enum CodingKeys: String, CodingKey {
        case action
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case reportID = "report_id"
        case expectedRevision = "expected_revision"
        case expectedWallpaperRevision = "expected_wallpaper_revision"
        case reasonCode = "reason_code"
        case privateNote = "private_note"
    }
}

private struct ResolveReportResponseDTO: Decodable, Sendable {
    let reportID: String
    let revision: UInt64
    let status: String
    let action: String
    let wallpaperID: String
    let wallpaperRevision: UInt64
    let wallpaperStatus: String
    enum CodingKeys: String, CodingKey {
        case revision, status, action
        case reportID = "report_id"
        case wallpaperID = "wallpaper_id"
        case wallpaperRevision = "wallpaper_revision"
        case wallpaperStatus = "wallpaper_status"
    }
}

private struct ModerateSubmissionRequestDTO: Encodable, Sendable {
    let apiVersion = "moderation.v1"
    let requestID: String
    let idempotencyKey: String
    let submissionID: String
    let expectedRevision: UInt64
    let expectedGeneration: UInt64
    let decision: String
    let checklistRevision: UInt64
    let reasonCodes: [String]
    let creatorNote: String
    let privateNote: String

    init(requestID: String, request: ModerationDecisionRequest) {
        self.requestID = requestID
        idempotencyKey = request.idempotencyKey
        submissionID = request.submissionID.uuidString.lowercased()
        expectedRevision = request.expectedRevision
        expectedGeneration = request.expectedGeneration
        decision = request.decision.rawValue
        checklistRevision = request.checklistRevision
        reasonCodes = request.reasonCodes
        creatorNote = request.creatorNote
        privateNote = request.privateNote
    }

    enum CodingKeys: String, CodingKey {
        case decision
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case submissionID = "submission_id"
        case expectedRevision = "expected_revision"
        case expectedGeneration = "expected_generation"
        case checklistRevision = "checklist_revision"
        case reasonCodes = "reason_codes"
        case creatorNote = "creator_note"
        case privateNote = "private_note"
    }
}

private struct ModerationDecisionResponseDTO: Decodable, Sendable {
    let submissionID: String
    let revision: UInt64
    let generation: UInt64
    let state: String
    let decision: String
    enum CodingKeys: String, CodingKey {
        case revision, generation, state, decision
        case submissionID = "submission_id"
    }
}

private struct PublishReleaseRequestDTO: Encodable, Sendable {
    let apiVersion = "moderation.v1"
    let requestID: String
    let idempotencyKey: String
    let submissionID: String
    let expectedRevision: UInt64
    let expectedGeneration: UInt64
    let expectedWallpaperRevision: UInt64
    let manifestSchema = ["epoch": 1, "revision": 0]

    init(requestID: String, request: PublishReleaseRequest) {
        self.requestID = requestID
        idempotencyKey = request.idempotencyKey
        submissionID = request.submissionID.uuidString.lowercased()
        expectedRevision = request.expectedRevision
        expectedGeneration = request.expectedGeneration
        expectedWallpaperRevision = request.expectedWallpaperRevision
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version", requestID = "request_id", idempotencyKey = "idempotency_key"
        case submissionID = "submission_id", expectedRevision = "expected_revision"
        case expectedGeneration = "expected_generation", expectedWallpaperRevision = "expected_wallpaper_revision"
        case manifestSchema = "manifest_schema"
    }
}

private struct PublishedReleaseDTO: Decodable, Sendable {
    let wallpaperID: String
    let releaseID: String
    let edition: UInt64
    let wallpaperRevision: UInt64
    let manifestDigest: String
    let keyID: String
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case edition
        case wallpaperID = "wallpaper_id", releaseID = "release_id", wallpaperRevision = "wallpaper_revision"
        case manifestDigest = "manifest_digest", keyID = "key_id", publishedAt = "published_at"
    }
}

private struct AccountProfileDTO: Decodable, Sendable {
    let id: String
    let handle: String
    let displayName: String
    let status: String
    let revision: UInt64

    enum CodingKeys: String, CodingKey {
        case id, handle, status, revision
        case displayName = "display_name"
    }
}

private struct AccountExportRequestDTO: Encodable, Sendable {
    let apiVersion: String
    let requestID: String
    let idempotencyKey: String
    let operation: String?
    let exportID: String?

    enum CodingKeys: String, CodingKey {
        case operation
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case exportID = "export_id"
    }
}

private struct AccountExportResponseDTO: Decodable, Sendable {
    let exportID: String
    let status: String
    let expiresAt: String
    let completedAt: String?
    let byteCount: UInt64?
    let digest: String?
    let downloadURL: String?
    let downloadExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case status, digest
        case exportID = "export_id"
        case expiresAt = "expires_at"
        case completedAt = "completed_at"
        case byteCount = "byte_count"
        case downloadURL = "download_url"
        case downloadExpiresAt = "download_expires_at"
    }
}

private struct AccountDeletionRequestDTO: Encodable, Sendable {
    let apiVersion: String
    let requestID: String
    let idempotencyKey: String
    let operation: String?
    let deletionID: String?
    let expectedProfileRevision: UInt64?
    let confirmation: String?

    enum CodingKeys: String, CodingKey {
        case operation, confirmation
        case apiVersion = "api_version"
        case requestID = "request_id"
        case idempotencyKey = "idempotency_key"
        case deletionID = "deletion_id"
        case expectedProfileRevision = "expected_profile_revision"
    }
}

private struct AccountDeletionResponseDTO: Decodable, Sendable {
    let deletionID: String
    let status: String
    let processingStatus: String?
    let authIdentityStatus: String
    let revision: UInt64
    let requestedAt: String
    let completedAt: String?
    let held: Bool?

    enum CodingKeys: String, CodingKey {
        case status, revision, held
        case deletionID = "deletion_id"
        case processingStatus = "processing_status"
        case authIdentityStatus = "auth_identity_status"
        case requestedAt = "requested_at"
        case completedAt = "completed_at"
    }
}

private func validateUUID(_ value: String) throws {
    guard UUID(uuidString: value)?.uuidString.lowercased() == value else {
        throw CatalogRequestError.invalidRequest
    }
}

private func validateRevision(_ value: UInt64) throws {
    guard value <= 9_007_199_254_740_991 else { throw CatalogRequestError.invalidRequest }
}

private func validateIdempotencyKey(_ value: String) throws {
    guard (16...64).contains(value.utf8.count),
          value.utf8.allSatisfy({
              (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95
          })
    else {
        throw CatalogRequestError.invalidRequest
    }
}

private func canonicalUUID(_ value: String) -> UUID? {
    guard let result = UUID(uuidString: value), result.uuidString.lowercased() == value else {
        return nil
    }
    return result
}

private func requiredCanonicalUUID(_ value: String) throws -> UUID {
    guard let result = canonicalUUID(value) else { throw CatalogMappingError.invalidResponse }
    return result
}

private func canonicalOptionalUUID(_ value: String?) throws -> UUID? {
    guard let value else { return nil }
    return try requiredCanonicalUUID(value)
}

private func canonicalOptionalCursor(_ value: String?) throws -> String? {
    guard let value else { return nil }
    guard canonicalUUID(value) != nil else { throw CatalogMappingError.invalidResponse }
    return value
}

private func isSafeRevision(_ value: UInt64) -> Bool {
    value <= 9_007_199_254_740_991
}

private func isBoundedCreatorToken(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || $0 == 45 || $0 == 46 || $0 == 95
    }
}

private func isPlainCreatorText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty
        && value.count <= maximum
        && value == value.precomposedStringWithCanonicalMapping
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

private func isCreatorSlug(_ value: String) -> Bool {
    (1...80).contains(value.utf8.count) && value.utf8.allSatisfy {
        (48...57).contains($0) || (97...122).contains($0) || $0 == 45
    }
}

private func creatorTaxonomyOption(_ value: CreatorTaxonomyOptionDTO) throws -> CreatorTaxonomyOption {
    guard let id = canonicalUUID(value.id),
          isPlainCreatorText(value.name, maximum: 120),
          isCreatorSlug(value.slug)
    else { throw CatalogMappingError.invalidResponse }
    return CreatorTaxonomyOption(id: id, name: value.name, slug: value.slug)
}

private func validatedOptionalHTTPSURL(_ value: String?) throws -> URL? {
    guard let value else { return nil }
    guard value.utf8.count <= 2_048,
          let url = URL(string: value),
          url.absoluteString == value,
          url.scheme?.lowercased() == "https",
          url.user == nil,
          url.password == nil,
          url.port == nil,
          url.host.map(validateCatalogPublicHostname) == true
    else { throw CatalogMappingError.invalidResponse }
    return url
}

private func exactTimestamp(_ value: String) throws -> Date {
    guard value.utf8.count == 20 else { throw CatalogMappingError.invalidResponse }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
        throw CatalogMappingError.invalidResponse
    }
    return date
}

private extension Data {
    init?(unpaddedBase64URL value: String) {
        guard !value.contains("="),
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
              })
        else {
            return nil
        }
        var encoded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        self.init(base64Encoded: encoded)
    }
}
