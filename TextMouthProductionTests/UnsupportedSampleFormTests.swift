import AudioToolbox
import XCTest
@testable import TextMouth

/// A valid audio file whose samples are of a form TextMouth cannot decode is
/// told so, never called damaged (B15). The form comes from the file's own
/// description, before any sample is decoded, on every path: the import's
/// probe, the parse of a book's files, the import of a single file, and the
/// conversion of a file the import converts first. Every file is written by
/// the tests, byte by byte, as tiny as a tone of a second can be; no sound is
/// played, and the converter and `afinfo` run in child processes, as in the
/// app.
final class UnsupportedSampleFormTests: XCTestCase {
    /// A form of samples, from its depth and kind (never zero bits).
    private static func form(_ bits: Int, float: Bool = false) -> AudioSampleForm {
        guard let form = AudioSampleForm(bits: bits, isFloat: float) else { preconditionFailure("\(bits) is no depth") }
        return form
    }

    /// The forms the decoders refuse, each found refused by test on macOS 26
    /// with a file of it: integers deeper than 32 bits, and floats of 16 bits.
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

    /// The decoders read integers of 1 to 32 bits and floats of 32 and 64
    /// bits, and no other form; a description with no depth has no form, and
    /// coded audio has none of its own.
    func testAFormIsDecodableWhereTheDecodersReadIt() {
        for form in Self.supported { XCTAssertTrue(form.isDecodable, "\(form)") }
        for form in Self.unsupported { XCTAssertFalse(form.isDecodable, "\(form)") }
        XCTAssertNil(AudioSampleForm(bits: 0, isFloat: false))
        XCTAssertNil(AudioSampleForm(bits: -8, isFloat: true))
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
    }

    // MARK: - The Words

    /// Each refusal names the file, the form in words a listener knows, and
    /// what to do; the file is never called damaged. Pinned word for word.
    func testTheRefusalNamesTheFormAndSaysWhatToDo() {
        XCTAssertEqual(
            AudioSampleFormWording.refusal(fileName: "Talk.wav", form: Self.form(64)),
            "“Talk.wav” uses 64-bit integer samples, which TextMouth can't play. "
                + "Convert it to 16-bit or 24-bit, then add it again."
        )
        XCTAssertEqual(
            AudioSampleFormWording.refusal(fileName: "Disc 2/03.caf", form: Self.form(16, float: true)),
            "“Disc 2/03.caf” uses 16-bit floating-point samples, which TextMouth can't play. "
                + "Convert it to 16-bit or 24-bit, then add it again."
        )
        XCTAssertEqual(AudioSampleFormWording.advice, "Convert it to 16-bit or 24-bit, then add it again.")
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
                + "Convert it to 16-bit or 24-bit, then add it again."
        )
        XCTAssertTrue(AudioParseError.unplayableFile(file: "a.wav", problem: unsupported).refusesAValidFile)
        for problem in [AudioMediaProblem.cannotOpen, .noAudio, .cannotDecode, .endsEarly] {
            let error = AudioParseError.unplayableFile(file: "03.mp3", problem: problem)
            XCTAssertEqual(
                error.errorDescription,
                "The file “03.mp3” in this audiobook is damaged or incomplete: \(problem.reason). "
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
                problem.sentence(file: "a.wav", container: "this audiobook", original: "the book").contains("damaged or incomplete")
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
                    + "Convert it to 16-bit or 24-bit, then add it again."
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
                    + "Convert it to 16-bit or 24-bit, then add it again."
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
                    + "Convert it to 16-bit or 24-bit, then add it again."
            )
        }

        XCTAssertEqual(OggTestFixtures.names(in: TextMouthPaths.libraryDir), libraryBefore)
    }

    /// A CAF file of each form the decoders read still converts, to Apple
    /// Lossless of the source's length: the refusal takes only what fails.
    func testTheConverterStillConvertsEachSupportedForm() async throws {
        for form in Self.supported {
            let name = "\(form.bits)-\(form.isFloat ? "float" : "integer").caf"
            let source = folder.appendingPathComponent(name)
            try AudioTestFixtures.writeToneCAF(to: source, frames: 8_000, sampleRate: 8_000, bits: form.bits, isFloat: form.isFloat)

            let conversion = try await ImportAudioConverter.convert(source)

            XCTAssertEqual(conversion.duration, 1, accuracy: 0.05, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: conversion.converted.path), name)
        }
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
