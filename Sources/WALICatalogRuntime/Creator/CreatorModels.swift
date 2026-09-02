import Foundation
import WALICatalog

public enum CreatorContractError: String, Error, Sendable, Equatable {
    case invalidRequest = "invalid_request"
    case rightsIncomplete = "rights_incomplete"
    case creatorTermsStale = "creator_terms_stale"
    case nonCanonicalArtifact = "non_canonical_artifact"
    case invalidRemoteResponse = "invalid_remote_response"
}

public enum CreatorAssuranceLevel: String, Codable, Sendable, Hashable {
    case aal1
    case aal2
}

public struct CreatorAuthorizationSnapshot: Sendable, Hashable {
    public let subjectID: String
    public let accountIsActive: Bool
    public let sessionExpiresAt: Date
    public let creatorGrantRevision: UInt64?
    public let acceptedCreatorTermsVersion: String?
    public let currentCreatorTermsVersion: String
    public let moderatorGrantRevision: UInt64?
    public let assuranceLevel: CreatorAssuranceLevel

    public init(
        subjectID: String,
        accountIsActive: Bool,
        sessionExpiresAt: Date,
        creatorGrantRevision: UInt64?,
        acceptedCreatorTermsVersion: String?,
        currentCreatorTermsVersion: String,
        moderatorGrantRevision: UInt64?,
        assuranceLevel: CreatorAssuranceLevel
    ) {
        self.subjectID = subjectID
        self.accountIsActive = accountIsActive
        self.sessionExpiresAt = sessionExpiresAt
        self.creatorGrantRevision = creatorGrantRevision
        self.acceptedCreatorTermsVersion = acceptedCreatorTermsVersion
        self.currentCreatorTermsVersion = currentCreatorTermsVersion
        self.moderatorGrantRevision = moderatorGrantRevision
        self.assuranceLevel = assuranceLevel
    }

    public func canAccessCreatorStudio(at date: Date = .now) -> Bool {
        accountIsActive
            && sessionExpiresAt > date
            && creatorGrantRevision != nil
            && acceptedCreatorTermsVersion == currentCreatorTermsVersion
            && !currentCreatorTermsVersion.isEmpty
    }

    public func canAccessModeration(at date: Date = .now) -> Bool {
        accountIsActive
            && sessionExpiresAt > date
            && moderatorGrantRevision != nil
            && assuranceLevel == .aal2
    }

    public func removingModeratorGrant() -> Self {
        .init(
            subjectID: subjectID,
            accountIsActive: accountIsActive,
            sessionExpiresAt: sessionExpiresAt,
            creatorGrantRevision: creatorGrantRevision,
            acceptedCreatorTermsVersion: acceptedCreatorTermsVersion,
            currentCreatorTermsVersion: currentCreatorTermsVersion,
            moderatorGrantRevision: nil,
            assuranceLevel: assuranceLevel
        )
    }

    public func withAssuranceLevel(_ value: CreatorAssuranceLevel) -> Self {
        .init(
            subjectID: subjectID,
            accountIsActive: accountIsActive,
            sessionExpiresAt: sessionExpiresAt,
            creatorGrantRevision: creatorGrantRevision,
            acceptedCreatorTermsVersion: acceptedCreatorTermsVersion,
            currentCreatorTermsVersion: currentCreatorTermsVersion,
            moderatorGrantRevision: moderatorGrantRevision,
            assuranceLevel: value
        )
    }
}

public enum CreatorSubmissionState: String, Codable, CaseIterable, Sendable, Hashable {
    case draft
    case uploading
    case uploaded
    case processing
    case processingFailed = "processing_failed"
    case readyForSubmission = "ready_for_submission"
    case submitted
    case underReview = "under_review"
    case changesRequested = "changes_requested"
    case approved
    case rejected
    case published
    case withdrawn
}

public enum CreatorRightsBasis: String, Codable, CaseIterable, Sendable, Hashable {
    case original
    case licensed
    case publicDomain = "public_domain"
    case other
}

public struct CreatorRightsRequirements: Sendable, Hashable {
    public let requiresSourceURL: Bool
    public let requiresAttribution: Bool
    public let requiresProof: Bool

    public init(requiresSourceURL: Bool, requiresAttribution: Bool, requiresProof: Bool) {
        self.requiresSourceURL = requiresSourceURL
        self.requiresAttribution = requiresAttribution
        self.requiresProof = requiresProof
    }
}

public struct CreatorRightsDeclaration: Sendable, Hashable {
    public let basis: CreatorRightsBasis
    public let rightsHolder: String
    public let licenseID: UUID
    public let sourceURL: URL?
    public let attributionText: String?
    public let proofObjectIDs: [UUID]
    public let attestsRights: Bool
    public let requirements: CreatorRightsRequirements

    public init(
        basis: CreatorRightsBasis,
        rightsHolder: String,
        licenseID: UUID,
        sourceURL: URL?,
        attributionText: String?,
        proofObjectIDs: [UUID],
        attestsRights: Bool,
        requirements: CreatorRightsRequirements
    ) throws {
        guard CreatorValidation.isPlainText(rightsHolder, range: 1...160),
              proofObjectIDs.count <= 5,
              Set(proofObjectIDs).count == proofObjectIDs.count,
              attestsRights,
              sourceURL.map(CreatorValidation.isHTTPSURL) ?? !requirements.requiresSourceURL,
              attributionText.map({ CreatorValidation.isPlainText($0, range: 1...1_000) })
                ?? !requirements.requiresAttribution,
              !requirements.requiresProof || !proofObjectIDs.isEmpty
        else {
            throw CreatorContractError.rightsIncomplete
        }
        self.basis = basis
        self.rightsHolder = rightsHolder
        self.licenseID = licenseID
        self.sourceURL = sourceURL
        self.attributionText = attributionText
        self.proofObjectIDs = proofObjectIDs
        self.attestsRights = attestsRights
        self.requirements = requirements
    }
}

public struct CreatorDraft: Sendable, Hashable {
    public let title: String
    public let description: String
    public let primaryCategoryID: UUID
    public let suggestedTagIDs: [UUID]
    public let contentWarning: String?
    public let rights: CreatorRightsDeclaration

    public init(
        title: String,
        description: String,
        primaryCategoryID: UUID,
        suggestedTagIDs: [UUID],
        contentWarning: String?,
        rights: CreatorRightsDeclaration
    ) throws {
        guard CreatorValidation.isPlainText(title, range: 1...120),
              CreatorValidation.isPlainText(description, range: 1...2_000),
              suggestedTagIDs.count <= 20,
              Set(suggestedTagIDs).count == suggestedTagIDs.count,
              contentWarning.map({ CreatorValidation.isPlainText($0, range: 1...500) }) ?? true
        else {
            throw CreatorContractError.invalidRequest
        }
        self.title = title
        self.description = description
        self.primaryCategoryID = primaryCategoryID
        self.suggestedTagIDs = suggestedTagIDs
        self.contentWarning = contentWarning
        self.rights = rights
    }
}

public struct CreatorTaxonomyOption: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let slug: String

    public init(id: UUID, name: String, slug: String) {
        self.id = id
        self.name = name
        self.slug = slug
    }
}

public struct CreatorLicenseOption: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let name: String
    public let code: String
    public let requirements: CreatorRightsRequirements

    public init(id: UUID, name: String, code: String, requirements: CreatorRightsRequirements) {
        self.id = id
        self.name = name
        self.code = code
        self.requirements = requirements
    }
}

public struct CreatorMetadata: Sendable, Hashable {
    public let categories: [CreatorTaxonomyOption]
    public let tags: [CreatorTaxonomyOption]
    public let licenses: [CreatorLicenseOption]
    public let currentCreatorTermsVersion: String

    public init(
        categories: [CreatorTaxonomyOption],
        tags: [CreatorTaxonomyOption],
        licenses: [CreatorLicenseOption],
        currentCreatorTermsVersion: String
    ) throws {
        guard !categories.isEmpty,
              !licenses.isEmpty,
              categories.count <= 100,
              tags.count <= 500,
              licenses.count <= 100,
              Set(categories.map(\.id)).count == categories.count,
              Set(tags.map(\.id)).count == tags.count,
              Set(licenses.map(\.id)).count == licenses.count,
              CreatorValidation.isBoundedToken(currentCreatorTermsVersion, maximum: 64)
        else { throw CreatorContractError.invalidRemoteResponse }
        self.categories = categories
        self.tags = tags
        self.licenses = licenses
        self.currentCreatorTermsVersion = currentCreatorTermsVersion
    }
}

public struct CreatorMediaFacts: Sendable, Hashable {
    public let container: String
    public let codec: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let durationMilliseconds: UInt64

    public init(
        container: String,
        codec: String,
        width: Int,
        height: Int,
        frameRate: Double,
        durationMilliseconds: UInt64
    ) throws {
        guard CreatorValidation.isBoundedToken(container, maximum: 64),
              CreatorValidation.isBoundedToken(codec, maximum: 64),
              (1...16_384).contains(width),
              (1...16_384).contains(height),
              frameRate.isFinite,
              frameRate > 0,
              frameRate <= 240,
              (1...600_000).contains(durationMilliseconds)
        else {
            throw CreatorContractError.invalidRemoteResponse
        }
        self.container = container
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum CreatorArtifactRole: String, Codable, Sendable, Hashable {
    case poster
    case preview
}

public struct CreatorCanonicalArtifact: Identifiable, Sendable, Hashable {
    public let id: String
    public let role: CreatorArtifactRole
    public let url: URL
    public let sha256: String
    public let byteCount: UInt64
    public let mediaType: String
    public let width: Int
    public let height: Int
    public let durationMilliseconds: UInt64

    public init(
        role: CreatorArtifactRole,
        url: URL,
        sha256: String,
        byteCount: UInt64,
        mediaType: String,
        width: Int,
        height: Int,
        durationMilliseconds: UInt64,
        remoteURLPolicy: CatalogRemoteURLPolicy
    ) throws {
        guard remoteURLPolicy.allowsMedia(url) || remoteURLPolicy.allowsSignedModeratorArtifact(url),
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...CatalogArtifact.maximumByteCount).contains(byteCount),
              (1...16_384).contains(width),
              (1...16_384).contains(height)
        else {
            throw CreatorContractError.nonCanonicalArtifact
        }
        let validMedia = switch role {
        case .poster:
            ["image/jpeg", "image/png"].contains(mediaType) && durationMilliseconds == 0
        case .preview:
            mediaType == "video/mp4" && (1...600_000).contains(durationMilliseconds)
        }
        guard validMedia else { throw CreatorContractError.nonCanonicalArtifact }
        id = "\(role.rawValue):\(sha256)"
        self.role = role
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct CreatorGeneratedVariant: Identifiable, Sendable, Hashable {
    public let id: String
    public let role: String
    public let width: Int
    public let height: Int

    public init(role: String, width: Int, height: Int) {
        id = "\(role):\(width)x\(height)"
        self.role = role
        self.width = width
        self.height = height
    }
}

public enum CreatorSuggestionKind: String, Codable, Sendable, Hashable {
    case category
    case tag
    case title
    case description
}

public struct CreatorModelSuggestion: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: CreatorSuggestionKind
    public let value: String
    public let confidence: Double
    public let modelID: String
    public let modelRevision: String

    public init(
        kind: CreatorSuggestionKind,
        value: String,
        confidence: Double,
        modelID: String,
        modelRevision: String
    ) {
        id = "\(kind.rawValue):\(value):\(modelID):\(modelRevision)"
        self.kind = kind
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
        self.modelID = modelID
        self.modelRevision = modelRevision
    }
}

public enum CreatorFindingSeverity: String, Codable, Sendable, Hashable {
    case info
    case warning
    case blocking
}

public struct CreatorFinding: Identifiable, Sendable, Hashable {
    public let id: String
    public let code: String
    public let message: String
    public let severity: CreatorFindingSeverity

    public init(code: String, message: String, severity: CreatorFindingSeverity) {
        id = code
        self.code = code
        self.message = message
        self.severity = severity
    }
}

public struct CreatorProcessingStatus: Sendable, Hashable {
    public let submissionID: UUID
    public let revision: UInt64
    public let generation: UInt64
    public let state: CreatorSubmissionState
    public let progress: Double?
    public let safeErrorCode: String?
    public let mediaFacts: CreatorMediaFacts?
    public let generatedVariants: [CreatorGeneratedVariant]
    public let duplicateWarning: Bool
    public let suggestions: [CreatorModelSuggestion]
    public let findings: [CreatorFinding]

    public init(
        submissionID: UUID,
        revision: UInt64,
        generation: UInt64,
        state: CreatorSubmissionState,
        progress: Double?,
        safeErrorCode: String?,
        mediaFacts: CreatorMediaFacts?,
        generatedVariants: [CreatorGeneratedVariant],
        duplicateWarning: Bool,
        suggestions: [CreatorModelSuggestion],
        findings: [CreatorFinding]
    ) {
        self.submissionID = submissionID
        self.revision = revision
        self.generation = generation
        self.state = state
        self.progress = progress.map { min(max($0, 0), 1) }
        self.safeErrorCode = safeErrorCode
        self.mediaFacts = mediaFacts
        self.generatedVariants = generatedVariants
        self.duplicateWarning = duplicateWarning
        self.suggestions = suggestions
        self.findings = findings
    }
}

public struct CreatorSubmission: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let wallpaperID: UUID?
    public let revision: UInt64
    public let generation: UInt64
    public let state: CreatorSubmissionState
    public let draft: CreatorDraft?
    public let processing: CreatorProcessingStatus?
    public let moderationReasonCodes: [String]
    public let creatorFacingNote: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        wallpaperID: UUID?,
        revision: UInt64,
        generation: UInt64,
        state: CreatorSubmissionState,
        draft: CreatorDraft?,
        processing: CreatorProcessingStatus?,
        moderationReasonCodes: [String],
        creatorFacingNote: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.wallpaperID = wallpaperID
        self.revision = revision
        self.generation = generation
        self.state = state
        self.draft = draft
        self.processing = processing
        self.moderationReasonCodes = moderationReasonCodes
        self.creatorFacingNote = creatorFacingNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CreatorSubmissionPage: Sendable, Hashable {
    public let items: [CreatorSubmission]
    public let nextCursor: String?

    public init(items: [CreatorSubmission], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum CreatorUploadTarget: Sendable, Hashable {
    case new
    case wallpaperUpdate(wallpaperID: UUID, expectedRevision: UInt64)
}

public struct CreatorUploadGrantRequest: Sendable, Hashable {
    public let declaredByteCount: UInt64
    public let containerHint: String
    public let originalFilename: String
    public let target: CreatorUploadTarget
    public let idempotencyKey: String

    public init(
        declaredByteCount: UInt64,
        containerHint: String,
        originalFilename: String,
        target: CreatorUploadTarget,
        idempotencyKey: String
    ) throws {
        let filename = URL(fileURLWithPath: originalFilename).lastPathComponent
        guard (1...1_073_741_824).contains(declaredByteCount),
              ["video/mp4", "video/quicktime"].contains(containerHint),
              filename == originalFilename,
              CreatorValidation.isPlainText(filename, range: 1...255),
              CreatorValidation.isIdempotencyKey(idempotencyKey),
              CreatorValidation.valid(target: target)
        else {
            throw CreatorContractError.invalidRequest
        }
        self.declaredByteCount = declaredByteCount
        self.containerHint = containerHint
        self.originalFilename = filename
        self.target = target
        self.idempotencyKey = idempotencyKey
    }
}

public struct CreatorUploadSession: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let revision: UInt64
    public let endpoint: URL
    public let requiredHeaders: [String: String]
    public let scopedUploadToken: String
    public let expiresAt: Date
    public let declaredByteCount: UInt64

    public init(
        id: UUID,
        revision: UInt64,
        endpoint: URL,
        requiredHeaders: [String: String],
        scopedUploadToken: String,
        expiresAt: Date,
        declaredByteCount: UInt64
    ) throws {
        guard CreatorValidation.isHTTPSURL(endpoint),
              CreatorValidation.isRevision(revision),
              revision > 0,
              (1...1_073_741_824).contains(declaredByteCount),
              (1...20).contains(requiredHeaders.count),
              requiredHeaders.allSatisfy({
                  CreatorValidation.isHeaderName($0.key)
                      && CreatorValidation.isHeaderValue($0.value)
              }),
              (1...4_096).contains(scopedUploadToken.utf8.count)
        else {
            throw CreatorContractError.invalidRemoteResponse
        }
        self.id = id
        self.revision = revision
        self.endpoint = endpoint
        self.requiredHeaders = requiredHeaders
        self.scopedUploadToken = scopedUploadToken
        self.expiresAt = expiresAt
        self.declaredByteCount = declaredByteCount
    }
}

public struct CreatorCompleteUploadRequest: Sendable, Hashable {
    public let uploadSessionID: UUID
    public let expectedSessionRevision: UInt64
    public let idempotencyKey: String

    public init(uploadSessionID: UUID, expectedSessionRevision: UInt64, idempotencyKey: String) throws {
        guard expectedSessionRevision > 0,
              CreatorValidation.isRevision(expectedSessionRevision),
              CreatorValidation.isIdempotencyKey(idempotencyKey)
        else {
            throw CreatorContractError.invalidRequest
        }
        self.uploadSessionID = uploadSessionID
        self.expectedSessionRevision = expectedSessionRevision
        self.idempotencyKey = idempotencyKey
    }
}

public struct CreatorMutationResult: Sendable, Hashable {
    public let submissionID: UUID
    public let revision: UInt64
    public let generation: UInt64
    public let state: CreatorSubmissionState
    public let fieldErrors: [CreatorFieldError]

    public init(
        submissionID: UUID,
        revision: UInt64,
        generation: UInt64,
        state: CreatorSubmissionState,
        fieldErrors: [CreatorFieldError] = []
    ) {
        self.submissionID = submissionID
        self.revision = revision
        self.generation = generation
        self.state = state
        self.fieldErrors = fieldErrors
    }
}

public struct CreatorFieldError: Sendable, Hashable {
    public let field: String
    public let code: String

    public init(field: String, code: String) {
        self.field = field
        self.code = code
    }
}

public struct CreatorSaveDraftRequest: Sendable, Hashable {
    public let submissionID: UUID
    public let expectedRevision: UInt64
    public let draft: CreatorDraft
    public let creatorTermsVersion: String
    public let idempotencyKey: String

    public init(
        submissionID: UUID,
        expectedRevision: UInt64,
        draft: CreatorDraft,
        creatorTermsVersion: String,
        idempotencyKey: String
    ) throws {
        guard CreatorValidation.isRevision(expectedRevision),
              CreatorValidation.isBoundedToken(creatorTermsVersion, maximum: 64),
              CreatorValidation.isIdempotencyKey(idempotencyKey)
        else { throw CreatorContractError.invalidRequest }
        self.submissionID = submissionID
        self.expectedRevision = expectedRevision
        self.draft = draft
        self.creatorTermsVersion = creatorTermsVersion
        self.idempotencyKey = idempotencyKey
    }
}

public struct CreatorSubmitRequest: Sendable, Hashable {
    public let submissionID: UUID
    public let expectedRevision: UInt64
    public let expectedGeneration: UInt64
    public let creatorTermsVersion: String
    public let idempotencyKey: String

    public init(
        submissionID: UUID,
        expectedRevision: UInt64,
        expectedGeneration: UInt64,
        acceptedCreatorTermsVersion: String,
        currentCreatorTermsVersion: String,
        idempotencyKey: String
    ) throws {
        guard CreatorValidation.isRevision(expectedRevision),
              CreatorValidation.isRevision(expectedGeneration),
              expectedGeneration > 0,
              !currentCreatorTermsVersion.isEmpty,
              acceptedCreatorTermsVersion == currentCreatorTermsVersion,
              CreatorValidation.isBoundedToken(currentCreatorTermsVersion, maximum: 64),
              CreatorValidation.isIdempotencyKey(idempotencyKey)
        else {
            throw acceptedCreatorTermsVersion == currentCreatorTermsVersion
                ? CreatorContractError.invalidRequest
                : CreatorContractError.creatorTermsStale
        }
        self.submissionID = submissionID
        self.expectedRevision = expectedRevision
        self.expectedGeneration = expectedGeneration
        creatorTermsVersion = currentCreatorTermsVersion
        self.idempotencyKey = idempotencyKey
    }
}

public struct CreatorWithdrawRequest: Sendable, Hashable {
    public let submissionID: UUID
    public let expectedRevision: UInt64
    public let idempotencyKey: String

    public init(submissionID: UUID, expectedRevision: UInt64, idempotencyKey: String) throws {
        guard CreatorValidation.isRevision(expectedRevision),
              CreatorValidation.isIdempotencyKey(idempotencyKey)
        else { throw CreatorContractError.invalidRequest }
        self.submissionID = submissionID
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
    }
}

public struct CreatorListRequest: Sendable, Hashable {
    public let cursor: String?
    public let limit: Int

    public init(cursor: String? = nil, limit: Int = 24) throws {
        guard (1...50).contains(limit), CreatorValidation.isCursor(cursor) else {
            throw CreatorContractError.invalidRequest
        }
        self.cursor = cursor
        self.limit = limit
    }
}

public struct CreatorPublicIdentity: Sendable, Hashable {
    public let id: UUID
    public let handle: String
    public let displayName: String

    public init(id: UUID, handle: String, displayName: String) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
    }
}

public enum CreatorProofStatus: String, Codable, Sendable, Hashable {
    case notRequired = "not_required"
    case missing
    case scanning
    case verified
    case rejected
}

public struct ModerationQueueItem: Identifiable, Sendable, Hashable {
    public var id: UUID { submissionID }
    public let submissionID: UUID
    public let revision: UInt64
    public let generation: UInt64
    public let creator: CreatorPublicIdentity
    public let proposedTitle: String
    public let proposedDescription: String
    public let primaryCategoryName: String
    public let tagNames: [String]
    public let contentRating: String
    public let attributionText: String?
    public let sourceURL: URL?
    public let rightsSummary: String
    public let proofStatus: CreatorProofStatus
    public let canonicalArtifacts: [CreatorCanonicalArtifact]
    public let mediaFacts: CreatorMediaFacts?
    public let findings: [CreatorFinding]
    public let modelSuggestions: [CreatorModelSuggestion]
    public let submittedAt: Date

    public init(
        submissionID: UUID,
        revision: UInt64,
        generation: UInt64,
        creator: CreatorPublicIdentity,
        proposedTitle: String,
        proposedDescription: String,
        primaryCategoryName: String,
        tagNames: [String],
        contentRating: String,
        attributionText: String?,
        sourceURL: URL?,
        rightsSummary: String,
        proofStatus: CreatorProofStatus,
        canonicalArtifacts: [CreatorCanonicalArtifact],
        mediaFacts: CreatorMediaFacts?,
        findings: [CreatorFinding],
        modelSuggestions: [CreatorModelSuggestion],
        submittedAt: Date
    ) {
        self.submissionID = submissionID
        self.revision = revision
        self.generation = generation
        self.creator = creator
        self.proposedTitle = proposedTitle
        self.proposedDescription = proposedDescription
        self.primaryCategoryName = primaryCategoryName
        self.tagNames = tagNames
        self.contentRating = contentRating
        self.attributionText = attributionText
        self.sourceURL = sourceURL
        self.rightsSummary = rightsSummary
        self.proofStatus = proofStatus
        self.canonicalArtifacts = canonicalArtifacts
        self.mediaFacts = mediaFacts
        self.findings = findings
        self.modelSuggestions = modelSuggestions
        self.submittedAt = submittedAt
    }
}

public enum ModerationQueueSort: String, Codable, CaseIterable, Sendable, Hashable {
    case oldestSubmitted = "oldest_submitted"
    case newestSubmitted = "newest_submitted"
    case riskPriority = "risk_priority"
}

public struct ModerationQueueRequest: Sendable, Hashable {
    public let status: String
    public let sort: ModerationQueueSort
    public let cursor: String?
    public let limit: Int

    public init(
        status: String = "pending",
        sort: ModerationQueueSort = .oldestSubmitted,
        cursor: String? = nil,
        limit: Int = 24
    ) throws {
        guard CreatorValidation.isBoundedToken(status, maximum: 40),
              CreatorValidation.isCursor(cursor),
              (1...50).contains(limit)
        else { throw CreatorContractError.invalidRequest }
        self.status = status
        self.sort = sort
        self.cursor = cursor
        self.limit = limit
    }
}

public struct ModerationQueuePage: Sendable, Hashable {
    public let items: [ModerationQueueItem]
    public let nextCursor: String?

    public init(items: [ModerationQueueItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public enum ModerationDecision: String, Codable, CaseIterable, Sendable, Hashable {
    case approved
    case changesRequested = "changes_requested"
    case rejected
}

public struct ModerationReasonOption: Identifiable, Sendable, Hashable {
    public var id: String { code }
    public let code: String
    public let label: String
    public let decisions: Set<ModerationDecision>

    public init(code: String, label: String, decisions: Set<ModerationDecision>) throws {
        guard CreatorValidation.isBoundedToken(code, maximum: 80),
              CreatorValidation.isPlainText(label, range: 1...160),
              !decisions.isEmpty
        else { throw CreatorContractError.invalidRemoteResponse }
        self.code = code
        self.label = label
        self.decisions = decisions
    }
}

public struct ModerationMetadata: Sendable, Hashable {
    public let checklistRevision: UInt64
    public let creatorNoteRequired: Bool
    public let reasonCodes: [ModerationReasonOption]

    public init(
        checklistRevision: UInt64,
        creatorNoteRequired: Bool,
        reasonCodes: [ModerationReasonOption]
    ) throws {
        guard CreatorValidation.isRevision(checklistRevision),
              checklistRevision > 0,
              (1...100).contains(reasonCodes.count),
              Set(reasonCodes.map(\.code)).count == reasonCodes.count
        else { throw CreatorContractError.invalidRemoteResponse }
        self.checklistRevision = checklistRevision
        self.creatorNoteRequired = creatorNoteRequired
        self.reasonCodes = reasonCodes
    }

    public func reasons(for decision: ModerationDecision) -> [ModerationReasonOption] {
        reasonCodes.filter { $0.decisions.contains(decision) }
    }
}

public struct ModerationDecisionRequest: Sendable, Hashable {
    public let submissionID: UUID
    public let expectedRevision: UInt64
    public let expectedGeneration: UInt64
    public let decision: ModerationDecision
    public let checklistRevision: UInt64
    public let reasonCodes: [String]
    public let creatorNote: String
    public let privateNote: String
    public let idempotencyKey: String

    public init(
        submissionID: UUID,
        expectedRevision: UInt64,
        expectedGeneration: UInt64,
        decision: ModerationDecision,
        checklistRevision: UInt64,
        reasonCodes: [String],
        creatorNote: String,
        privateNote: String,
        idempotencyKey: String
    ) throws {
        guard CreatorValidation.isRevision(expectedRevision),
              CreatorValidation.isRevision(expectedGeneration),
              expectedGeneration > 0,
              CreatorValidation.isRevision(checklistRevision),
              checklistRevision > 0,
              (1...20).contains(reasonCodes.count),
              Set(reasonCodes).count == reasonCodes.count,
              reasonCodes.allSatisfy({ CreatorValidation.isBoundedToken($0, maximum: 80) }),
              CreatorValidation.isPlainText(creatorNote, range: 1...2_000),
              CreatorValidation.isPlainTextAllowingEmpty(privateNote, maximum: 4_000),
              CreatorValidation.isIdempotencyKey(idempotencyKey)
        else { throw CreatorContractError.invalidRequest }
        self.submissionID = submissionID
        self.expectedRevision = expectedRevision
        self.expectedGeneration = expectedGeneration
        self.decision = decision
        self.checklistRevision = checklistRevision
        self.reasonCodes = reasonCodes
        self.creatorNote = creatorNote
        self.privateNote = privateNote
        self.idempotencyKey = idempotencyKey
    }
}

public struct ModerationDecisionResult: Sendable, Hashable {
    public let submissionID: UUID
    public let revision: UInt64
    public let generation: UInt64
    public let state: CreatorSubmissionState

    public init(
        submissionID: UUID,
        revision: UInt64,
        generation: UInt64,
        state: CreatorSubmissionState
    ) {
        self.submissionID = submissionID
        self.revision = revision
        self.generation = generation
        self.state = state
    }
}

public struct ModerationReport: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let revision: UInt64
    public let reasonCode: String
    public let safeSummary: String
    public let createdAt: Date

    public init(id: UUID, revision: UInt64, reasonCode: String, safeSummary: String, createdAt: Date) {
        self.id = id
        self.revision = revision
        self.reasonCode = reasonCode
        self.safeSummary = safeSummary
        self.createdAt = createdAt
    }
}

public struct ModerationReportQueueRequest: Sendable, Hashable {
    public let cursor: String?
    public let limit: Int

    public init(cursor: String? = nil, limit: Int = 24) throws {
        guard CreatorValidation.isCursor(cursor), (1...50).contains(limit) else {
            throw CreatorContractError.invalidRequest
        }
        self.cursor = cursor
        self.limit = limit
    }
}

public struct ModerationReportPage: Sendable, Hashable {
    public let items: [ModerationReport]
    public let nextCursor: String?

    public init(items: [ModerationReport], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

enum CreatorValidation {
    static let maximumSafeInteger: UInt64 = 9_007_199_254_740_991

    static func isPlainText(_ value: String, range: ClosedRange<Int>) -> Bool {
        range.contains(value.count)
            && value == value.precomposedStringWithCanonicalMapping
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func isPlainTextAllowingEmpty(_ value: String, maximum: Int) -> Bool {
        value.isEmpty || isPlainText(value, range: 1...maximum)
    }

    static func isHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && !(url.host(percentEncoded: false) ?? "").isEmpty
            && url.absoluteString.utf8.count <= 2_048
            && url.user == nil
            && url.password == nil
    }

    static func isRevision(_ value: UInt64) -> Bool { value <= maximumSafeInteger }

    static func isBoundedToken(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    static func isIdempotencyKey(_ value: String) -> Bool {
        (16...64).contains(value.utf8.count) && isBoundedToken(value, maximum: 64)
    }

    static func isCursor(_ value: String?) -> Bool {
        guard let value else { return true }
        return (1...1_024).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    static func valid(target: CreatorUploadTarget) -> Bool {
        switch target {
        case .new:
            return true
        case let .wallpaperUpdate(_, expectedRevision):
            return isRevision(expectedRevision)
        }
    }

    static func isHeaderName(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45
        }
    }

    static func isHeaderValue(_ value: String) -> Bool {
        (1...4_096).contains(value.utf8.count)
            && !value.unicodeScalars.contains(where: CharacterSet.newlines.contains)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
