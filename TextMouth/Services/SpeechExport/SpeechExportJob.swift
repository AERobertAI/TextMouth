import Foundation
import os

// MARK: - The Request

/// Everything one speech export (FMT43) reads besides the book's text: the
/// book, the file it makes, the part of the book it speaks, and how the book
/// is spoken. The Export dialog makes it on the main actor from the book and
/// its own controls; being a value, nothing changed afterwards reaches an
/// export that is running, so every chapter of one file is spoken alike.
struct SpeechExportRequest: Equatable, Sendable {
    /// The book's ID, one of the things that decide whether chapters kept
    /// from an earlier export can be used again (`SpeechExportStore.key`).
    var bookID: UUID
    /// The book's title, which names the chapter of the text before the
    /// first heading, and of a heading whose text is blank.
    var bookTitle: String
    /// The exported file's name, without its extension.
    var fileTitle: String
    /// The exported file's title tag.
    var titleTag: String
    /// The exported file's artist tag, or nil for none.
    var author: String?
    /// The format the file is written in.
    var format: SpeechExportFormat
    /// The part of the book spoken: all of it, or a range of its headings.
    var range: SpeechExportRange
    /// The voice that speaks, at the speed and pitch of the dialog's
    /// sliders.
    var voice: SpeechExportVoiceSettings
    /// The IDs of the book's skipped headings, whose sections are left out
    /// as the reader leaves them out.
    var skippedHeadingIDs: Set<String>
    /// The settings the speech is prepared with, as the reader prepares it.
    var preparation: SpeechPreparationSettings
}

// MARK: - Progress

/// How far a speech export has come, as the Export dialog shows it and
/// VoiceOver reads it.
enum SpeechExportProgress: Equatable, Sendable {
    /// The chapters are being spoken: `done` of the file's `total` chapters
    /// are finished, those kept from an earlier export among them, and
    /// `fraction` of the whole export's speech, from 0 to 1, is spoken.
    case speaking(done: Int, total: Int, fraction: Double)
    /// The file's `chapters` spoken chapters are being encoded into it,
    /// `fraction` of the way, from 0 to 1.
    case encoding(chapters: Int, fraction: Double)
    /// The export has ended, however it ended, with `kept` of its `total`
    /// chapters kept for the next export of the same speech to go on from:
    /// none once its file is in place, and any finished so far after a Stop
    /// or a failure. Told once, last of all.
    case ended(kept: Int, total: Int)
}

// MARK: - What an Export Reaches

/// What a speech export reaches beyond its own work: the synthesizer that
/// speaks, the installed voices, the power assertion, the disks, and the
/// folder its chapters are kept in. The app passes `live`; tests pass
/// fakes, so that no test speaks aloud, uses a Personal Voice, keeps the Mac
/// awake, or depends on the disk's free space.
struct SpeechExportEnvironment: Sendable {
    /// What speaks each chapter into buffers, never aloud.
    var synthesizer: any SpeechBufferSynthesizing
    /// What is known of the installed voice with an identifier, or nil when
    /// no installed voice has it.
    var voiceInfo: @Sendable (String) -> SpeechExportVoiceInfo?
    /// The assertion that keeps the Mac awake while the export speaks and
    /// encodes.
    var power: SpeechExportPower
    /// The free bytes on the volume holding a location, or nil when they
    /// can't be told.
    var freeSpace: @Sendable (URL) -> Int64?
    /// Whether two locations are on one volume.
    var sameVolume: @Sendable (URL, URL) -> Bool
    /// The folder every export's kept chapters are under.
    var storeRoot: URL

    /// The app's own: the Mac's synthesizer, its installed voices, the
    /// system's power assertions, the disks' own free space, and the kept
    /// chapters' folder in this Mac's Caches folder.
    static var live: SpeechExportEnvironment {
        SpeechExportEnvironment(
            synthesizer: SystemSpeechBufferSynthesizer(),
            voiceInfo: { SpeechExportVoiceInfo.installed($0) },
            power: .live,
            freeSpace: { ArchiveLimits.volumeFreeSpace(at: $0) },
            sameVolume: { ImportScratchSpace.areOnSameVolume($0, $1) },
            storeRoot: SpeechExportStore.liveRoot
        )
    }
}

/// What the Export job runner (`BookExportService`) hands a speech export:
/// what the export reaches, and where its progress goes.
struct SpeechExportContext: Sendable {
    /// What the export reaches.
    var environment: SpeechExportEnvironment
    /// Hears the export's progress, on the thread the export runs on, the
    /// synthesizer's, or the encoder's: it must be quick, and must never wait
    /// for the thread that runs the export.
    var progress: @Sendable (SpeechExportProgress) -> Void

    /// The live environment, its progress heard by no one.
    static var live: SpeechExportContext {
        SpeechExportContext(environment: .live, progress: { _ in })
    }
}

// MARK: - The Job

/// Exports a text book, or a range of its headings, as one spoken audio file
/// (FMT43): the reader's text of each heading's section is spoken by the
/// book's voice into a chapter file of its own, kept so that a stopped export
/// goes on from its next chapter, and the chapters are then encoded into one
/// M4B, M4A, or MP3 with a chapter marker at the start of each.
///
/// A run blocks its thread for as long as the voice speaks, which can be half
/// an hour: the job runner calls it on its background thread, never the main
/// one.
enum SpeechExportJob {
    /// Seconds of silence closing every chapter but the last, so that one
    /// chapter's last words do not run into the next chapter's heading.
    static let chapterGap: TimeInterval = 0.5

    /// The least time between two reports of progress made while a chapter
    /// is spoken or the file is encoded, in seconds: the renderer tells of
    /// every buffer it writes, tens of times a second. The export's start,
    /// each chapter's end, and the encode's start and end are told at once.
    static let progressInterval: TimeInterval = 0.25

    /// The name the power assertion is held under, as `pmset -g assertions`
    /// lists it.
    static let powerAssertionReason = "TextMouth is exporting a book as spoken audio"

    /// Speaks `request`'s part of the book whose text cache holds `markdown`
    /// into one audio file at `destination`, telling its progress all along
    /// to `context.progress`.
    ///
    /// In order, it claims the store, so that one export runs at a time;
    /// reads the reader's text of the range, a chapter for each heading;
    /// refuses a voice that cannot speak into a file; opens the store,
    /// keeping the chapters an earlier export of the same speech finished;
    /// and checks that the disks have room. Then, keeping the Mac awake, it
    /// speaks each chapter not kept into a file of its own, encodes them all
    /// into the file, has `deliver` put the file where it belongs, and only
    /// then lets the kept chapters go. A Stop or a failure, of `deliver` too,
    /// leaves every chapter finished so far kept, for the next export of the
    /// same speech to go on from, in any format: speaking a book can take
    /// hours, and a file that could not be moved in costs none of them.
    ///
    /// However it ends, it writes one line in the debug log, which tells how
    /// it ended, its chapters, and its seconds, and nothing else, and tells
    /// `context.progress` how many chapters it left kept (`.ended`).
    ///
    /// - Parameters:
    ///   - request: What to export, and how.
    ///   - markdown: The bytes of the book's text cache, its content.md.
    ///   - source: Where those bytes were read from, which an error reading
    ///     them names.
    ///   - destination: Where the file goes; a file already there is
    ///     replaced.
    ///   - context: What the export reaches, and where its progress goes.
    ///   - cancellation: The export's Stop.
    ///   - deliver: Runs once the file is whole at `destination`, before the
    ///     kept chapters go, while the store and the Mac are still held: what
    ///     moves a file made in a scratch folder to where it belongs. By
    ///     default nothing, `destination` being that place.
    /// - Throws: A `SpeechExportError` for an export refused before anything
    ///   is spoken; `CancellationError` at Stop; a `SpeechRenderFailure` for a
    ///   chapter that could not be spoken; an `AudioEditError` for chapters
    ///   that could not be encoded; what `deliver` throws; or the file
    ///   system's error, each as it is.
    static func run(
        _ request: SpeechExportRequest,
        markdown: Data,
        source: URL,
        to destination: URL,
        context: SpeechExportContext,
        cancellation: BookExportCancellation,
        deliver: () throws -> Void = {}
    ) throws {
        let started = ContinuousClock.now
        // What the export has counted so far, which its log line tells.
        var counts = ChapterCounts()
        do {
            // One export at a time; the store is released however this one
            // ends.
            guard SpeechExportStore.claim() else { throw SpeechExportError.busy }
            defer { SpeechExportStore.release() }

            // What is spoken, and by which voice: either refused before
            // anything is held or spoken.
            let sections = try spokenSections(of: request, markdown: markdown, source: source)
            counts.total = sections.count
            let voiceIdentifier = try usableVoice(of: request, lookingUp: context.environment.voiceInfo)
            // Stop pressed while the text was read ends the export before its
            // store is opened, which would let every other export's kept
            // chapters go.
            try cancellation.checkCancelled()

            // The chapters an earlier export of the same speech finished are
            // kept, and this export goes on after them.
            let plan = Plan(
                request: request,
                sections: sections,
                voiceIdentifier: voiceIdentifier,
                environment: context.environment,
                cancellation: cancellation
            )
            counts.kept = try min(plan.store.open(), sections.count)
            counts.done = counts.kept
            try plan.checkSpace(keeping: counts.kept, destination: destination, environment: context.environment)

            try context.environment.power.whileHeld(reason: powerAssertionReason) {
                let reporter = ProgressReporter(listener: context.progress, interval: progressInterval)
                let shares = plan.shares
                reporter.report(shares.progress(finished: counts.done), urgent: true)
                for index in counts.kept..<sections.count {
                    // The chapter's own progress, between its start and its
                    // end, comes with its buffers, on the synthesizer's thread.
                    try plan.speakChapter(index) { frames in
                        reporter.report(shares.progress(speaking: index, framesWritten: frames), urgent: false)
                    }
                    counts.done = index + 1
                    reporter.report(shares.progress(finished: counts.done), urgent: true)
                }
                try plan.encode(to: destination, reporter: reporter)
                try deliver()
                // Only a file in its place lets the kept chapters go.
                plan.store.removeAll()
            }
            log(.finished, counts, since: started)
            context.progress(.ended(kept: 0, total: counts.total))
        } catch {
            log(error is CancellationError ? .stopped : .failed, counts, since: started)
            context.progress(.ended(kept: counts.done, total: counts.total))
            throw error
        }
    }

    // MARK: Before Anything Is Held

    /// The file's chapters: the reader's speech of `request`'s range in the
    /// book whose text cache holds `markdown`, read from `source`, with a
    /// chapter for each heading and one for any text before the first, and
    /// what has nothing to speak left out (`SpeechExportText.sections`).
    /// - Throws: `SpeechExportError.headingsChanged` when the range names a
    ///   heading the book no longer has; `.nothingToSpeak` when it holds
    ///   nothing to speak; or the error reading the text cache throws, for
    ///   bytes that are not UTF-8.
    private static func spokenSections(
        of request: SpeechExportRequest,
        markdown: Data,
        source: URL
    ) throws -> [SpeechExportSection] {
        let content = try BookExportService.readingContent(fromMarkdown: markdown, at: source, title: request.bookTitle)
        let sections: [SpeechExportSection]
        do {
            sections = try SpeechExportText.sections(
                of: content,
                range: request.range,
                skippedHeadingIDs: request.skippedHeadingIDs,
                settings: request.preparation,
                bookTitle: request.bookTitle
            )
        } catch SpeechExportText.Failure.headingNotFound(_) {
            // The book was read again with other headings after the dialog
            // chose the range.
            throw SpeechExportError.headingsChanged
        }
        guard !sections.isEmpty else { throw SpeechExportError.nothingToSpeak }
        return sections
    }

    /// The identifier of the voice that speaks `request`, once `voiceInfo`
    /// finds it installed and not a Personal Voice.
    /// - Throws: `SpeechExportError.noVoice` when the request names no voice,
    ///   or no installed voice has its identifier; `.personalVoice(name:)`
    ///   for a Personal Voice, which macOS speaks aloud but never into a
    ///   file.
    private static func usableVoice(
        of request: SpeechExportRequest,
        lookingUp voiceInfo: (String) -> SpeechExportVoiceInfo?
    ) throws -> String {
        guard let identifier = request.voice.voiceIdentifier, let voice = voiceInfo(identifier) else {
            throw SpeechExportError.noVoice
        }
        guard !voice.isPersonalVoice else {
            throw SpeechExportError.personalVoice(name: voice.name)
        }
        return identifier
    }

    // MARK: The Log

    /// Writes the export's one line in the debug log, however it ended: how
    /// it ended, its chapters, and its seconds since `started`, and nothing
    /// that could name the book, its text, its voice, or a path.
    private static func log(_ ending: Ending, _ counts: ChapterCounts, since started: ContinuousClock.Instant) {
        let elapsed: Double = started.duration(to: ContinuousClock.now) / .seconds(1)
        let seconds = String(format: "%.1f", elapsed)
        DiagnosticLog.event(
            .storage,
            "SPEECH_EXPORT: \(ending.rawValue) after \(counts.done) of \(counts.total) chapters "
                + "(\(counts.kept) kept from an earlier export) in \(seconds) s"
        )
    }
}

// MARK: - One Export's Parts

extension SpeechExportJob {
    /// How an export ended, in its log line's word.
    fileprivate enum Ending: String {
        /// Its file was made.
        case finished
        /// Stop ended it.
        case stopped
        /// A refusal or an error ended it.
        case failed
    }

    /// The chapters an export has counted as it goes, which its log line
    /// tells.
    fileprivate struct ChapterCounts {
        /// The file's chapters: 0 until the book's text is read.
        var total = 0
        /// The chapters kept from an earlier export, which this one went on
        /// from without speaking them.
        var kept = 0
        /// The chapters finished, the kept ones among them.
        var done = 0
    }

    /// One export once it knows what it speaks and how: the file's chapters,
    /// the voice, and the store they are kept in. What the steps that write
    /// files are made from.
    fileprivate struct Plan {
        /// The frames a second a chapter's speech is estimated in, to tell how
        /// far through a chapter its voice has come: the rate the system's
        /// voices speak at, as the disk check assumes
        /// (`SpeechExportSpace.speechBytesPerSecond`, 16-bit mono).
        private static let estimatedFramesPerSecond = 22_050.0

        /// What was asked for.
        let request: SpeechExportRequest
        /// The file's chapters, in order.
        let sections: [SpeechExportSection]
        /// Each chapter's words, counted once for the disk check and for the
        /// estimates of how long each chapter takes to speak.
        let wordCounts: [Int]
        /// The voice that speaks: installed, and not a Personal Voice.
        let voiceIdentifier: String
        /// Where the chapters are spoken and kept, under a key made of
        /// everything that changes how they sound.
        let store: SpeechExportStore
        /// What speaks each chapter into buffers.
        let synthesizer: any SpeechBufferSynthesizing
        /// The export's Stop.
        let cancellation: BookExportCancellation

        /// The plan for speaking `sections` as `request` asks, in the voice
        /// `voiceIdentifier`, with what `environment` provides.
        ///
        /// The store's key covers the book, the voice, the speed, the pitch,
        /// and each section as its title then its texts, so kept chapters are
        /// used again only by an export that would speak them alike. The
        /// format is not in it: an export asked again in another format goes
        /// on from the chapters kept.
        init(
            request: SpeechExportRequest,
            sections: [SpeechExportSection],
            voiceIdentifier: String,
            environment: SpeechExportEnvironment,
            cancellation: BookExportCancellation
        ) {
            self.request = request
            self.sections = sections
            wordCounts = sections.map(\.wordCount)
            self.voiceIdentifier = voiceIdentifier
            store = SpeechExportStore(
                root: environment.storeRoot,
                key: SpeechExportStore.key(
                    bookID: request.bookID,
                    voiceIdentifier: voiceIdentifier,
                    wordsPerMinute: request.voice.wordsPerMinute,
                    pitch: request.voice.pitch,
                    sections: sections.map { [$0.title] + $0.texts }
                )
            )
            synthesizer = environment.synthesizer
            self.cancellation = cancellation
        }

        /// How the chapters share the export's speech, for its progress: each
        /// by its length, and each estimated to take as many frames as its
        /// words take to speak at the request's speed.
        var shares: Shares {
            Shares(
                lengths: sections.map(\.utf16Length),
                estimatedFrames: wordCounts.map { seconds(ofWords: $0) * Self.estimatedFramesPerSecond }
            )
        }

        /// Checks that the disks have room for the chapters still to speak,
        /// those after the first `kept`, on the store's volume, and for the
        /// file of every chapter, on the volume of `destination`'s folder,
        /// each as long as its words take to speak at the request's speed.
        /// - Throws: `SpeechExportError.notEnoughSpace` for a disk without
        ///   room.
        func checkSpace(keeping kept: Int, destination: URL, environment: SpeechExportEnvironment) throws {
            try SpeechExportSpace.check(
                speechSeconds: seconds(ofWords: wordCounts[kept...].reduce(0, +)),
                fileSeconds: seconds(ofWords: wordCounts.reduce(0, +)),
                speechFolder: store.root,
                fileFolder: destination.deletingLastPathComponent(),
                freeSpace: environment.freeSpace,
                sameVolume: environment.sameVolume
            )
        }

        /// Speaks chapter `index` into its part file, then keeps it under its
        /// chapter's name: its title and texts, in the plan's voice, at the
        /// request's speed and pitch, closed by `chapterGap` of silence unless
        /// it is the file's last chapter. `framesWritten` hears the chapter's
        /// frames of speech so far after each buffer, on the synthesizer's
        /// thread.
        /// - Throws: What the renderer throws, which leaves no part file: a
        ///   `SpeechRenderFailure`, `CancellationError` at Stop, or the file
        ///   system's error; or the file system's error keeping the chapter.
        func speakChapter(_ index: Int, framesWritten: @escaping (Int64) -> Void) throws {
            let section = sections[index]
            _ = try SpeechChapterRenderer.render(
                title: section.title,
                texts: section.texts,
                voiceIdentifier: voiceIdentifier,
                wordsPerMinute: request.voice.wordsPerMinute,
                pitch: request.voice.pitch,
                trailingSilence: index < sections.count - 1 ? SpeechExportJob.chapterGap : 0,
                to: store.partURL(index),
                synthesizer: synthesizer,
                cancellation: cancellation,
                framesWritten: framesWritten
            )
            try store.finishChapter(index)
        }

        /// Encodes every chapter, each finished and kept by now, into one file
        /// of the request's format at `destination`, with a chapter marker at
        /// the start of each, tagged with the request's title and author.
        /// `reporter` hears the encode at 0 as it starts, the encoder's own
        /// progress at most once every `progressInterval`, and 1 once the file
        /// is written.
        /// - Throws: What `SpeechExportEncoder.encode` throws, which leaves
        ///   nothing at `destination`.
        func encode(to destination: URL, reporter: ProgressReporter) throws {
            let count = sections.count
            reporter.report(.encoding(chapters: count, fraction: 0), urgent: true)
            try SpeechExportEncoder.encode(
                sections.enumerated().map { index, section in
                    SpeechExportChapterFile(name: store.chapterName(index), title: section.title)
                },
                in: store.folder,
                format: request.format,
                metadata: AudioRenderMetadata(title: request.titleTag, author: request.author),
                to: destination,
                cancellation: cancellation,
                progress: { fraction in
                    reporter.report(.encoding(chapters: count, fraction: fraction), urgent: false)
                }
            )
            reporter.report(.encoding(chapters: count, fraction: 1), urgent: true)
        }

        /// How long `words` words take to speak at the request's speed.
        private func seconds(ofWords words: Int) -> TimeInterval {
            SpeechExportSpace.seconds(wordCount: words, wordsPerMinute: request.voice.wordsPerMinute)
        }
    }

    /// How the chapters share an export's speech, for the progress told while
    /// they are spoken (`SpeechExportProgress.speaking`). Each chapter's share
    /// is its length in UTF-16 units over all the chapters'. A chapter being
    /// spoken counts the part of its share that its frames so far are of the
    /// frames it is estimated to take, but never all of it, which only its
    /// end counts, since an estimate can fall short of a slow voice.
    fileprivate struct Shares {
        /// The most of its share a chapter being spoken counts before it
        /// ends.
        private static let partCap = 0.99

        /// Each chapter's length, in UTF-16 units.
        private let lengths: [Int]
        /// The UTF-16 units of the chapters before each chapter, then of them
        /// all: one more sum than there are chapters, the first 0.
        private let lengthsBefore: [Int]
        /// The frames each chapter is estimated to take.
        private let estimatedFrames: [Double]

        /// The shares of chapters `lengths` long, which are estimated to take
        /// `estimatedFrames`, one for each.
        init(lengths: [Int], estimatedFrames: [Double]) {
            self.lengths = lengths
            lengthsBefore = lengths.reduce(into: [0]) { sums, length in
                sums.append((sums.last ?? 0) + length)
            }
            self.estimatedFrames = estimatedFrames
        }

        /// The progress once the first `done` chapters are finished.
        func progress(finished done: Int) -> SpeechExportProgress {
            .speaking(done: done, total: lengths.count, fraction: fraction(ofUnits: Double(lengthsBefore[done])))
        }

        /// The progress while chapter `index` is spoken, `frames` frames of
        /// its speech written: the chapters before it, and the part of its
        /// own share its frames are of its estimate, at most `partCap`.
        func progress(speaking index: Int, framesWritten frames: Int64) -> SpeechExportProgress {
            let estimate = estimatedFrames[index]
            // A chapter estimated at no frames, one without words, counts all
            // it may from its first buffer.
            let part = estimate > 0 ? min(Self.partCap, Double(frames) / estimate) : Self.partCap
            return .speaking(
                done: index,
                total: lengths.count,
                fraction: fraction(ofUnits: Double(lengthsBefore[index]) + Double(lengths[index]) * part)
            )
        }

        /// `units` UTF-16 units as a fraction of all the chapters'.
        private func fraction(ofUnits units: Double) -> Double {
            units / Double(max(1, lengthsBefore.last ?? 0))
        }
    }

    /// Hands an export's progress to its listener: at once when it is urgent
    /// (the export's start, each chapter's end, and the encode's start and
    /// end), and otherwise at most once every `interval`, since the renderer
    /// tells of every buffer it writes, tens of times a second, and the
    /// encoder of its work as often. The progress last handed on is never
    /// handed on again straight after it.
    ///
    /// Sendable without `@unchecked`: its listener is a Sendable closure, and
    /// its last report is kept in a lock, since the renderer's callback runs
    /// on the synthesizer's thread and the encoder's on its own.
    fileprivate final class ProgressReporter: Sendable {
        /// The progress last handed on, and when.
        private struct LastReport {
            /// What was handed on.
            let progress: SpeechExportProgress
            /// When it was handed on.
            let time: ContinuousClock.Instant
        }

        /// Where the progress goes.
        private let listener: @Sendable (SpeechExportProgress) -> Void
        /// The least time between a report and one after it that is not
        /// urgent.
        private let interval: Duration
        /// The last report, nil before the first.
        private let lastReport = OSAllocatedUnfairLock<LastReport?>(initialState: nil)

        /// A reporter to `listener`, telling it what is not urgent at most
        /// once every `interval` seconds.
        init(listener: @escaping @Sendable (SpeechExportProgress) -> Void, interval: TimeInterval) {
            self.listener = listener
            self.interval = .seconds(interval)
        }

        /// Hands `progress` to the listener, unless it is the progress last
        /// handed on, or it is not `urgent` and less than the interval has
        /// passed since the last report.
        func report(_ progress: SpeechExportProgress, urgent: Bool) {
            let now = ContinuousClock.now
            let interval = self.interval
            let isDue = lastReport.withLock { last -> Bool in
                if let previous = last {
                    guard progress != previous.progress,
                          urgent || previous.time.duration(to: now) >= interval else { return false }
                }
                last = LastReport(progress: progress, time: now)
                return true
            }
            // Outside the lock, so that a listener that waits, or reports in
            // turn, holds no report up.
            if isDue {
                listener(progress)
            }
        }
    }
}
