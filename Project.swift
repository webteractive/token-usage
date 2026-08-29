import ProjectDescription

let project = Project(
    name: "TokenUsage",
    packages: [.local(path: ".")],
    targets: [
        .target(
            name: "TokenUsage",
            destinations: .macOS,
            product: .app,
            bundleId: "co.webteractive.tokenusage",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                // Menu bar only: no Dock icon, no main window.
                "LSUIElement": true,
                "CFBundleName": "Token Usage",
                "CFBundleDisplayName": "Token Usage",
                "CFBundleShortVersionString": "0.1.0",
                "LSApplicationCategoryType": "public.app-category.developer-tools",
            ]),
            sources: ["App/**"],
            dependencies: [.package(product: "TokenUsageCore")]
        ),
    ]
)
