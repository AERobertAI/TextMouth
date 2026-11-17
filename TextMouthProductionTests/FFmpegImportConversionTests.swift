import XCTest
@testable import TextMouth

/// The FFmpeg import's conversions and imports (FMT31, FMT32, FMT50), through
/// the helper the app carries, TextMouthFFmpeg, which every build of the app
/// holds, on GitHub's runners too. A stand-in script stands in front of it
/// (`ffmpegHelperStandIn`) where a test needs a run to end otherwise: a probe
/// written by hand, a hang, a crash, an early end, a damaged stream. What each
/// refusal says and when it comes, what is left behind (nothing), and a whole
/// import of a file and of a folder through the import's own path.
/// `FFmpegImportRealTests` imports every sample with the helper alone.
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

    /// A probe written by hand of the WMA sample with `changes` to its INFO
    /// (a nil value leaves the key out).
    private func cannedProbe(_ changes: [(String, String?)] = []) -> [UInt8] {
        FFmpegTestStream.probe(info: changes.reduce(FFmpegTestStream.wmaInfo) { FFmpegTestStream.replacing($1.0, with: $1.1, in: $0) })
    }

    // MARK: - Converting One File

    /// A WMA file becomes an .m4a beside it, named for it, by the helper's
    /// probe and then its decode: of AAC, lasting as long as the source
    /// says, carrying its title and artist; the source is untouched, and
    /// nothing else is left in its folder.
    func testAFileBecomesAnM4ABesideIt() async throws {
        let wma = try source()
        let before = try Data(contentsOf: wma)
        let (helper, log) = try ffmpegHelperStandIn()

        let conversion = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper))

        XCTAssertEqual(conversion.converted.lastPathComponent, "tones.m4a")
        XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.m4a", "tones.wma"])
        XCTAssertEqual(try Data(contentsOf: wma), before)
        XCTAssertEqual(conversion.duration, 3.999)
        XCTAssertEqual(try standInCalls(log), ["probe asf", "decode asf"])
        let info = try await AudioFileInfo.read(conversion.converted)
        XCTAssertEqual(info?.formatID.trimmingCharacters(in: .whitespaces), "aac")
        XCTAssertEqual(info?.channels, 1)
        let tags = await AudioPlaybackService.extractFullMetadata(from: conversion.converted)
        XCTAssertEqual([tags.title, tags.artist], ["Three Tones", "TextMouth Test"])
    }

    /// A name that is taken gets the next free one, as every conversion's does.
    func testATakenNameGetsTheNextFreeOne() async throws {
        let wma = try source()
        try Data("taken".utf8).write(to: wma.deletingLastPathComponent().appendingPathComponent("tones.m4a"))

        let conversion = try await FFmpegAudioConverter.convert(wma, using: try bundledFFmpegTool())

        XCTAssertEqual(conversion.converted.lastPathComponent, "tones 2.m4a")
    }

    /// An app whose helper is missing (a damaged copy) refuses the file,
    /// naming its format and what to do, and no program runs.
    func testWithoutTheHelperTheFileIsRefusedWithWhatToDo() async throws {
        let wma = try source()
        let launches = WatchedProcess.launchCount
        do {
            _ = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: nil))
            XCTFail("the file must be refused")
        } catch {
            XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .helperMissing(kind: "WMA"))
        }
        XCTAssertEqual(WatchedProcess.launchCount, launches, "no program may run")
        XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"])
    }

    /// A copy-protected WMA file is refused as copy-protected, with the
    /// helper or without, before anything runs: no converter would help.
    func testACopyProtectedFileIsRefusedBeforeAnythingElse() async throws {
        let folder = try makeSandboxDirectory("FFmpegProtected")
        let locked = folder.appendingPathComponent("Locked.wma")
        try copyProtectedASF(from: try formatSampleURL("wma/tones-wma1.wma")).write(to: locked)
        for helper in [try bundledFFmpegHelper(), nil] {
            let launches = WatchedProcess.launchCount
            do {
                _ = try await FFmpegAudioConverter.convert(locked, using: ffmpegTool(helper: helper))
                XCTFail("a copy-protected file must be refused")
            } catch {
                XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .copyProtected)
            }
            XCTAssertEqual(WatchedProcess.launchCount, launches)
        }
        XCTAssertEqual(try names(in: folder), ["Locked.wma"])
    }

    /// A file whose bytes are not of its name's format is refused as such
    /// before anything runs; so is one the helper's demuxer refuses (its exit
    /// status 3); and one that holds no sound (status 4) says so, as a helper
    /// that could not confine itself (status 12) says that.
    func testAFileThatIsNotWhatItsNameSaysIsRefused() async throws {
        let folder = try makeSandboxDirectory("FFmpegNotRecognized")
        let fake = folder.appendingPathComponent("Fake.wma")
        try Data("not a Windows Media file".utf8).write(to: fake)
        let launches = WatchedProcess.launchCount
        do {
            _ = try await FFmpegAudioConverter.convert(fake, using: try bundledFFmpegTool())
            XCTFail("a file that is no WMA must be refused")
        } catch {
            XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .notRecognized(fileName: "Fake.wma", kind: "WMA"))
        }
        XCTAssertEqual(WatchedProcess.launchCount, launches)

        let cases: [(Int32, FFmpegAudioConverter.Failure)] = [
            (3, .notRecognized(fileName: "tones.wma", kind: "WMA")), (4, .noSound(fileName: "tones.wma")),
            (5, .soundNotDecoded(fileName: "tones.wma")), (7, .formChanged(fileName: "tones.wma")),
            (12, .notConfined(fileName: "tones.wma")),
        ]
        for (status, expected) in cases {
            let wma = try source()
            let (helper, _) = try ffmpegHelperStandIn(probe: .write([], status: status))
            do {
                _ = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper))
                XCTFail("status \(status): the file must be refused")
            } catch {
                XCTAssertEqual(error as? FFmpegAudioConverter.Failure, expected, "status \(status)")
            }
            XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"], "status \(status)")
        }
    }

    /// A probe or a decode that hangs is killed by the watchdog; a helper
    /// that crashes (its own exit status, or a signal) is named as crashed; a
    /// decode that ends cleanly too soon, one that fails, and one whose
    /// stream is damaged each say so; a result that does not last as long as
    /// its source fails its check. Each leaves nothing behind, and the helper
    /// is never left running.
    func testHangsCrashesAndBrokenRunsLeaveNothingBehind() async throws {
        let partial = FFmpegTestStream.head() + FFmpegTestStream.info(FFmpegTestStream.wmaInfo)
            + FFmpegTestStream.pcm32([0, 0, 0])
        let killed: (any Error) -> Bool = { error in
            if case .killed(fileName: "tones.wma", _)? = error as? ImportAudioConverter.Failure { return true }
            return false
        }
        let cases: [(String, StandInAction, StandInAction, (any Error) -> Bool)] = [
            ("a probe that hangs", .hang(seconds: 30), .realHelper, killed),
            ("a decode that hangs", .realHelper, .hang(seconds: 30), killed),
            ("a decode that crashes", .realHelper, .write(partial, status: 70),
             { ($0 as? FFmpegAudioConverter.Failure) == .crashed(fileName: "tones.wma") }),
            ("a decode killed by a signal", .realHelper, .killItself,
             { ($0 as? FFmpegAudioConverter.Failure) == .crashed(fileName: "tones.wma") }),
            ("a decode that ends too soon", .realHelper, .write(partial, status: 0),
             { ($0 as? FFmpegAudioConverter.Failure) == .endedEarly(fileName: "tones.wma") }),
            ("a decode that fails", .realHelper, .write([], status: 1),
             { ($0 as? ImportAudioConverter.Failure) == .processFailed(fileName: "tones.wma", status: 1) }),
            ("a damaged stream", .realHelper, .write(Array("not the helper's stream at all".utf8), status: 0),
             { ($0 as? FFmpegAudioConverter.Failure) == .unreadableStream(fileName: "tones.wma") }),
            ("a length the sound does not have", .write(cannedProbe([("duration", "100.000000")]), status: 0), .realHelper,
             { error in
                 if case .checkFailed(fileName: "tones.wma", let reason)? = error as? ImportAudioConverter.Failure {
                     return reason.contains("not 100.0")
                 }
                 return false
             }),
        ]
        for (name, probe, decode, isExpected) in cases {
            let wma = try source()
            let (helper, _) = try ffmpegHelperStandIn(probe: probe, decode: decode)
            do {
                _ = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper, seconds: 2))
                XCTFail("\(name): the conversion must fail")
            } catch {
                XCTAssertTrue(isExpected(error), "\(name): \(error)")
            }
            XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"], name)
            XCTAssertEqual(WatchedProcess.runningChildCount, 0, name)
        }
    }

    /// A helper that has written a whole stream and then does not exit is
    /// ended once the stream's END has been read, and the import succeeds:
    /// only the stall limit would have ended it, as a failure.
    func testAHelperThatHangsAfterAWholeStreamStillImports() async throws {
        let wma = try source()
        let (helper, _) = try ffmpegHelperStandIn(decode: .realHelperThenHang(seconds: 60))

        let conversion = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper, seconds: TestMachine.allowed(6)))

        XCTAssertEqual(conversion.converted.lastPathComponent, "tones.m4a")
        XCTAssertEqual(conversion.duration, 4.0, accuracy: 0.1)
        XCTAssertEqual(WatchedProcess.runningChildCount, 0)
    }

    /// A decode whose .m4a passes the output cap is stopped by the reader's
    /// own check before the next block, not by the watchdog's look once a
    /// second: the watchdog here looks once in ten minutes, and the stream
    /// has no END, so only the check can end the import as a kill for
    /// writing too much, with nothing left behind.
    func testADecodeThatWritesPastItsCapIsStoppedByTheReader() async throws {
        // Forty blocks of noise, 30 seconds of mono sound, that an AAC file of 100 KB or more holds.
        var seed: UInt32 = 12_345
        let blocks = (0..<40).flatMap { _ -> [UInt8] in
            let samples = (0..<16_384).map { _ -> UInt32 in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return (Float(Int32(bitPattern: seed)) / Float(Int32.max) / 2).bitPattern
            }
            return FFmpegTestStream.pcm32(samples)
        }
        let stream = FFmpegTestStream.head() + FFmpegTestStream.info(FFmpegTestStream.wmaInfo) + blocks
        let wma = try source()
        let (helper, _) = try ffmpegHelperStandIn(decode: .write(stream, status: 0))
        var tool = ffmpegTool(helper: helper, seconds: TestMachine.allowed(30))
        let watched = tool.limits(4)
        tool.limits = { _ in
            var limits = watched
            limits.maximumOutputBytes = 20_000
            limits.pollInterval = 600
            return limits
        }

        do {
            _ = try await FFmpegAudioConverter.convert(wma, using: tool)
            XCTFail("a decode past its cap must fail")
        } catch let ImportAudioConverter.Failure.killed(fileName, reason) {
            XCTAssertEqual(fileName, "tones.wma")
            XCTAssertEqual(reason, WatchedProcess.KillReason.wroteTooMuch(bytes: 20_000).words)
        }
        XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"])
        XCTAssertEqual(WatchedProcess.runningChildCount, 0)
    }

    /// The reader's check of the cap: nothing past it, nothing when there is
    /// no cap or no file yet, and a file past it names the cap.
    func testTheOutputCapCheck() throws {
        let file = try makeSandboxDirectory("FFmpegCap").appendingPathComponent("written.m4a")
        var limits = WatchedProcess.Limits(maximumSeconds: 10, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 10)
        limits.maximumOutputBytes = 1_000
        XCTAssertNoThrow(try FFmpegAudioConverter.checkOutputCap(of: file, against: limits), "no file is no bytes")
        try Data(count: 1_000).write(to: file)
        XCTAssertNoThrow(try FFmpegAudioConverter.checkOutputCap(of: file, against: limits), "the cap itself is allowed")
        try Data(count: 1_001).write(to: file)
        XCTAssertThrowsError(try FFmpegAudioConverter.checkOutputCap(of: file, against: limits)) { error in
            XCTAssertEqual(error as? FFmpegAudioConverter.WroteTooMuch, FFmpegAudioConverter.WroteTooMuch(bytes: 1_000))
        }
        limits.maximumOutputBytes = nil
        XCTAssertNoThrow(try FFmpegAudioConverter.checkOutputCap(of: file, against: limits), "no cap allows any size")
    }

    /// A source that says no length is taken as long as its converted file
    /// lasts, which must play and last longer than nothing.
    func testASourceOfUnknownLengthTakesTheConvertedLength() async throws {
        let (helper, _) = try ffmpegHelperStandIn(probe: .write(cannedProbe([("duration", nil), ("format_duration", nil)]), status: 0))

        let conversion = try await FFmpegAudioConverter.convert(try source(), using: ffmpegTool(helper: helper))

        XCTAssertEqual(conversion.duration, 4.0, accuracy: 0.1)
    }

    /// A source that says no length is refused before the decode runs when
    /// the volume has no room for what it may write (64 MB for a file this
    /// small) and the 512 MB reserve, with nothing left behind; with room,
    /// it converts.
    func testASourceOfNoLengthIsRefusedWhenItsCapWouldNotFit() async throws {
        let unknown = cannedProbe([("duration", nil), ("format_duration", nil)])
        let wma = try source()
        let needed = FFmpegAudioConverter.unknownLengthOutputCap(ofBytes: ImportAudioConverter.fileSize(of: wma))
            + ImportAudioConverter.downmixReserveBytes
        XCTAssertEqual(needed, 576 * 1_048_576)
        let (helper, log) = try ffmpegHelperStandIn(probe: .write(unknown, status: 0))

        do {
            _ = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper, available: needed - 1))
            XCTFail("a source of no length must be refused when its cap would not fit")
        } catch let ImportAudioConverter.Failure.notEnoughSpace(fileName, bytesNeeded) {
            XCTAssertEqual(fileName, "tones.wma")
            XCTAssertEqual(bytesNeeded, needed)
        }
        XCTAssertEqual(try standInCalls(log), ["probe asf"], "the decode must not run")
        XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"])

        let conversion = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper, available: needed))
        XCTAssertEqual(conversion.converted.lastPathComponent, "tones.m4a")
    }

    /// A header that claims more than its file can hold (a day in 20 KB) is
    /// no length: the conversion goes by what is measured, and the debug log
    /// says why, as it says of afinfo's.
    func testALengthTheFileCannotHoldIsMeasuredInstead() async throws {
        let (helper, _) = try ffmpegHelperStandIn(probe: .write(cannedProbe([("duration", "86400.000000")]), status: 0))
        let wma = try source(named: "Lying.wma")

        let conversion = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper))

        XCTAssertEqual(conversion.duration, 4.0, accuracy: 0.1)
        let logged = debugLogLines(containing: "AUDIO_INFO_IMPLAUSIBLE: Lying.wma: claims 86400 seconds in ")
        XCTAssertEqual(logged.count, 1, "\(logged)")
    }

    /// The import's converter hands a file only FFmpeg reads to the helper of
    /// the tool it carries, with the demuxer its bytes name, and Ogg holding
    /// Speex too, whatever its name; Ogg of another codec never reaches it.
    func testTheImportsConverterHandsFFmpegFilesOn() async throws {
        let (helper, log) = try ffmpegHelperStandIn()
        var tool = ImportAudioConverter.Tool.afconvert
        tool.ffmpeg = ffmpegTool(helper: helper)

        _ = try await ImportAudioConverter.convert(try source(), using: tool)
        _ = try await ImportAudioConverter.convert(try source("spx/tones.spx", named: "Speech.ogg"), using: tool)

        XCTAssertEqual(try standInCalls(log), ["probe asf", "decode asf", "probe ogg", "decode ogg"])
        XCTAssertFalse(FFmpegAudioConverter.converts(try requireFile("audio/ogg-vorbis-tone.ogg")))
    }

    // MARK: - Importing

    /// A WMA file opened as a book imports as an .m4a book named by the
    /// file's own tags, with its three chapters, through the import's own
    /// path and the app's helper; the file imported from is untouched.
    func testAWMAFileImportsAsAnM4ABookNamedByItsTags() throws {
        let wma = try source()
        let before = try Data(contentsOf: wma)
        var steps: [ImportStep] = []

        let imported = try FFmpegAudioConverter.$tool.withValue(try bundledFFmpegTool()) {
            try FileImportService.importFileWithReport(from: wma) { step, _ in steps.append(step) }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertEqual(URL(fileURLWithPath: imported.book.filePath).lastPathComponent, "tones.m4a")
        XCTAssertEqual(imported.book.title, "Three Tones")
        XCTAssertEqual(imported.book.author, "TextMouth Test")
        XCTAssertTrue(steps.contains(.convertingImportedAudio(done: 1, of: 1)), "\(steps)")
        XCTAssertEqual(try Data(contentsOf: wma), before)
        let names = try FileManager.default.contentsOfDirectory(atPath: imported.book.tmbDirectory.path)
        XCTAssertFalse(names.contains { $0.lowercased().hasSuffix(".wma") }, "\(names)")
        XCTAssertEqual(try BookContentAnalysisService.load(book: imported.book).content.chapters.map(\.title),
                       ["Tone 440 Hz", "Tone 660 Hz - second", "Tone 880 Hz (café)"])
    }

    /// Without the helper the import fails at Converting its audio with what
    /// to do, word for word as the alert reads it, and nothing is added. No
    /// sentence sends anyone to Homebrew any more.
    func testWithoutTheHelperTheImportSaysWhatToDo() throws {
        let wma = try source()
        let libraryBefore = try names(in: TextMouthPaths.libraryDir)

        XCTAssertThrowsError(try FFmpegAudioConverter.$tool.withValue(ffmpegTool(helper: nil)) {
            try FileImportService.importFileWithReport(from: wma)
        }) { error in
            XCTAssertEqual(
                (error as? ImportFailure)?.errorDescription,
                "Could not import “tones.wma”. Converting its audio failed: TextMouth can't convert WMA files because its "
                    + "converter is missing from the app. Install TextMouth again, then import the file again."
            )
        }
        XCTAssertEqual(try names(in: TextMouthPaths.libraryDir), libraryBefore)
    }

    /// A folder of tracks converts its WMA tracks with the helper and leaves
    /// its MP3 as it is; the folder imported from keeps its own files.
    func testAFolderConvertsItsWMATracksAndKeepsItsMP3() throws {
        let folder = try makeSandboxDirectory("FFmpegFolder").appendingPathComponent("Lectures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["01.wma", "02.wma"] {
            try FileManager.default.copyItem(at: try formatSampleURL("wma/tones-wma1.wma"), to: folder.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: try formatSampleURL("mp3-chapters/three-tones.mp3"), to: folder.appendingPathComponent("03.mp3"))
        let (helper, log) = try ffmpegHelperStandIn()

        let imported = try FFmpegAudioConverter.$tool.withValue(ffmpegTool(helper: helper)) {
            try FileImportService.importAudioFolderWithReport(from: folder)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        XCTAssertEqual(try AudioBookParser.trackPaths(in: URL(fileURLWithPath: imported.book.filePath)).sorted(), ["01.m4a", "02.m4a", "03.mp3"])
        XCTAssertEqual(try standInCalls(log).filter { $0.hasPrefix("decode") }, ["decode asf", "decode asf"])
        XCTAssertEqual(try names(in: folder), ["01.wma", "02.wma", "03.mp3"])
    }

    /// A folder of MP3s with a stray video and a file merely named like
    /// Speex (review9 finding 2): with the app's helper missing both are left
    /// out, named in the import's notice with what to do, and the book is its
    /// two MP3s; with the helper the video is a third track, and only the
    /// file that holds no sound is left out. The folder imported from keeps
    /// its files.
    func testAFolderLeavesOutWhatThisMacCannotConvert() throws {
        let folder = try makeSandboxDirectory("FFmpegStray").appendingPathComponent("Book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["01.mp3", "02.mp3"] {
            try FileManager.default.copyItem(at: try formatSampleURL("mp3-chapters/three-tones.mp3"), to: folder.appendingPathComponent(name))
        }
        try FileManager.default.copyItem(at: try formatSampleURL("avi/tones-mp3.avi"), to: folder.appendingPathComponent("Trailer.avi"))
        try Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array/></plist>"#.utf8)
            .write(to: folder.appendingPathComponent("Report.spx"))
        let noSound = "TextMouth left out “Report.spx”, which holds no sound it can read."

        let withoutHelper = try FFmpegAudioConverter.$tool.withValue(ffmpegTool(helper: nil)) {
            try FileImportService.importAudioFolderWithReport(from: folder)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: withoutHelper.book.tmbDirectory) }
        XCTAssertEqual(try AudioBookParser.trackPaths(in: URL(fileURLWithPath: withoutHelper.book.filePath)).sorted(), ["01.mp3", "02.mp3"])
        XCTAssertEqual(
            withoutHelper.notice,
            "TextMouth left out “Trailer.avi”, which needs TextMouth's converter, missing from the app. "
                + "Install TextMouth again, then import the book again. " + noSound
        )

        let withHelper = try FFmpegAudioConverter.$tool.withValue(try bundledFFmpegTool()) {
            try FileImportService.importAudioFolderWithReport(from: folder)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: withHelper.book.tmbDirectory) }
        XCTAssertEqual(
            try AudioBookParser.trackPaths(in: URL(fileURLWithPath: withHelper.book.filePath)).sorted(),
            ["01.mp3", "02.mp3", "Trailer.m4a"]
        )
        XCTAssertEqual(withHelper.notice, noSound)
        XCTAssertEqual(try names(in: folder), ["01.mp3", "02.mp3", "Report.spx", "Trailer.avi"])
    }

    /// A folder with no track but the ones this Mac can't convert leaves
    /// none out: it is refused as one such file is, with what to do.
    func testAFolderOfNothingThisMacCanConvertIsRefused() throws {
        let folder = try makeSandboxDirectory("FFmpegOnlyStray").appendingPathComponent("Clips")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try formatSampleURL("avi/tones-mp3.avi"), to: folder.appendingPathComponent("Trailer.avi"))

        XCTAssertThrowsError(try FFmpegAudioConverter.$tool.withValue(ffmpegTool(helper: nil)) {
            try FileImportService.importAudioFolderWithReport(from: folder)
        }) { error in
            XCTAssertEqual(
                (error as? ImportFailure)?.errorDescription,
                "Could not import “Clips”. Converting its audio failed: " + FFmpegImportWording.helperMissing(kind: "AVI video")
            )
        }
    }

    /// With the setting that keeps originals on, the WMA file is kept in the
    /// package's hidden folder beside the .m4a that is the book (FMT14).
    func testTheOriginalIsKeptWhenTheSettingSaysSo() throws {
        let service = ConfigService.shared
        let previous = service.config.keepsOriginalOfConvertedAudio
        service.config.keepsOriginalOfConvertedAudio = true
        addTeardownBlock { @MainActor in service.config.keepsOriginalOfConvertedAudio = previous }
        let wma = try source()

        let imported = try FFmpegAudioConverter.$tool.withValue(try bundledFFmpegTool()) {
            try FileImportService.importFileWithReport(from: wma)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }

        let kept = ImportAudioConverter.keptOriginals(inPackage: imported.book.tmbDirectory)
        XCTAssertEqual(kept.map(\.lastPathComponent), ["tones.wma"])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(kept.first)), try Data(contentsOf: wma))
    }

    // MARK: - Tags Before the Conversion

    /// A file only FFmpeg reads is named by the tags the helper reports, the
    /// file's own first and, in Ogg, the stream's where the file names none
    /// (a Matroska track's name is no title); a RealMedia file's author is
    /// the book's; with no helper it keeps its file's name.
    func testTheTagsBeforeTheConversionComeFromTheHelper() throws {
        /// The book's names of `file` with a helper whose probe is `probe`.
        func named(_ file: URL, probe: [UInt8]?) throws -> ImportedFileMetadata {
            let tool: FFmpegAudioConverter.Tool
            if let probe {
                tool = ffmpegTool(helper: try ffmpegHelperStandIn(probe: .write(probe, status: 0)).helper)
            } else {
                tool = ffmpegTool(helper: nil)
            }
            return FFmpegAudioConverter.$tool.withValue(tool) { ImportedFileMetadata.read(from: file, format: .audio) }
        }
        let wma = try source()
        let fromFile = try named(wma, probe: FFmpegTestStream.probe())
        XCTAssertEqual([fromFile.title, fromFile.author, fromFile.audioAlbum], ["Three Tones", "TextMouth Test", "Harbour Recordings"])

        let speexInfo = FFmpegTestStream.replacing("codec", with: "speex", in: FFmpegTestStream.wmaInfo)
        let fromStream = try named(try source("spx/tones.spx", named: "notes.spx"), probe: FFmpegTestStream.probe(
            info: speexInfo, tags: [], streamTags: [("title", "Field Notes"), ("artist", "A Speaker")]))
        XCTAssertEqual([fromStream.title, fromStream.author], ["Field Notes", "A Speaker"])

        // Matroska keeps a track's name on the stream: a file that names no
        // title of its own keeps its file's name (review9 finding 3).
        let fromTrackName = try named(try source("mkv/three-tones-flac.mkv", named: "Lecture.mkv"), probe: FFmpegTestStream.probe(
            tags: [], streamTags: [("title", "Stereo")]))
        XCTAssertEqual(fromTrackName.title, "Lecture")

        // RealMedia's author keeps its name (review9 finding 5); an artist
        // would come first, an album's last.
        let fromAuthor = try named(try source("rm/tones.ra", named: "tones.ra"), probe: FFmpegTestStream.probe(
            tags: [("title", "Talk"), ("author", "Only Author"), ("album_artist", "An Album's Artist")]))
        XCTAssertEqual([fromAuthor.title, fromAuthor.author], ["Talk", "Only Author"])

        let unnamed = try named(wma, probe: nil)
        XCTAssertEqual([unnamed.title, unnamed.author], ["tones", Book.unknownAuthor])
    }

    /// The helper is asked only of files FFmpeg converts: an AC-3 file,
    /// which afconvert converts, is never read by it; a WMA file is, and
    /// says its title and length.
    func testTheHelperIsAskedOnlyOfFilesFFmpegConverts() async throws {
        let (helper, log) = try ffmpegHelperStandIn()
        let tool = ffmpegTool(helper: helper)
        let ac3Tags = await FFmpegAudioConverter.tags(of: try source("ac3/tones.ac3", named: "tones.ac3"), using: tool)
        XCTAssertNil(ac3Tags)
        XCTAssertEqual(try standInCalls(log), [])
        let wmaTags = await FFmpegAudioConverter.tags(of: try source(), using: tool)
        XCTAssertEqual(wmaTags?.tags.title, "Three Tones")
        XCTAssertEqual(wmaTags?.duration, 3.999)
        XCTAssertEqual(try standInCalls(log), ["probe asf"])
    }

    // MARK: - The iPhone

    /// The iPhone refuses a file only FFmpeg reads with a sentence of its
    /// own, naming the format as the Mac does and the Mac as the way, even
    /// among other files it refuses; Speex in Ogg is Speex.
    func testTheIPhoneRefusesFFmpegFormatsSayingTheMacConvertsThem() throws {
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
            "“Lecture” is in WMA, which TextMouth on iPhone can't play. Add it on your Mac, then send the book here."
        )
        XCTAssertEqual(
            PhoneImportRefusal.ffmpegAudio(kind: "Matroska").sentence(naming: nil),
            "This file is in Matroska, which TextMouth on iPhone can't play. Add it on your Mac, then send the book here."
        )
    }
}
