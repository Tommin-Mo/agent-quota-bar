// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentQuotaBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentQuotaBar",
            path: "Sources/AgentQuotaBar"
        )
    ]
)
