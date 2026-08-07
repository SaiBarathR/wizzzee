import Foundation

// MARK: - Attribute bits
//
// Declared locally as UInt32 rather than using the imported `ATTR_*` macros,
// which come across with inconsistent signedness (ATTR_CMN_RETURNED_ATTRS does
// not fit in Int32) and make the bitwise arithmetic below unreadable.
private enum Attr {
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnFlags: UInt32 = 0x0004_0000
    static let cmnFileID: UInt32 = 0x0200_0000

    static let dirMountStatus: UInt32 = 0x0000_0004

    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileTotalSize: UInt32 = 0x0000_0002
    static let fileAllocSize: UInt32 = 0x0000_0004

    /// Packed width of each field in the reply buffer, in bit order.
    static let sizeAttrReference = 8  // attrreference_t
    static let sizeObjType = 4        // fsobj_type_t
    static let sizeTimespec = 16      // struct timespec (64-bit)
    static let sizeFlags = 4          // u_int32_t
    static let sizeFileID = 8         // u_int64_t
    static let sizeMountStatus = 4    // u_int32_t
    static let sizeLinkCount = 4      // u_int32_t
    static let sizeOffT = 8           // off_t
    static let sizeAttributeSet = 20  // attribute_set_t (5 x attrgroup_t)
}

/// `vnode` object types we care about (sys/vnode.h).
private let vtypeREG: UInt32 = 1
private let vtypeDIR: UInt32 = 2
private let vtypeLNK: UInt32 = 5

/// `DIR_MNTSTATUS_MNTPOINT` (sys/attr.h) — the directory is a mount point.
private let mntStatusMountPoint: UInt32 = 0x0000_0001

/// One directory entry, as reported by `getattrlistbulk(2)`.
struct BulkEntry {
    var name: String = ""
    var objType: UInt32 = 0
    var mtime: Double = 0
    var fileID: UInt64 = 0
    var bsdFlags: UInt32 = 0
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 1
    /// Logical size, including any resource fork (`ATTR_FILE_TOTALSIZE`).
    var size: UInt64 = 0
    /// Size on disk (`ATTR_FILE_ALLOCSIZE`).
    var alloc: UInt64 = 0

    var isDir: Bool { objType == vtypeDIR }
    var isRegularFile: Bool { objType == vtypeREG }
    var isSymlink: Bool { objType == vtypeLNK }
    var isMountPoint: Bool { mountStatus & mntStatusMountPoint != 0 }
    var isHardLinked: Bool { linkCount > 1 }
}

/// Fast directory reader built on `getattrlistbulk(2)`, which returns names,
/// types, sizes and dates for many entries per syscall — no per-file `stat`.
/// This is the fastest public API for bulk enumeration on APFS.
///
/// One instance owns one reply buffer and is **not** thread-safe: give each
/// scan worker its own.
final class BulkEnumerator {
    private static let bufferSize = 1 << 19  // 512 KiB — ~1500 entries per call

    private let buffer: UnsafeMutableRawPointer
    private var request: attrlist

    init() {
        buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Self.bufferSize,
            alignment: 8
        )
        request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr =
            Attr.cmnReturnedAttrs | Attr.cmnName | Attr.cmnObjType
            | Attr.cmnModTime | Attr.cmnFlags | Attr.cmnFileID
        request.dirattr = Attr.dirMountStatus
        request.fileattr =
            Attr.fileLinkCount | Attr.fileTotalSize | Attr.fileAllocSize
    }

    deinit { buffer.deallocate() }

    /// Reads every entry in the directory `fd`, invoking `visit` for each.
    /// `.` and `..` are not reported by `getattrlistbulk`.
    ///
    /// - Returns: 0 on a complete enumeration, otherwise the `errno` that
    ///   stopped it (entries visited before the failure still count).
    func enumerate(fd: Int32, _ visit: (BulkEntry) -> Void) -> Int32 {
        while true {
            // getattrlistbulk mutates the attrlist, so hand it a fresh copy.
            var req = request
            let count = getattrlistbulk(fd, &req, buffer, Self.bufferSize, 0)
            if count == -1 {
                // A signal delivered to this worker thread is not a failure to
                // read the directory; the next call resumes where this one was
                // interrupted. Returning here instead silently truncated the
                // folder at whatever batch the signal happened to land on.
                if errno == EINTR { continue }
                return errno
            }
            if count == 0 { return 0 }

            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let entryLength = Int(entry.loadUnaligned(as: UInt32.self))
                decode(entry: entry, visit)
                entry += entryLength
            }
        }
    }

    /// Decodes one variable-length entry. Fields appear in ascending bit order
    /// within each attribute group (common, then dir, then file), preceded by
    /// the `attribute_set_t` saying which ones the filesystem actually filled
    /// in — anything absent must not be skipped over.
    private func decode(entry: UnsafeRawPointer, _ visit: (BulkEntry) -> Void) {
        var field = entry + 4  // past the u_int32_t entry length
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += Attr.sizeAttributeSet

        var e = BulkEntry()

        if returned.commonattr & Attr.cmnName != 0 {
            let ref = field.loadUnaligned(as: attrreference_t.self)
            if ref.attr_length > 1 {
                let bytes = (field + Int(ref.attr_dataoffset))
                    .assumingMemoryBound(to: UInt8.self)
                // attr_length counts the trailing NUL.
                e.name = String(
                    decoding: UnsafeBufferPointer(
                        start: bytes,
                        count: Int(ref.attr_length) - 1
                    ),
                    as: UTF8.self
                )
            }
            field += Attr.sizeAttrReference
        }
        if returned.commonattr & Attr.cmnObjType != 0 {
            e.objType = field.loadUnaligned(as: UInt32.self)
            field += Attr.sizeObjType
        }
        if returned.commonattr & Attr.cmnModTime != 0 {
            let ts = field.loadUnaligned(as: timespec.self)
            e.mtime = Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
            field += Attr.sizeTimespec
        }
        if returned.commonattr & Attr.cmnFlags != 0 {
            e.bsdFlags = field.loadUnaligned(as: UInt32.self)
            field += Attr.sizeFlags
        }
        if returned.commonattr & Attr.cmnFileID != 0 {
            e.fileID = field.loadUnaligned(as: UInt64.self)
            field += Attr.sizeFileID
        }

        if returned.dirattr & Attr.dirMountStatus != 0 {
            e.mountStatus = field.loadUnaligned(as: UInt32.self)
            field += Attr.sizeMountStatus
        }

        if returned.fileattr & Attr.fileLinkCount != 0 {
            e.linkCount = field.loadUnaligned(as: UInt32.self)
            field += Attr.sizeLinkCount
        }
        if returned.fileattr & Attr.fileTotalSize != 0 {
            e.size = field.loadUnaligned(as: UInt64.self)
            field += Attr.sizeOffT
        }
        if returned.fileattr & Attr.fileAllocSize != 0 {
            e.alloc = field.loadUnaligned(as: UInt64.self)
            field += Attr.sizeOffT
        }

        visit(e)
    }
}
