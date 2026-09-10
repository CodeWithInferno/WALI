import Foundation
import WALICatalog

public enum CatalogAuthenticationMethod: String, Sendable, Hashable {
    case disabled
    case nativeApple = "native_apple"
    case emailOTP = "email_otp"
}

public struct CatalogEnvironment: Sendable, Hashable {
    public let authenticationMethod: CatalogAuthenticationMethod
    public let supabaseURL: URL
    public let publishableKey: String
    public let approvedCDNHosts: Set<String>
    public let signingKeyID: String
    public let signingPublicKey: Data
    public let recoverySigningKeyID: String?
    public let recoverySigningPublicKey: Data?

    public init(
        supabaseURL: URL,
        publishableKey: String,
        approvedCDNHosts: Set<String>,
        signingKeyID: String,
        signingPublicKey: Data,
        recoverySigningKeyID: String? = nil,
        recoverySigningPublicKey: Data? = nil,
        authenticationMethod: CatalogAuthenticationMethod = .nativeApple
    ) throws {
        guard authenticationMethod != .disabled,
              supabaseURL.scheme?.lowercased() == "https",
              supabaseURL.host != nil,
              supabaseURL.user == nil,
              supabaseURL.password == nil,
              supabaseURL.port == nil,
              supabaseURL.query == nil,
              supabaseURL.fragment == nil,
              supabaseURL.path.isEmpty || supabaseURL.path == "/",
              !publishableKey.isEmpty,
              publishableKey.utf8.count <= 4_096,
              !approvedCDNHosts.isEmpty,
              approvedCDNHosts.allSatisfy(validateCatalogPublicHostname),
              supabaseURL.host.map(validateCatalogPublicHostname) == true,
              !signingKeyID.isEmpty,
              signingKeyID.utf8.count <= 64,
              signingPublicKey.count == 32,
              (recoverySigningKeyID == nil) == (recoverySigningPublicKey == nil),
              recoverySigningKeyID.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              recoverySigningPublicKey.map({ $0.count == 32 }) ?? true,
              recoverySigningKeyID != signingKeyID
        else {
            throw CatalogRequestError.invalidConfiguration
        }
        self.authenticationMethod = authenticationMethod
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.approvedCDNHosts = approvedCDNHosts
        self.signingKeyID = signingKeyID
        self.signingPublicKey = signingPublicKey
        self.recoverySigningKeyID = recoverySigningKeyID
        self.recoverySigningPublicKey = recoverySigningPublicKey
    }

    public static func from(bundle: Bundle = .main) throws -> CatalogEnvironment {
        try from(infoDictionary: bundle.infoDictionary ?? [:], bundleIdentifier: bundle.bundleIdentifier)
    }

    static func from(infoDictionary info: [String: Any], bundleIdentifier: String?) throws -> CatalogEnvironment {
        guard isMarketplaceEnabled(infoDictionary: info) else {
            throw CatalogRequestError.invalidConfiguration
        }
        guard let methodValue = info["WALIAuthenticationMethod"] as? String,
              let method = CatalogAuthenticationMethod(rawValue: methodValue), method != .disabled
        else { throw CatalogRequestError.invalidConfiguration }
        if method == .emailOTP || bundleIdentifier == "io.github.codewithinferno.wali.WALI" {
            try CatalogProductionConfiguration.validate(info: info, bundleIdentifier: bundleIdentifier)
        }
        guard let urlString = info["WALIMarketplaceURL"] as? String,
              let url = URL(string: urlString),
              let key = info["WALIMarketplacePublishableKey"] as? String,
              let hostString = info["WALIApprovedCDNHosts"] as? String,
              let signingKeyID = info["WALICatalogSigningKeyID"] as? String,
              let publicKeyValue = info["WALICatalogSigningPublicKeyBase64"] as? String,
              let signingPublicKey = Data.catalogBase64Decoded(publicKeyValue)
        else {
            throw CatalogRequestError.invalidConfiguration
        }
        let hosts = Set(
            hostString.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        )
        let recoveryKeyID = info["WALICatalogRecoverySigningKeyID"] as? String
        let recoveryPublicKey = (info["WALICatalogRecoverySigningPublicKeyBase64"] as? String).flatMap(Data.catalogBase64Decoded)
        return try CatalogEnvironment(
            supabaseURL: url,
            publishableKey: key,
            approvedCDNHosts: hosts,
            signingKeyID: signingKeyID,
            signingPublicKey: signingPublicKey,
            recoverySigningKeyID: recoveryKeyID,
            recoverySigningPublicKey: recoveryPublicKey,
            authenticationMethod: method
        )
    }

    /// Marketplace activation is an explicit build-time decision. Xcode keeps
    /// xcconfig substitutions in generated plists as strings, so only the exact
    /// canonical value `YES` (or a native plist boolean) enables the client.
    public static func isMarketplaceEnabled(infoDictionary: [String: Any]) -> Bool {
        switch infoDictionary["WALIMarketplaceEnabled"] {
        case let value as Bool: value
        case let value as String: value == "YES"
        default: false
        }
    }

    public func compiledTrustAnchors() throws -> [TrustedCatalogSigningKey] {
        var values = [try trustedKey(id: signingKeyID, publicKey: signingPublicKey)]
        if let recoverySigningKeyID, let recoverySigningPublicKey {
            values.append(try trustedKey(id: recoverySigningKeyID, publicKey: recoverySigningPublicKey))
        }
        return values
    }

    private func trustedKey(id: String, publicKey: Data) throws -> TrustedCatalogSigningKey {
        try TrustedCatalogSigningKey(
            id: CatalogKeyID(id),
            publicKey: publicKey,
            validFrom: Date(timeIntervalSince1970: 0),
            validUntil: Date(timeIntervalSince1970: 4_102_444_800),
            status: .active
        )
    }
}

private extension Data {
    static func catalogBase64Decoded(_ value: String) -> Data? {
        if let data = Data(base64Encoded: value) { return data }
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        return Data(base64Encoded: normalized)
    }
}
