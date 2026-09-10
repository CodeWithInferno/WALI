import CryptoKit
import Foundation

/// Mirrors scripts/production-config.rb's bounded public configuration encoding.
/// The release validators additionally compare every value to the reviewed source manifest.
enum CatalogProductionConfiguration {
    static let projectRef = "afgxvhhubqzgpijcstsv"
    static let fields: [String: String] = [
        "WALI_MARKETPLACE_ENABLED": "WALIMarketplaceEnabled",
        "WALI_RELEASE_MODE": "WALIReleaseMode",
        "WALI_AUTHENTICATION_METHOD": "WALIAuthenticationMethod",
        "WALI_SUPABASE_PROJECT_REF": "WALISupabaseProjectRef",
        "WALI_SUPABASE_URL": "WALIMarketplaceURL",
        "WALI_SUPABASE_PUBLISHABLE_KEY": "WALIMarketplacePublishableKey",
        "WALI_SUPABASE_PUBLISHABLE_KEY_SHA256": "WALIMarketplacePublishableKeySHA256",
        "WALI_CATALOG_CDN_HOST": "WALIApprovedCDNHosts",
        "WALI_CATALOG_SIGNING_KEY_ID": "WALICatalogSigningKeyID",
        "WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64": "WALICatalogSigningPublicKeyBase64",
        "WALI_CATALOG_RECOVERY_SIGNING_KEY_ID": "WALICatalogRecoverySigningKeyID",
        "WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64": "WALICatalogRecoverySigningPublicKeyBase64",
        "WALI_LEGAL_BASE_URL": "WALILegalBaseURL",
    ]

    static func validate(info: [String: Any], bundleIdentifier: String?) throws {
        guard bundleIdentifier == "io.github.codewithinferno.wali.WALI" else {
            throw CatalogRequestError.invalidConfiguration
        }
        let values = try fields.mapValues { field -> String in
            guard let value = info[field] as? String,
                  (1...2048).contains(value.utf8.count),
                  value.utf8.allSatisfy({ (33...126).contains($0) && ![34, 35, 36, 92].contains($0) })
            else { throw CatalogRequestError.invalidConfiguration }
            return value
        }
        let expected = [
            "WALI_MARKETPLACE_ENABLED": "YES", "WALI_RELEASE_MODE": "production",
            "WALI_AUTHENTICATION_METHOD": "email_otp", "WALI_SUPABASE_PROJECT_REF": projectRef,
            "WALI_SUPABASE_URL": "https://\(projectRef).supabase.co",
            "WALI_CATALOG_CDN_HOST": "\(projectRef).supabase.co",
            "WALI_LEGAL_BASE_URL": "https://github.com/CodeWithInferno/WALI/blob/main/docs/legal",
        ]
        guard expected.allSatisfy({ values[$0.key] == $0.value }),
              let key = values["WALI_SUPABASE_PUBLISHABLE_KEY"],
              key.range(of: #"^sb_publishable_[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil,
              values["WALI_SUPABASE_PUBLISHABLE_KEY_SHA256"] == sha256(Data(key.utf8))
        else { throw CatalogRequestError.invalidConfiguration }
        for name in ["WALI_CATALOG_SIGNING_KEY_ID", "WALI_CATALOG_RECOVERY_SIGNING_KEY_ID"] {
            guard let value = values[name], value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
            else { throw CatalogRequestError.invalidConfiguration }
        }
        for name in ["WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64", "WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64"] {
            guard let value = values[name], let decoded = Data(base64Encoded: value),
                  decoded.count == 32, decoded.contains(where: { $0 != 0 }), decoded.base64EncodedString() == value
            else { throw CatalogRequestError.invalidConfiguration }
        }
        guard values["WALI_CATALOG_SIGNING_KEY_ID"] != values["WALI_CATALOG_RECOVERY_SIGNING_KEY_ID"],
              values["WALI_CATALOG_SIGNING_PUBLIC_KEY_BASE64"] != values["WALI_CATALOG_RECOVERY_SIGNING_PUBLIC_KEY_BASE64"],
              info["WALIProductionConfigurationSHA256"] as? String == digest(values: values)
        else { throw CatalogRequestError.invalidConfiguration }
    }

    static func digest(values: [String: String]) -> String {
        let canonical = "schema_version=1\n" + fields.keys.sorted().map { "\($0)=\(values[$0] ?? "")\n" }.joined()
        return sha256(Data(canonical.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
