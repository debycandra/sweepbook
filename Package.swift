// swift-tools-version:5.9
// `swift build` compiles the binary (handy for editors and CI).
// Use ./build.sh to get a double-clickable Sweepbook.app.
import PackageDescription

let package = Package(
    name: "Sweepbook",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Sweepbook", path: "Sources")
    ]
)
