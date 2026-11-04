import Foundation
let sampler = CPUSampler()
let idle = Process()
idle.executableURL = URL(fileURLWithPath: "/bin/sleep")
idle.arguments = ["10"]
let busy = Process()
busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
busy.standardOutput = FileHandle.nullDevice
try idle.run()
try busy.run()
defer { idle.terminate(); busy.terminate(); idle.waitUntilExit(); busy.waitUntilExit() }
assert(sampler.display(pid: idle.processIdentifier) == "—")
assert(sampler.display(pid: busy.processIdentifier) == "—")
Thread.sleep(forTimeInterval: 2)
let low = Double(sampler.display(pid: idle.processIdentifier))!
let high = Double(sampler.display(pid: busy.processIdentifier))!
print("Idle: \(low)% · Busy: \(high)%")
assert(low < 5)
assert(high > 50 && high < 120)
