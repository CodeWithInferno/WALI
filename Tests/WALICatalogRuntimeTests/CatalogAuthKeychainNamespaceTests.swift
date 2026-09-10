@testable import WALICatalogRuntime
import XCTest

final class CatalogAuthKeychainNamespaceTests: XCTestCase {
    private let productionURL = URL(string: "https://production.supabase.co")!

    func testServiceIsScopedToTheExactSignedApplicationIdentifier() throws {
        let production = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "io.github.codewithinferno.wali.WALI",
            supabaseURL: productionURL
        )
        let development = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "com.wali.development.WALI",
            supabaseURL: productionURL
        )

        XCTAssertNotEqual(production, development)
        XCTAssertTrue(production.hasPrefix("com.wali.marketplace.auth.v1.io.github.codewithinferno.wali.WALI."))
        XCTAssertTrue(
            development.hasPrefix("com.wali.marketplace.auth.v1.com.wali.development.WALI.")
        )
    }

    func testRegisteredReleaseDoesNotReuseUnshippedIdentityCredentials() throws {
        let current = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "io.github.codewithinferno.wali.WALI", supabaseURL: productionURL
        )
        for identifier in [
            "com.wali.WALI", "com.wali.debug.WALI", "com.wali.development.WALI",
            "com.wali.store.WALI", "com.wali.store.development.WALI",
        ] {
            let other = try CatalogAuthKeychainNamespace.service(
                bundleIdentifier: identifier, supabaseURL: productionURL
            )
            XCTAssertNotEqual(current, other, identifier)
        }
    }

    func testSameBundleUsesDifferentServicesForDifferentSupabaseProjects() throws {
        let production = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "io.github.codewithinferno.wali.WALI",
            supabaseURL: productionURL
        )
        let staging = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "io.github.codewithinferno.wali.WALI",
            supabaseURL: XCTUnwrap(URL(string: "https://staging.supabase.co"))
        )

        XCTAssertNotEqual(production, staging)
    }

    func testCanonicalRootURLsUseTheSameService() throws {
        let withoutSlash = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "io.github.codewithinferno.wali.WALI",
            supabaseURL: productionURL
        )
        let withSlash = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "io.github.codewithinferno.wali.WALI",
            supabaseURL: XCTUnwrap(URL(string: "https://production.supabase.co/"))
        )

        XCTAssertEqual(withoutSlash, withSlash)
    }

    #if !WALI_APP_STORE
    func testDirectAppAndAgentDeriveTheSameCatalogNamespace() throws {
        let base = URL(fileURLWithPath: "/private/tmp/WALI-Catalog-Identity-Paths", isDirectory: true)
        let fileManager = CatalogIdentityPathsFileManager(base: base)
        for prefix in ["io.github.codewithinferno.wali", "com.wali.debug", "com.wali.development"] {
            for role in ["WALI", "WALIAgent"] {
                let identifier = prefix + "." + role
                XCTAssertEqual(
                    try CatalogInstallPreparer.defaultQuarantineDirectory(bundleIdentifier: identifier, fileManager: fileManager),
                    base.appendingPathComponent(prefix + "/CatalogQuarantine", isDirectory: true)
                )
                XCTAssertEqual(
                    try CatalogSecurityStateStore.defaultCacheURL(bundleIdentifier: identifier, fileManager: fileManager),
                    base.appendingPathComponent(prefix + "/CatalogSecurity/state.json")
                )
            }
        }
    }
    #endif

    func testMissingBundleIdentifierFailsClosed() {
        assertInvalidConfiguration(
            try CatalogAuthKeychainNamespace.service(
                bundleIdentifier: nil,
                supabaseURL: productionURL
            )
        )
        assertInvalidConfiguration(
            try CatalogAuthKeychainNamespace.service(
                bundleIdentifier: "",
                supabaseURL: productionURL
            )
        )
    }

    func testInvalidSupabaseOriginsFailClosed() throws {
        let invalidOrigins = try [
            XCTUnwrap(URL(string: "http://production.supabase.co")),
            XCTUnwrap(URL(string: "https://user@production.supabase.co")),
            XCTUnwrap(URL(string: "https://production.supabase.co:443")),
            XCTUnwrap(URL(string: "https://production.supabase.co/rest")),
            XCTUnwrap(URL(string: "https://production.supabase.co?project=other")),
            XCTUnwrap(URL(string: "https://production.supabase.co#other")),
            XCTUnwrap(URL(string: "https://localhost")),
        ]

        for origin in invalidOrigins {
            assertInvalidConfiguration(
                try CatalogAuthKeychainNamespace.service(
                    bundleIdentifier: "io.github.codewithinferno.wali.WALI",
                    supabaseURL: origin
                ),
                file: #filePath,
                line: #line
            )
        }
    }

    private func assertInvalidConfiguration(
        _ operation: @autoclosure () throws -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                (error as? CatalogRequestError)?.rawValue,
                CatalogRequestError.invalidConfiguration.rawValue,
                file: file,
                line: line
            )
        }
    }
}

#if !WALI_APP_STORE
private final class CatalogIdentityPathsFileManager: FileManager, @unchecked Sendable {
    let base: URL
    init(base: URL) { self.base = base; super.init() }
    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        XCTAssertEqual(directory, .applicationSupportDirectory)
        return base
    }
}
#endif
