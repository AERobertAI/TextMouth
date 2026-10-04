import Foundation

/// Where the experimental transcript cleanup's rules come from (FR05):
/// TextMouth's own, transcript-cleanup.json in its bundle, unless the user
/// keeps a copy of their own, transcript-cleanup.json in the data directory
/// beside substitutions.json, which syncs with the library and which they
/// edit in their own text editor (the Clean Up sheet's Edit Rules…).
///
/// The user's copy is read as substitutions.json is (`SavedFile`), never
/// downloaded: a copy only in the cloud is left there, the sync service is
/// asked for it, and TextMouth's own rules stand in until it is on this
/// Mac; a copy that can't be read or used is preserved beside itself and
/// TextMouth's own rules stand in. One TRANSCRIPT_CLEANUP_RULES line in the
/// debug log tells of each, never quoting a rule. TextMouth writes the copy
/// only when Edit Rules… finds none, and then it holds TextMouth's own
/// rules, notes and all, to change.
enum TranscriptCleanupRuleFile {
    /// The file's name, in the app's bundle and in the data directory.
    static let fileName = "transcript-cleanup.json"
    /// The tag of the debug log's lines about the user's copy.
    static let logTag = "TRANSCRIPT_CLEANUP_RULES"

    /// What the user's copy was found to be.
    enum UserCopy: Equatable, Sendable {
        /// There is none: TextMouth's own rules are used.
        case none
        /// It is there, and its rules are used.
        case used
        /// It is only in the cloud, so it was not read: TextMouth's own rules
        /// stand in.
        case inCloud
        /// It can't be used, for the reason given, which names the field at
        /// fault: it was preserved beside itself, and TextMouth's own rules
        /// stand in.
        case unusable(String)
    }

    /// The rules to clean up with, and where they came from.
    struct Lookup: Equatable, Sendable {
        /// The rules.
        let rules: TranscriptCleanupRuleSet
        /// Whose they are.
        let source: TranscriptCleanupRuleSource
        /// What the user's copy was found to be.
        let userCopy: UserCopy
        /// The version of TextMouth's own rules, so the sheet can say when
        /// they are newer than the user's copy.
        let builtInVersion: Int
    }

    // MARK: - TextMouth's Own Rules

    /// The bytes of TextMouth's own rule file in `bundle`; nil when it has
    /// none.
    static func builtInBytes(in bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: (fileName as NSString).deletingPathExtension, withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// TextMouth's own rules, from `bundle`: its file's, which the tests
    /// check are usable, or, should a build lack them, no rules, at version
    /// 0, so a cleanup finds nothing to change.
    static func builtIn(in bundle: Bundle = .main) -> TranscriptCleanupRuleSet {
        guard let bytes = builtInBytes(in: bundle), let rules = try? TranscriptCleanupRuleSet.decoded(bytes) else {
            return TranscriptCleanupRuleSet(version: 0, date: "", rules: [])
        }
        return rules
    }

    // MARK: - The Rules to Use

    /// The rules to clean up with: the user's copy at `url`, read through
    /// `reader`, when it is there and usable, and otherwise `builtIn`.
    /// Blocks while it reads; run it off the main thread. A copy only in
    /// the cloud is the caller's to ask the sync service for, on the main
    /// actor (`SavedFile.requestDownload(of:)`).
    static func load(
        userCopyAt url: URL = TextMouthPaths.transcriptCleanupRulesFile,
        reader: SavedFile.Reader = SavedFile.readWithoutDownloading,
        builtIn: TranscriptCleanupRuleSet = builtIn()
    ) -> Lookup {
        /// TextMouth's own rules, standing in for a copy found as `copy`.
        func standIn(_ copy: UserCopy) -> Lookup {
            Lookup(rules: builtIn, source: .builtIn, userCopy: copy, builtInVersion: builtIn.version)
        }
        // Nothing is read from a data directory the library found
        // unavailable; a copy there is not missing, but its books can't be
        // cleaned up either.
        guard !TextMouthPaths.isDataDirectoryUnavailable else { return standIn(.none) }
        switch SavedFile.read(url, using: reader) {
        case .missing:
            return standIn(.none)
        case .inCloud:
            DiagnosticLog.event(
                .storage,
                "\(logTag): \(url.lastPathComponent) is only in the cloud, so it was not read; "
                    + "TextMouth's own rules stand in until it is on this Mac"
            )
            return standIn(.inCloud)
        case .unreadable(let reason):
            preserveUnusable(url, bytes: nil, because: reason)
            return standIn(.unusable(reason))
        case .contents(let bytes):
            do {
                let rules = try TranscriptCleanupRuleSet.decoded(bytes)
                return Lookup(rules: rules, source: .user, userCopy: .used, builtInVersion: builtIn.version)
            } catch {
                let reason = (error as? TranscriptCleanupRuleSet.Unusable)?.reason ?? "it could not be decoded"
                preserveUnusable(url, bytes: bytes, because: reason)
                return standIn(.unusable(reason))
            }
        }
    }

    /// Keeps a copy of the user's unusable copy at `url`, holding `bytes`
    /// when they could be read, with the one line that says so. The copy
    /// itself stays, for the user to mend: TextMouth never writes over it.
    private static func preserveUnusable(_ url: URL, bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            url,
            bytes: bytes,
            because: reason,
            logging: logTag,
            in: .storage,
            standIn: "TextMouth's own rules stand in"
        )
    }

    // MARK: - The User's Copy

    /// Makes sure the user has a copy of the rules to edit at `url`: when
    /// there is none, TextMouth's own file, `builtInBytes`, is written
    /// there exactly, notes and all. A copy already there, usable or not,
    /// is left as it is, and so is one that arrives while this writes.
    /// Blocks while it reads and writes; run it off the main thread, as
    /// storage work.
    /// - Returns: Whether a copy was made.
    /// - Throws: `SavedFile.InCloudError` for a copy only in the cloud, which
    ///   nothing is written over; `TranscriptCleanupError.libraryUnavailable`
    ///   while the data directory can't be used or the app lacks its own
    ///   rules; or why the copy could not be written.
    @discardableResult
    static func prepareUserCopy(
        at url: URL = TextMouthPaths.transcriptCleanupRulesFile,
        reader: SavedFile.Reader = SavedFile.readWithoutDownloading,
        builtInBytes: Data? = builtInBytes()
    ) throws -> Bool {
        guard !TextMouthPaths.isDataDirectoryUnavailable else { throw TranscriptCleanupError.libraryUnavailable }
        switch SavedFile.read(url, using: reader) {
        case .inCloud:
            throw SavedFile.InCloudError(fileName: url.lastPathComponent)
        case .contents, .unreadable:
            return false
        case .missing:
            guard let builtInBytes else { throw TranscriptCleanupError.libraryUnavailable }
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Written whole beside it first, then moved into place, which
            // fails rather than replace a copy that arrived meanwhile.
            let staged = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            try builtInBytes.write(to: staged, options: .atomic)
            defer { try? FileManager.default.removeItem(at: staged) }
            do {
                try FileManager.default.moveItem(at: staged, to: url)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // The sync service brought the user's copy meanwhile.
                return false
            }
            return true
        }
    }
}

extension TextMouthPaths {
    /// The user's copy of the transcript cleanup's rules in the data
    /// directory (FR05, `TranscriptCleanupRuleFile`), beside
    /// substitutions.json.
    static var transcriptCleanupRulesFile: URL {
        root.appendingPathComponent(TranscriptCleanupRuleFile.fileName)
    }
}
