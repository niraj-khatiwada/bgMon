import Foundation
let fixture = "p123\nf4\nn127.0.0.1:3000\nf5\nn[::1]:3000\nf6\nn*:8080\np456\nn*:5000\n"
let parsed = ListeningPorts.parse(fixture)
assert(parsed[123] == [3000, 8080])
assert(parsed[456] == [5000])
assert(ListeningPorts.parse("").isEmpty)
let live = ListeningPorts.scan()
print("Parser passed; listening ports detected for \(live.count) processes")
