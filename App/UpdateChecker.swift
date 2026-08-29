import Foundation
import TokenUsageCore

struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let releasePage: URL
    let dmgURL: URL?
    let checksumURL: URL?

    var isInstallable: Bool { dmgURL != nil && checksumURL != nil }
}

/// Checks Token Usage's public GitHub releases feed for a newer version.
struct UpdateChecker: Sendable {
    private static let endpoint = URL(
        string: "https://api.github.com/repos/webteractive/token-usage/releases/latest"
    )!
    private static let releasesPage = URL(
        string: "https://github.com/webteractive/token-usage/releases/latest"
    )!

    let currentVersion: String

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    enum CheckError: Error {
        case badResponse
    }

    func check() async throws -> AvailableUpdate? {
        guard SemVer(currentVersion) != nil else { return nil }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let release = try? JSONDecoder().decode(Release.self, from: data)
        else {
            throw CheckError.badResponse
        }

        guard SemVer.isNewer(latest: release.tagName, than: currentVersion) else { return nil }
        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName
        let page = URL(string: release.htmlURL) ?? Self.releasesPage
        let assets = release.assets.compactMap { asset -> ReleaseAsset? in
            URL(string: asset.browserDownloadURL).map {
                ReleaseAsset(name: asset.name, downloadURL: $0)
            }
        }
        let selected = UpdateAssets.select(from: assets)

        return AvailableUpdate(
            version: version,
            releasePage: page,
            dmgURL: selected.dmg,
            checksumURL: selected.checksum
        )
    }
}
