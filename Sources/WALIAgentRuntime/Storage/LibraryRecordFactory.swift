import Foundation
import WALIEngine
import WALIModel

enum LibraryRecordFactoryError: LocalizedError {
    case incompleteArtifactSet
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .incompleteArtifactSet:
            "The transcoder did not produce a complete wallpaper."
        case .invalidDuration:
            "The transcoded wallpaper has an invalid duration."
        }
    }
}

enum LibraryRecordFactory {
    static func makeRecord(
        itemID: UUID,
        displayName proposedName: String,
        sourceFileName: String,
        sourceDigest: ContentDigest,
        artifacts storedArtifacts: [StoredArtifact]
    ) throws -> CommittedLibraryRecord {
        guard let master = storedArtifacts.first(where: { $0.role == .masterVideo }),
              let preview = storedArtifacts.first(where: { $0.role == .previewVideo }),
              let poster = storedArtifacts.first(where: { $0.role == .posterImage })
        else {
            throw LibraryRecordFactoryError.incompleteArtifactSet
        }

        let releaseID = try AssetReleaseID(canonicalUUID())
        let masterVariantID = try AssetVariantID(canonicalUUID())
        let previewVariantID = try AssetVariantID(canonicalUUID())
        let artifacts = try storedArtifacts.map(makeArtifact)
        let variants = [
            try AssetVariant(
                id: masterVariantID,
                qualityTier: .high,
                rendererRequirement: .init(rendererID: .waliVideo),
                bindings: [.init(role: .waliPlayback, artifactID: master.digest)]
            ),
            try AssetVariant(
                id: previewVariantID,
                qualityTier: .preview,
                rendererRequirement: .init(rendererID: .waliVideo),
                bindings: [.init(role: .waliPlayback, artifactID: preview.digest)]
            ),
        ]
        let release = try AssetRelease(
            schema: .current,
            id: releaseID,
            assetID: AssetID(canonicalUUID()),
            edition: 1,
            artifacts: artifacts,
            posterArtifactID: poster.digest,
            variants: variants,
            defaultVariantID: masterVariantID
        )
        let item = try LibraryItem(
            schema: .current,
            id: LibraryItemID(itemID.uuidString.lowercased()),
            releaseID: releaseID,
            displayName: boundedName(proposedName, maximumUTF8Bytes: LibraryItem.maximumDisplayNameUTF8Length),
            origin: .localImport
        )
        return try CommittedLibraryRecord(
            item: item,
            release: release,
            sourceDigest: sourceDigest,
            sourceFileName: boundedName(sourceFileName, maximumUTF8Bytes: 1_024),
            artifacts: storedArtifacts
        )
    }

    static func makeEngineItem(
        from record: CommittedLibraryRecord,
        preserving existing: EngineLibraryItem? = nil
    ) throws -> EngineLibraryItem {
        guard let master = record.artifacts.first(where: { $0.role == .masterVideo }),
              let masterURL = record.masterURL,
              let previewURL = record.previewURL,
              let posterURL = record.posterURL,
              let duration = master.durationSeconds,
              duration.isFinite,
              duration > 0,
              let id = UUID(uuidString: record.item.id.rawValue)
        else {
            throw LibraryRecordFactoryError.incompleteArtifactSet
        }
        return EngineLibraryItem(
            id: id,
            name: existing?.name ?? record.item.displayName,
            createdAt: record.importedAt,
            duration: duration,
            pixelWidth: Int(master.pixelSize.width),
            pixelHeight: Int(master.pixelSize.height),
            masterURL: masterURL,
            previewURL: previewURL,
            posterURL: posterURL,
            contentDigest: record.sourceDigest.value,
            byteCount: record.artifacts.reduce(0) { $0 &+ $1.byteCount },
            isFavorite: existing?.isFavorite ?? false
        )
    }

    private static func makeArtifact(_ stored: StoredArtifact) throws -> Artifact {
        let duration: MediaRational?
        if let seconds = stored.durationSeconds {
            guard seconds.isFinite, seconds > 0, seconds < Double(UInt64.max) / 1_000 else {
                throw LibraryRecordFactoryError.invalidDuration
            }
            duration = try MediaRational(
                numerator: UInt64((seconds * 1_000).rounded()),
                denominator: 1_000
            )
        } else {
            duration = nil
        }
        return try Artifact(
            schema: .current,
            contentID: stored.digest,
            byteCount: stored.byteCount,
            mediaType: stored.mediaKind == .hevcVideo ? .waliVideoHEVC : .waliImageHEIC,
            // Every newly installed HEVC artifact reaches this point only after
            // ContentStorage has independently verified Aerial-compatible
            // SDR BT.709 Main10 bytes.
            characteristics: MediaCharacteristics(
                pixelSize: stored.pixelSize,
                duration: duration,
                bitDepth: stored.mediaKind == .hevcVideo ? 10 : nil,
                dynamicRange: stored.mediaKind == .hevcVideo ? .sdr : nil
            )
        )
    }

    private static func canonicalUUID() -> String {
        UUID().uuidString.lowercased()
    }

    private static func boundedName(_ value: String, maximumUTF8Bytes: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Untitled Wallpaper" : trimmed
        var result = ""
        for character in candidate {
            let next = result + String(character)
            guard next.utf8.count <= maximumUTF8Bytes else { break }
            result = next
        }
        return result.isEmpty ? "Untitled" : result
    }
}
