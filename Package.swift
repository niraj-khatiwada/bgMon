// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "bgMon", platforms: [.macOS(.v14)], products: [.executable(name: "bgMon", targets: ["bgMon"])], targets: [.executableTarget(name: "bgMon")])
