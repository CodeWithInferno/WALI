import Foundation

public struct CreatorTermsDocument: Sendable, Equatable, Identifiable {
    public struct Section: Sendable, Equatable, Identifiable {
        public let title: String
        public let paragraphs: [String]
        public var id: String { title }
        public init(title: String, paragraphs: [String]) { self.title = title; self.paragraphs = paragraphs }
    }
    public let version: String
    public let title: String
    public let status: String
    public let introduction: String
    public let sections: [Section]
    public var id: String { version }

    public static func supported(version: String) -> CreatorTermsDocument? {
        version == current.version ? current : nil
    }

    private static let current = CreatorTermsDocument(
        version: "2026-09-12",
        title: "WALI Creator Content License",
        status: "Effective 12 September 2026",
        introduction: "Read these permissions and responsibilities before enabling Creator publishing for your account.",
        sections: [
            Section(title: "Your account and acceptance", paragraphs: [
                "By accepting this version, you agree to these terms for the content you upload to WALI. Use your own active account and provide accurate submission information. You must be able to grant the permissions described below.",
                "Ordinary Creator publishing uses your signed-in account. Two-factor authentication is not required for your own uploads. Each upload also requires your explicit rights declaration and selected content license.",
            ]),
            Section(title: "Ownership and credits", paragraphs: [
                "You and the applicable rights holders keep ownership. Uploading or processing a work does not transfer ownership to WALI.",
                "Identify the actual rights holder and original author, retain required credits, and provide the source when required. If you publish licensed work, your account is its publisher; do not claim to be its original author.",
            ]),
            Section(title: "Permission and the selected license", paragraphs: [
                "Upload only work you created, work you have permission to publish under the selected license, or work you can accurately identify as public domain. Buying or downloading a file, or giving credit, does not by itself grant permission to redistribute it.",
                "To the extent you hold the necessary rights, you grant WALI and its service providers a non-exclusive, worldwide, royalty-free permission to securely receive, inspect, classify, transcode, resize, make technical delivery copies, host, distribute through WALI, and display the submitted work to operate the wallpaper service. This includes delivering permitted copies for users to download and display as wallpapers.",
                "Select only a content license you are authorized to grant. That license controls end-user use; these terms do not expand it. The WALI Wallpaper Use License permits attributed wallpaper use and WALI delivery, without granting users standalone resale, rehosting, or creative derivative rights. Other license options apply only when expressly selected and authorized.",
            ]),
            Section(title: "Your rights declaration", paragraphs: [
                "Confirm that the named rights holder, source, license, and attribution are accurate, and that your permission covers every selected work and the required hosting, processing, distribution, and wallpaper display.",
                "Obtain any necessary permissions for third-party artwork, identifiable people, trademarks, characters, music, and private information. Keep your permission or public-domain evidence and cooperate with a substantiated rights inquiry. Do not upload private agreements as public metadata.",
            ]),
            Section(title: "Content and automatic publication", paragraphs: [
                "Do not upload infringing, unlawful, malicious, deceptive, or nonconsensual content; sexual exploitation of minors; credible threats; targeted harassment; or private information without permission. Describe the actual content and provide appropriate content warnings.",
                "After your metadata and rights declaration are saved, WALI processes and verifies the media. Eligible uploads may become public automatically when the checks complete. This is not a claim that a person reviewed the work or that automated checks establish legal rights or guarantee safety.",
                "WALI may reject, restrict, remove, or disable content or accounts for a rights concern, policy violation, security issue, or valid notice. Report inappropriate content using the wallpaper Report action or WALI’s published rights-notice process.",
            ]),
            Section(title: "Removal, records, and later versions", paragraphs: [
                "You may withdraw an eligible pending upload or request removal of a published work through WALI’s published rights-notice process. Removal stops future availability when applied; already downloaded copies remain subject to their content license.",
                "WALI records your acceptance version and submission declaration and may retain bounded permission, moderation, security, and legal-hold records as described in its published privacy and retention policies. No new upload accepts a changed terms version silently; you must review and accept the then-current version.",
            ]),
        ]
    )
}
