import Foundation
import Testing
@testable import WALIEngine

@Suite("Engine media migration")
struct EngineMediaMigrationTests {
    @Test("Historic video item migrates without changing identity or media URLs")
    func legacyVideo() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Existing","createdAt":0,"duration":12.5,"pixelWidth":3840,"pixelHeight":2160,"masterURL":"file:///tmp/master.mp4","previewURL":"file:///tmp/preview.mp4","posterURL":"file:///tmp/poster.heic","contentDigest":"old","byteCount":123,"isFavorite":true}"#
        let item = try JSONDecoder().decode(EngineLibraryItem.self, from: Data(json.utf8))
        #expect(item.id.uuidString.lowercased() == "00000000-0000-0000-0000-000000000001")
        #expect(item.isFavorite && item.byteCount == 123)
        guard case let .video(master, preview, duration) = item.mediaContent else {
            Issue.record("Legacy video became a still"); return
        }
        #expect(master.path == "/tmp/master.mp4" && preview.path == "/tmp/preview.mp4" && duration == 12.5)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(encoded["masterURL"] == nil && encoded["duration"] == nil)
        #expect(encoded["mediaContent"] != nil)
    }

    @Test("Still item round-trips with no fabricated video fields")
    func stillRoundTrip() throws {
        let item = EngineLibraryItem(id: UUID(), name: "Still", createdAt: Date(), mediaContent: .still(imageURL: URL(fileURLWithPath: "/tmp/image.png")), pixelWidth: 100, pixelHeight: 100, posterURL: URL(fileURLWithPath: "/tmp/poster.heic"), contentDigest: "digest")
        #expect(try JSONDecoder().decode(EngineLibraryItem.self, from: JSONEncoder().encode(item)) == item)
    }
}
