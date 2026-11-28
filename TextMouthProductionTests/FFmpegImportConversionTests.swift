import XCTest
@testable import TextMouth

/// The FFmpeg import's conversions and imports (FMT31, FMT32, FMT50), through
/// the session the app carries: on the Mac the helper TextMouthFFmpeg, which
/// every build of the app holds, on GitHub's runners too, and on the iPhone
/// the same session in the app itself (FMT54), so each test asks the same of
/// both. A stand-in stands in front of it (`ffmpegHelperStandIn`: a script on
/// the Mac, a session on the iPhone) where a test needs a run to end
/// otherwise: a probe written by hand, a hang, a crash, an early end, a
/// damaged stream. What each refusal says and when it comes, what is left
/// behind (nothing), and a whole import of a file and of a folder through the
/// import's own path. `FFmpegImportRealTests` imports every sample with the
/// session alone. Shared with the iPhone's unit bundle.
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
        let entry = try M4ASampleEntry.read(conversion.converted)
        XCTAssertEqual(entry?.codec, "aac")
        XCTAssertEqual(entry?.channels, 1)
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
        let (tool, starts) = countingSessionStarts(of: ffmpegTool(helper: nil))
        do {
            _ = try await FFmpegAudioConverter.convert(wma, using: tool)
            XCTFail("the file must be refused")
        } catch {
            XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .helperMissing(kind: "WMA"))
        }
        XCTAssertEqual(starts(), 0, "no session may run")
        XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"])
    }

    /// A symbolic link to a good WMA file converts as the file does (FU04's
    /// review): the import stages a source as it is, and a copy of a link is
    /// a link, so the path is resolved once before the session opens it,
    /// whose own opener refuses a link (`testASymbolicLinkIsRefusedAsUnreadable`).
    /// The .m4a is made beside the link, which and whose target are untouched.
    func testASymbolicLinkToAGoodFileIsConverted() async throws {
        let wma = try source()
        let folder = try makeSandboxDirectory("FFmpegLinkedSource")
        let link = folder.appendingPathComponent("linked.wma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wma)
        let conversion = try await FFmpegAudioConverter.convert(link, using: try bundledFFmpegTool())
        XCTAssertEqual(conversion.converted.lastPathComponent, "linked.m4a")
        XCTAssertEqual(conversion.duration, 4.0, accuracy: 0.1)
        XCTAssertEqual(try names(in: folder), ["linked.m4a", "linked.wma"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), wma.path)
        XCTAssertEqual(try names(in: wma.deletingLastPathComponent()), ["tones.wma"])
    }

    /// Importing a symbolic link to a good WMA file makes a book of it, as the
    /// file itself does: the staged copy of the link is a link too, and the
    /// conversion follows it.
    func testImportingASymbolicLinkToAGoodFileMakesABook() throws {
        let wma = try source()
        let link = try makeSandboxDirectory("FFmpegLinkedImport").appendingPathComponent("Linked.wma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wma)
        let tool = try bundledFFmpegTool()
        let imported = try FFmpegAudioConverter.$tool.withValue(tool) { try FileImportService.importFileWithReport(from: link) }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
        XCTAssertTrue(imported.book.format.isAudio)
        XCTAssertEqual(imported.book.bookFileURL.pathExtension, "m4a")
        XCTAssertNil(imported.notice)
    }

    // MARK: - Sound the Decoder Refused (FU03)

    /// A stand-in that probes a sample of two seconds and decodes two seconds of
    /// silence in a stream whose END counts `refusedPackets`: what the session
    /// writes when its decoder refused packets and the session kept their place
    /// as silence.
    private func standInOfTwoSeconds(refusedPackets: UInt32) throws -> FFmpegTestHelper {
        let info = FFmpegTestStream.replacing("sample_format", with: "s16", in:
            FFmpegTestStream.replacing("bits", with: "16", in:
                FFmpegTestStream.replacing("duration", with: "2.000000", in:
                    FFmpegTestStream.replacing("format_duration", with: "2.000000", in: FFmpegTestStream.wmaInfo))))
        let decode = FFmpegTestStream.head() + FFmpegTestStream.info(info)
            + FFmpegTestStream.pcm16([Int16](repeating: 0, count: 44_100))
            + FFmpegTestStream.end(frames: 44_100, refusedPackets: refusedPackets)
        return try ffmpegHelperStandIn(probe: .write(FFmpegTestStream.probe(info: info), status: 0), decode: .write(decode, status: 0)).helper
    }

    /// A conversion whose stream counts refused packets says so, and one that
    /// counts none does not; the import tells the listener of the first, in one
    /// short sentence naming the file, and of the second nothing.
    func testAConversionOfPartlyRefusedSoundIsToldAsSuch() async throws {
        let wma = try source()
        let refused = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: try standInOfTwoSeconds(refusedPackets: 3)))
        XCTAssertTrue(refused.partlyDecoded)
        let whole = try source("wma/tones-wma1.wma", named: "whole.wma")
        let clean = try await FFmpegAudioConverter.convert(whole, using: ffmpegTool(helper: try standInOfTwoSeconds(refusedPackets: 0)))
        XCTAssertFalse(clean.partlyDecoded)

        let sentence = "Part of “tones.wma” could not be decoded and is kept as silence."
        XCTAssertEqual(FileImportService.partlyDecodedNotice(of: [refused]), sentence)
        XCTAssertNil(FileImportService.partlyDecodedNotice(of: [clean]))
        XCTAssertEqual(FFmpegImportWording.partlyDecodedNotice(["tones.wma"]), sentence)
        XCTAssertEqual(
            FileImportService.partlyDecodedNotice(of: [refused, clean]), sentence, "only the tracks that were refused in part are named"
        )
        XCTAssertNil(FFmpegImportWording.partlyDecodedNotice([]))
        XCTAssertEqual(
            FFmpegImportWording.partlyDecodedNotice(["a.wma", "b.wma"]),
            "Part of 2 files, “a.wma” and “b.wma”, could not be decoded and is kept as silence."
        )
    }

    /// Importing a file whose sound the decoder refused in part makes its book
    /// all the same and tells the listener, in the import's notice, which is
    /// shown and spoken with the rest of the import's result; a whole file's
    /// import tells nothing.
    func testImportingPartlyRefusedSoundTellsTheListener() throws {
        let imported = try FFmpegAudioConverter.$tool.withValue(ffmpegTool(helper: try standInOfTwoSeconds(refusedPackets: 3))) {
            try FileImportService.importFileWithReport(from: try source())
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
        XCTAssertEqual(imported.notice, "Part of “tones.wma” could not be decoded and is kept as silence.")
        XCTAssertTrue(imported.book.format.isAudio)
        let whole = try FFmpegAudioConverter.$tool.withValue(ffmpegTool(helper: try standInOfTwoSeconds(refusedPackets: 0))) {
            try FileImportService.importFileWithReport(from: try source())
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: whole.book.tmbDirectory) }
        XCTAssertNil(whole.notice)
    }

    /// An encrypted Matroska or WebM file is refused as copy-protected too
    /// (B19), as a Windows Media file is: with the helper or without, before
    /// anything runs, and not told as damaged. A file of the same containers
    /// that is not encrypted still goes on to the session (the sample imports
    /// in `FFmpegImportRealTests`).
    func testAnEncryptedMatroskaFileIsRefusedAsCopyProtected() async throws {
        let folder = try makeSandboxDirectory("FFmpegProtectedMatroska")
        let locked = [("Locked.mka", "matroska"), ("Locked.webm", "webm"), ("Locked.mkv", "matroska")]
        for (name, doctype) in locked {
            try Data(matroskaFile(tracks: [MatroskaTrack(type: 1), MatroskaTrack(type: 2, encryption: 5)], doctype: doctype))
                .write(to: folder.appendingPathComponent(name))
        }
        for (name, _) in locked {
            for helper in [try bundledFFmpegHelper(), nil] {
                let (tool, starts) = countingSessionStarts(of: ffmpegTool(helper: helper))
                do {
                    _ = try await FFmpegAudioConverter.convert(folder.appendingPathComponent(name), using: tool)
                    XCTFail("\(name): an encrypted file must be refused")
                } catch {
                    XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .copyProtected, name)
                }
                XCTAssertEqual(starts(), 0, "\(name): the session ran before the copy protection was told")
            }
        }
        XCTAssertEqual(try names(in: folder), ["Locked.mka", "Locked.mkv", "Locked.webm"])
    }

    /// Importing a copy-protected Windows Media file, alone or as a track of
    /// a book, says why as the Mac says it, on both platforms: "Could not
    /// import “Locked.wma”. Converting its audio failed: TextMouth cannot open
    /// copy-protected files." The iPhone refuses it before it converts
    /// anything (FU-FFMPEG), under the conversion's own step, not the copy
    /// or the scan before it (the FMT54 review, finding 3).
    func testImportingACopyProtectedFileSaysWhyAsTheMacDoes() throws {
        let sandbox = try makeSandboxDirectory("FFmpegProtectedImport")
        let locked = sandbox.appendingPathComponent("Locked.wma")
        try copyProtectedASF(from: try formatSampleURL("wma/tones-wma1.wma")).write(to: locked)
        let book = sandbox.appendingPathComponent("Locked Lectures")
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: locked, to: book.appendingPathComponent("01.wma"))
        try FileManager.default.copyItem(at: try formatSampleURL("mp3-chapters/three-tones.mp3"), to: book.appendingPathComponent("02.mp3"))
        let tool = try bundledFFmpegTool()
        let reason = "Converting its audio failed: TextMouth cannot open copy-protected files."
        XCTAssertThrowsError(try FFmpegAudioConverter.$tool.withValue(tool) { try FileImportService.importFileWithReport(from: locked) }) {
            XCTAssertEqual(($0 as? ImportFailure)?.errorDescription, "Could not import “Locked.wma”. \(reason)")
        }
        XCTAssertThrowsError(try FFmpegAudioConverter.$tool.withValue(tool) { try FileImportService.importAudioFolderWithReport(from: book) }) {
            XCTAssertEqual(($0 as? ImportFailure)?.errorDescription, "Could not import “Locked Lectures”. \(reason)")
        }
        XCTAssertEqual(try names(in: book), ["01.wma", "02.mp3"])
    }

    /// A file whose bytes are not of its name's format is refused as such
    /// before anything runs; so is one the helper's demuxer refuses (its exit
    /// status 3); and one that holds no sound (status 4) says so, as a helper
    /// that could not confine itself (status 12) says that.
    func testAFileThatIsNotWhatItsNameSaysIsRefused() async throws {
        let folder = try makeSandboxDirectory("FFmpegNotRecognized")
        let fake = folder.appendingPathComponent("Fake.wma")
        try Data("not a Windows Media file".utf8).write(to: fake)
        let (tool, starts) = countingSessionStarts(of: try bundledFFmpegTool())
        do {
            _ = try await FFmpegAudioConverter.convert(fake, using: tool)
            XCTFail("a file that is no WMA must be refused")
        } catch {
            XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .notRecognized(fileName: "Fake.wma", kind: "WMA"))
        }
        XCTAssertEqual(starts(), 0, "the session ran on a file that is no WMA")

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
        var cases: [(String, StandInAction, StandInAction, (any Error) -> Bool)] = [
            ("a probe that hangs", .hang(seconds: 30), .realHelper, killed),
            ("a decode that hangs", .realHelper, .hang(seconds: 30), killed),
            ("a decode that crashes", .realHelper, .write(partial, status: 70),
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
        #if os(macOS)
        // A helper killed by a signal is the Mac's alone: a crash in the iPhone app ends the app.
        cases.append(("a decode killed by a signal", .realHelper, .killItself,
                      { ($0 as? FFmpegAudioConverter.Failure) == .crashed(fileName: "tones.wma") }))
        #endif
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
    ///
    /// Fenced to the Mac: in the iPhone app the session ends at END by
    /// itself, with no program to outlive its stream (FMT54).
    #if os(macOS)
    func testAHelperThatHangsAfterAWholeStreamStillImports() async throws {
        let wma = try source()
        let (helper, _) = try ffmpegHelperStandIn(decode: .realHelperThenHang(seconds: 60))

        let conversion = try await FFmpegAudioConverter.convert(wma, using: ffmpegTool(helper: helper, seconds: TestMachine.allowed(6)))

        XCTAssertEqual(conversion.converted.lastPathComponent, "tones.m4a")
        XCTAssertEqual(conversion.duration, 4.0, accuracy: 0.1)
        XCTAssertEqual(WatchedProcess.runningChildCount, 0)
    }
    #endif

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

    /// The iPhone refuses no file only FFmpeg reads, which it converts in the
    /// app itself (FMT54): the refusal of what it can't convert lets WMA,
    /// Speex in Ogg (whatever its name), and the other formats by, and
    /// refuses an Ogg Vorbis file among them, naming Ogg.
    func testTheIPhoneRefusesNoFFmpegFormat() throws {
        let ffmpegFiles = [
            try source(), try source("spx/tones.spx", named: "Notes.ogg"), try source("mkv/three-tones-flac.mkv", named: "Lecture.mkv"),
            try source("webm/tones-opus.webm", named: "Talk.webm"), try source("avi/tones-mp3.avi", named: "Clip.avi"),
            try source("rm/tones.ra", named: "Show.ra"), URL(fileURLWithPath: "/nonexistent/Lecture.wma"),
        ]
        XCTAssertNoThrow(try PhoneImportRefusal.refuseConversion(of: ffmpegFiles))
        let ogg = URL(fileURLWithPath: "/nonexistent/Radio Drama.ogg")
        XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: ffmpegFiles + [ogg])) { error in
            XCTAssertEqual(error as? PhoneImportRefusal, .convertedAudio(kind: "Ogg"))
        }
    }

    /// On the iPhone a copy-protected Windows Media file is told as such
    /// first, in the Mac's own words, before any conversion and before the
    /// iPhone refuses another file and sends the person to the Mac, which
    /// could not convert it either (FU-FFMPEG).
    func testTheIPhoneTellsACopyProtectedFileFirst() throws {
        let folder = try makeSandboxDirectory("FFmpegProtectedPhone")
        let locked = folder.appendingPathComponent("Locked.wma")
        try copyProtectedASF(from: try formatSampleURL("wma/tones-wma1.wma")).write(to: locked)
        let ogg = URL(fileURLWithPath: "/nonexistent/Radio Drama.ogg")
        for sources in [[locked], [ogg, locked], [try source(), locked]] {
            XCTAssertThrowsError(try PhoneImportRefusal.refuseConversion(of: sources)) { error in
                XCTAssertEqual(error as? FFmpegAudioConverter.Failure, .copyProtected, "\(sources.map(\.lastPathComponent))")
            }
        }
        XCTAssertEqual(FFmpegAudioConverter.Failure.copyProtected.errorDescription, "TextMouth cannot open copy-protected files.")
    }
}
