// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TiesCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "TiesCore", targets: ["TiesCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.0"),
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "TiesCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup",
                "PhoneNumberKit",
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "TiesCoreTests",
            dependencies: ["TiesCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
