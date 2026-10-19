// swift-tools-version: 6.2
import PackageDescription

// Pile protocolaire ZCode, couche par couche :
// ZCodeWire (trames + sérialisation) → ZCodeRPC (canaux) → ZCodeV4 (conversation) → ZCodeClient.
let package = Package(
    name: "ZCodeKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ZCodeKit", targets: ["ZCodeWire", "ZCodeRPC", "ZCodeV4", "ZCodeClient", "ZCodeAppCore"]),
        .executable(name: "zcode-probe", targets: ["zcode-probe"]),
    ],
    targets: [
        .target(name: "ZCodeWire"),
        .target(name: "ZCodeRPC", dependencies: ["ZCodeWire"]),
        .target(name: "ZCodeV4", dependencies: ["ZCodeWire"]),
        .target(name: "ZCodeClient", dependencies: ["ZCodeWire", "ZCodeRPC", "ZCodeV4"]),
        .target(name: "ZCodeAppCore", dependencies: ["ZCodeWire", "ZCodeRPC", "ZCodeV4", "ZCodeClient"]),
        .executableTarget(name: "zcode-probe", dependencies: ["ZCodeWire", "ZCodeRPC", "ZCodeV4", "ZCodeClient"]),
        .target(name: "ZCodeTestSupport", dependencies: ["ZCodeWire", "ZCodeRPC"], path: "Tests/ZCodeTestSupport"),
        .testTarget(name: "ZCodeWireTests", dependencies: ["ZCodeWire", "ZCodeTestSupport"]),
        .testTarget(name: "ZCodeRPCTests", dependencies: ["ZCodeRPC", "ZCodeWire", "ZCodeTestSupport"]),
        .testTarget(name: "ZCodeV4Tests", dependencies: ["ZCodeV4", "ZCodeWire", "ZCodeTestSupport"]),
        .testTarget(name: "ZCodeClientTests", dependencies: ["ZCodeClient", "ZCodeRPC", "ZCodeV4", "ZCodeWire", "ZCodeTestSupport"]),
        .testTarget(name: "ZCodeAppCoreTests", dependencies: ["ZCodeAppCore", "ZCodeClient", "ZCodeRPC", "ZCodeV4", "ZCodeWire", "ZCodeTestSupport"]),
        .testTarget(name: "ZCodeProbeTests", dependencies: ["zcode-probe", "ZCodeWire"]),
    ]
)
