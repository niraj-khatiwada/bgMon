import Foundation

let suite = "bgMon-ignore-tests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

var ignored = WarningIgnoreList(defaults: defaults)
assert(ignored.apps.isEmpty)
ignored.ignore(id: "bundle:com.example.browser", name: "Browser")
ignored.ignore(id: "path:/usr/local/bin/worker", name: "Worker")
assert(ignored.contains("bundle:com.example.browser"))
assert(!ignored.contains("bundle:com.example.other-browser"))

// The list must survive relaunches and retain apps that are no longer running.
var reloaded = WarningIgnoreList(defaults: defaults)
assert(reloaded.apps == ignored.apps)
reloaded.remove("bundle:com.example.browser")
let afterRemoval = WarningIgnoreList(defaults: defaults)
assert(!afterRemoval.contains("bundle:com.example.browser"))
assert(afterRemoval.apps == ["path:/usr/local/bin/worker": "Worker"])
reloaded.remove("path:/usr/local/bin/worker")
assert(WarningIgnoreList(defaults: defaults).apps.isEmpty)
print("Warning ignore persistence and removal passed")
