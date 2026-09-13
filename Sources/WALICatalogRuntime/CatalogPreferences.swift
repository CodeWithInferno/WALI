import Foundation

public struct CatalogPreferences: Sendable, Equatable {
    public let userID: String
    public let categoryIDs: [String]
    public let ratingCeiling: String
    public let personalizationOptOut: Bool
    public let revision: UInt64

    public init(userID: String, categoryIDs: [String], ratingCeiling: String,
                personalizationOptOut: Bool, revision: UInt64) throws {
        guard UUID(uuidString: userID)?.uuidString.lowercased() == userID,
              categoryIDs.count <= 12, Set(categoryIDs).count == categoryIDs.count,
              categoryIDs.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              ["everyone", "teen", "mature"].contains(ratingCeiling),
              revision > 0, revision <= 9_007_199_254_740_991 else {
            throw CatalogMappingError.invalidResponse
        }
        self.userID = userID
        self.categoryIDs = categoryIDs.sorted()
        self.ratingCeiling = ratingCeiling
        self.personalizationOptOut = personalizationOptOut
        self.revision = revision
    }
}

struct CatalogPreferencesDTO: Decodable, Sendable {
    let userID: String
    let categoryIDs: [String]
    let ratingCeiling: String
    let personalizationOptOut: Bool
    let revision: UInt64
    enum CodingKeys: String, CodingKey {
        case userID = "user_id", categoryIDs = "category_ids", ratingCeiling = "rating_ceiling"
        case personalizationOptOut = "personalization_opt_out", revision
    }
    func validated() throws -> CatalogPreferences {
        try CatalogPreferences(userID: userID, categoryIDs: categoryIDs, ratingCeiling: ratingCeiling,
                               personalizationOptOut: personalizationOptOut, revision: revision)
    }
}
