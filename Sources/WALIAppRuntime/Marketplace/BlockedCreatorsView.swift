import SwiftUI
import WALICatalogRuntime
import WALIUI

struct BlockedCreatorsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CreatorBlockingModel
    @State private var blockPage = 0
    @State private var actionError: String?
    var body: some View {
        VStack(spacing: 0) {
            WALIPageHeader("Blocked Creators") { EmptyView() }
            Form {
                Section {
                    Text(model.subjectID == nil ? "These choices are saved on this Mac while you’re signed out. They are kept separate from every account." : "These choices are private and apply to your account. Creators are not notified.")
                    Text("Existing wallpapers stay in your Library. Unblocking restores catalog visibility.").foregroundStyle(.secondary)
                }
                if !model.isReady {
                    Section {
                        if let message = model.failureMessage {
                            Text(message)
                            Button("Try Again") { reload() }
                        } else { ProgressView("Loading creator preferences…") }
                    }
                } else {
                    Section("Blocked Creators") {
                        if model.blockedCreatorIDs.isEmpty { Text("No blocked creators").foregroundStyle(.secondary) }
                        ForEach(Array(model.blockedCreatorIDs.sorted().dropFirst(blockPage * 100).prefix(100)), id: \.self) { id in
                            HStack {
                                Text(model.rows.first(where: { $0.creatorID == id })?.displayName ?? id)
                                    .lineLimit(2).textSelection(.enabled)
                                Spacer()
                                Button("Unblock") { Task { do { try await model.setBlocked(creatorID: id, desired: false) } catch { actionError = "That creator couldn’t be unblocked. Try again." } } }
                                    .disabled(model.isWorking)
                            }
                        }
                    }
                    if model.blockedCreatorIDs.count > 100 {
                        HStack {
                            Button("Previous") { blockPage -= 1 }.disabled(blockPage == 0)
                            Text("Page \(blockPage + 1)").foregroundStyle(.secondary)
                            Button("Next") { blockPage += 1 }.disabled((blockPage + 1) * 100 >= model.blockedCreatorIDs.count)
                        }
                    }
                    if model.subjectID != nil {
                        Section("Hidden Saved Items and Follows") {
                            Text("Blocking keeps your existing saves, favorites and follows. You can remove those choices here without unblocking.")
                                .foregroundStyle(.secondary)
                            Button("Load Hidden Choices") { Task { do { try await model.loadHiddenInteractions() } catch { actionError = "Hidden choices couldn’t be loaded. Try again." } } }
                            ForEach(model.hiddenInteractions) { item in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.kind.rawValue.capitalized)
                                        Text(item.targetID).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button("Remove") { Task { do { try await model.removeHiddenInteraction(item) } catch { actionError = "That choice couldn’t be removed. Reload and try again." } } }
                                        .disabled(model.isWorking)
                                }
                            }
                            if model.hiddenNextCursor != nil {
                                Button("Next Page") { Task { do { try await model.loadHiddenInteractions(more: true) } catch { actionError = "The list changed. Load hidden choices again." } } }
                            }
                        }
                    }
                }
                if let message = actionError ?? model.failureMessage { Section { Label(message, systemImage: "exclamationmark.triangle") } }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { reload() }
        .onChange(of: model.blockedCreatorIDs) { _, _ in blockPage = 0 }
        .accessibilityIdentifier("WALI.Account.BlockedCreators")
    }
    private func reload() {
        actionError = nil
        Task { do { _ = try await model.refresh() } catch { /* The model carries the safe retry message. */ } }
    }
}
