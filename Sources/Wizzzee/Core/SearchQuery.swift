import Foundation

/// What was typed into the File View's filter, read into what to look for.
///
/// The filter was one piece of text matched against file names. It could not
/// find a folder, and could not be told how big or how old: "every
/// `node_modules`, and what they come to" and "anything over a gigabyte that
/// has not been touched in a year" are both things a scan already knows, and
/// neither could be asked for.
///
/// Words are matched against names, all of them, in any order; a word with a
/// `/` in it against the whole path. Something in double quotes is one word,
/// spaces and all. The rest are filters:
///
///     >1gb  <500kb          bigger or smaller than, in the measure on show
///     older:1y  newer:30d   by when it was last modified (d, w, m, y)
///     ext:dmg               one file type; ext:none for files with none
///     kind:folder  kind:file
struct SearchQuery: Equatable {
    enum Kind: Equatable {
        case file, folder
    }

    /// Words to find in a name, folded for comparing.
    private(set) var names: [String] = []
    /// Words to find in a whole path, folded for comparing.
    private(set) var paths: [String] = []
    /// True when a word was typed with anything beyond ASCII in it, which is
    /// when the names it is compared against have to be folded as well.
    private(set) var foldsNames = false
    /// Only what is bigger than this, and only what is smaller than that.
    private(set) var above: UInt64?
    private(set) var below: UInt64?
    /// Only what was last modified before this, and only what was after that.
    private(set) var modifiedBefore: Double?
    private(set) var modifiedAfter: Double?
    /// One file type, by its extension: empty is the files that have none.
    private(set) var ext: String?
    /// Files or folders. Nil is whichever the rest of the query calls for:
    /// see `finds`.
    var kind: Kind?
    /// What looked like a filter and could not be read as one. A query with
    /// any of these finds nothing: a filter dropped without a word would show
    /// everything, as though it had been met.
    private(set) var unreadable: [String] = []
    /// True when two filters were given that nothing can meet both of: two
    /// different types, or files and folders. Such a query finds nothing.
    private(set) var isImpossible = false

    init(_ text: String = "", now: Date = Date()) {
        for word in Self.words(of: text) {
            if word.isQuoted {
                addText(word.text)
            } else if !addFilter(word.text, now: now) {
                addText(word.text)
            }
        }
    }

    /// True when nothing was asked for, which is the File View as it opens:
    /// the largest files in the scan.
    var isEmpty: Bool {
        names.isEmpty && paths.isEmpty && above == nil && below == nil
            && modifiedBefore == nil && modifiedAfter == nil && ext == nil
            && kind == nil && unreadable.isEmpty
    }

    /// Whether files, and whether folders, are looked through.
    ///
    /// Folders only when there is a word to find them by, or they are asked
    /// for by name. With neither the list is of files, as it always was: a
    /// folder is at least as big as anything in it, so the largest of
    /// everything would be the scan's own top folders and nothing else.
    func finds(_ wanted: Kind) -> Bool {
        if let kind { return kind == wanted }
        if wanted == .file { return true }
        return ext == nil && !(names.isEmpty && paths.isEmpty)
    }

    // MARK: - Matching

    /// Whether something this big and this old passes the size and age
    /// filters. Checked ahead of the words: they cost two comparisons, and a
    /// word costs a search through a name.
    func admits(bytes: UInt64, mtime: Double) -> Bool {
        if let above, bytes <= above { return false }
        if let below, bytes >= below { return false }
        if let modifiedBefore, mtime >= modifiedBefore { return false }
        if let modifiedAfter, mtime < modifiedAfter { return false }
        return true
    }

    /// Whether every word asked for is in `name`.
    func matches(name: String) -> Bool {
        for needle in names {
            let found =
                foldsNames
                ? name.containsFolded(needle)
                : name.containsCaseInsensitive(needle)
            if !found { return false }
        }
        return true
    }

    /// Whether every word asked for of the path is in `path`.
    func matches(path: String) -> Bool {
        for needle in paths {
            let found =
                foldsNames
                ? path.containsFolded(needle)
                : path.containsCaseInsensitive(needle)
            if !found { return false }
        }
        return true
    }

    /// True when where a thing is has to be looked at as well as its name.
    var needsPaths: Bool { !paths.isEmpty }

    /// What the words asked of the path come to for the things directly
    /// inside one folder.
    enum PathScope: Equatable {
        /// The folder's own path has every one of them in it, so everything
        /// in the folder does.
        case everything
        /// One of them can't be in the path of anything in here.
        case nothing
        /// The path has them if the name starts with each of these.
        case namesStarting([String])
        /// It can't be told from the parts: put the path together and look.
        case wholePath
    }

    /// Works that out, once per folder.
    ///
    /// The path of a thing is the folder's path, a slash, and its name, and
    /// a word with a slash in it can only be found there in two ways: all of
    /// it in the folder's part, or its last slash on the slash that joins
    /// the two — the rest of it then being the end of the folder's path and
    /// the start of the name. A name has no slash of its own.
    ///
    /// So the path never has to be put together for a file. It was, once per
    /// file in the scan, for every file a search had to count.
    func pathScope(inFolder folder: String) -> PathScope {
        guard !paths.isEmpty else { return .everything }
        // Folding a name to compare it is not something that can be done
        // to the two halves of a path separately.
        guard !foldsNames else { return .wholePath }
        let withSlash = folder.hasSuffix("/") ? folder : folder + "/"
        var starts: [String] = []
        for needle in paths {
            if withSlash.containsCaseInsensitive(needle) { continue }
            guard let slash = needle.lastIndex(of: "/") else { return .nothing }
            let start = String(needle[needle.index(after: slash)...])
            // Ending in the slash, it could only have been in the folder's
            // part, and it was not.
            guard !start.isEmpty,
                withSlash.dropLast().hasSuffixIgnoringCase(needle[..<slash])
            else { return .nothing }
            starts.append(start)
        }
        return starts.isEmpty ? .everything : .namesStarting(starts)
    }

    /// Whether something called `name`, in a folder `scope` was worked out
    /// for, is where the words asked of the path say. `path` is only built
    /// if it has to be.
    func isInScope(_ scope: PathScope, name: String, path: () -> String) -> Bool {
        switch scope {
        case .everything: return true
        case .nothing: return false
        case .namesStarting(let starts):
            return starts.allSatisfy { name.hasPrefixIgnoringCase($0) }
        case .wholePath: return matches(path: path())
        }
    }

    // MARK: - Reading

    private mutating func addText(_ text: String) {
        guard !text.isEmpty else { return }
        // Asked of what was typed, not of what it folds to. Folding can leave
        // a needle that is pure ASCII — `ß` becomes "ss" — and the name it
        // was typed to find still has the `ß` in it.
        if text.utf8.contains(where: { $0 >= 0x80 }) { foldsNames = true }
        let needle = text.foldedForSearch
        if needle.contains("/") {
            paths.append(needle)
        } else {
            names.append(needle)
        }
    }

    /// Reads `word` as a filter. False when it is not one, and is a word to
    /// look for; true when it was one, read or not.
    private mutating func addFilter(_ word: String, now: Date) -> Bool {
        let lowered = word.lowercased()
        if lowered.hasPrefix(">") || lowered.hasPrefix("<") {
            guard let bytes = Self.bytes(lowered.dropFirst()) else {
                unreadable.append(word)
                return true
            }
            // A second filter of a kind is one more to meet, as a second
            // word is, and not a correction of the first: the tighter of the
            // two is what meets both.
            if lowered.hasPrefix(">") {
                above = max(above ?? bytes, bytes)
            } else {
                below = min(below ?? bytes, bytes)
            }
            return true
        }
        guard let colon = lowered.firstIndex(of: ":") else { return false }
        let value = lowered[lowered.index(after: colon)...]
        switch lowered[..<colon] {
        case "kind":
            let asked: Kind
            switch value {
            case "folder", "folders", "dir": asked = .folder
            case "file", "files": asked = .file
            default:
                unreadable.append(word)
                return true
            }
            if let kind, kind != asked { isImpossible = true }
            kind = asked
        case "ext":
            let name = value.drop(while: { $0 == "." })
            // Nothing after the dots is not the files with no extension:
            // those are asked for by name, with `none`.
            guard !name.isEmpty else {
                unreadable.append(word)
                return true
            }
            let asked = name == "none" ? "" : String(name)
            if let ext, ext != asked { isImpossible = true }
            ext = asked
        case "older", "newer":
            guard let seconds = Self.seconds(value) else {
                unreadable.append(word)
                return true
            }
            let cutoff = now.timeIntervalSince1970 - seconds
            if lowered.hasPrefix("older") {
                modifiedBefore = min(modifiedBefore ?? cutoff, cutoff)
            } else {
                modifiedAfter = max(modifiedAfter ?? cutoff, cutoff)
            }
        default:
            // A name with a colon in it, which is a word like any other.
            return false
        }
        return true
    }

    /// "1.5gb" as bytes, in the base-10 units the app shows sizes in.
    static func bytes(_ text: Substring) -> UInt64? {
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number >= 0 else { return nil }
        let scale: Double
        switch text.dropFirst(digits.count) {
        case "", "b": scale = 1
        case "k", "kb": scale = 1e3
        case "m", "mb": scale = 1e6
        case "g", "gb": scale = 1e9
        case "t", "tb": scale = 1e12
        default: return nil
        }
        let bytes = number * scale
        guard bytes < 1e18 else { return nil }
        return UInt64(bytes)
    }

    /// "30d", "2w", "6m" or "1y" as a length of time.
    static func seconds(_ text: Substring) -> Double? {
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number >= 0 else { return nil }
        let day = 86_400.0
        switch text.dropFirst(digits.count) {
        case "d": return number * day
        case "w": return number * day * 7
        case "m", "mo": return number * day * 30
        case "y": return number * day * 365
        default: return nil
        }
    }

    /// `text` split at its spaces, keeping what is in double quotes together.
    private static func words(of text: String) -> [(text: String, isQuoted: Bool)] {
        var words: [(text: String, isQuoted: Bool)] = []
        var current = ""
        var inQuotes = false
        var wasQuoted = false
        func finish() {
            if !current.isEmpty { words.append((current, wasQuoted)) }
            current = ""
            wasQuoted = false
        }
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                wasQuoted = true
            } else if character.isWhitespace && !inQuotes {
                finish()
            } else {
                current.append(character)
            }
        }
        finish()
        return words
    }
}

extension StringProtocol {
    /// Whether this ends with `lowered`, which is expected to be lowercase
    /// already, taking A–Z and a–z as the same. Read as bytes, in place.
    func hasSuffixIgnoringCase<S: StringProtocol>(_ lowered: S) -> Bool {
        var mine = utf8.reversed().makeIterator()
        for wanted in lowered.utf8.reversed() {
            guard let byte = mine.next(), Self.lowered(byte) == wanted else {
                return false
            }
        }
        return true
    }

    /// As `hasSuffixIgnoringCase`, for the start.
    func hasPrefixIgnoringCase<S: StringProtocol>(_ lowered: S) -> Bool {
        var mine = utf8.makeIterator()
        for wanted in lowered.utf8 {
            guard let byte = mine.next(), Self.lowered(byte) == wanted else {
                return false
            }
        }
        return true
    }

    private static func lowered(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }
}

/// What a search of a scan came back with.
struct SearchResult {
    /// The largest of what matched, largest first.
    var rows: [NodeRef] = []
    /// How many of what matched are folders, listed or not.
    var folders = 0
    /// How many things matched, listed or not. Nil when nothing was asked
    /// for and nothing was counted: the list is then just the largest files.
    var matches: Int?
    /// What everything that matched comes to in the measure asked for. A
    /// match inside a folder that also matched is counted once.
    var bytes: UInt64 = 0
}
