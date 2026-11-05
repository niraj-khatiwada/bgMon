import Foundation
import Darwin

let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("bgMon-process-control-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

func startSleeper(name: String) throws -> (Process, String, ProcessIdentity) {
    let executable = directory.appendingPathComponent(name)
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["30"]
    try process.run()
    // Use the kernel path, as ps does, including macOS's /private/var spelling.
    var buffer = [CChar](repeating: 0, count: 4096)
    assert(proc_pidpath(process.processIdentifier, &buffer, UInt32(buffer.count)) > 0)
    return (process, String(cString: buffer), ProcessIdentity.read(pid: process.processIdentifier)!)
}

let (running, path, identity) = try startSleeper(name: "running")
let pid = running.processIdentifier
let staleIdentity = ProcessIdentity(uid: identity.uid, startSeconds: identity.startSeconds - 1, startMicroseconds: identity.startMicroseconds)
assert(ProcessControl.stop(pid: pid, command: path, identity: staleIdentity, force: true) != nil)
assert(ProcessControl.stop(pid: pid, command: path + "-different", identity: identity, force: true) != nil)
assert(ProcessControl.stop(pid: pid, command: path, identity: nil, force: true) != nil)
assert(running.isRunning)
assert(ProcessControl.stop(pid: pid, command: path, identity: identity, force: true) == nil)
running.waitUntilExit()
assert(running.terminationReason == .uncaughtSignal && running.terminationStatus == SIGKILL)

// Reproduce an uninstalled app whose executable no longer exists on disk.
let (deleted, deletedPath, deletedIdentity) = try startSleeper(name: "deleted executable")
try FileManager.default.removeItem(atPath: deletedPath)
assert(ProcessControl.stop(pid: deleted.processIdentifier, command: deletedPath, identity: deletedIdentity, force: true) == nil)
deleted.waitUntilExit()
assert(deleted.terminationReason == .uncaughtSignal && deleted.terminationStatus == SIGKILL)
assert(ProcessControl.stop(pid: deleted.processIdentifier, command: deletedPath, identity: deletedIdentity, force: true) != nil)

let (graceful, gracefulPath, gracefulIdentity) = try startSleeper(name: "graceful")
assert(ProcessControl.stop(pid: graceful.processIdentifier, command: gracefulPath, identity: gracefulIdentity, force: false) == nil)
graceful.waitUntilExit()
assert(!graceful.isRunning)
print("Process control passed: deleted executables, stale identities, path changes, force quit, and normal stop")
