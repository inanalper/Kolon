// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KolonCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KolonCore", targets: ["KolonCore"])
    ],
    targets: [
        // DuckDB C API; the dylib itself is linked and embedded by the app targets.
        .systemLibrary(name: "Cduckdb"),
        .target(name: "KolonCore", dependencies: ["Cduckdb"]),
    ]
)
