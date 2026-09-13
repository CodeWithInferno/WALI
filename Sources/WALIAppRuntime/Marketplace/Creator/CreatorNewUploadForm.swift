import Foundation
import Observation
import SwiftUI
import WALICatalogRuntime

@MainActor
@Observable
final class CreatorUploadDraftModel {
    var title: String
    var description = ""
    var categoryID: UUID?
    var selectedTagIDs: Set<UUID> = []
    var contentWarning = ""
    var rightsBasis: CreatorRightsBasis = .original
    var rightsHolder = ""
    var licenseID: UUID?
    var sourceURL = ""
    var attributionText = ""
    var attestsRights = false

    init(title: String = "") { self.title = title }

    func makeDraft(
        categories: [CreatorTaxonomyOption], tags: [CreatorTaxonomyOption], licenses: [CreatorLicenseOption]
    ) throws -> CreatorDraft {
        guard let categoryID, categories.contains(where: { $0.id == categoryID }),
              selectedTagIDs.isSubset(of: Set(tags.map(\.id))),
              let license = licenses.first(where: { $0.id == licenseID }),
              [.original, .licensed, .publicDomain].contains(rightsBasis) else {
            throw CreatorContractError.invalidRequest
        }
        let source = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution = attributionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedSource = source.isEmpty ? nil : URL(string: source)
        guard source.isEmpty || parsedSource != nil else {
            throw CreatorContractError.rightsIncomplete
        }
        let requirements = creatorRightsRequirements(basis: rightsBasis, license: license)
        let rights = try CreatorRightsDeclaration(
            basis: rightsBasis, rightsHolder: rightsHolder.trimmingCharacters(in: .whitespacesAndNewlines),
            licenseID: license.id, sourceURL: parsedSource,
            attributionText: attribution.isEmpty ? nil : attribution, proofObjectIDs: [],
            attestsRights: attestsRights, requirements: requirements
        )
        let draft = try CreatorDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines), primaryCategoryID: categoryID,
            suggestedTagIDs: selectedTagIDs.sorted { $0.uuidString < $1.uuidString },
            contentWarning: contentWarning.isEmpty ? nil : contentWarning, rights: rights
        )
        try draft.validateForUpload()
        return draft
    }
}

struct CreatorNewUploadForm: View {
    let fileName: String
    let categories: [CreatorTaxonomyOption]
    let tags: [CreatorTaxonomyOption]
    let licenses: [CreatorLicenseOption]
    let currentTermsVersion: String
    let onUpload: (CreatorDraft) -> Void
    let onCancel: () -> Void
    @State private var model: CreatorUploadDraftModel
    @State private var errorMessage: String?

    init(fileName: String, categories: [CreatorTaxonomyOption], tags: [CreatorTaxonomyOption],
         licenses: [CreatorLicenseOption], currentTermsVersion: String,
         onUpload: @escaping (CreatorDraft) -> Void, onCancel: @escaping () -> Void) {
        self.fileName = fileName
        self.categories = categories
        self.tags = tags
        self.licenses = licenses
        self.currentTermsVersion = currentTermsVersion
        self.onUpload = onUpload
        self.onCancel = onCancel
        _model = State(initialValue: CreatorUploadDraftModel(title: String(URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.prefix(120))))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upload Wallpaper").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(fileName)
                }
                Spacer()
            }.padding(20)
            Form {
                Section("Wallpaper details") {
                    TextField("Title", text: $model.title)
                        .accessibilityHint("Up to 120 characters")
                    TextField("Description", text: $model.description, axis: .vertical).lineLimit(3...6)
                    Picker("Category", selection: $model.categoryID) {
                        Text("Choose a category").tag(UUID?.none)
                        ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Menu("Tags (\(model.selectedTagIDs.count)/20)") {
                        ForEach(tags) { tag in
                            Toggle(tag.name, isOn: Binding(
                                get: { model.selectedTagIDs.contains(tag.id) },
                                set: { selected in
                                    if selected, model.selectedTagIDs.count < 20 { model.selectedTagIDs.insert(tag.id) }
                                    else if !selected { model.selectedTagIDs.remove(tag.id) }
                                }
                            ))
                            .disabled(model.selectedTagIDs.count >= 20 && !model.selectedTagIDs.contains(tag.id))
                        }
                    }
                    .help("Choose up to 20 tags")
                    TextField("Content warning (optional)", text: $model.contentWarning)
                }
                RightsDeclarationView(
                    basis: $model.rightsBasis, rightsHolder: $model.rightsHolder,
                    selectedLicenseID: $model.licenseID, sourceURL: $model.sourceURL,
                    attributionText: $model.attributionText, proofObjectIDs: .constant([]),
                    attestsRights: $model.attestsRights, acceptsCurrentTerms: .constant(true),
                    licenses: licenses, currentTermsVersion: currentTermsVersion, showTermsAcceptance: false
                )
                Section {
                    Text("Your wallpaper will appear in the catalog automatically after processing and verification. Its rights holder, license, and supplied credits will be public.")
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.formStyle(.grouped)
                .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Upload and Publish") {
                    do { onUpload(try model.makeDraft(categories: categories, tags: tags, licenses: licenses)) }
                    catch {
                        errorMessage = "Add a title, description, category, license, rights holder, required source and credits, and confirm your permission."
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.attestsRights)
            }.padding(20)
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
