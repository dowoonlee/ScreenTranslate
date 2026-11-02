// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenTranslate",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ScreenTranslate", targets: ["ScreenTranslate"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .executableTarget(name: "ScreenTranslate", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ScreenTranslateTests", dependencies: ["ScreenTranslate"])
    ]
)
