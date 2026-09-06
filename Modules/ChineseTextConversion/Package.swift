// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ChineseTextConversion",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ChineseTextConversion", targets: ["ChineseTextConversion"]),
    ],
    dependencies: [
        // Pin the revision so release builds do not silently change conversion
        // dictionaries when the upstream main branch advances.
        .package(
            url: "https://github.com/doggy8088/opencc-swift.git",
            revision: "69fdd9601a7bee4485ea60847910e40744608012"
        ),
    ],
    targets: [
        .target(
            name: "ChineseTextConversion",
            dependencies: [
                .product(name: "OpenCCSwift", package: "opencc-swift"),
            ]
        ),
        .testTarget(
            name: "ChineseTextConversionTests",
            dependencies: ["ChineseTextConversion"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
