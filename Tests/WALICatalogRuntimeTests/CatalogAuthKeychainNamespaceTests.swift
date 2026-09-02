@testable import WALICatalogRuntime
import XCTest

final class CatalogAuthKeychainNamespaceTests: XCTestCase {
    private let productionURL = URL(string: "https://production.supabase.co")!

    func testServiceIsScopedToTheExactSignedApplicationIdentifier() throws {
        let production = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "com.wali.WALI",
            supabaseURL: productionURL
        )
        let development = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "com.wali.development.WALI",
            supabaseURL: productionURL
        )

        XCTAssertNotEqual(production, development)
        XCTAssertTrue(production.hasPrefix("com.wali.marketplace.auth.v1.com.wali.WALI."))
        XCTAssertTrue(
            development.hasPrefix("com.wali.marketplace.auth.v1.com.wali.development.WALI.")
        )
    }

    func testSameBundleUsesDifferentServicesForDifferentSupabaseProjects() throws {
        let production = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "com.wali.WALI",
            supabaseURL: productionURL
        )
        let staging = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "com.wali.WALI",
            supabaseURL: XCTUnwrap(URL(string: "https://staging.supabase.co"))
        )

        XCTAssertNotEqual(production, staging)
    }

    func testCanonicalRootURLsUseTheSameService() throws {
        let withoutSlash = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "com.wali.WALI",
            supabaseURL: productionURL
        )
        let withSlash = try CatalogAuthKeychainNamespace.service(
            bundleIdentifier: "com.wali.WALI",
            supabaseURL: XCTUnwrap(URL(string: "https://production.supabase.co/"))
        )

        XCTAssertEqual(withoutSlash, withSlash)
    }

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
                    bundleIdentifier: "com.wali.WALI",
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
