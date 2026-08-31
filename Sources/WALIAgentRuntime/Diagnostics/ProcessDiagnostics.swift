import Darwin
import Foundation

public struct ProcessResourceSample: Sendable, Hashable {
    public let timestamp: Date
    /// Process CPU where one fully occupied core is approximately 100 percent.
    public let cpuPercent: Double
    /// Dirty and compressed physical footprint, in bytes.
    public let physicalMemoryBytes: UInt64

    public init(timestamp: Date, cpuPercent: Double, physicalMemoryBytes: UInt64) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

/// Lifetime token for demand-driven process diagnostics.
public final class ProcessDiagnosticsLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    fileprivate init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    public func invalidate() {
        let action = lock.withLock {
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }

    deinit {
        invalidate()
    }
}

/// Samples only while at least one lease exists and retains at most 60 values.
@MainActor
public final class ProcessDiagnostics {
    public typealias SampleHandler = @MainActor (ProcessResourceSample) -> Void

    public private(set) var history: [ProcessResourceSample] = []

    private var handlers: [UUID: SampleHandler] = [:]
    private var timer: Timer?
    private var baseline: CPUBaseline?

    public init() {}

    public func acquireLease(onSample: @escaping SampleHandler) -> ProcessDiagnosticsLease {
        let id = UUID()
        handlers[id] = onSample
        startSamplingIfNeeded()

        return ProcessDiagnosticsLease { [weak self] in
            Task { @MainActor in
                self?.releaseLease(id)
            }
        }
    }

    private func startSamplingIfNeeded() {
        guard timer == nil else { return }
        baseline = currentCPUBaseline()
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func releaseLease(_ id: UUID) {
        handlers.removeValue(forKey: id)
        guard handlers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        baseline = nil
        history.removeAll(keepingCapacity: false)
    }

    private func sample() {
        guard !handlers.isEmpty else { return }
        let nextBaseline = currentCPUBaseline()
        let cpuPercent = baseline.map { previous in
            let elapsed = max(nextBaseline.wallSeconds - previous.wallSeconds, 0.000_001)
            let consumed = max(nextBaseline.cpuSeconds - previous.cpuSeconds, 0)
            return consumed / elapsed * 100
        } ?? 0
        baseline = nextBaseline

        let sample = ProcessResourceSample(
            timestamp: Date(),
            cpuPercent: cpuPercent.isFinite ? cpuPercent : 0,
            physicalMemoryBytes: physicalFootprint()
        )
        history.append(sample)
        if history.count > 60 {
            history.removeFirst(history.count - 60)
        }
        let currentHandlers = Array(handlers.values)
        for handler in currentHandlers {
            handler(sample)
        }
    }

    private func currentCPUBaseline() -> CPUBaseline {
        var usage = rusage()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            getrusage(RUSAGE_SELF, pointer)
        }
        let cpuSeconds: Double
        if result == 0 {
            cpuSeconds = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        } else {
            cpuSeconds = 0
        }
        return CPUBaseline(
            wallSeconds: ProcessInfo.processInfo.systemUptime,
            cpuSeconds: cpuSeconds
        )
    }

    private func seconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    private func physicalFootprint() -> UInt64 {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return information.phys_footprint
    }

    private struct CPUBaseline {
        let wallSeconds: TimeInterval
        let cpuSeconds: TimeInterval
    }
}
