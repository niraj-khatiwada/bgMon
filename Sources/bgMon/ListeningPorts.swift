import Foundation

enum ListeningPorts {
    static func parse(_ text: String) -> [Int32: [Int]] {
        var result: [Int32: Set<Int>] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            else if line.first == "n", let pid,
                    let suffix = line.split(separator: ":").last,
                    let port = Int(suffix), (1...65535).contains(port) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }
    static func scan() -> [Int32: [Int]] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }
}
