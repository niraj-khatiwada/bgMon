import Foundation

struct WarningIgnoreList {
    private let defaults: UserDefaults
    private static let defaultsKey = "ignoredResourceWarningApps"
    private(set) var apps: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apps = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    func contains(_ id: String) -> Bool { apps[id] != nil }

    mutating func ignore(id: String, name: String) {
        apps[id] = name
        defaults.set(apps, forKey: Self.defaultsKey)
    }

    mutating func remove(_ id: String) {
        apps.removeValue(forKey: id)
        defaults.set(apps, forKey: Self.defaultsKey)
    }
}
