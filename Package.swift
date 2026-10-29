// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Witcher2KoreanFontFix",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Witcher2KoreanFontFix", targets: ["Witcher2KoreanFontFix"])
    ],
    targets: [
        .executableTarget(
            name: "Witcher2KoreanFontFix",
            path: "Witcher2KoreanFontFix",
            exclude: ["Resources"],
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ],
    swiftLanguageVersions: [.v5]
)
