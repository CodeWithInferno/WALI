#if WALI_APP_STORE
import Foundation
import WALIWire

/// The file importer returns a user-selected readonly URL. Only a transient
/// implicit grant crosses to the agent; the foreground never persists it.
@MainActor
enum ForegroundImportBookmarks {
    @MainActor
    struct Access {
        var begin: (URL) -> Bool
        var end: (URL) -> Void
        var bookmark: (URL) throws -> Data

        static let selectedFile = Access(
            begin: { $0.startAccessingSecurityScopedResource() },
            end: { $0.stopAccessingSecurityScopedResource() },
            bookmark: { try $0.bookmarkData(options: [.minimalBookmark]) }
        )
    }

    static func make(for urls: [URL], access: Access = .selectedFile) throws -> [Data] {
        guard urls.count <= 32 else {
            throw AgentFailure(code: .invalidRequest, message: "Import up to 32 videos at a time.")
        }
        return try urls.map { url in
            guard url.isFileURL, access.begin(url) else {
                throw AgentFailure(code: .invalidRequest, message: "Choose this video again to allow WALI to read it.")
            }
            defer { access.end(url) }
            let bookmark = try access.bookmark(url)
            guard bookmark.count <= StoreImportGrant.maximumBookmarkBytes else {
                throw AgentFailure(code: .invalidRequest, message: "This video access grant is too large.")
            }
            return try StoreImportGrantCodec.encode(StoreImportGrant(bookmark: bookmark))
        }
    }
}
#endif
