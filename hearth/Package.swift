// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hearth",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10), .tvOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "HearthCore", targets: ["HearthCore"]),
        .executable(name: "hearthctl", targets: ["hearthctl"]),
    ],
    dependencies: [
        // On Apple platforms `Crypto` re-exports CryptoKit; on Linux it is BoringSSL-backed.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.8.0"..<"5.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        .target(
            name: "HearthCore",
            dependencies: [
                "CSQLite",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .executableTarget(name: "hearthctl", dependencies: ["HearthCore"]),
        .testTarget(name: "HearthCoreTests", dependencies: ["HearthCore"]),
    ]
)
