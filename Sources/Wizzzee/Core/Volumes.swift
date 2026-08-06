import AppKit
import Foundation

/// A mounted volume offered in the scan target picker.
struct VolumeInfo: Identifiable, Hashable {
    let path: String
    let name: String
    let total: UInt64
    let free: UInt64

    var id: String { path }
    var used: UInt64 { total > free ? total - free : 0 }
    var isBootVolume: Bool { path == "/" }

    /// e.g. "Macintosh HD — 926 GB"
    var menuTitle: String {
        total > 0 ? "\(name) — \(ByteFormat.decimal(total))" : name
    }

    static func current() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsLocalKey,
            .volumeIsBrowsableKey,
            .volumeTotalCapacityKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]
            ) ?? []

        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            // Network shares are excluded: they are not part of any local disk's
            // used space, and walking one over the wire would take hours.
            guard values.volumeIsLocal == true, values.volumeIsBrowsable == true
            else { continue }

            let path = url.path
            let (total, free) = capacity(of: path)
            volumes.append(
                VolumeInfo(
                    path: path,
                    name: values.volumeName ?? url.lastPathComponent,
                    total: total,
                    free: free
                )
            )
        }
        // Boot volume first, then alphabetically.
        return volumes.sorted {
            if $0.isBootVolume != $1.isBootVolume { return $0.isBootVolume }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Total and available bytes, straight from `statfs`.
    static func capacity(of path: String) -> (total: UInt64, free: UInt64) {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return (0, 0) }
        let blockSize = UInt64(info.f_bsize)
        return (UInt64(info.f_blocks) * blockSize, UInt64(info.f_bavail) * blockSize)
    }
}

/// Whether the app can read TCC-protected locations, which it needs in order to
/// account for every file on the disk.
enum FullDiskAccess {
    /// Probes a path that is readable only with Full Disk Access granted.
    ///
    /// `TCC.db` is the conventional sentinel: the sandbox denies it to every app
    /// that has not been explicitly authorized, and reading it has no side
    /// effects.
    static func isGranted() -> Bool {
        let sentinels = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
        ]
        for path in sentinels {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            // A missing sentinel proves nothing; only EACCES/EPERM is a denial.
            if errno != EACCES && errno != EPERM { continue }
            return false
        }
        // None of the sentinels exist on this system — assume access is fine
        // rather than nagging about a permission that may not be needed.
        return true
    }

    static func openSystemSettings() {
        let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )!
        NSWorkspace.shared.open(url)
    }
}
