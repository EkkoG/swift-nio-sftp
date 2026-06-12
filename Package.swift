// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "swift-nio-sftp",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .watchOS(.v6),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "NIOSFTP", targets: ["NIOSFTP"]),
        .executable(name: "NIOSFTPWhiteboxDemo", targets: ["NIOSFTPWhiteboxDemo"]),
        .executable(name: "NIOSFTPServerDemo", targets: ["NIOSFTPServerDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "NIOSFTP",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "NIOSFTPWhiteboxDemo",
            dependencies: [
                "NIOSFTP",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "NIOSFTPServerDemo",
            dependencies: [
                "NIOSFTP",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "NIOSFTPTests",
            dependencies: [
                "NIOSFTP",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
    ]
)
