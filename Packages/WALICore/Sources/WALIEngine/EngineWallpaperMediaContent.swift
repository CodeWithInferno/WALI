import Foundation

/// A concrete local media family. A raster cannot be mistaken for a video URL.
public enum EngineWallpaperMediaContent: Codable, Sendable, Hashable {
    case video(masterURL: URL, previewURL: URL, duration: TimeInterval)
    case still(imageURL: URL)

    private struct Key: CodingKey, Hashable {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let kind = try values.decode(String.self, forKey: Key("kind"))
        let keys = Set(values.allKeys.map(\.stringValue))
        switch kind {
        case "video":
            guard keys == ["kind", "master_url", "preview_url", "duration_seconds"] else {
                throw Self.invalid(decoder.codingPath)
            }
            self = .video(
                masterURL: try values.decode(URL.self, forKey: Key("master_url")),
                previewURL: try values.decode(URL.self, forKey: Key("preview_url")),
                duration: try values.decode(TimeInterval.self, forKey: Key("duration_seconds"))
            )
        case "still":
            guard keys == ["kind", "image_url"] else { throw Self.invalid(decoder.codingPath) }
            self = .still(imageURL: try values.decode(URL.self, forKey: Key("image_url")))
        default:
            throw Self.invalid(decoder.codingPath)
        }
        try validate(codingPath: decoder.codingPath)
    }

    public func encode(to encoder: any Encoder) throws {
        try validate(codingPath: encoder.codingPath)
        var values = encoder.container(keyedBy: Key.self)
        switch self {
        case let .video(masterURL, previewURL, duration):
            try values.encode("video", forKey: Key("kind"))
            try values.encode(masterURL, forKey: Key("master_url"))
            try values.encode(previewURL, forKey: Key("preview_url"))
            try values.encode(duration, forKey: Key("duration_seconds"))
        case let .still(imageURL):
            try values.encode("still", forKey: Key("kind"))
            try values.encode(imageURL, forKey: Key("image_url"))
        }
    }

    private func validate(codingPath: [any CodingKey]) throws {
        switch self {
        case let .video(masterURL, previewURL, duration):
            guard Self.valid(masterURL), Self.valid(previewURL), duration.isFinite,
                  duration > 0, duration <= 86_400 else { throw Self.invalid(codingPath) }
        case let .still(imageURL):
            guard Self.valid(imageURL) else { throw Self.invalid(codingPath) }
        }
    }

    private static func valid(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.user == nil && url.password == nil && url.port == nil &&
            url.query == nil && url.fragment == nil && url.path.hasPrefix("/") &&
            url.path.utf8.count <= 4_096 && !url.path.utf8.contains(0)
    }

    private static func invalid(_ path: [any CodingKey]) -> DecodingError {
        .dataCorrupted(.init(codingPath: path, debugDescription: "Invalid typed wallpaper media."))
    }
}
