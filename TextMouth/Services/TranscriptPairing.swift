import Foundation

// MARK: - A Transcript Beside the Audio (FMT23)

/// Where an import looks for a transcript beside the audio it imports
/// (FMT23): a WebVTT or SubRip file named as a track is, such as lecture.vtt
/// beside lecture.m4a, or 03.vtt beside 03.mp3 in a folder of tracks, a ZIP
/// of them, or a playlist's folder. Such a file becomes the book's
/// transcript, timed on its track, with nothing transcribed, on any macOS;
/// WebVTT is preferred to SubRip when both are there.
///
/// The transcript is kept as recognition's are, in the staged package's
/// transcript.json (`TranscriptStore`), recording where it came from
/// (`TranscriptSource.Origin.imported`). The book's text is written from it
/// the first time the book opens (`TranscriptTextLoader`), its library row
/// says it is transcribed as soon as it is listed, and its import offers no
/// transcription (`TranscriptionOffers`). A file found that cannot be used is
/// named to the listener once the import is done (`ImportedBook.notice`),
/// and the debug log says why. Attaching never fails an import, and a book
/// with no such file beside it imports as it always did.
enum TranscriptPairing: Sendable, Equatable {
    /// Beside the one file the import was chosen as: its name with .vtt,
    /// else .srt. The track's own path is not used: a conversion may have
    /// renamed the book's file (lecture.ogg becomes lecture.m4a).
    case besideFile(URL)
    /// In the folder the tracks' paths are relative to: each track's path
    /// with .vtt, else .srt, in place of its extension.
    case inFolder(URL)

    /// A transcript file found beside one of a book's tracks.
    struct FoundFile: Equatable, Sendable {
        /// The track's path in the book, as the book's transcript names the
        /// track (`TranscriptionPlan.File.path`).
        let trackPath: String
        /// Where the transcript file is.
        let url: URL
        /// The file's format, by its extension.
        let format: TimedTextFormat
        /// What the listener and the debug log call the file: its name as it
        /// is stored on disk (on a disk that ignores case, a lecture.VTT
        /// found by looking for lecture.vtt is named lecture.VTT), after the
        /// folders of its track's path for a track in a subfolder, such as
        /// "Disc 1/01.vtt", so two discs' 01.vtt are told apart. Never a
        /// path leading outside the folder looked in.
        let name: String
    }

    // MARK: Transcript Files Chosen With Their Audio

    /// `urls`, the items chosen to import, without the WebVTT and SubRip
    /// files among them that an audio file chosen with them finds as its
    /// transcript (`besideFile`): the audio's import attaches such a file
    /// itself, so it is no book of its own, and importing it as one would
    /// only refuse it as an unsupported format while the audio's book is
    /// made with it. A transcript file chosen without its audio, or whose
    /// audio is not among the items, or one the audio does not find (a .srt
    /// beside the audio's .vtt), stays in the list. The order of the rest is
    /// kept. It looks at the file system, a few times for each audio file
    /// chosen, and only when a transcript file is among `urls`.
    static func droppingTranscriptsChosenWithTheirAudio(_ urls: [URL]) -> [URL] {
        let isTranscript = urls.map { TimedTextFormat.cueFileFormat(forExtension: $0.pathExtension) != nil }
        guard isTranscript.contains(true) else { return urls }
        // The files the chosen audio files find, as lowercase paths: a disk
        // that ignores case may store a name in another case than the
        // lookup spells it.
        let found = Set(
            zip(urls, isTranscript)
                .filter { url, isTranscript in !isTranscript && BookFormat.detect(from: url) == .audio }
                .compactMap { url, _ in TranscriptPairing.besideFile(url).foundFile(forTrack: url.lastPathComponent) }
                .map { $0.url.standardizedFileURL.path.lowercased() }
        )
        return zip(urls, isTranscript)
            .filter { url, isTranscript in !(isTranscript && found.contains(url.standardizedFileURL.path.lowercased())) }
            .map(\.0)
    }

    // MARK: Finding a Track's Transcript File

    /// Where the transcript file of the track whose path in the book is
    /// `path` is (`foundFile(forTrack:)`); nil when there is none.
    func transcriptFile(forTrack path: String) -> URL? {
        foundFile(forTrack: path)?.url
    }

    /// The transcript file of the track whose path in the book is `path`:
    /// the track's name without its extension (for `besideFile`, the chosen
    /// file's name, whatever `path` is), with each extension of
    /// `TimedTextFormat.cueFileFormats` in order, .vtt before .srt, each
    /// tried in lowercase and then in uppercase ("VTT"). The first that names
    /// a regular file wins: a symbolic link is never followed, a folder is no
    /// transcript, and a named pipe or other special file is never taken,
    /// since reading one would wait forever. Nil when none is there.
    func foundFile(forTrack path: String) -> FoundFile? {
        guard let stem = stem(forTrack: path) else { return nil }
        for format in TimedTextFormat.cueFileFormats {
            for fileExtension in [format.fileExtension, format.fileExtension.uppercased()] {
                let candidate = stem.appendingPathExtension(fileExtension)
                if let storedName = Self.storedNameOfRegularFile(at: candidate) {
                    return FoundFile(
                        trackPath: path,
                        url: candidate,
                        format: format,
                        name: name(ofStored: storedName, forTrack: path)
                    )
                }
            }
        }
        return nil
    }

    /// The track's transcript file without its extension: for `besideFile`,
    /// the chosen file without its own, whatever the track's path; for
    /// `inFolder`, the track's path in the folder without its extension. Nil
    /// for a path that is empty, absolute, or climbs out of the folder with
    /// "..", which no book's content index holds: nothing outside the folder
    /// is ever looked at.
    private func stem(forTrack path: String) -> URL? {
        switch self {
        case .besideFile(let source):
            return source.deletingPathExtension()
        case .inFolder(let folder):
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            return folder.appendingPathComponent(path).deletingPathExtension()
        }
    }

    /// What the listener and the debug log call the transcript file stored
    /// as `storedName` beside the track at `path` (`FoundFile.name`): the
    /// name alone beside the one file chosen, and after the folders of the
    /// track's path in a folder of tracks.
    private func name(ofStored storedName: String, forTrack path: String) -> String {
        guard case .inFolder = self else { return storedName }
        let folders = (path as NSString).deletingLastPathComponent
        return folders.isEmpty ? storedName : "\(folders)/\(storedName)"
    }

    /// The name the item at `url` is stored under, when it is a regular file
    /// itself; nil when nothing is there, and for a folder, a symbolic link
    /// (`FileImportService.isSymbolicLink`: never followed, since it could
    /// lead anywhere), or a special file such as a named pipe, which
    /// `FileManager.fileExists(atPath:isDirectory:)` takes for a file and
    /// whose reading would wait forever. On a disk that ignores case, the
    /// name stored may differ in case from `url`'s.
    private static func storedNameOfRegularFile(at url: URL) -> String? {
        guard !FileImportService.isSymbolicLink(url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .nameKey]),
              values.isRegularFile == true else { return nil }
        return values.name ?? url.lastPathComponent
    }

    // MARK: Attaching

    /// Attaches the transcript files `pairing` finds beside the tracks of
    /// `staged`, an audiobook whose content was just read as `index`, as the
    /// book's transcript, written into its staged package
    /// (`staged.tmbDirectory`) before the package is published.
    ///
    /// The book's tracks are looked through first, in the order the book
    /// plays them, without measuring any
    /// (`TranscriptionPlan.audioFileLocations(of:index:)`): a book with no
    /// transcript file beside it is left as it is, with nothing measured,
    /// written, or logged. Otherwise every track is measured
    /// (`TranscriptionPlan.make`), and each file found is read as its format
    /// (`TimedTextReader`, at most `TimedTextLimits.localFileBytes`) and
    /// checked against its own track's length (`OutsideTranscript.checkFits`):
    /// one that cannot be read, or runs on past its track's end, is set aside
    /// with why. The files kept make one transcript
    /// (`OutsideTranscript.transcript(sentencesByFile:plan:source:now:hasher:)`),
    /// whose source names each file's format, in the order the tracks play,
    /// and its name when it is the only one kept.
    ///
    /// Nothing here fails the import: when the tracks cannot be measured, or
    /// the transcript cannot be made or written, every file that would have
    /// been attached is set aside with that reason instead. The debug log
    /// has one TRANSCRIPT_FOUND_AT_IMPORT line for a transcript attached and
    /// one TRANSCRIPT_FOUND_AT_IMPORT_REFUSED line for each file set aside,
    /// naming the book by its title and each file by its name
    /// (`FoundFile.name`), never by a path, and never quoting a transcript's
    /// words. It blocks while it reads, measures, and fingerprints the
    /// book's audio, as an import does on its own thread.
    /// - Returns: what the listener is told of the files set aside, in the
    ///   order the book plays their tracks (`notice(forSetAside:)`); nil
    ///   when none was, and for a book that is not an audiobook.
    static func attach(_ pairing: TranscriptPairing, to staged: Book, index: BookContentIndex) -> String? {
        guard staged.format.isAudio else { return nil }
        let found = distinctFiles(
            TranscriptionPlan.audioFileLocations(of: staged, index: index)
                .compactMap { pairing.foundFile(forTrack: $0.path) }
        )
        guard !found.isEmpty else { return nil }
        let setAside = attaching(found, to: staged, index: index).compactMap(\.asSetAside)
        for (file, refusal) in setAside {
            DiagnosticLog.event(
                .import,
                "TRANSCRIPT_FOUND_AT_IMPORT_REFUSED: \(staged.title): \(file.name): \(refusal.logReason)"
            )
        }
        return notice(forSetAside: setAside.map { (fileName: $0.file.name, reason: $0.refusal.reason) })
    }

    /// `files`, the transcript files found beside a book's tracks in the
    /// order it plays them, without a second track taking a file an earlier
    /// track has. Two tracks share a transcript file when their names differ
    /// only in their extension (01.mp3 and 01.flac both look for 01.vtt);
    /// the file times the one that plays first, so its sentences are never
    /// laid over two tracks, which would read the same passage twice in the
    /// book's text. The other track simply has no transcript, as a track
    /// with no file beside it has none.
    static func distinctFiles(_ files: [FoundFile]) -> [FoundFile] {
        var taken = Set<URL>()
        return files.filter { taken.insert($0.url).inserted }
    }

    /// Attaches the files of `found`, the transcript files beside the tracks
    /// of `staged`, as `attach(_:to:index:)` describes, and returns what
    /// became of each, in the order the book plays their tracks.
    private static func attaching(_ found: [FoundFile], to staged: Book, index: BookContentIndex) -> [Outcome] {
        let plan: TranscriptionPlan
        do {
            plan = try TranscriptionPlan.make(
                for: staged,
                index: index,
                isDataless: DatalessFiles.isDataless,
                measure: TranscriptionPlan.duration(ofAudioFileAt:)
            )
        } catch {
            // The audio is read already, so only a track macOS cannot
            // measure gets here.
            return found.map { .setAside($0, Refusal(error)) }
        }
        // The plan lists the same tracks the files were found beside, each
        // once, in the same order.
        let foundByTrack = Dictionary(found.map { ($0.trackPath, $0) }, uniquingKeysWith: { earlier, _ in earlier })
        var outcomes = plan.files.compactMap { track in
            foundByTrack[track.path].map { read($0, fitting: track) }
        }
        let kept = outcomes.compactMap(\.asKept)
        guard let first = kept.first else { return outcomes }
        do {
            let transcript = try OutsideTranscript.transcript(
                sentencesByFile: Dictionary(
                    kept.map { ($0.file.trackPath, $0.sentences) },
                    uniquingKeysWith: { earlier, _ in earlier }
                ),
                plan: plan,
                source: TranscriptSource(
                    origin: .imported,
                    format: first.file.format,
                    fileName: kept.count == 1 ? first.file.name : nil,
                    otherFormats: kept.dropFirst().map(\.file.format)
                )
            )
            try TranscriptStore.write(transcript, into: staged.tmbDirectory)
            DiagnosticLog.event(
                .import,
                "TRANSCRIPT_FOUND_AT_IMPORT: \(staged.title): \(kept.count) of \(plan.files.count) tracks' transcripts attached"
            )
        } catch {
            // A transcript that cannot be made or written attaches none of
            // its files, and the listener hears of each.
            let refusal = Refusal(error)
            outcomes = outcomes.map { $0.settingAsideIfKept(for: refusal) }
        }
        return outcomes
    }

    /// What becomes of `file`, the transcript file found beside `track`:
    /// kept, with its sentences timed from the track's start, when it reads
    /// as its format and runs no further past the track's end than
    /// `TimedTextLimits.pastTheEndMarginMilliseconds`; set aside with why
    /// otherwise.
    private static func read(_ file: FoundFile, fitting track: TranscriptionPlan.File) -> Outcome {
        do {
            let sentences = try TimedTextReader.read(fileAt: file.url, as: file.format).sentences
            try OutsideTranscript.checkFits(sentences, durationMilliseconds: Transcript.milliseconds(track.duration))
            return .kept(file, sentences: sentences)
        } catch {
            return .setAside(file, Refusal(error))
        }
    }

    // MARK: Telling the Listener

    /// What the listener is told once the import is done of the transcript
    /// files `setAside`, found beside the audio but not attached, in the
    /// order the book plays their tracks: the one file with why
    /// (`TranscriptionWording.transcriptNotAttached(fileName:reason:)`), or
    /// several by name, the debug log saying why
    /// (`TranscriptionWording.transcriptsNotAttached(fileNames:)`). Nil for
    /// none.
    static func notice(forSetAside setAside: [(fileName: String, reason: String)]) -> String? {
        guard let first = setAside.first else { return nil }
        guard setAside.count > 1 else {
            return TranscriptionWording.transcriptNotAttached(fileName: first.fileName, reason: first.reason)
        }
        return TranscriptionWording.transcriptsNotAttached(fileNames: setAside.map { $0.fileName })
    }

    // MARK: What Became of a File

    /// What became of one transcript file found beside a track.
    private enum Outcome {
        /// Read, and fitting its track: its sentences, timed from the
        /// track's start.
        case kept(FoundFile, sentences: [TranscriptSentence])
        /// Not attached, for the reason given.
        case setAside(FoundFile, Refusal)

        /// The file and its sentences, when it was kept.
        var asKept: (file: FoundFile, sentences: [TranscriptSentence])? {
            guard case .kept(let file, let sentences) = self else { return nil }
            return (file, sentences)
        }

        /// The file and why, when it was set aside.
        var asSetAside: (file: FoundFile, refusal: Refusal)? {
            guard case .setAside(let file, let refusal) = self else { return nil }
            return (file, refusal)
        }

        /// This outcome with a file kept set aside for `refusal` instead, as
        /// when the transcript the kept files make cannot be written.
        func settingAsideIfKept(for refusal: Refusal) -> Outcome {
            guard case .kept(let file, _) = self else { return self }
            return .setAside(file, refusal)
        }
    }

    /// Why a transcript file was set aside.
    private struct Refusal {
        /// In words a listener understands: the error's description, which
        /// never quotes the file's text (`TimedTextError`,
        /// `OutsideTranscriptError`), or the system's words for a file it
        /// could not read or write.
        let reason: String
        /// The same for the debug log, with the detail an unusable
        /// transcript's error keeps for the log alone
        /// (`OutsideTranscriptError.unusable`), which names fields and
        /// numbers, never words.
        let logReason: String

        /// The refusal `error` gives.
        init(_ error: any Error) {
            reason = error.localizedDescription
            if case .unusable(let detail)? = error as? OutsideTranscriptError {
                logReason = "\(reason) (\(detail))"
            } else {
                logReason = reason
            }
        }
    }
}

// MARK: - A Transcript Found at Import

/// The words an import says of a transcript file found beside the audio
/// (FMT23), kept beside the pairing that says them.
extension TranscriptionWording {
    /// What the listener is told once an import is done when the one
    /// transcript file found beside the audio was not attached as the book's
    /// transcript, naming it and why: "“lecture.vtt” was beside the audio
    /// but wasn't attached as the book's transcript: The file isn't a WebVTT
    /// transcript TextMouth can read."
    static func transcriptNotAttached(fileName: String, reason: String) -> String {
        "“\(fileName)” was beside the audio but wasn't attached as the book's transcript: \(reason)"
    }

    /// What the listener is told when several transcript files found beside
    /// the audio were not attached: their names, in the order given, as a
    /// sentence lists them, at most `transcriptFilesNamedAtMost` of them and
    /// then how many more, with the debug log saying why for each: "These
    /// transcript files were beside the audio but weren't attached:
    /// “03.vtt”, “07.vtt”, and “09.srt”. The debug log says why."
    static func transcriptsNotAttached(fileNames: [String]) -> String {
        let named = fileNames.prefix(transcriptFilesNamedAtMost).map { "“\($0)”" }
        let rest = fileNames.count - named.count
        let list = CountWording.list(rest > 0 ? named + ["\(rest) more"] : named)
        return "These transcript files were beside the audio but weren't attached: \(list). The debug log says why."
    }

    /// The most transcript files `transcriptsNotAttached(fileNames:)` names
    /// before it counts the rest.
    static let transcriptFilesNamedAtMost = 5

    /// What the listener hears once Replace Existing has kept the existing
    /// copy's transcript over the one the new copy brought from a file
    /// beside its audio (B1), as the question said: the one file by name,
    /// with the way to use it after all, "“lecture.vtt” was beside the audio
    /// but wasn't attached as the book's transcript: Replacing kept the
    /// existing copy's transcript. To use the file instead, open the book and
    /// choose Attach Transcript… from the Book menu."; or, when each track
    /// brought its own, the files together, which Attach Transcript…, taking
    /// one file for the book, cannot attach again.
    static func broughtTranscriptNotUsed(fileName: String?) -> String {
        let reason = "Replacing kept the existing copy's transcript."
        guard let fileName else {
            return "The transcript files beside the audio weren't attached as the book's transcript: \(reason)"
        }
        return transcriptNotAttached(fileName: fileName, reason: reason)
            + " To use the file instead, open the book and choose \(attachCommandTitle) from the Book menu."
    }
}
