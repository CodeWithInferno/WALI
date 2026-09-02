import Foundation
import Testing
@testable import WALICatalog

@Suite("Canonical catalog JSON")
struct CanonicalJSONTests {
    @Test("Accepts compact NFC JSON with shortest escapes")
    func acceptsCanonicalBytes() throws {
        let data = Data(#"{"schema":{"epoch":1,"revision":0},"name":"café\nwall"}"#.utf8)
        let document = try CanonicalJSON.requireCanonical(
            data,
            limits: .init(
                maximumDocumentBytes: 1_024,
                maximumDepth: 3,
                maximumCollectionCount: 8
            )
        )
        #expect(document.data == data)
    }

    @Test("Rejects duplicate keys before Foundation decoding")
    func rejectsDuplicateKeys() {
        expectCatalogError(.duplicateJSONKey) {
            _ = try CanonicalJSON.requireCanonical(
                Data(#"{"epoch":1,"epoch":1}"#.utf8),
                limits: .manifest
            )
        }
    }

    @Test("Rejects whitespace, trailing newline, and long-form escapes")
    func rejectsNonCanonicalRepresentations() {
        for value in [#"{"a": 1}"#, "{\"a\":1}\n", #"{"a":"\u0061"}"#] {
            expectCatalogError(.invalidCanonicalJSON) {
                _ = try CanonicalJSON.requireCanonical(Data(value.utf8), limits: .manifest)
            }
        }
    }

    @Test("Rejects floating point and exponent forms")
    func rejectsFloatingPointNumbers() {
        for value in [#"{"n":1.0}"#, #"{"n":1e3}"#] {
            expectCatalogError(.floatingPointNumber) {
                _ = try CanonicalJSON.requireCanonical(Data(value.utf8), limits: .manifest)
            }
        }
    }

    @Test("Rejects non-NFC strings and oversized documents")
    func rejectsNormalizationAndSizeViolations() {
        let decomposed = "{\"name\":\"cafe\u{301}\"}"
        expectCatalogError(.invalidCanonicalJSON) {
            _ = try CanonicalJSON.requireCanonical(Data(decomposed.utf8), limits: .manifest)
        }
        expectCatalogError(.documentTooLarge) {
            _ = try CanonicalJSON.requireCanonical(
                Data(#"{"a":1}"#.utf8),
                limits: .init(maximumDocumentBytes: 3, maximumDepth: 2, maximumCollectionCount: 2)
            )
        }
    }
}

func expectCatalogError(
    _ expected: CatalogValidationError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected \(expected.rawValue)")
    } catch let error as CatalogValidationError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
