import AVFoundation
import XCTest
@testable import TextMouth

/// Books whose samples are wider than AVFoundation's readers take (B12): a
/// 64-bit float WAVE, AIFF, or CAF file, or a 64-bit integer CAF.
/// AVAssetReader's outputs and AVAssetWriter's inputs raise an Objective-C
/// exception, which ends the app, for any depth but 8, 16, 24, and 32 bits
/// ("Bit depth can only be one of: 24, 16, 8, 32"), and a render took the
/// depth of its settings from the book. These tests drive every path that
/// decodes such a book's edits: a punch-in, inserted silence, a filter, a
/// resampled render, every export format, a save, and the preview. Each
/// checks the length of what it made and that its samples are the book's,
/// not silence. No sound is played.
extension AudioEditRenderingTests {
    /// A book stored in a sample layout the readers refuse.
    struct WideBook: CustomStringConvertible {
        /// The file's name, which gives its type.
        let fileName: String
        /// Bits a sample as the file stores them.
        let bits: Int
        /// Whether they are floats.
        let isFloat: Bool
        /// Whether AVFoundation can decode the layout at all. It can't decode
        /// 64-bit integers (its audio queue refuses them with 'fmt?'), so a
        /// render of such a book may fail, with an error, but never end the app.
        var decodes = true
        /// Writes `frames` frames of `AudioTestFixtures.tone` at `rate` to the URL.
        let write: (URL, Int, Double) throws -> Void

        var description: String { "\(bits)-bit \(isFloat ? "float" : "integer") \(fileName)" }

        /// A CAF file of 64-bit samples, written by hand.
        static func caf(isFloat: Bool) -> WideBook {
            WideBook(fileName: "Canal Survey.caf", bits: 64, isFloat: isFloat, decodes: isFloat) { url, frames, rate in
                try AudioTestFixtures.writeToneCAF64(to: url, frames: frames, sampleRate: rate, isFloat: isFloat)
            }
        }
    }

    /// The layouts the tests try: every one the readers refuse that a
    /// book is found in as a file type TextMouth imports: 64-bit floats in
    /// WAVE, AIFF, and CAF files, and 64-bit integers in a CAF file. A
    /// computed list, since a book holds closures, which a stored static
    /// property of a test class may not.
    static var wideBooks: [WideBook] { [
        WideBook(fileName: "Canal Survey.wav", bits: 64, isFloat: true) { url, frames, rate in
            try AudioTestFixtures.writeToneFloat64WAVE(to: url, frames: frames, sampleRate: rate)
        },
        WideBook(fileName: "Canal Survey.aiff", bits: 64, isFloat: true) { url, frames, rate in
            try AudioTestFixtures.writeToneFloat64AIFC(to: url, frames: frames, sampleRate: rate)
        },
        .caf(isFloat: true),
        .caf(isFloat: false),
    ] }

    /// The seconds the books last: three, so a stretch is cut from the middle.
    private static let wideSeconds = 3.0

    // MARK: - The Settings

    /// No render's reader or writer is given a depth AVFoundation refuses,
    /// whatever depth the book stores, in any format: the layouts it takes
    /// stay as they are, and 64-bit floats and integers become 32-bit floats
    /// in CAF files and 32-bit integers where the writer takes no floats.
    func testNoRenderIsGivenADepthTheReadersRefuse() {
        let layouts: [(bits: UInt32, flags: AudioFormatFlags)] = [
            (64, kAudioFormatFlagIsFloat), (32, kAudioFormatFlagIsFloat), (64, kAudioFormatFlagIsSignedInteger),
            (32, kAudioFormatFlagIsSignedInteger), (24, kAudioFormatFlagIsSignedInteger),
            (20, kAudioFormatFlagIsSignedInteger), (16, kAudioFormatFlagIsSignedInteger),
            (12, kAudioFormatFlagIsSignedInteger), (8, 0),
        ]
        var problems: [String] = []
        for layout in layouts {
            let stored = AudioStreamBasicDescription(
                mSampleRate: 8_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: layout.flags,
                mBytesPerPacket: (layout.bits + 7) / 8, mFramesPerPacket: 1, mBytesPerFrame: (layout.bits + 7) / 8,
                mChannelsPerFrame: 1, mBitsPerChannel: layout.bits, mReserved: 0
            )
            let base = AudioEditBase(url: URL(fileURLWithPath: "/book.caf"), sampleRate: 8_000, channelCount: 1, frames: 8_000, format: stored, bitRate: nil, chapters: [])
            for format in AudioRenderFormat.allCases {
                let settings = AudioRenderSettings.make(format, for: base)
                for (name, keys) in [("reader", settings.readerSettings), ("writer", settings.outputSettings)] {
                    guard let depth = keys[AVLinearPCMBitDepthKey] as? Int else { continue }
                    let isFloat = keys[AVLinearPCMIsFloatKey] as? Bool ?? false
                    let accepted = isFloat ? depth == 32 : AudioRenderSettings.acceptedIntegerDepths.contains(depth)
                    if !accepted {
                        problems.append("\(layout.bits)-bit (flags \(layout.flags)) to \(format): the \(name) gets \(depth) bits, float \(isFloat)")
                    }
                }
            }
            // The two files that hold floats exactly keep them as 32-bit floats.
            if layout.flags == kAudioFormatFlagIsFloat {
                let caf = AudioRenderSettings.make(.pcmCAF, for: base)
                if caf.bitsPerSample != 32 || !caf.isFloat { problems.append("a \(layout.bits)-bit float CAF is rendered as \(caf)") }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// An integer depth AVFoundation refuses between two it takes is stored at
    /// the next one up, which holds every sample exactly (20 bits at 24, 12 at
    /// 16), while the depths it takes stay and the deeper or unknown ones
    /// become 32-bit floats.
    func testAnOddIntegerDepthIsStoredAtTheNextDepthUp() {
        let expected: [(bits: Int, isFloat: Bool, stored: Int, storedFloat: Bool)] = [
            (8, false, 8, false), (12, false, 16, false), (16, false, 16, false), (20, false, 24, false),
            (24, false, 24, false), (28, false, 32, false), (32, false, 32, false),
            (33, false, 32, true), (64, false, 32, true), (0, false, 32, true),
            (32, true, 32, true), (64, true, 32, true),
        ]
        for layout in expected {
            let found = AudioRenderSettings.readableDepth(bits: layout.bits, isFloat: layout.isFloat)
            XCTAssertEqual(found.bits, layout.stored, "\(layout.bits) bits, float \(layout.isFloat)")
            XCTAssertEqual(found.isFloat, layout.storedFloat, "\(layout.bits) bits, float \(layout.isFloat)")
        }
    }

    /// A raised Objective-C exception from the initializer of a reader's
    /// output fails the render with a Swift error, which says the edited
    /// audio couldn't be written, rather than ending the app: the net under
    /// the settings, for any layout still refused. The exception here is
    /// AVFoundation's own refusal of a 64-bit float, "Bit depth can only be
    /// one of: 24, 16, 8, 32", caught.
    /// Runs on GitHub's runner only, since it raises an exception on purpose
    /// (`TestMachine.skipUnlessGitHubRunner`).
    func testAnExceptionFromAVFoundationFailsTheRenderInsteadOfEndingTheApp() async throws {
        try TestMachine.skipUnlessGitHubRunner("This test raises an Objective-C exception on purpose")
        let folder = try makeFolder()
        let url = folder.appendingPathComponent("Canal Survey.caf")
        try AudioTestFixtures.writeIdentityRamp(to: url, frames: 8_000, sampleRate: Self.rate)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let refused: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 64,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        XCTAssertThrowsError(try AudioEditRenderer.makingWithoutRaising {
            AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: refused)
        }) { error in
            guard case AudioEditError.renderFailed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertEqual((error as? AudioEditError)?.errorDescription, "The edited audio couldn't be written.")
        }
        // Any exception becomes the same error, and a call that raises none
        // gives its value.
        XCTAssertThrowsError(try AudioEditRenderer.makingWithoutRaising { () -> Int in
            NSException(name: .genericException, reason: "refused", userInfo: nil).raise()
            return 0
        })
        XCTAssertEqual(try AudioEditRenderer.makingWithoutRaising { 7 }, 7)
    }

    /// A render given settings of its caller's own (a filter's stretch is
    /// one) that ask for a depth AVFoundation refuses fails with the
    /// render's own error, the edited audio couldn't be written, and leaves
    /// no file: the writer's input raised an exception for these, which
    /// ended the app, in the render of every book until B12 was fixed.
    /// Runs on GitHub's runner only, since it raises an exception on purpose
    /// (`TestMachine.skipUnlessGitHubRunner`).
    func testARenderAskedForADepthAVFoundationRefusesFailsInsteadOfEndingTheApp() async throws {
        try TestMachine.skipUnlessGitHubRunner("This test raises an Objective-C exception on purpose")
        let (sources, folder) = try await makeRampSources(seconds: 1)
        var timeline = sources.base.timeline
        try timeline.applyRearranging(.insertSilence(at: 0.5, duration: 0.25))
        let refused = AudioRenderSettings(
            format: .pcmCAF, sampleRate: Self.rate, channels: 1, bitRate: nil, bitsPerSample: 64, isFloat: true
        )
        let output = folder.appendingPathComponent("refused.caf")

        do {
            _ = try await AudioEditRenderer.render(
                timeline,
                sources: sources,
                to: output,
                format: .pcmCAF,
                settings: refused,
                metadata: AudioRenderMetadata(title: "Canal Survey", author: nil)
            )
            XCTFail("a render in 64-bit floats was written")
        } catch AudioEditError.renderFailed(let reason) {
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Decoded Renders

    /// A punch-in, inserted silence, a filter, and a render at another rate
    /// of each wide book come out the length the edits make, and every
    /// stretch is the book's tone (or the take's ramp, or silence, where the
    /// edit put them), not silence.
    func testEveryDecodedRenderOfAWideBookKeepsItsLengthAndItsSound() async throws {
        var problems: [String] = []
        for book in Self.wideBooks {
            do {
                problems += try await decodedRenderProblems(of: book).map { "\(book): \($0)" }
            } catch {
                if book.decodes { problems.append("\(book): \(error)") }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// Every export format renders a cut of each wide book to the length of
    /// the cut, with its sound.
    func testEveryExportFormatRendersAWideBook() async throws {
        var problems: [String] = []
        for book in Self.wideBooks {
            let (base, folder) = try await makeWideBase(book)
            var timeline = base.timeline
            try timeline.applyRearranging(.cut(AudioTimeRange(start: 1, end: 2)))
            for format in AudioRenderFormat.allCases {
                let output = folder.appendingPathComponent("export.\(format.fileExtension)")
                do {
                    _ = try await AudioEditRenderer.render(
                        timeline,
                        sources: AudioEditComposition.Sources(base: base, package: folder, scratch: folder),
                        to: output,
                        format: format,
                        metadata: AudioRenderMetadata(title: "Canal Survey", author: nil)
                    )
                } catch {
                    if book.decodes { problems.append("\(book) as \(format): \(error)") }
                    continue
                }
                // A book AVFoundation can't decode is asked only not to end the app.
                guard book.decodes else { continue }
                // A compressed export, with its priming and padding, lasts a
                // few frames more or less than the cut; a PCM one is exact.
                let samples = try AudioTestFixtures.floatSamples(of: output)
                let slack = format.isPCM ? 0 : 4_000
                if abs(samples.count - 16_000) > slack {
                    problems.append("\(book) as \(format): lasts \(samples.count) frames, not 16,000")
                }
                if AudioTestFixtures.rms(samples) < 0.1 {
                    problems.append("\(book) as \(format): is silent (rms \(AudioTestFixtures.rms(samples)))")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    // MARK: - Through a Session

    /// A session on each wide book previews inserted silence, saves it into
    /// the book's own file, and exports it: the preview and the saved file
    /// both last the three seconds and the half second, with silence where
    /// the edit put it and the book's tone around it.
    @MainActor
    func testAWideBookPreviewsSavesAndExportsItsEdits() async throws {
        var problems: [String] = []
        for book in Self.wideBooks {
            let (model, entry) = try makeLibraryBook(seconds: Self.wideSeconds, fileName: book.fileName) { url, frames in
                try book.write(url, frames, Self.rate)
            }
            let session = try await AudioEditSession.open(bookID: entry.id, in: model)
            defer { session.close() }
            do {
                _ = try await session.perform(.insertSilence(at: 1, duration: 0.5))

                // A book AVFoundation can't decode is asked only not to end the app.
                if book.decodes {
                    let preview = try await Self.compositionSamples(try await session.makePreview())
                    problems += silenceProblems(in: preview, expectedFrames: 28_000).map { "\(book), preview: \($0)" }
                }

                let exported = try makeFolder().appendingPathComponent("exported.caf")
                try await session.export(to: exported, as: .caf)
                if book.decodes {
                    problems += silenceProblems(in: try AudioTestFixtures.floatSamples(of: exported), expectedFrames: 28_000).map { "\(book), export: \($0)" }
                }

                let outcome = try await session.save()
                if book.decodes {
                    XCTAssertTrue(outcome.rendered, "\(book)")
                    problems += silenceProblems(in: try AudioTestFixtures.floatSamples(of: outcome.book.bookFileURL), expectedFrames: 28_000).map { "\(book), save: \($0)" }
                }
            } catch {
                if book.decodes { problems.append("\(book): \(error)") }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    /// A render asked for 32-bit floats (a filter's input, the stretch of a
    /// Copy or Cut, MP3's intermediate file) of a cut of a 64-bit float book
    /// decodes them and writes 32-bit floats, as asked, rather than copying
    /// the book's 64-bit samples, which its own standard settings now equal.
    func testAskedFor32BitFloatsA64BitFloatBookIsDecodedNotCopied() async throws {
        let book = AudioEditRenderingTests.WideBook.caf(isFloat: true)
        let (base, folder) = try await makeWideBase(book)
        var timeline = base.timeline
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 1, end: 2)))
        let output = folder.appendingPathComponent("stretch.caf")

        let outcome = try await AudioEditRenderer.render(
            timeline,
            sources: AudioEditComposition.Sources(base: base, package: folder, scratch: folder),
            to: output,
            format: .pcmCAF,
            settings: AudioRenderSettings.floatCAF(for: base),
            metadata: AudioRenderMetadata(title: "", author: nil)
        )

        XCTAssertFalse(outcome.copiedSamples)
        let written = try await AudioEditBase.load(output, name: "stretch.caf")
        XCTAssertEqual(written.format.mBitsPerChannel, 32)
        XCTAssertNotEqual(written.format.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        XCTAssertEqual(written.frames, 16_000)
    }

    // MARK: - Lossless Books

    /// The depth of a lossless book is read from its format flags (1, 2, 3,
    /// and 4 for 16, 20, 24, and 32 bits), since the format reports no bits a
    /// channel for compressed samples; a linear PCM file's own depth counts,
    /// and floats and lossy audio have none. A 20-bit lossless book is saved
    /// at 24 bits, as the import writes it, and its WAVE export keeps its
    /// depth, 20 bits being stored at 24.
    func testTheDepthOfALosslessBookComesFromItsFormatFlags() {
        func format(_ id: AudioFormatID, bits: UInt32, flags: AudioFormatFlags) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: 8_000, mFormatID: id, mFormatFlags: flags, mBytesPerPacket: 0, mFramesPerPacket: 4_096,
                mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: bits, mReserved: 0
            )
        }
        for id in [kAudioFormatAppleLossless, kAudioFormatFLAC] {
            for (flags, depth) in [(1, 16), (2, 20), (3, 24), (4, 32)] as [(AudioFormatFlags, Int)] {
                XCTAssertEqual(AudioRenderSettings.storedIntegerDepth(of: format(id, bits: 0, flags: flags)), depth, "\(id) flags \(flags)")
            }
            XCTAssertNil(AudioRenderSettings.storedIntegerDepth(of: format(id, bits: 0, flags: 0)), "\(id) without flags")
        }
        XCTAssertEqual(AudioRenderSettings.storedIntegerDepth(of: format(kAudioFormatLinearPCM, bits: 24, flags: kAudioFormatFlagIsSignedInteger)), 24)
        XCTAssertNil(AudioRenderSettings.storedIntegerDepth(of: format(kAudioFormatLinearPCM, bits: 32, flags: kAudioFormatFlagIsFloat)))
        XCTAssertNil(AudioRenderSettings.storedIntegerDepth(of: format(kAudioFormatMPEG4AAC, bits: 0, flags: 2)))

        func settings(_ target: AudioRenderFormat, _ id: AudioFormatID, flags: AudioFormatFlags) -> AudioRenderSettings {
            let base = AudioEditBase(
                url: URL(fileURLWithPath: "/book.m4a"), sampleRate: 8_000, channelCount: 1, frames: 8_000,
                format: format(id, bits: 0, flags: flags), bitRate: nil, chapters: []
            )
            return AudioRenderSettings.make(target, for: base)
        }
        XCTAssertEqual(settings(.alacM4A, kAudioFormatAppleLossless, flags: 3).bitsPerSample, 24)
        XCTAssertEqual(settings(.alacM4A, kAudioFormatFLAC, flags: 3).bitsPerSample, 24)
        XCTAssertEqual(settings(.alacM4A, kAudioFormatAppleLossless, flags: 2).bitsPerSample, 24, "20 bits are written as 24")
        XCTAssertEqual(settings(.alacM4A, kAudioFormatAppleLossless, flags: 1).bitsPerSample, 16)
        XCTAssertEqual(settings(.pcmWAV, kAudioFormatAppleLossless, flags: 3).bitsPerSample, 24)
        XCTAssertEqual(settings(.pcmAIFF, kAudioFormatFLAC, flags: 4).bitsPerSample, 32)
        XCTAssertEqual(settings(.pcmWAV, kAudioFormatAppleLossless, flags: 2).bitsPerSample, 24)
        XCTAssertEqual(settings(.pcmWAV, kAudioFormatMPEG4AAC, flags: 0).bitsPerSample, 16, "lossy audio is 16-bit")
    }

    /// A book of 24-bit Apple Lossless, made as the import makes one, is saved
    /// as 24-bit Apple Lossless and exported to WAVE at 24 bits, not 16, and
    /// what it saves is the book's tone.
    func testA24BitAppleLosslessBookKeepsItsDepth() async throws {
        let folder = try makeFolder()
        let book = folder.appendingPathComponent("Canal Survey.m4a")
        try AudioTestFixtures.writeToneAppleLossless24(to: book, frames: 24_000, sampleRate: Self.rate)
        let base = try await AudioEditBase.load(book, name: "Canal Survey.m4a")
        XCTAssertEqual(AudioRenderSettings.storedIntegerDepth(of: base.format), 24, "the fixture is 24-bit Apple Lossless")
        var timeline = base.timeline
        try timeline.applyRearranging(.cut(AudioTimeRange(start: 1, end: 2)))
        let sources = AudioEditComposition.Sources(base: base, package: folder, scratch: folder)

        for (format, name) in [(AudioRenderFormat.alacM4A, "saved.m4a"), (.pcmWAV, "exported.wav")] {
            let output = folder.appendingPathComponent(name)
            _ = try await AudioEditRenderer.render(
                timeline, sources: sources, to: output, format: format,
                metadata: AudioRenderMetadata(title: "Canal Survey", author: nil)
            )
            let written = try await AudioEditBase.load(output, name: name)
            XCTAssertEqual(AudioRenderSettings.storedIntegerDepth(of: written.format), 24, "\(format) is written at its source's depth")
            XCTAssertEqual(written.frames, 16_000, "\(format)")
            XCTAssertGreaterThan(AudioTestFixtures.rms(try AudioTestFixtures.floatSamples(of: output)), 0.1, "\(format) is silent")
        }
    }

    // MARK: - Helpers

    /// The edits each decoded render is checked on, rendered from `book`,
    /// and what is wrong with each: empty when every render is right.
    private func decodedRenderProblems(of book: WideBook) async throws -> [String] {
        let (base, folder) = try await makeWideBase(book)
        // The book as it decodes on its own: the tone, exactly, the depth the
        // file stores aside.
        let tone = AudioTestFixtures.tone(frames: Int(Self.wideSeconds * Self.rate), sampleRate: Self.rate)
        try AudioTestFixtures.writeIdentityRamp(
            to: folder.appendingPathComponent("audioEdits/takes/take.caf"),
            frames: 8_000,
            sampleRate: Self.rate,
            source: .take
        )
        let sources = AudioEditComposition.Sources(base: base, package: folder, scratch: folder)
        var problems: [String] = []

        /// Renders `timeline` to `settings` and returns its samples, or notes why not.
        func render(_ label: String, _ timeline: AudioEditTimeline, settings: AudioRenderSettings? = nil) async throws -> [Float]? {
            let output = folder.appendingPathComponent("\(label).caf")
            do {
                _ = try await AudioEditRenderer.render(
                    timeline, sources: sources, to: output, format: .pcmCAF, settings: settings,
                    metadata: AudioRenderMetadata(title: "Canal Survey", author: nil)
                )
            } catch {
                if book.decodes { problems.append("\(label): \(error)") }
                return nil
            }
            // A book AVFoundation can't decode is asked only not to end the app.
            guard book.decodes else { return nil }
            return try AudioTestFixtures.floatSamples(of: output)
        }
        /// Notes where `samples` isn't `expected` within `accuracy`, from `offset` on.
        func check(_ label: String, _ samples: [Float], against expected: ArraySlice<Float>, from offset: Int, accuracy: Float = 1e-4) {
            guard samples.count >= offset + expected.count else { return }
            let wrong = zip(samples[offset...], expected).enumerated().filter { abs($0.element.0 - $0.element.1) > accuracy }
            if let first = wrong.first {
                problems.append("\(label): \(wrong.count) samples differ, the first at frame \(offset + first.offset)")
            }
        }

        // A punch-in: the second second is the take's ramp.
        var punched = base.timeline
        try punched.applyRearranging(.replace(
            AudioTimeRange(start: 1, end: 2),
            with: AudioEditTake(file: "audioEdits/takes/take.caf", range: AudioTimeRange(start: 0, end: 1))
        ))
        if let samples = try await render("punch-in", punched) {
            if samples.count != 24_000 { problems.append("punch-in lasts \(samples.count) frames, not 24,000") }
            check("punch-in before", samples, against: tone[..<8_000], from: 0)
            check("punch-in after", samples, against: tone[16_000...], from: 16_000)
            // The take's ramp is negative, one step more each frame, so the
            // stretch holds the take, with no silence and none of the book.
            if samples.count >= 16_000, samples[8_000..<16_000].contains(where: { $0 >= 0 }) {
                problems.append("punch-in: the take's stretch holds silence or the book")
            }
        }

        // Inserted silence: half a second of it a second in.
        var silenced = base.timeline
        try silenced.applyRearranging(.insertSilence(at: 1, duration: 0.5))
        if let samples = try await render("silence", silenced) {
            problems += silenceProblems(in: samples, expectedFrames: 28_000).map { "silence: \($0)" }
            check("silence before", samples, against: tone[..<8_000], from: 0)
            check("silence after", samples, against: tone[8_000...], from: 12_000)
        }

        // A filter: -6 dB on the second second, through TextMouth's own engine.
        var filtered = base.timeline
        do {
            try await filtered.apply(
                .gain(decibels: -6, range: AudioTimeRange(start: 1, end: 2)),
                processor: AudioFilterProcessor(sources: sources, engine: .builtIn)
            )
        } catch {
            if book.decodes { problems.append("filter: \(error)") }
        }
        if let samples = try await render("filter", filtered) {
            if samples.count != 24_000 { problems.append("filter lasts \(samples.count) frames, not 24,000") }
            check("filter before", samples, against: tone[..<8_000], from: 0)
            let quieter = tone[8_000..<16_000].map { $0 * 0.501_187 }
            check("filter during", samples, against: quieter[...], from: 8_000, accuracy: 1e-3)
        }

        // A render at another rate, as a resampled export is: twice the
        // frames of a cut second.
        var cut = base.timeline
        try cut.applyRearranging(.cut(AudioTimeRange(start: 1, end: 2)))
        let resampled = AudioRenderSettings(format: .pcmCAF, sampleRate: 16_000, channels: 1, bitRate: nil, bitsPerSample: 32, isFloat: true)
        if let samples = try await render("resampled", cut, settings: resampled) {
            if abs(samples.count - 32_000) > 64 { problems.append("the resampled render lasts \(samples.count) frames, not 32,000") }
            if AudioTestFixtures.rms(samples) < 0.1 { problems.append("the resampled render is silent") }
        }
        return problems
    }

    /// What is wrong with `samples`, a render of a wide book with a half
    /// second of silence inserted a second in: its length, the silence
    /// where it belongs, and sound in the stretches either side.
    private func silenceProblems(in samples: [Float], expectedFrames: Int) -> [String] {
        var problems: [String] = []
        if samples.count != expectedFrames { problems.append("lasts \(samples.count) frames, not \(expectedFrames)") }
        guard samples.count >= expectedFrames else { return problems }
        if AudioTestFixtures.peak(samples[8_000..<12_000]) > 0 { problems.append("no silence where it was inserted") }
        if AudioTestFixtures.rms(samples[..<8_000]) < 0.1 { problems.append("the sound before it is silent") }
        if AudioTestFixtures.rms(samples[12_000...]) < 0.1 { problems.append("the sound after it is silent") }
        return problems
    }

    /// The book `book` stands for, written in a folder of this test's own and
    /// loaded as the editor loads it, with a sanity check that AVFoundation
    /// reports the depth the fixture was written in.
    private func makeWideBase(_ book: WideBook) async throws -> (AudioEditBase, URL) {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(book.fileName)
        try book.write(url, Int(Self.wideSeconds * Self.rate), Self.rate)
        let base = try await AudioEditBase.load(url, name: book.fileName)
        XCTAssertEqual(base.frames, Int64(Self.wideSeconds * Self.rate), "\(book)")
        XCTAssertEqual(Int(base.format.mBitsPerChannel), book.bits, "\(book): the fixture isn't stored as it should be")
        return (base, folder)
    }
}
