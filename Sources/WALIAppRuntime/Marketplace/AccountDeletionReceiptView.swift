import SwiftUI
import WALICatalogRuntime

struct AccountDeletionReceiptView: View {
    let model: AccountDeletionReceiptModel
    @State private var dismissID: String?
    var body: some View {
        Section("Deletion Requests on This Mac") {
            Text("These status records are separate from the account currently signed in. Keep this app to check an unfinished request. Server status remains available until 30 days after deletion completes.")
                .foregroundStyle(.secondary)
            ForEach(model.receipts) { receipt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(receipt.requestedAt, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline.weight(.semibold))
                    if let confirmation = receipt.confirmation {
                        Label("Account deletion completed", systemImage: "checkmark.circle")
                        Text(confirmation.completedAt, format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                        Text("Server status access ends \(confirmation.completedAt.addingTimeInterval(30 * 86_400), format: .dateTime.year().month().day()). This local confirmation remains until you dismiss it.")
                            .foregroundStyle(.secondary)
                        retainedCategories(confirmation.retainedCategories)
                        if confirmation.appleActionRequired { appleRecovery }
                    } else if model.unavailableIDs.contains(receipt.id) {
                        Text("Status is unavailable. The request may not have been accepted, or its status-access period may have ended. This does not confirm deletion.")
                            .foregroundStyle(.secondary)
                    } else if let status = receipt.status {
                        Text(label(status))
                        Text(status.status == .cancelled ? "This request was cancelled; it does not confirm deletion." : "Deletion has not completed yet. Closing the app does not cancel an accepted request.")
                            .foregroundStyle(.secondary)
                        retainedCategories(status.retainedCategories)
                        if status.appleActionRequired { appleRecovery }
                    } else {
                        Text("Checking whether the request was accepted…").foregroundStyle(.secondary)
                    }
                    Button(receipt.confirmation == nil ? "Remove Status from This Mac…" : "Dismiss Confirmation") {
                        if receipt.confirmation == nil { dismissID = receipt.id }
                        else { model.dismiss(id: receipt.id) }
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.secondary) }
            if !model.receipts.isEmpty { Button("Refresh Deletion Status") { model.refresh() } }
        }
        .accessibilityIdentifier("WALI.Account.DeletionReceipts")
        .confirmationDialog("Remove this status record?", isPresented: Binding(get: { dismissID != nil }, set: { if !$0 { dismissID = nil } })) {
            Button("Remove Status", role: .destructive) { if let id = dismissID { model.dismiss(id: id) }; dismissID = nil }
        } message: {
            Text("This does not cancel account deletion. You will lose this Mac’s access to the request’s status.")
        }
    }
    private func label(_ status: AccountDeletionReceiptStatus) -> String {
        if status.status == .cancelled { return "Account deletion cancelled" }
        if status.status == .failed { return "Account deletion will be retried" }
        return switch status.stage {
        case .cleanup: "Removing account data and hosted uploads"
        case .held: "Waiting for a required review"
        case .appleRevocation: "Removing Apple sign-in access"
        case .identityDeletion: "Finishing account deletion"
        case .retrying: "Retrying account deletion"
        case .completed: "Account deletion completed"
        }
    }
    @ViewBuilder private func retainedCategories(_ categories: [String]) -> some View {
        if !categories.isEmpty { Text("Retained records: " + categories.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
    }
    private var appleRecovery: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This older account has no stored Apple revocation credential. Remove WALI from Sign in with Apple in your Apple Account settings.")
            Link("Open Apple Account", destination: URL(string: "https://account.apple.com")!)
        }.font(.caption)
    }
}
