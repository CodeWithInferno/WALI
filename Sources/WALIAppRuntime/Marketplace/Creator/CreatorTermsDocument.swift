import Foundation

public struct CreatorTermsDocument: Sendable, Equatable, Identifiable {
    public struct Section: Sendable, Equatable, Identifiable {
        public let title: String
        public let paragraphs: [String]

        public var id: String { title }

        public init(title: String, paragraphs: [String]) {
            self.title = title
            self.paragraphs = paragraphs
        }
    }

    public let version: String
    public let title: String
    public let status: String
    public let introduction: String
    public let sections: [Section]

    public var id: String { version }

    public static func supported(version: String) -> CreatorTermsDocument? {
        guard version == current.version else { return nil }
        return current
    }

    private static let current = CreatorTermsDocument(
        version: "2026-09-01",
        title: "WALI Creator Content License",
        status: "Draft for counsel review; not yet effective for public UGC",
        introduction: "Review the complete Creator Content License before choosing whether to accept it.",
        sections: [
            Section(
                title: "Ownership",
                paragraphs: [
                    "The creator keeps ownership of uploaded content. WALI receives only the grants needed to review, process, distribute, display, and maintain the marketplace.",
                ]
            ),
            Section(
                title: "License to WALI",
                paragraphs: [
                    "For each submission, the creator grants WALI and its service providers a worldwide, non-exclusive, royalty-free license to copy, transcode, resize, classify, scan, review, host, distribute, publicly display, and make technical derivatives of the submission for operating and securing WALI. The grant must permit users to download the approved release and use it as a wallpaper under the selected content license.",
                    "The marketplace records the chosen license, rights holder, source, attribution, terms revision, and approved release. WALI does not silently broaden that license.",
                ]
            ),
            Section(
                title: "Creator promises",
                paragraphs: [
                    "The creator represents that they:",
                    "own the content or hold written rights sufficient for every grant above;",
                    "have permission for identifiable people, trademarks, characters, music, and other protected material where required;",
                    "accurately state the source, rights holder, license, and attribution;",
                    "are not uploading malicious, deceptive, private, or unlawfully obtained data;",
                    "will preserve rights evidence and cooperate with valid notices.",
                ]
            ),
            Section(
                title: "Removal and survival",
                paragraphs: [
                    "A creator may request delisting. Cached or previously downloaded copies may remain on user devices where the applicable license permits. WALI may retain bounded evidence and audit records for legal and security purposes. WALI may immediately block a release or signing key when safety or rights are in doubt.",
                    "The exact termination, indemnity, jurisdiction, age, and entity provisions require counsel approval before creator uploads are enabled.",
                ]
            ),
        ]
    )
}
