import CryptoKit
import Foundation

enum CatalogAuthKeychainNamespace {
    private static let baseService = "com.wali.marketplace.auth"

    static func service(bundleIdentifier: String?, supabaseURL: URL) throws -> String {
        guard let bundleIdentifier,
              isValidBundleIdentifier(bundleIdentifier),
              CatalogRemoteURLPolicy.isCanonicalHTTPS(supabaseURL),
              supabaseURL.path.isEmpty || supabaseURL.path == "/",
              let host = supabaseURL.host(percentEncoded: false)
        else {
            throw CatalogRequestError.invalidConfiguration
        }

        let canonicalOrigin = "https://\(host)"
        let originFingerprint = SHA256.hash(data: Data(canonicalOrigin.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(baseService).v1.\(bundleIdentifier).\(originFingerprint)"
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard (3...255).contains(value.utf8.count),
              value.contains("."),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("..")
        else {
            return false
        }

        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { component in
            guard !component.isEmpty,
                  component.utf8.count <= 63,
                  component.first != "-",
                  component.last != "-"
            else {
                return false
            }
            return component.utf8.allSatisfy { byte in
                (48...57).contains(byte)
                    || (65...90).contains(byte)
                    || (97...122).contains(byte)
                    || byte == 45
            }
        }
    }
}
