import ProjectDescription

let stampBuildCommit = """
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
COMMIT=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "${SRCROOT}" status --porcelain 2>/dev/null)" ]; then COMMIT="${COMMIT}*"; fi
/usr/libexec/PlistBuddy -c "Set :TokenUsageBuildCommit ${COMMIT}" "${PLIST}" 2>/dev/null \\
  || /usr/libexec/PlistBuddy -c "Add :TokenUsageBuildCommit string ${COMMIT}" "${PLIST}"
BUILDNUM=$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILDNUM}" "${PLIST}" 2>/dev/null \\
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILDNUM}" "${PLIST}"
"""

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
                "CFBundleShortVersionString": "0.1.1",
                "LSMultipleInstancesProhibited": true,
                "LSApplicationCategoryType": "public.app-category.developer-tools",
            ]),
            sources: ["App/**"],
            resources: ["App/Resources/**"],
            scripts: [
                .post(
                    script: stampBuildCommit,
                    name: "Stamp build commit",
                    inputPaths: ["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"],
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [.package(product: "TokenUsageCore")],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                // The catalog exists only for the icon; keep the system accent colour.
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
            ])
        ),
    ]
)
