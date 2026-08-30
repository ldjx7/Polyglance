// swift-tools-version: 6.1

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path

let package = Package(
    name: "Polyglance",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Polyglance", targets: ["Polyglance"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "translator_uniffiFFI",
            path: "Generated/translator_uniffiFFI",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", "\(packageDirectory)/Libraries"]),
                .linkedLibrary("translator_uniffi"),
            ]
        ),
        .target(
            name: "TranslatorCore",
            dependencies: ["translator_uniffiFFI"],
            path: "Generated/TranslatorCore"
        ),
        .target(
            name: "PolyglanceKit",
            dependencies: ["TranslatorCore"],
            path: "Sources/PolyglanceKit"
        ),
        .executableTarget(
            name: "Polyglance",
            dependencies: [
                "PolyglanceKit",
                "TranslatorCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Polyglance",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "PolyglanceKitTests",
            dependencies: ["PolyglanceKit"],
            path: "Tests/PolyglanceKitTests"
        ),
        .testTarget(
            name: "PolyglanceTests",
            dependencies: ["Polyglance"],
            path: "Tests/PolyglanceTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
