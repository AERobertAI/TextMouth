import AVFoundation
import CryptoKit
import Foundation
import os

/// The chapters one speech export (FMT43) has spoken, each kept in an audio
/// file of its own in this Mac's Caches folder (never the library) until
/// that export finishes, another export replaces them, or TextMouth next
/// launches, so that an export stopped partway goes on from its next chapter
/// (the user's answer to question 19).
///
/// One export's chapters are kept in a folder named by its `key`, which
/// changes with anything that changes how they sound, so kept chapters are
/// only ever used again by an export that would speak them the same way.
/// Each chapter is spoken into its part file ("0001.partial.caf") and given
/// its own name ("0001.caf") only once it is whole (`finishChapter(_:)`), so
/// a file with a chapter's name is a finished chapter. One export runs at a
/// time (`claim()`), and opening its store (`open()`) removes every other
/// export's folder, so the Caches folder holds one export's chapters at most.
struct SpeechExportStore: Sendable {
    /// The folder every export's kept chapters are under.
    let root: URL
    /// The name of this export's folder: a key that
    /// `key(bookID:voiceIdentifier:wordsPerMinute:pitch:sections:)` made.
    let key: String

    /// The folder the app keeps exports' chapters under: "Speech Export" in
    /// this Mac's Caches folder, which Time Machine leaves out of backups and
    /// macOS may empty when the disk runs low. Under hosted tests it is in
    /// the test sandbox, as `MachineLocalPaths.caches` is.
    static var liveRoot: URL {
        MachineLocalPaths.caches.appendingPathComponent("Speech Export", isDirectory: true)
    }

    /// The folder this export's chapters are kept in.
    var folder: URL {
        root.appendingPathComponent(key, isDirectory: true)
    }

    // MARK: - The Key

    /// What the key is made from first. Raising its number makes every
    /// chapter an earlier TextMouth kept unusable, as a change to what the
    /// key covers, or to how chapters are written, needs.
    private static let keyVersion = "TextMouth speech export 1"

    /// What decides whether kept chapters can be used again: the book; the
    /// voice, speed, and pitch; and the sections to speak, each given as its
    /// title, then its texts. Changing any of them changes the key, and so
    /// the folder, and the chapters are spoken afresh.
    ///
    /// The key is the first 16 bytes of a SHA-256 digest, in lowercase
    /// hexadecimal (32 characters), over: the key's version; the book ID's
    /// `uuidString`; the voice identifier, or "" for none; the speed and the
    /// pitch, each as `String(_:)` writes it; the number of sections; and for
    /// each section the number of its strings, then each string. Each string
    /// goes in as its UTF-8 length, then its bytes, and each number as
    /// itself, every length and number in 8 bytes, least significant first,
    /// so that no two inputs can run together: ["a", "bc"] is not
    /// ["ab", "c"], and a section split in two is not the section whole.
    static func key(
        bookID: UUID,
        voiceIdentifier: String?,
        wordsPerMinute: Double,
        pitch: Double,
        sections: [[String]]
    ) -> String {
        var digest = KeyDigest()
        digest.add(keyVersion)
        digest.add(bookID.uuidString)
        digest.add(voiceIdentifier ?? "")
        digest.add(String(wordsPerMinute))
        digest.add(String(pitch))
        digest.add(sections.count)
        for section in sections {
            digest.add(section.count)
            for text in section {
                digest.add(text)
            }
        }
        return digest.hexadecimalPrefix(byteCount: 16)
    }

    // MARK: - The Chapter Files

    /// What ends a finished chapter's file name.
    private static let chapterSuffix = ".caf"
    /// What ends the file name of a chapter being spoken. It keeps the `caf`
    /// extension, from which `AVAudioFile` knows what kind of file to write.
    private static let partSuffix = ".partial.caf"

    /// The file name of chapter `index` (counted from 0) once it is whole:
    /// its number from 1, in four digits at least ("0001.caf").
    func chapterName(_ index: Int) -> String {
        Self.number(index) + Self.chapterSuffix
    }

    /// The file of chapter `index` once it is whole.
    func chapterURL(_ index: Int) -> URL {
        folder.appendingPathComponent(chapterName(index), isDirectory: false)
    }

    /// The file chapter `index` is spoken into ("0001.partial.caf"), which
    /// `finishChapter(_:)` gives the chapter's own name once it is whole.
    func partURL(_ index: Int) -> URL {
        folder.appendingPathComponent(Self.number(index) + Self.partSuffix, isDirectory: false)
    }

    /// Chapter `index`'s number from 1, in four digits at least: "0001".
    private static func number(_ index: Int) -> String {
        String(format: "%04d", index + 1)
    }

    /// The index of the chapter whose finished file is named `name`, or nil
    /// when `name` is not a finished chapter's name ("0001.partial.caf",
    /// "1.caf", "notes.txt").
    private func chapterIndex(ofName name: String) -> Int? {
        guard name.hasSuffix(Self.chapterSuffix),
              let number = Int(name.dropLast(Self.chapterSuffix.count)),
              number > 0 else { return nil }
        // A name is a chapter's only when it is exactly the one
        // `chapterName(_:)` gives it, so "00001.caf" and "+0001.caf" name no
        // chapter.
        return chapterName(number - 1) == name ? number - 1 : nil
    }

    // MARK: - Opening and Finishing

    /// Makes this export's folder ready, and counts the chapters kept in it,
    /// which the export goes on after.
    ///
    /// It makes `root` and `folder`; removes everything else in `root` (any
    /// other export's kept chapters, and anything else); removes every part
    /// file in `folder`, each a chapter a Stop, a failure, or a quit cut off
    /// midway; and counts the chapters kept, from the first, while each opens
    /// as audio holding at least one frame. The first that does not ends the
    /// count, and it and every chapter after it are removed, so the chapters
    /// kept are exactly the first `count`, and the next to speak is chapter
    /// `count`.
    ///
    /// Removing is done as far as it can be: what cannot be removed is left,
    /// for the sweep at the next launch, and a chapter's file left where the
    /// next chapter goes is replaced by `finishChapter(_:)`.
    /// - Returns: How many chapters are kept, from the first.
    /// - Throws: The file system's error when a folder can't be made or read.
    func open() throws -> Int {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

        // One export's chapters are kept at a time: another export's, and
        // anything else in the root, go.
        let others = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != key }
        for item in others {
            try? files.removeItem(at: item)
        }

        // A part file is a chapter cut off midway: it is spoken again.
        let names = try files.contentsOfDirectory(atPath: folder.path)
        for name in names where name.hasSuffix(Self.partSuffix) {
            try? files.removeItem(at: folder.appendingPathComponent(name, isDirectory: false))
        }

        // The chapters kept run from the first up to the first that is
        // missing or not whole.
        var count = 0
        while Self.isWholeChapter(at: chapterURL(count)) {
            count += 1
        }

        // That one and every chapter after it are spoken again, so none is
        // ever taken up out of order.
        for name in names {
            if let index = chapterIndex(ofName: name), index >= count {
                try? files.removeItem(at: chapterURL(index))
            }
        }
        return count
    }

    /// Whether the file at `url` is a whole chapter: one that exists and
    /// opens as audio holding at least one frame. Audio the import converts,
    /// Ogg above all, is never opened in the app (B06), so a file whose
    /// bytes are such audio is not a chapter, whatever its name.
    private static func isWholeChapter(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              !ImportAudioConverter.isNeverDecodedInApp(url),
              let file = try? AVAudioFile(forReading: url) // lint-ok: isNeverDecodedInApp refuses every format the import converts, Ogg by its bytes, first
        else { return false }
        return file.length > 0
    }

    /// Gives chapter `index`, spoken whole into its part file, its own name,
    /// replacing a file already there, so it is kept.
    /// - Throws: The file system's error when the part can't be moved, or a
    ///   file in its way can't be removed.
    func finishChapter(_ index: Int) throws {
        let files = FileManager.default
        let chapter = chapterURL(index)
        if files.fileExists(atPath: chapter.path) {
            try files.removeItem(at: chapter)
        }
        try files.moveItem(at: partURL(index), to: chapter)
    }

    /// Removes `root` and every export's chapters in it, once an export has
    /// finished. Nothing is reported: what can't be removed now goes at the
    /// next launch.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - One Export at a Time

    /// Whether an export holds the store, process-wide.
    private static let claimed = OSAllocatedUnfairLock(initialState: false)

    /// Claims the store for one export, which releases it when it ends,
    /// however it ends (`release()`).
    /// - Returns: True when it is claimed now; false while another export
    ///   holds it.
    static func claim() -> Bool {
        claimed.withLock { isClaimed in
            guard !isClaimed else { return false }
            isClaimed = true
            return true
        }
    }

    /// Lets the store go, for the next export to claim.
    static func release() {
        claimed.withLock { $0 = false }
    }

    // MARK: - The Launch Sweep

    /// Removes the chapters every export kept at `root`, unless an export
    /// holds the store and is using them: a quit or a crash leaves kept
    /// chapters behind, which outlive only the session that spoke them.
    static func sweep(root: URL = liveRoot) {
        guard claim() else { return }
        defer { release() }
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs `sweep()` once, off the main thread at utility priority. It does
    /// nothing in hosted tests, as the other launch sweeps do nothing there,
    /// so it never holds the store while a test claims it.
    /// - Parameters:
    ///   - isHostedTest: Whether this is a hosted test run.
    ///   - completion: Called on the background queue when the sweep has
    ///     finished (tests wait on it); not called when nothing is run.
    static func sweepInBackground(
        isHostedTest: Bool = TextMouthRuntime.current.isHostedTest,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard !isHostedTest else { return }
        DispatchQueue.global(qos: .utility).async {
            sweep()
            completion?()
        }
    }
}

// MARK: - The Key's Digest

/// A SHA-256 digest fed strings and numbers so that no two of them can run
/// together: each number as its 8 bytes, least significant first, and each
/// string as its UTF-8 length, so fed, then its bytes.
private struct KeyDigest {
    /// The digest of everything fed so far.
    private var hasher = SHA256()

    /// Feeds `number` as its 8 bytes, least significant first.
    mutating func add(_ number: Int) {
        withUnsafeBytes(of: Int64(number).littleEndian) { hasher.update(bufferPointer: $0) }
    }

    /// Feeds `text`'s UTF-8 length, then its UTF-8 bytes.
    mutating func add(_ text: String) {
        let bytes = Data(text.utf8)
        add(bytes.count)
        hasher.update(data: bytes)
    }

    /// The first `byteCount` bytes of the digest, each as two lowercase
    /// hexadecimal digits.
    func hexadecimalPrefix(byteCount: Int) -> String {
        hasher.finalize().prefix(byteCount).map { String(format: "%02x", $0) }.joined()
    }
}
