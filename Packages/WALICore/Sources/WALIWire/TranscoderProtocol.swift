import Foundation

public struct TranscoderRequest: Codable, Sendable, Hashable {
    public let protocolVersion: UInt16
    public let jobID: UUID
    public let sourceBookmark: Data
    public let outputDirectory: URL

    public init(
        protocolVersion: UInt16 = WALIProtocol.currentVersion,
        jobID: UUID,
        sourceBookmark: Data,
        outputDirectory: URL
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.sourceBookmark = sourceBookmark
        self.outputDirectory = outputDirectory
    }
}

public struct TranscoderOutput: Codable, Sendable, Hashable {
    public let jobID: UUID
    public let displayName: String
    public let duration: TimeInterval
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let masterURL: URL
    public let previewURL: URL
    public let posterURL: URL
    public let sourceDigest: String

    public init(
        jobID: UUID,
        displayName: String,
        duration: TimeInterval,
        pixelWidth: Int,
        pixelHeight: Int,
        masterURL: URL,
        previewURL: URL,
        posterURL: URL,
        sourceDigest: String
    ) {
        self.jobID = jobID
        self.displayName = displayName
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.masterURL = masterURL
        self.previewURL = previewURL
        self.posterURL = posterURL
        self.sourceDigest = sourceDigest
    }
}

@objc public protocol WALITranscoderXPCProtocol {
    func transcode(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func cancel(_ jobID: UUID, withReply reply: @escaping (NSError?) -> Void)
}
