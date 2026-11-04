import Foundation
import Darwin

final class CPUSampler: @unchecked Sendable {
    private struct Sample {
        let start: UInt64
        let cpu: UInt64
        let time: UInt64
    }
    private let lock = NSLock()
    private var samples: [Int32: Sample] = [:]

    func display(pid: Int32) -> String {
        lock.lock()
        defer { lock.unlock() }
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { samples.removeValue(forKey: pid); return "—" }
        let sample = Sample(start: usage.ri_proc_start_abstime,
                            cpu: usage.ri_user_time + usage.ri_system_time,
                            time: mach_absolute_time())
        let previous = samples.updateValue(sample, forKey: pid)
        guard let previous, previous.start == sample.start,
              sample.cpu >= previous.cpu, sample.time > previous.time else { return "—" }
        let percent = Double(sample.cpu - previous.cpu) / Double(sample.time - previous.time) * 100
        return String(format: "%.1f", percent)
    }
    func prune(livePIDs: Set<Int32>) {
        lock.lock()
        defer { lock.unlock() }
        samples = samples.filter { livePIDs.contains($0.key) }
    }
}
