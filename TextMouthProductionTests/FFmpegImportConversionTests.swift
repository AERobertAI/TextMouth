import XCTest
import os
@testable import TextMouth

// MARK: - A Stand-in for ffmpeg

/// The plans a stand-in ffmpeg was given, in the order it was run, so a test
/// can see what the import asked of it. Its one property is a lock over
/// values that are `Sendable`, so the class is `Sendable` as it stands.
final class FFmpegPlanLog: Sendable {
    private let plans = OSAllocatedUnfairLock<[FFmpegAudioConverter.Plan]>(initialState: [])

    /// Records `plan`.
    func append(_ plan: FFmpegAudioConverter.Plan) {
        plans.withLock { $0.append(plan) }
    }

    /// Every plan recorded so far.
    var all: [FFmpegAudioConverter.Plan] { plans.withLock { $0 } }
}

extension XCTestCase {
    /// The programs a stand-in says it found: names of real executables
    /// that the stand-in's own command uses (`/bin/cp`), never ffmpeg.
    var standInPrograms: FFmpegAudioConverter.Programs {
        FFmpegAudioConverter.Programs(ffmpeg: URL(fileURLWithPath: "/bin/cp"), ffprobe: URL(fileURLWithPath: "/usr/bin/true"))
    }

    /// A stand-in for the installed ffmpeg and ffprobe (FMT31), since GitHub's
    /// runners have neither: it finds what `located` says, reports `report`
    /// (ffprobe's JSON, nil for no answer), and "converts" by copying
    /// `finished`, an AAC .m4a, to the output with `/bin/cp` in a watched
    /// child, as the real ffmpeg would write it; `command`, when given, runs
    /// instead (a `sleep` that hangs, a `false` that fails). Each plan it is
    /// given is recorded in `log`. Its limits are `seconds` for everything.
    func ffmpegStandIn(
        located: FFmpegAudioConverter.Located? = nil,
        report: String?,
        finished: URL? = nil,
        command: (@Sendable (_ output: URL) -> (executable: URL, arguments: [String]))? = nil,
        log: FFmpegPlanLog? = nil,
        seconds: TimeInterval = 60
    ) throws -> FFmpegAudioConverter.Tool {
        let located = located ?? .found(standInPrograms)
        let finished = try finished ?? formatSampleURL("m4b-chapters/three-tones.m4b")
        return FFmpegAudioConverter.Tool(
            locate: { located },
            probe: { _, _, _ in report.flatMap { FFprobeReport(json: Data($0.utf8)) } },
            hasAppleAACEncoder: { _ in true },
            command: { _, output, plan, _ in
                log?.append(plan)
                return command?(output) ?? (executable: URL(fileURLWithPath: "/bin/cp"), arguments: [finished.path, output.path])
            },
            limits: { _ in
                WatchedProcess.Limits(maximumSeconds: seconds, maximumResidentBytes: 1_073_741_824, maximumStalledSeconds: seconds)
            },
            residentMemory: { WatchedProcess.residentMemory(of: $0) }
        )
    }

    /// ffprobe's report of wma/tones-wma1.wma, trimmed: one WMA 1 stream of
    /// four seconds, as long as the stand-in's finished file, with the file's
    /// title, artist, and album.
    var standInWMAReport: String {
        """
        {"streams": [{"index": 0, "codec_name": "wmav1", "codec_type": "audio", "sample_rate": "22050", "channels": 1,
          "bit_rate": "32000", "duration": "3.999000", "disposition": {"default": 0, "attached_pic": 0}}],
         "format": {"format_name": "asf", "duration": "3.999000", "bit_rate": "40258",
          "tags": {"TITLE": "Three Tones", "artist": "TextMouth Test", "album": "Harbour Recordings"}}}
        """
    }
}

/// The ffmpeg import's conversions and imports (FMT31, FMT32), driven by a
/// stand-in for ffmpeg, so they run on GitHub's runners, which have none:
/// what each refusal says and when it comes, what is left behind (nothing),
/// how a hang, a failure, and a bad length end, and a whole import of a file
/// and of a folder through the import's own path. The tests that need the
/// real ffmpeg are `FFmpegImportRealTests`.
@MainActor
final class FFmpegImportConversionTests: XCTestCase {
    /// A copy of the sample `sample` named `name`, in a folder of its own.
    private func source(_ sample: String = "wma/tones-wma1.wma", named name: String = "tones.wma") throws -> URL {
        try copyOfFormatSample(sample, named: name)
    }

    /// The names of the files in `folder`, sorted, hidden ones included.
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: - Converting One File

    /// A WMA file becomes an .m4a beside it, named for it, that plays as
    /// long as the source says; the source is untouched, nothing else is left
    /// in its folder, and the plan is the one the report makes.
    func testAFileBecomesAnM4ABesideIt() async throws {
        let wma = try source()
        let before = try Data(contentsOf: wma)
        let log = FFmpegPlanLog()

        let conversion = try await FFmpegAudioConverter.convert(wma, using: try ffmpegStandIn(report: standInWMAReport, log: log))

        XCTAssertEqual(conversion.converted.lastPathComponent, "tones.m4a")
        XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.m4a", "tones.wma"])
        XCTAssertEqual(try Data(contentsOf: wma), before)
        XCTAssertEqual(conversion.duration, 3.999)
        XCTAssertEqual(log.all.map(\.container), [.asf])
        XCTAssertEqual(log.all.map(\.encoding), [.aac(encoder: "aac_at")])
        XCTAssertEqual(log.all.map(\.streamIndex), [0])
    }

    /// A name that is taken gets the next free one, as every conversion's does.
    func testATakenNameGetsTheNextFreeOne() async throws {
        let wma = try source()
        try Data("taken".utf8).write(to: wma.deletingLastPathComponent().appendingPathComponent("tones.m4a"))

        let conversion = try await FFmpegAudioConverter.convert(wma, using: try ffmpegStandIn(report: standInWMAReport))

        XCTAssertEqual(conversion.converted.lastPathComponent, "tones 2.m4a")
    }

    /// Without ffmpeg, or with an ffmpeg that has no ffprobe, the file is
    /// refused with what to install, naming its format, and no program runs.
    func testWithoutFFmpegTheFileIsRefusedWithWhatToInstall() async throws {
        for (located, expected) in [
            (FFmpegAudioConverter.Located.ffmpegMissing, FFmpegAudioConverter.Failure.ffmpegMissing(kind: "WMA")),
            (.ffprobeMissing, .ffprobeMissing(kind: "WMA")),
        ] {
            let wma = try source()
            let launches = WatchedProcess.launchCount
            do {
                _ = try await FFmpegAudioConverter.convert(wma, using: try ffmpegStandIn(located: located, report: standInWMAReport))
                XCTFail("\(located): the file must be refused")
            } catch {
                XCTAssertEqual(error as? FFmpegAudioConverter.Failure, expected)
            }
            XCTAssertEqual(WatchedProcess.launchCount, launches, "\(located): no program may run")
            XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"])
        }
    }

    /// A copy-protected WMA file is refused as copy-protected whether or not
    /// ffmpeg is installed, before anything runs: installing it would not help.
    func testACopyProtectedFileIsRefusedBeforeAnythingElse() async throws {
        let folder = try makeSandboxDirectory("FFmpegProtected")
        let locked = folder.appendingPathComponent("Locked.wma")
        try copyProtectedASF(from: try formatSampleURL("wma/tones-wma1.wma")).write(to: locked)
        for located in [FFmpegAudioConverter.Located.found(standInPrograms), .ffmpegMissing] {
            let launches = WatchedProcess.launchCount
            do {
                _ = try await FFmpegAudioConverter.convert(locked, using: try ffmpegStandIn(located: located, report: standInWMAReport))
                XCTFail("A copy-protected file must be refused")
            } catch {
                XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .copyProtected)
            }
            XCTAssertEqual(WatchedProcess.launchCount, launches)
        }
        XCTAssertEqual(try names(in: folder), ["Locked.wma"])
    }

    /// A file whose bytes are not of its name's format is refused as such,
    /// ffmpeg or not; so is one ffprobe can say nothing of; and one that holds
    /// no sound says so.
    func testAFileThatIsNotWhatItsNameSaysIsRefused() async throws {
        let folder = try makeSandboxDirectory("FFmpegNotRecognized")
        let fake = folder.appendingPathComponent("Fake.wma")
        try Data("not a Windows Media file".utf8).write(to: fake)
        for located in [FFmpegAudioConverter.Located.found(standInPrograms), .ffmpegMissing] {
            do {
                _ = try await FFmpegAudioConverter.convert(fake, using: try ffmpegStandIn(located: located, report: standInWMAReport))
                XCTFail("A file that is no WMA must be refused")
            } catch {
                XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .notRecognized(fileName: "Fake.wma", kind: "WMA"))
            }
        }
        let wma = try source()
        do {
            _ = try await FFmpegAudioConverter.convert(wma, using: try ffmpegStandIn(report: nil))
            XCTFail("A file ffprobe can't read must be refused")
        } catch {
            XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .notRecognized(fileName: "tones.wma", kind: "WMA"))
        }
        let video = try source("mkv/three-tones-flac.mkv", named: "Clip.mkv")
        let pictureOnly = #"{"streams": [{"index": 0, "codec_type": "video", "codec_name": "mjpeg", "disposition": {"default": 1}}], "format": {"format_name": "matroska,webm"}}"#
        do {
            _ = try await FFmpegAudioConverter.convert(video, using: try ffmpegStandIn(report: pictureOnly))
            XCTFail("A video without sound must be refused")
        } catch {
            XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .noSound(fileName: "Clip.mkv"))
        }
        XCTAssertEqual(try names(in: video.deletingLastPathComponent()), ["Clip.mkv"])
    }

    /// An ffmpeg that hangs is killed by the watchdog, one that fails is
    /// reported with its code, and a result that does not last as long as
    /// its source fails its check; each leaves nothing behind.
    func testAHangAFailureAndABadLengthLeaveNothingBehind() async throws {
        let hanging = try ffmpegStandIn(report: standInWMAReport, command: { _ in
            (URL(fileURLWithPath: "/bin/sleep"), ["30"])
        }, seconds: 1)
        let failing = try ffmpegStandIn(report: standInWMAReport, command: { _ in (URL(fileURLWithPath: "/usr/bin/false"), []) })
        let tooLong = standInWMAReport.replacingOccurrences(of: "3.999000", with: "100.000000")
        let wrongLength = try ffmpegStandIn(report: tooLong)
        let cases: [(String, FFmpegAudioConverter.Tool, (Error) -> Bool)] = [
            ("hang", hanging, { error in
                if case .killed(fileName: "tones.wma", _)? = error as? ImportAudioConverter.Failure { return true }
                return false
            }),
            ("failure", failing, { ($0 as? ImportAudioConverter.Failure) == .processFailed(fileName: "tones.wma", status: 1) }),
            ("length", wrongLength, { error in
                if case .checkFailed(fileName: "tones.wma", let reason)? = error as? ImportAudioConverter.Failure {
                    return reason.contains("not 100.0")
                }
                return false
            }),
        ]
        for (name, tool, isExpected) in cases {
            let wma = try source()
            do {
                _ = try await FFmpegAudioConverter.convert(wma, using: tool)
                XCTFail("\(name): the conversion must fail")
            } catch {
                XCTAssertTrue(isExpected(error), "\(name): \(error)")
            }
            XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"], name)
        }
    }

    /// A source that says no length is taken as long as its converted file
    /// lasts, which must play and last longer than nothing.
    func testASourceOfUnknownLengthTakesTheConvertedLength() async throws {
        let unknown = standInWMAReport.replacingOccurrences(of: #""duration": "3.999000", "#, with: "")
        let wma = try source()

        let conversion = try await FFmpegAudioConverter.convert(wma, using: try ffmpegStandIn(report: unknown))

        XCTAssertEqual(conversion.duration, 4.04, accuracy: 0.1)
    }

    /// A header that claims more than its file can hold (a day in 20 KB) is
    /// no length: the conversion goes by what is measured, and the debug log
    /// says why, as it says of afinfo's.
    func testALengthTheFileCannotHoldIsMeasuredInstead() async throws {
        let lying = standInWMAReport.replacingOccurrences(of: "3.999000", with: "86400.000000")
        let wma = try source(named: "Lying.wma")

        let conversion = try await FFmpegAudioConverter.convert(wma, using: try ffmpegStandIn(report: lying))

        XCTAssertEqual(conversion.duration, 4.04, accuracy: 0.1)
        let logged = debugLogLines(containing: "AUDIO_INFO_IMPLAUSIBLE: Lying.wma: claims 86400 seconds in ")
        XCTAssertEqual(logged.count, 1, "\(logged)")
    }

    /// The import's converter hands a file only ffmpeg reads to the tool it
    /// carries, and Ogg holding Speex too, whatever its name; Ogg of another
    /// codec never reaches it.
    func testTheImportsConverterHandsFFmpegFilesOn() async throws {
        let log = FFmpegPlanLog()
        var tool = ImportAudioConverter.Tool.afconvert
        tool.ffmpeg = try ffmpegStandIn(report: standInWMAReport, log: log)
        let speexReport = standInWMAReport.replacingOccurrences(of: "wmav1", with: "speex")

        _ = try await ImportAudioConverter.convert(try source(), using: tool)
        tool.ffmpeg = try ffmpegStandIn(report: speexReport, log: log)
        _ = try await ImportAudioConverter.convert(try source("spx/tones.spx", named: "Speech.ogg"), using: tool)

        XCTAssertEqual(log.all.map(\.container), [.asf, .oggSpeex])
        XCTAssertFalse(FFmpegAudioConverter.converts(try requireFile("audio/ogg-vorbis-tone.ogg")))
    }

    // MARK: - Importing

    /// A WMA file opened as a book imports as an .m4a book named by the
    /// file's own tags, through the import's own path, with the stand-in
    /// bound as the import's tool; the file imported from is untouched.
    func testAWMAFileImportsAsAnM4ABookNamedByItsTags() throws {
        let wma = try source()
        let before = try Data(contentsOf: wma)
        let log = FFmpegPlanLog()
        var steps: [ImportStep] = []

        let imported = try FFmpegAudioConverter.$tool.withValue(try ffmpegStandIn(report: standInWMAReport, log: log)) {
            try FileImportService.importFileWithReport(from: wma) { step, _ in steps.append(step) }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertEqual(URL(fileURLWithPath: imported.book.filePath).lastPathComponent, "tones.m4a")
        XCTAssertEqual(imported.book.title, "Three Tones")
        XCTAssertEqual(imported.book.author, "TextMouth Test")
        XCTAssertEqual(imported.book.audioAlbum, "Harbour Recordings")
        XCTAssertEqual(log.all.count, 1)
        XCTAssertTrue(steps.contains(.convertingImportedAudio(done: 1, of: 1)), "\(steps)")
        XCTAssertEqual(try Data(contentsOf: wma), before)
        let names = try FileManager.default.contentsOfDirectory(atPath: imported.book.tmbDirectory.path)
        XCTAssertFalse(names.contains { $0.lowercased().hasSuffix(".wma") }, "\(names)")
        XCTAssertEqual(try BookContentAnalysisService.load(book: imported.book).content.chapters.count, 3)
    }

    /// Without ffmpeg the import fails at Converting its audio with what to
    /// install, word for word as the alert reads it, and nothing is added.
    func testWithoutFFmpegTheImportSaysWhatToInstall() throws {
        let wma = try source()
        let libraryBefore = try names(in: TextMouthPaths.libraryDir)

        XCTAssertThrowsError(try FFmpegAudioConverter.$tool.withValue(try ffmpegStandIn(located: .ffmpegMissing, report: nil)) {
            try FileImportService.importFileWithReport(from: wma)
        }) { error in
            XCTAssertEqual(
                (error as? ImportFailure)?.errorDescription,
                "Could not import “tones.wma”. Converting its audio failed: To import WMA files, TextMouth needs ffmpeg, "
                    + "a free program that isn't installed on this Mac. Install it with Homebrew by typing brew install ffmpeg "
                    + "in Terminal, then import the file again."
            )
        }
        XCTAssertEqual(try names(in: TextMouthPaths.libraryDir), libraryBefore)
    }

    /// A folder of tracks converts its WMA tracks with ffmpeg and leaves its
    /// MP3 as it is; the folder imported from keeps its own files.
    func testAFolderConvertsItsWMATracksAndKeepsItsMP3() throws {
        let folder = try makeSandboxDirectory("FFmpegFolder").appendingPathComponent("Lectures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["01.wma", "02.wma"] {
            try FileManager.default.copyItem(at: try formatSampleURL("wma/tones-wma1.wma"), to: folder.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: try formatSampleURL("mp3-chapters/three-tones.mp3"), to: folder.appendingPathComponent("03.mp3"))
        let log = FFmpegPlanLog()

        let imported = try FFmpegAudioConverter.$tool.withValue(try ffmpegStandIn(report: standInWMAReport, log: log)) {
            try FileImportService.importAudioFolderWithReport(from: folder)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        XCTAssertEqual(try AudioBookParser.trackPaths(in: URL(fileURLWithPath: imported.book.filePath)).sorted(), ["01.m4a", "02.m4a", "03.mp3"])
        XCTAssertEqual(log.all.count, 2)
        XCTAssertEqual(try names(in: folder), ["01.wma", "02.wma", "03.mp3"])
    }

    /// With the setting that keeps originals on, the WMA file is kept in the
    /// package's hidden folder beside the .m4a that is the book (FMT14).
    func testTheOriginalIsKeptWhenTheSettingSaysSo() throws {
        let service = ConfigService.shared
        let previous = service.config.keepsOriginalOfConvertedAudio
        service.config.keepsOriginalOfConvertedAudio = true
        addTeardownBlock { @MainActor in service.config.keepsOriginalOfConvertedAudio = previous }
        let wma = try source()

        let imported = try FFmpegAudioConverter.$tool.withValue(try ffmpegStandIn(report: standInWMAReport)) {
            try FileImportService.importFileWithReport(from: wma)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        let kept = ImportAudioConverter.keptOriginals(inPackage: imported.book.tmbDirectory)
        XCTAssertEqual(kept.map(\.lastPathComponent), ["tones.wma"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(kept.first)), try Data(contentsOf: wma))
    }

    // MARK: - Tags Before the Conversion

    /// A file only ffmpeg reads is named by the tags ffprobe reports, the
    /// file's own first and the stream's where the file names none; with no
    /// ffmpeg it keeps its file's name.
    func testTheTagsBeforeTheConversionComeFromFFprobe() throws {
        let wma = try source()
        let wmaStandIn = try ffmpegStandIn(report: standInWMAReport)
        let named = FFmpegAudioConverter.$tool.withValue(wmaStandIn) {
            ImportedFileMetadata.read(from: wma, format: .audio)
        }
        XCTAssertEqual([named.title, named.author, named.audioAlbum], ["Three Tones", "TextMouth Test", "Harbour Recordings"])

        let streamTagged = #"{"streams": [{"index": 0, "codec_type": "audio", "codec_name": "speex", "sample_rate": "8000", "channels": 1, "disposition": {"default": 0}, "tags": {"title": "Field Notes", "artist": "A Speaker"}}], "format": {"format_name": "ogg"}}"#
        let speex = try source("spx/tones.spx", named: "notes.spx")
        let speexStandIn = try ffmpegStandIn(report: streamTagged)
        let fromStream = FFmpegAudioConverter.$tool.withValue(speexStandIn) {
            ImportedFileMetadata.read(from: speex, format: .audio)
        }
        XCTAssertEqual([fromStream.title, fromStream.author], ["Field Notes", "A Speaker"])

        let missingStandIn = try ffmpegStandIn(located: .ffmpegMissing, report: standInWMAReport)
        let unnamed = FFmpegAudioConverter.$tool.withValue(missingStandIn) {
            ImportedFileMetadata.read(from: wma, format: .audio)
        }
        XCTAssertEqual([unnamed.title, unnamed.author], ["tones", Book.unknownAuthor])
    }

    /// ffprobe is asked only of files ffmpeg converts: an AC-3 file, which
    /// afconvert converts, is never read by it, though the stand-in would
    /// answer with a title.
    func testFFprobeIsAskedOnlyOfFilesFFmpegConverts() async throws {
        let standIn = try ffmpegStandIn(report: standInWMAReport)
        let ac3 = try source("ac3/tones.ac3", named: "tones.ac3")
        let ac3Tags = await FFmpegAudioConverter.tags(of: ac3, using: standIn)
        XCTAssertNil(ac3Tags)
        let wmaTags = await FFmpegAudioConverter.tags(of: try source(), using: standIn)
        XCTAssertEqual(wmaTags?.tags["title"], "Three Tones")
        XCTAssertEqual(wmaTags?.duration, 3.999)
    }

    // MARK: - The iPhone

    /// The iPhone refuses a file only ffmpeg reads with a sentence of its
    /// own, naming the format as the Mac does and a Mac with ffmpeg as the
    /// way, even among other files it refuses; Speex in Ogg is Speex.
    func testTheIPhoneRefusesFFmpegFormatsSayingAMacNeedsFFmpeg() throws {
        let ogg = URL(fileURLWithPath: "/nonexistent/Radio Drama.ogg")
        let wma = URL(fileURLWithPath: "/nonexistent/Lecture.wma")
        XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: [ogg, wma])) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .ffmpegAudio(kind: "WMA"))
        }
        XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: [try source("spx/tones.spx", named: "Notes.ogg")])) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .ffmpegAudio(kind: "Speex"))
        }
        XCTAssertEqual(
            PhoneImportRefusal.ffmpegAudio(kind: "WMA").sentence(naming: "Lecture"),
            "“Lecture” is in WMA, which TextMouth on iPhone can't play. Add it on a Mac with ffmpeg installed, then send the book here."
        )
        XCTAssertEqual(
            PhoneImportRefusal.ffmpegAudio(kind: "Matroska").sentence(naming: nil),
            "This file is in Matroska, which TextMouth on iPhone can't play. Add it on a Mac with ffmpeg installed, then send the book here."
        )
    }
}
