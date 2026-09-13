import Foundation
import Observation
import WALICatalogRuntime

@MainActor
@Observable
public final class AccountDeletionReceiptModel {
    public private(set) var receipts: [AccountDeletionReceiptSummary] = []
    public private(set) var errorMessage: String?
    public private(set) var unavailableIDs: Set<String> = []
    private let store: AccountDeletionReceiptStore
    private var task: Task<Void, Never>?
    private var visible = false
    private var generation = UUID()

    public init(store: AccountDeletionReceiptStore) { self.store = store }
    isolated deinit { task?.cancel() }

    public func prepare(subjectID: String, revision: UInt64, key: String) async throws -> AccountDeletionReceiptAdmission {
        let receipt = try await store.prepare(subjectID: subjectID, expectedProfileRevision: revision, idempotencyKey: key)
        await reload()
        if visible { refresh() }
        return receipt
    }
    public func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        generation = UUID()
        task?.cancel()
        if value { refresh() }
    }
    public func refresh() {
        guard visible else { return }
        task?.cancel()
        generation = UUID()
        let current = generation
        unavailableIDs.removeAll()
        task = Task { [weak self] in
            guard let self else { return }
            var delay = 5
            repeat {
                await reload()
                guard !Task.isCancelled, visible, generation == current else { return }
                let pending = receipts.filter { $0.needsRefresh && !unavailableIDs.contains($0.id) }
                guard !pending.isEmpty else { return }
                for receipt in pending {
                    do {
                        _ = try await store.refresh(id: receipt.id)
                        guard !Task.isCancelled, visible, generation == current else { return }
                        errorMessage = nil
                    } catch is CancellationError { return }
                    catch AccountDeletionReceiptError.statusUnavailable {
                        guard !Task.isCancelled, generation == current else { return }
                        unavailableIDs.insert(receipt.id)
                    } catch {
                        guard !Task.isCancelled, generation == current else { return }
                        errorMessage = "Status could not be refreshed. WALI will retry while this page is open."
                    }
                }
                await reload()
                guard receipts.contains(where: { $0.needsRefresh && !unavailableIDs.contains($0.id) }) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                delay = min(60, delay * 2)
            } while visible && !Task.isCancelled && generation == current
        }
    }
    public func dismiss(id: String) {
        task?.cancel()
        generation = UUID()
        task = Task { [weak self] in
            guard let self else { return }
            do { try await store.dismiss(id: id); await reload(); if visible { refresh() } }
            catch { errorMessage = "The status record could not be removed from this Mac." }
        }
    }
    public func reload() async {
        do { receipts = try await store.summaries() }
        catch { errorMessage = "Deletion status storage is unavailable. Try again before requesting deletion." }
    }
}
