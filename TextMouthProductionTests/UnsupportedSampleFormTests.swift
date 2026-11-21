import AudioToolbox
import XCTest
@testable import TextMouth

/// A valid audio file whose samples are of a form TextMouth cannot decode is
/// told so, never called damaged (B15). The form comes from the file's own
/// description and is named only after a decode or a conversion has failed,
/// on every path: the import's probe, the parse of a book's files, the import
/// of a single file, and the conversion of a file the import converts first.
/// Every file is written by the tests, byte by byte, as tiny as a tone of a
/// second can be; no sound is played, and the converter and `afinfo` run in
/// child processes, as in the app.
final class UnsupportedSampleFormTests: XCTestCase {
    /// A form of samples, from its depth and kind.
    private static func form(_ bits: Int, float: Bool = false) -> AudioSampleForm {
        AudioSampleForm(bits: bits, isFloat: float)
    }

    /// The forms the decoders refuse, each found refused by test on macOS 26
    /// with a file of it: integers deeper than 32 bits, and floats of 16, 24,
    /// and 128 bits.
    private static let unsupported: [AudioSampleForm] = [
        form(64), form(48), form(40), form(33), form(16, float: true), form(24, float: true), form(128, float: true),
    ]

    /// The forms the decoders read, each found read by test: integers up to 32
    /// bits (an odd depth too, 12 and 20), and floats of 32 and 64 bits.
    private static let supported: [AudioSampleForm] = [
        form(8), form(12), form(16), form(20), form(24), form(32), form(32, float: true), form(64, float: true),
    ]

    /// The forms a WAVE file can name in its header and Core Audio opens as
    /// audio (a 24-bit float or a 33-bit integer there is no valid file), the
    /// ones the decoders refuse or read.
    private static func wavForms(unsupported refused: Bool) -> [AudioSampleForm] {
        refused
            ? [form(64), form(48), form(40), form(16, float: true)]
            : [form(16), form(24), form(32), form(32, float: true), form(64, float: true)]
    }

    /// The folder every file of a test is written in, removed when it ends.
    private var folder: URL! // lint-ok: made in setUpWithError before every test
    /// Imported book packages, removed when a test ends.
    private var importedPackages: [URL] = []

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        for package in importedPackages { try? FileManager.default.removeItem(at: package) }
        importedPackages = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Which Forms

    /// The decoders read integers of 8 to 32 bits and floats of 32 and 64
    /// bits, and no other form; the lists are whole.
    func testAFormIsDecodableWhereTheDecodersReadIt() {
        XCTAssertEqual(Self.supported.count, 8)
        XCTAssertEqual(Self.unsupported.count, 7)
        for form in Self.supported { XCTAssertTrue(form.isDecodable, "\(form)") }
        for form in Self.unsupported { XCTAssertFalse(form.isDecodable, "\(form)") }
    }

    /// A description is believed only when its depth is above zero and at
    /// most 64 bits, and its frame holds that many bits in every channel (in
    /// one channel's, when the channels are not interleaved); one that does
    /// not name no form, and the file is left to the damage checks. A frame
    /// the description does not give is believed.
    func testADamagedDescriptionNamesNoForm() {
        func form(bits: Int, bytes: Int?, channels: Int = 1, interleaved: Bool = true) -> AudioSampleForm? {
            AudioSampleForm(bits: bits, isFloat: false, bytesPerFrame: bytes, channels: channels, interleaved: interleaved)
        }
        XCTAssertEqual(form(bits: 64, bytes: 8), Self.form(64))
        XCTAssertEqual(form(bits: 24, bytes: 6, channels: 2), Self.form(24))
        XCTAssertEqual(form(bits: 20, bytes: 4), Self.form(20), "a 20-bit sample in a 32-bit container")
        XCTAssertEqual(form(bits: 48, bytes: nil), Self.form(48), "no frame size given")
        XCTAssertEqual(form(bits: 16, bytes: 2, channels: 2, interleaved: false), Self.form(16), "one channel's bytes")
        XCTAssertNil(form(bits: 48, bytes: 2), "a 16-bit frame under a depth corrupted to 48")
        XCTAssertNil(form(bits: 24, bytes: 3, channels: 2), "two channels of 24 bits need 6 bytes")
        XCTAssertNil(form(bits: 16, bytes: 2, channels: 2), "interleaved channels need their bytes")
        XCTAssertNil(form(bits: 65, bytes: 9))
        XCTAssertNil(form(bits: 4_294_967_295, bytes: nil))
        XCTAssertNil(form(bits: 0, bytes: nil))
        XCTAssertNil(form(bits: -8, bytes: nil))
    }

    /// A stream description gives its form: its depth and whether its flags
    /// say float; a description of coded audio gives none.
    func testAStreamDescriptionGivesItsForm() {
        func description(_ format: AudioFormatID, bits: UInt32, flags: AudioFormatFlags) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: 8_000, mFormatID: format, mFormatFlags: flags, mBytesPerPacket: bits / 8,
                mFramesPerPacket: 1, mBytesPerFrame: bits / 8, mChannelsPerFrame: 1, mBitsPerChannel: bits, mReserved: 0
            )
        }
        XCTAssertEqual(
            AudioSampleForm(description(kAudioFormatLinearPCM, bits: 64, flags: kAudioFormatFlagIsSignedInteger)),
            Self.form(64)
        )
        XCTAssertEqual(
            AudioSampleForm(description(kAudioFormatLinearPCM, bits: 16, flags: kAudioFormatFlagIsFloat)),
            Self.form(16, float: true)
        )
        XCTAssertNil(AudioSampleForm(description(kAudioFormatMPEG4AAC, bits: 0, flags: 0)))
        XCTAssertNil(AudioSampleForm(description(kAudioFormatLinearPCM, bits: 0, flags: 0)))
        // A depth that its own frame cannot hold is no form: 48 bits in 2 bytes.
        var lying = description(kAudioFormatLinearPCM, bits: 48, flags: kAudioFormatFlagIsSignedInteger)
        lying.mBytesPerFrame = 2
        XCTAssertNil(AudioSampleForm(lying))
        // Non-interleaved channels give the bytes of one channel's samples.
        var planar = description(kAudioFormatLinearPCM, bits: 64, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved)
        planar.mChannelsPerFrame = 2
        XCTAssertEqual(AudioSampleForm(planar), Self.form(64))
    }

    // MARK: - The Words

    /// Each refusal names the file, the form in words a listener knows, and
    /// what to do; the file is never called damaged. Pinned word for word.
    func testTheRefusalNamesTheFormAndSaysWhatToDo() {
        XCTAssertEqual(
            AudioSampleFormWording.refusal(fileName: "Talk.wav", form: Self.form(64)),
            "“Talk.wav” uses 64-bit integer samples, which TextMouth can't play. "
                + "Convert it to 16-bit or 24-bit integer samples, then import it again."
        )
        XCTAssertEqual(
            AudioSampleFormWording.refusal(fileName: "Disc 2/03.caf", form: Self.form(16, float: true)),
            "“Disc 2/03.caf” uses 16-bit floating-point samples, which TextMouth can't play. "
                + "Convert it to 16-bit or 24-bit integer samples, then import it again."
        )
        XCTAssertEqual(
            AudioSampleFormWording.advice, "Convert it to 16-bit or 24-bit integer samples, then import it again."
        )
        for form in Self.unsupported {
            let sentence = AudioSampleFormWording.refusal(fileName: "a.wav", form: form)
            XCTAssertFalse(sentence.contains("damaged"), sentence)
            XCTAssertFalse(sentence.contains("fresh copy"), sentence)
        }
    }

    /// An unsupported form is told in its own sentence in the parse's error,
    /// whichever container and book it is named for, and every problem that
    /// is damage is told as before.
    func testOnlyDamageIsToldAsDamage() {
        let unsupported = AudioMediaProblem.unsupportedSamples(Self.form(64))
        XCTAssertEqual(
            AudioParseError.unplayableFile(file: "Disc 2/03.wav", problem: unsupported).errorDescription,
            "“Disc 2/03.wav” uses 64-bit integer samples, which TextMouth can't play. "
                + "Convert it to 16-bit or 24-bit integer samples, then import it again."
        )
        XCTAssertTrue(AudioParseError.unplayableFile(file: "a.wav", problem: unsupported).refusesAValidFile)
        for problem in [AudioMediaProblem.cannotOpen, .noAudio, .cannotDecode, .endsEarly] {
            let error = AudioParseError.unplayableFile(file: "03.mp3", problem: problem)
            XCTAssertEqual(
                error.errorDescription,
                "The file “03.mp3” in this book is damaged or incomplete: \(problem.reason). "
                    + "Get a fresh copy of the book, then import it again."
            )
            XCTAssertFalse(error.refusesAValidFile)
        }
    }

    // MARK: - The Probe

    /// A WAVE file of each unsupported form is refused by the probe for its
    /// form, not as undecodable. The form is the file's own, so a 64-bit
    /// integer file is not mistaken for a 32-bit float one.
    func testTheProbeRefusesEachUnsupportedFormByName() async throws {
        for form in Self.wavForms(unsupported: true) {
            let file = folder.appendingPathComponent("\(form.bits)-\(form.isFloat ? "float" : "integer").wav")
            try AudioTestFixtures.writeToneWAVE(to: file, frames: 8_000, sampleRate: 8_000, bits: form.bits, isFloat: form.isFloat)

            let outcome = await AudioMediaProbe.duration(of: file)

            XCTAssertEqual(outcome, .failure(.unsupportedSamples(form)), "\(form)")
        }
    }

    /// The form is looked at only after the decode has failed: a decode that
    /// passes leaves a 64-bit integer file measured (as a Mac that reads such
    /// samples would), a decode that fails at the opening names the form of a
    /// file in a form the table refuses and no other, and any other problem
    /// is left as it is.
    func testTheFormIsNamedOnlyAfterTheDecodeFails() async throws {
        let wide = folder.appendingPathComponent("wide.wav")
        try AudioTestFixtures.writeToneWAVE(to: wide, frames: 8_000, sampleRate: 8_000, bits: 64, isFloat: false)
        let narrow = folder.appendingPathComponent("narrow.wav")
        try AudioTestFixtures.writeToneWAVE(to: narrow, frames: 8_000, sampleRate: 8_000, bits: 16, isFloat: false)

        let passing = await AudioMediaProbe.duration(of: wide, decoding: { _ in nil })
        let wideFailing = await AudioMediaProbe.duration(of: wide, decoding: { _ in .cannotDecode })
        let narrowFailing = await AudioMediaProbe.duration(of: narrow, decoding: { _ in .cannotDecode })
        let wideBreakingOff = await AudioMediaProbe.duration(of: wide, decoding: { _ in .endsEarly })

        guard case .success(let seconds) = passing else { return XCTFail("a decode that passes was refused: \(passing)") }
        XCTAssertEqual(seconds, 1, accuracy: 0.01)
        XCTAssertEqual(wideFailing, .failure(.unsupportedSamples(Self.form(64))))
        XCTAssertEqual(narrowFailing, .failure(.cannotDecode), "a 16-bit file is damaged, whatever fails")
        XCTAssertEqual(wideBreakingOff, .failure(.endsEarly), "only the opening's failure is renamed")
    }

    /// A WAVE file of each form the decoders read is measured as before.
    func testTheProbeStillMeasuresEachSupportedForm() async throws {
        for form in Self.wavForms(unsupported: false) {
            let file = folder.appendingPathComponent("\(form.bits)-\(form.isFloat ? "float" : "integer").wav")
            try AudioTestFixtures.writeToneWAVE(to: file, frames: 8_000, sampleRate: 8_000, bits: form.bits, isFloat: form.isFloat)

            let outcome = await AudioMediaProbe.duration(of: file)

            guard case .success(let seconds) = outcome else { return XCTFail("\(form) was refused: \(outcome)") }
            XCTAssertEqual(seconds, 1, accuracy: 0.01, "\(form)")
        }
    }

    /// A file that is damaged is still told as damaged: text named as audio,
    /// a WAVE file whose samples are garbled, and a WAVE file cut off right
    /// after its header each give a problem that is damage, never a form.
    func testADamagedFileIsStillToldAsDamaged() async throws {
        let text = folder.appendingPathComponent("note.mp3")
        try AudioTestFixtures.writePlainText(to: text)
        let garbled = folder.appendingPathComponent("garbled.wav")
        try AudioTestFixtures.writeWAVWithUndecodableSamples(to: garbled)
        let cutOff = folder.appendingPathComponent("cut off.wav")
        try AudioTestFixtures.writeWAVHeaderWithoutSamples(to: cutOff)

        var problems: [AudioMediaProblem] = []
        for file in [text, garbled, cutOff] {
            guard case .failure(let problem) = await AudioMediaProbe.duration(of: file) else {
                return XCTFail("\(file.lastPathComponent) was accepted")
            }
            problems.append(problem)
        }

        XCTAssertEqual(problems, [.cannotOpen, .cannotOpen, .noAudio])
        for problem in problems {
            XCTAssertTrue(
                problem.sentence(file: "a.wav", container: .audiobook).contains("damaged or incomplete")
            )
        }
    }

    // MARK: - A Book's Files

    /// One track of a folder in an unsupported form fails the book, naming
    /// that track and its form, in the sentence that blames no damage.
    func testAFolderTrackOfAnUnsupportedFormFailsNamingItAndItsForm() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"))
        try AudioTestFixtures.writeToneWAVE(
            to: folder.appendingPathComponent("02.wav"), frames: 8_000, sampleRate: 8_000, bits: 64, isFloat: false
        )
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("03.wav"))

        do {
            _ = try await AudioBookParser.parseDirectory(url: folder)
            XCTFail("The folder parsed without an error")
        } catch let error as AudioParseError {
            XCTAssertEqual(error, .unplayableFile(file: "02.wav", problem: .unsupportedSamples(Self.form(64))))
            XCTAssertEqual(
                error.localizedDescription,
                "“02.wav” uses 64-bit integer samples, which TextMouth can't play. "
                    + "Convert it to 16-bit or 24-bit integer samples, then import it again."
            )
        }
    }

    /// A single file in an unsupported form fails the same way.
    func testASingleFileOfAnUnsupportedFormFailsNamingItsForm() async throws {
        let file = folder.appendingPathComponent("Talk.wav")
        try AudioTestFixtures.writeToneWAVE(to: file, frames: 8_000, sampleRate: 8_000, bits: 48, isFloat: false)

        do {
            _ = try await AudioBookParser.parse(url: file)
            XCTFail("A file of 48-bit samples parsed")
        } catch let error as AudioParseError {
            XCTAssertEqual(error, .unplayableFile(file: "Talk.wav", problem: .unsupportedSamples(Self.form(48))))
        }
    }

    // MARK: - The Import

    /// Importing a single file in an unsupported form fails while reading its
    /// audio, in the refusal's own words, not in the words playback uses for
    /// a damaged file; nothing is left in the library, and the source keeps
    /// its bytes.
    func testImportingAFileOfAnUnsupportedFormSaysSo() throws {
        let source = folder.appendingPathComponent("Canal Survey.wav")
        try AudioTestFixtures.writeToneWAVE(to: source, frames: 8_000, sampleRate: 8_000, bits: 64, isFloat: false)
        let sourceBytes = try Data(contentsOf: source)
        let libraryBefore = OggTestFixtures.names(in: TextMouthPaths.libraryDir)

        do {
            let imported = try FileImportService.importFileWithReport(from: source)
            importedPackages.append(imported.book.tmbDirectory)
            XCTFail("A file of 64-bit integer samples imported")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step, .readingAudio)
            XCTAssertEqual(
                failure.errorDescription,
                "Could not import “Canal Survey.wav”. Reading its audio failed: "
                    + "“Canal Survey.wav” uses 64-bit integer samples, which TextMouth can't play. "
                    + "Convert it to 16-bit or 24-bit integer samples, then import it again."
            )
        }

        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(OggTestFixtures.names(in: TextMouthPaths.libraryDir), libraryBefore)
    }

    /// A damaged single file is still told in playback's words, as before.
    func testImportingADamagedFileStillSaysItIsDamaged() throws {
        let source = folder.appendingPathComponent("Notes.mp3")
        try AudioTestFixtures.writePlainText(to: source)

        do {
            let imported = try FileImportService.importFileWithReport(from: source)
            importedPackages.append(imported.book.tmbDirectory)
            XCTFail("A text file imported as audio")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step, .readingAudio)
            XCTAssertTrue(failure.errorDescription?.contains("is damaged, unreadable, or not an audio file") == true,
                          failure.errorDescription ?? "no description")
        }
    }

    // MARK: - The Conversion

    /// What `afinfo` says of a file's samples is the file's own form: every
    /// depth and kind the tests write, floats included.
    func testAfinfoGivesTheFormOfALinearPCMFile() async throws {
        // A 128-bit float CAF file does not open at all, so afinfo gives no form for it.
        for form in Self.unsupported + Self.supported where form.bits != 128 {
            let file = folder.appendingPathComponent("\(form.bits)-\(form.isFloat ? "float" : "integer").caf")
            try AudioTestFixtures.writeToneCAF(to: file, frames: 8_000, sampleRate: 8_000, bits: form.bits, isFloat: form.isFloat)

            let facts = try await AudioFileInfo.read(file)

            XCTAssertEqual(facts?.sampleForm, form, "\(form)")
        }
    }

    /// A file that is no linear PCM has no form: its codec decides.
    func testCodedAudioHasNoSampleForm() async throws {
        let file = folder.appendingPathComponent("Coded.m4a")
        try AudioTestFixtures.writeAACSilence(to: file)

        let facts = try await AudioFileInfo.read(file)

        XCTAssertNotNil(facts)
        XCTAssertNil(facts?.sampleForm)
    }

    /// A CAF file of each unsupported form is refused before anything is
    /// converted, with the form named and no exit code, and the source is
    /// untouched and nothing is left beside it.
    func testTheConverterRefusesEachUnsupportedFormByName() async throws {
        for form in Self.unsupported where form.bits != 128 {
            let name = "\(form.bits)-\(form.isFloat ? "float" : "integer").caf"
            let source = folder.appendingPathComponent(name)
            try AudioTestFixtures.writeToneCAF(to: source, frames: 8_000, sampleRate: 8_000, bits: form.bits, isFloat: form.isFloat)
            let sourceBytes = try Data(contentsOf: source)
            let before = OggTestFixtures.names(in: folder)

            do {
                _ = try await ImportAudioConverter.convert(source)
                XCTFail("\(name) was converted")
            } catch let failure as ImportAudioConverter.Failure {
                XCTAssertEqual(failure, .unsupportedSamples(fileName: name, form: form), name)
                XCTAssertEqual(failure.errorDescription, AudioSampleFormWording.refusal(fileName: name, form: form), name)
            }

            XCTAssertEqual(try Data(contentsOf: source), sourceBytes, name)
            XCTAssertEqual(OggTestFixtures.names(in: folder), before, name)
        }
    }

    /// The form is looked at only after the converter has failed: a converter
    /// that succeeds on a source in a form the table refuses (a stand-in that
    /// converts a good file instead, as a newer macOS's would convert the
    /// file itself) leaves the conversion alone, a converter that fails with
    /// an exit status names the form, and one that fails to start, or any
    /// source in a form the table reads, keeps the failure it had.
    func testTheFormIsNamedOnlyAfterTheConverterFails() async throws {
        let wide = folder.appendingPathComponent("Wide.caf")
        try AudioTestFixtures.writeToneCAF64(to: wide, frames: 8_000, sampleRate: 8_000, isFloat: false)
        let narrow = folder.appendingPathComponent("Narrow.caf")
        try AudioTestFixtures.writeToneCAF(to: narrow, frames: 8_000, sampleRate: 8_000, bits: 16, isFloat: false)
        let good = folder.appendingPathComponent("Good.wav")
        try AudioTestFixtures.writeSilence(to: good, duration: 1)

        // A converter that reads the source: afconvert, run on a good file in its place.
        var succeeding = ImportAudioConverter.Tool.afconvert
        succeeding.command = { _, output, info, target in
            (URL(fileURLWithPath: "/usr/bin/afconvert"),
             ImportAudioConverter.afconvertArguments(from: good, to: output, info: info, target: target))
        }
        let converted = try await ImportAudioConverter.convert(wide, using: succeeding)
        XCTAssertEqual(converted.duration, 1, accuracy: 0.05)

        // A converter that ends with a status, and one that cannot start.
        var failing = ImportAudioConverter.Tool.afconvert
        failing.command = { _, _, _, _ in (URL(fileURLWithPath: "/usr/bin/false"), []) }
        var missing = ImportAudioConverter.Tool.afconvert
        missing.command = { _, _, _, _ in (URL(fileURLWithPath: "/usr/bin/no-such-converter"), []) }
        for (source, tool, expected) in [
            (wide, failing, ImportAudioConverter.Failure.unsupportedSamples(fileName: "Wide.caf", form: Self.form(64))),
            (narrow, failing, .processFailed(fileName: "Narrow.caf", status: 1)),
            (wide, missing, .processFailed(fileName: "Wide.caf", status: -1)),
        ] {
            do {
                _ = try await ImportAudioConverter.convert(source, using: tool)
                XCTFail("\(source.lastPathComponent) was converted by a converter that fails")
            } catch let failure as ImportAudioConverter.Failure {
                XCTAssertEqual(failure, expected, source.lastPathComponent)
            }
        }
    }

    /// The refusal of the converter, as the import tells it.
    func testImportingACAFFileOfAnUnsupportedFormSaysSo() throws {
        let source = folder.appendingPathComponent("Radio Play.caf")
        try AudioTestFixtures.writeToneCAF64(to: source, frames: 8_000, sampleRate: 8_000, isFloat: false)
        let libraryBefore = OggTestFixtures.names(in: TextMouthPaths.libraryDir)

        do {
            let imported = try FileImportService.importFileWithReport(from: source)
            importedPackages.append(imported.book.tmbDirectory)
            XCTFail("A CAF file of 64-bit integers imported")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step.activity, "Converting its audio")
            XCTAssertEqual(
                failure.errorDescription,
                "Could not import “Radio Play.caf”. Converting its audio failed: "
                    + "“Radio Play.caf” uses 64-bit integer samples, which TextMouth can't play. "
                    + "Convert it to 16-bit or 24-bit integer samples, then import it again."
            )
        }

        XCTAssertEqual(OggTestFixtures.names(in: TextMouthPaths.libraryDir), libraryBefore)
    }

    /// A CAF file of each form the decoders read still converts, to Apple
    /// Lossless of the source's length: the refusal takes only what fails.
    /// The 20-bit form and an 18-bit one are among them: the Apple Lossless
    /// file made of them is written at 24 bits, since AVAssetReader cannot
    /// read one of 20 (train 1117-0431).
    func testTheConverterStillConvertsEachSupportedForm() async throws {
        for form in Self.supported + [Self.form(18)] {
            let name = "\(form.bits)-\(form.isFloat ? "float" : "integer").caf"
            let source = folder.appendingPathComponent(name)
            try AudioTestFixtures.writeToneCAF(to: source, frames: 8_000, sampleRate: 8_000, bits: form.bits, isFloat: form.isFloat)

            let conversion = try await ImportAudioConverter.convert(source)

            XCTAssertEqual(conversion.duration, 1, accuracy: 0.05, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: conversion.converted.path), name)
            // A source of 17 to 20 bits is written at 24 bits: AVAssetReader cannot read a 20-bit Apple Lossless file.
            if !form.isFloat, (17...20).contains(form.bits) {
                let written = try await AudioFileInfo.read(conversion.converted)
                XCTAssertEqual(written?.bitsPerSample, 24, name)
            }
        }
    }

    // MARK: - Sources of 17 to 20 Bits

    /// Writes a 20-bit Apple Lossless .m4a, as `afconvert` has always written
    /// one from a 20-bit source (flag 2 after `alac/`), in this test's folder:
    /// the file an earlier TextMouth, or another program, made, which the
    /// import now meets as it is.
    private func writeAppleLossless20(named name: String) throws -> URL {
        let source = folder.appendingPathComponent(".source-\(name).caf")
        try AudioTestFixtures.writeToneCAF(to: source, frames: 8_000, sampleRate: 8_000, bits: 20, isFloat: false)
        let file = folder.appendingPathComponent(name)
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = ["-f", "m4af", "-d", "alac/2", source.path, file.path]
        try converter.run()
        converter.waitUntilExit()
        XCTAssertEqual(converter.terminationStatus, 0, "afconvert wrote the 20-bit file")
        return file
    }

    /// An Apple Lossless file of a 20-bit source is not played as it is: the
    /// import converts it, to 24 bits, while the same file at 16, 24, or 32
    /// bits is left alone. Without it the probe called the file damaged.
    func testAnAppleLosslessFileOfTwentyBitsIsConvertedNotKept() async throws {
        let twenty = try writeAppleLossless20(named: "Twenty.m4a")
        let twentyFour = folder.appendingPathComponent("Twenty Four.m4a")
        try AudioTestFixtures.writeToneAppleLossless24(to: twentyFour, frames: 8_000, sampleRate: 8_000)

        let converted = try await ImportAudioConverter.needsConversion(among: [twenty, twentyFour])

        XCTAssertEqual(converted.map(\.lastPathComponent), ["Twenty.m4a"])
    }

    /// Importing that file gives a book whose audio is Apple Lossless of 24
    /// bits, which plays, and not the refusal that called it damaged.
    func testImportingAnAppleLosslessFileOfTwentyBitsWritesItAtTwentyFour() async throws {
        let source = try writeAppleLossless20(named: "Canal Tapes.m4a")

        let imported = try FileImportService.importFileWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)

        let written = try await AudioFileInfo.read(URL(fileURLWithPath: imported.book.filePath))
        XCTAssertEqual(written?.formatID, "alac")
        XCTAssertEqual(written?.bitsPerSample, 24)
    }

    /// A damaged CAF file is still told as unreadable for converting: it has
    /// no description to name a form from.
    func testADamagedCAFFileIsStillUnreadable() async throws {
        let source = folder.appendingPathComponent("Damaged.caf")
        try (Data("caff".utf8) + Data(count: 64)).write(to: source)

        do {
            _ = try await ImportAudioConverter.convert(source)
            XCTFail("A damaged CAF file was converted")
        } catch let failure as ImportAudioConverter.Failure {
            XCTAssertEqual(failure, .unreadable(fileName: "Damaged.caf"))
        }
    }
}
