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

    /// True when a path has to be put together for each thing looked at.
    var needsPaths: Bool { !paths.isEmpty }

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
            if lowered.hasPrefix(">") { above = bytes } else { below = bytes }
            return true
        }
        guard let colon = lowered.firstIndex(of: ":") else { return false }
        let value = lowered[lowered.index(after: colon)...]
        switch lowered[..<colon] {
        case "kind":
            switch value {
            case "folder", "folders", "dir": kind = .folder
            case "file", "files": kind = .file
            default: unreadable.append(word)
            }
        case "ext":
            let name = value.drop(while: { $0 == "." })
            if value.isEmpty {
                unreadable.append(word)
            } else {
                ext = name == "none" ? "" : String(name)
            }
        case "older", "newer":
            guard let seconds = Self.seconds(value) else {
                unreadable.append(word)
                return true
            }
            let cutoff = now.timeIntervalSince1970 - seconds
            if lowered.hasPrefix("older") {
                modifiedBefore = cutoff
            } else {
                modifiedAfter = cutoff
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

/// What a search of a scan came back with.
struct SearchResult {
    /// The largest of what matched, largest first.
    var rows: [NodeRef] = []
    /// How many things matched, listed or not. Nil when nothing was asked
    /// for and nothing was counted: the list is then just the largest files.
    var matches: Int?
    /// What everything that matched comes to in the measure asked for. A
    /// match inside a folder that also matched is counted once.
    var bytes: UInt64 = 0
}
