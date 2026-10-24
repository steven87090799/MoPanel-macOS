// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "MoPanelCore", targets: ["MoPanelCore"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "MoPanelCore"),
    .target(name: "MoPanelProcess"),
    .testTarget(name: "MoPanelCoreTests", dependencies: ["MoPanelCore"], resources: [.copy("Fixtures")]),
    .testTarget(name: "MoPanelProcessTests", dependencies: ["MoPanelProcess"]),
    .executableTarget(name: "MoPanelGuardian", linkerSettings: [.linkedLibrary("util", .when(platforms: [.linux]))])
]
products.append(.executable(name: "MoPanelGuardian", targets: ["MoPanelGuardian"]))
#if os(macOS)
dependencies.append(.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"))
products.append(.executable(name: "MoPanel", targets: ["MoPanelApp"]))
products.append(.executable(name: "MoPanelEditor", targets: ["MoPanelEditor"]))
targets += [
    .executableTarget(name: "MoPanelEditor", dependencies: ["MoPanelProcess"]),
    .target(name: "MoPanelTerminal", dependencies: ["MoPanelProcess", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    .executableTarget(name: "MoPanelApp", dependencies: ["MoPanelCore", "MoPanelProcess", "MoPanelTerminal"], resources: [.copy("Fixtures")])
]
#endif

let package = Package(
    name: "MoPanel", defaultLocalization: "zh-Hant", platforms: [.macOS("27.0")],
    products: products, dependencies: dependencies, targets: targets,
    swiftLanguageModes: [.v5]
)
