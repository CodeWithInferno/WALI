import CryptoKit
import Foundation
import Security
import Supabase

public struct AccountDeletionReceiptAdmission: Sendable, Equatable {
    public let requestID: String
    public let subjectID: String
    public let idempotencyKey: String
    public let expectedProfileRevision: UInt64
    public let statusCapabilityHash: String
    public let policyVersion = "2026-09-13"
}

public struct AccountDeletionReceiptStatus: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pending, processing, held, awaitingAuthCleanup = "awaiting_auth_cleanup", completed, failed, cancelled }
    public enum Stage: String, Codable, Sendable { case cleanup, held, appleRevocation = "apple_revocation", identityDeletion = "identity_deletion", retrying, completed }
    public let status: Status
    public let stage: Stage
    public let requestedAt: Date
    public let completedAt: Date?
    public let statusExpiresAt: Date?
    public let retainedCategories: [String]
    public let appleActionRequired: Bool
    enum CodingKeys: String, CodingKey {
        case status, stage
        case requestedAt = "requested_at", completedAt = "completed_at", statusExpiresAt = "status_expires_at"
        case retainedCategories = "retained_categories", appleActionRequired = "apple_action_required"
    }
    func validate() throws {
        guard retainedCategories.count <= 8,
              Set(retainedCategories).count == retainedCategories.count,
              retainedCategories.allSatisfy({ $0.range(of: "^[a-z][a-z0-9_]{0,47}$", options: .regularExpression) != nil })
        else { throw CatalogMappingError.invalidResponse }
        if status == .completed {
            guard stage == .completed, let completedAt, let statusExpiresAt,
                  completedAt >= requestedAt,
                  abs(statusExpiresAt.timeIntervalSince(completedAt) - 30 * 86_400) < 0.001
            else { throw CatalogMappingError.invalidResponse }
        } else {
            guard stage != .completed, completedAt == nil, statusExpiresAt == nil else { throw CatalogMappingError.invalidResponse }
        }
    }
}

public struct AccountDeletionConfirmation: Codable, Sendable, Equatable {
    public let completedAt: Date
    public let retainedCategories: [String]
    public let appleActionRequired: Bool
}

public struct AccountDeletionReceiptSummary: Sendable, Identifiable, Equatable {
    public let id: String
    public let requestedAt: Date
    public let status: AccountDeletionReceiptStatus?
    public let confirmation: AccountDeletionConfirmation?
    public var needsRefresh: Bool { confirmation == nil && status?.status != .cancelled }
}

public protocol AccountDeletionReceiptGateway: Sendable {
    func status(requestID: String, capability: String) async throws -> AccountDeletionReceiptStatus
}
public enum AccountDeletionReceiptError: Error, Sendable { case storageUnavailable, limitReached, statusUnavailable }

public struct HTTPSAccountDeletionReceiptGateway: AccountDeletionReceiptGateway {
    private let environment: CatalogEnvironment
    private let transport = CatalogAccountHTTPTransport()
    public init(environment: CatalogEnvironment) { self.environment = environment }
    public func status(requestID: String, capability: String) async throws -> AccountDeletionReceiptStatus {
        var request = URLRequest(url: environment.supabaseURL.appendingPathComponent("functions/v1/account-deletion-receipt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(environment.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["api_version": "account_deletion_receipt.v1", "request_id": requestID, "capability": capability])
        let (data, response) = try await transport.send(request)
        if response.statusCode == 404 || response.statusCode == 410 { throw AccountDeletionReceiptError.statusUnavailable }
        guard response.statusCode == 200 else { throw CatalogRemoteError(code: "temporarily_unavailable", safeMessage: nil, retryable: true) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.utf8.count <= 40 else { throw CatalogMappingError.invalidResponse }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw CatalogMappingError.invalidResponse }
            return date
        }
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.apiVersion == "account_deletion_receipt.v1", envelope.requestID == requestID else { throw CatalogMappingError.invalidResponse }
        try envelope.data.validate()
        return envelope.data
    }
    private struct Envelope: Decodable {
        let apiVersion: String
        let requestID: String
        let data: AccountDeletionReceiptStatus
        enum CodingKeys: String, CodingKey { case data; case apiVersion = "api_version", requestID = "request_id" }
    }
}

/// Separate from Auth storage: sign-out cannot erase a consented operation's
/// receipt. One gateway-owned actor serializes every window's Keychain changes.
public actor AccountDeletionReceiptStore {
    private struct Pending: Codable {
        let subjectID: String
        let idempotencyKey: String
        let expectedProfileRevision: UInt64
        let capability: String
    }
    private struct Record: Codable {
        let id: String
        let requestedAt: Date
        var pending: Pending?
        var status: AccountDeletionReceiptStatus?
        var confirmation: AccountDeletionConfirmation?
        var summary: AccountDeletionReceiptSummary { .init(id: id, requestedAt: requestedAt, status: status, confirmation: confirmation) }
    }
    private let storage: any AuthLocalStorage
    private let gateway: any AccountDeletionReceiptGateway
    static let storageItemName = "deletion-receipts.v1"
    private static let maximumBytes = 65_536

    public init(environment: CatalogEnvironment, bundleIdentifier: String) throws {
        let service = try CatalogAuthKeychainNamespace.service(bundleIdentifier: bundleIdentifier, supabaseURL: environment.supabaseURL) + ".deletion-receipts.v1"
        storage = CatalogKeychainAuthStorage(service: service)
        gateway = HTTPSAccountDeletionReceiptGateway(environment: environment)
    }
    init(storage: any AuthLocalStorage, gateway: any AccountDeletionReceiptGateway) { self.storage = storage; self.gateway = gateway }

    public func prepare(subjectID: String, expectedProfileRevision: UInt64, idempotencyKey: String) throws -> AccountDeletionReceiptAdmission {
        guard UUID(uuidString: subjectID)?.uuidString.lowercased() == subjectID, expectedProfileRevision > 0,
              UUID(uuidString: idempotencyKey)?.uuidString.lowercased() == idempotencyKey else { throw CatalogRequestError.invalidRequest }
        var records = try read()
        if let existing = records.first(where: { $0.pending?.subjectID == subjectID }) { return try admission(existing) }
        guard records.count < 8 else { throw AccountDeletionReceiptError.limitReached }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountDeletionReceiptError.storageUnavailable }
        let record = Record(id: UUID().uuidString.lowercased(), requestedAt: .now,
            pending: Pending(subjectID: subjectID, idempotencyKey: idempotencyKey, expectedProfileRevision: expectedProfileRevision,
                capability: bytes.map { String(format: "%02x", $0) }.joined()), status: nil, confirmation: nil)
        records.append(record)
        try write(records)
        return try admission(record)
    }
    public func summaries() throws -> [AccountDeletionReceiptSummary] { try read().map(\.summary) }

    public func refresh(id: String) async throws -> AccountDeletionReceiptSummary? {
        guard let record = try read().first(where: { $0.id == id }), let pending = record.pending else { return nil }
        let status = try await gateway.status(requestID: record.id, capability: pending.capability)
        try status.validate()
        // Re-read after suspension. A dismissed or replaced receipt cannot return.
        var records = try read()
        guard let index = records.firstIndex(where: { $0.id == id && $0.pending?.capability == pending.capability }) else { return nil }
        if let completedAt = status.completedAt, status.status == .completed {
            records[index].confirmation = .init(completedAt: completedAt, retainedCategories: status.retainedCategories, appleActionRequired: status.appleActionRequired)
            records[index].pending = nil
            records[index].status = nil
        } else { records[index].status = status }
        try write(records)
        return records[index].summary
    }
    public func dismiss(id: String) throws {
        var records = try read()
        records.removeAll { $0.id == id }
        try write(records)
    }
    private func admission(_ record: Record) throws -> AccountDeletionReceiptAdmission {
        guard let pending = record.pending else { throw AccountDeletionReceiptError.storageUnavailable }
        let bytes = stride(from: 0, to: pending.capability.count, by: 2).compactMap { offset -> UInt8? in
            let start = pending.capability.index(pending.capability.startIndex, offsetBy: offset)
            let end = pending.capability.index(start, offsetBy: 2)
            return UInt8(pending.capability[start..<end], radix: 16)
        }
        guard bytes.count == 32 else { throw AccountDeletionReceiptError.storageUnavailable }
        return .init(requestID: record.id, subjectID: pending.subjectID, idempotencyKey: pending.idempotencyKey, expectedProfileRevision: pending.expectedProfileRevision,
            statusCapabilityHash: SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined())
    }
    private func read() throws -> [Record] {
        guard let data = try storage.retrieve(key: Self.storageItemName) else { return [] }
        guard data.count <= Self.maximumBytes else { throw AccountDeletionReceiptError.storageUnavailable }
        let records = try JSONDecoder().decode([Record].self, from: data)
        guard records.count <= 8, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ record in
                UUID(uuidString: record.id)?.uuidString.lowercased() == record.id &&
                ((record.pending != nil && record.confirmation == nil) || (record.pending == nil && record.confirmation != nil)) &&
                (record.pending.map { $0.capability.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil } ?? true)
              }) else { throw AccountDeletionReceiptError.storageUnavailable }
        for record in records { try record.status?.validate() }
        return records
    }
    private func write(_ records: [Record]) throws {
        let data = try JSONEncoder().encode(records)
        guard data.count <= Self.maximumBytes else { throw AccountDeletionReceiptError.storageUnavailable }
        try storage.store(key: Self.storageItemName, value: data)
        guard try storage.retrieve(key: Self.storageItemName) == data else { throw AccountDeletionReceiptError.storageUnavailable }
    }
}
