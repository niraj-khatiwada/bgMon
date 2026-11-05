import Foundation
import Darwin

struct ProcessIdentity: Equatable, Sendable {
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Self(uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}

enum ProcessControl {
    enum Failure: Error {
        case changedOrExited
        case cannotVerify
        case system(Int32)

        var message: String {
            switch self {
            case .changedOrExited: "This process changed or exited. Refresh and try again."
            case .cannotVerify: "Unable to verify this process safely. Refresh and try again."
            case .system(let code): "Unable to stop this process: \(String(cString: strerror(code)))"
            }
        }
    }

    static func validate(pid: Int32, command: String, identity: ProcessIdentity?) -> Failure? {
        guard pid > 1, pid != getpid(), let identity else { return .cannotVerify }
        guard identity.uid == getuid(), ProcessIdentity.read(pid: pid) == identity else { return .changedOrExited }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let pathError = errno
        if count > 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard path == command else { return .changedOrExited }
        } else if pathError != ENOENT {
            return .cannotVerify
        }
        // An uninstalled executable can no longer be resolved by proc_pidpath.
        // Verify the process instance again before allowing a signal in that case.
        guard ProcessIdentity.read(pid: pid) == identity else { return .changedOrExited }
        return nil
    }

    static func stop(pid: Int32, command: String, identity: ProcessIdentity?, force: Bool) -> Failure? {
        if let failure = validate(pid: pid, command: command, identity: identity) { return failure }
        guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else { return .system(errno) }
        return nil
    }
}
