// swift-tools-version: 5.9
// The Swift Package Manager manifest for the MicroSurveysSDK iOS SDK.

import PackageDescription

let package = Package(
    name: "MicroSurveysSDK",
    platforms: [
        .iOS(.v14),
        .macOS(.v11) // required for `swift build` on a Mac; the SDK is iOS-only in practice
    ],
    products: [
        .library(
            name: "MicroSurveysSDK",
            targets: ["MicroSurveysSDK"]
        )
    ],
    dependencies: [
        // Amplitude iOS SDK — optional at runtime; integration is conditionally
        // compiled via `#if canImport(AmplitudeSwift)` so apps without Amplitude
        // can still use MicroSurveysSDK via manual `trackEvent(...)` calls.
        .package(url: "https://github.com/amplitude/Amplitude-Swift", from: "1.18.1")
    ],
    targets: [
        .target(
            name: "MicroSurveysSDK",
            dependencies: [
                .product(name: "AmplitudeSwift", package: "Amplitude-Swift")
            ],
            path: "Sources/MicroSurveysSDK"
        ),
        .testTarget(
            name: "MicroSurveysSDKTests",
            dependencies: ["MicroSurveysSDK"],
            path: "Tests/MicroSurveysSDKTests"
        )
    ]
)
