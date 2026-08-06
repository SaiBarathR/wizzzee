import Foundation

/// Version reported by the UI and `--version`.
///
/// Read from the bundle rather than written in the source, so a release only
/// has to bump `Resources/Info.plist` and the tag check in
/// `scripts/validate-release.sh` covers it.
enum AppInfo {
    static let version: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }()
}
