import Foundation
import Testing
@testable import WALIEngine

@Suite("Typed wallpaper media")
struct EngineWallpaperMediaContentTests {
    @Test("Video and still retain distinct exact wire shapes")
    func roundTrip() throws {
        let image = EngineWallpaperMediaContent.still(imageURL: URL(fileURLWithPath: "/private/image.png"))
        let video = EngineWallpaperMediaContent.video(masterURL: URL(fileURLWithPath: "/private/master.mp4"), previewURL: URL(fileURLWithPath: "/private/preview.mp4"), duration: 12.5)
        for value in [image, video] {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(EngineWallpaperMediaContent.self, from: data) == value)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if case .still = value {
                #expect(Set(object.keys) == ["kind", "image_url"])
                #expect(object["kind"] as? String == "still")
            } else {
                #expect(Set(object.keys) == ["kind", "master_url", "preview_url", "duration_seconds"])
            }
        }
    }

    @Test("Mixed, unknown, missing and unsafe media fields fail closed", arguments: [
        #"{"kind":"still","image_url":"file:///tmp/a.png","duration_seconds":0}"#,
        #"{"kind":"video","master_url":"file:///tmp/a.mp4","preview_url":"file:///tmp/b.mp4","duration_seconds":0}"#,
        #"{"kind":"video","master_url":"file:///tmp/a.mp4","preview_url":"file:///tmp/b.mp4","duration_seconds":86401}"#,
        #"{"kind":"still","image_url":"https://example.com/a.png"}"#,
        #"{"kind":"still","image_url":"file://remote-host/tmp/a.png"}"#,
        #"{"kind":"still","image_url":"file:///tmp/a.png?token=x"}"#,
        #"{"kind":"still"}"#,
        #"{"kind":"future","image_url":"file:///tmp/a.png"}"#
    ])
    func rejectsInvalid(json: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EngineWallpaperMediaContent.self, from: Data(json.utf8)) }
    }

    @Test("Encoding also rejects invalid direct construction")
    func invalidEncoding() {
        #expect(throws: (any Error).self) {
            try JSONEncoder().encode(EngineWallpaperMediaContent.video(masterURL: URL(fileURLWithPath: "/a"), previewURL: URL(fileURLWithPath: "/b"), duration: .infinity))
        }
    }
}
