// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "thermohop",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "thermohop", targets: ["Thermohop"])],
    dependencies: [.package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.7.0")],
    targets: [.executableTarget(
        name: "Thermohop",
        dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
            "-Xlinker", "__info_plist", "-Xlinker", root + "/Info.plist"])]
    ),
    .testTarget(name: "ThermohopTests", dependencies: ["Thermohop"], path: "Tests/ThermohopTests")]
)
