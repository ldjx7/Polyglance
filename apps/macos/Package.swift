// swift-tools-version: 6.2

import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path

let package = Package(
    name: "NativeTranslatorMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NativeTranslatorMac", targets: ["NativeTranslatorMac"]),
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
            name: "NativeTranslatorMacKit",
            path: "Sources/NativeTranslatorMacKit"
        ),
        .executableTarget(
            name: "NativeTranslatorMac",
            dependencies: [
                "NativeTranslatorMacKit",
                "TranslatorCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/NativeTranslatorMac",
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
            ]
        ),
        .testTarget(
            name: "NativeTranslatorMacKitTests",
            dependencies: ["NativeTranslatorMacKit"],
            path: "Tests/NativeTranslatorMacKitTests"
        ),
        .testTarget(
            name: "NativeTranslatorMacTests",
            dependencies: ["NativeTranslatorMac"],
            path: "Tests/NativeTranslatorMacTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
