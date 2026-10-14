import AVFoundation
import Darwin

/// Converts Ogg audio (Vorbis or Opus, in .ogg, .oga, or .opus files) to
/// AAC-LC in an .m4a file beside it (B06), so TextMouth never hands Ogg to
/// a player.
///
/// On October 14, 2026 Apple's Vorbis decoder, playing an Ogg track through
/// AVPlayer at 1.5x, locked up inside AudioToolbox and grew TextMouth to
/// 34 GB until the Mac ran out of memory. Decoding the same files offline
/// had worked, so every import converts its Ogg audio, and a launch pass
/// converts the books already in the library, decoding through
/// AVAssetReader and never through a player.
///
/// A file is written by the audio editor's own AAC writer
/// (`AudioEditRenderer`, with `AudioRenderSettings`), at the source's own
/// average bit rate rounded up to the next standard AAC rate, so a track
/// stays about the same size and sounds no worse
/// (`bitRate(averaging:channels:accepted:)`). It is written under a hidden
/// temporary name, checked by `AudioMediaProbe` (it plays, and lasts as long
/// as its source to within `lengthTolerance`), and only then given its
/// final name: the source's stem with .m4a, made unique when taken.
enum OggAudioConverter {
    /// The extensions of Ogg audio, in lowercase: Vorbis's, the Ogg audio
    /// container's, and Opus's.
    static let fileExtensions: Set<String> = ["ogg", "oga", "opus"]

    /// How many files convert at once. Each conversion decodes and encodes
    /// one buffer at a time, so its memory stays small whatever the file's
    /// length. Measured on October 14, 2026 on the user's Mac (four
    /// performance cores, 8 GB) with 20-minute stereo Vorbis tracks: one at
    /// a time ran at 306 times real time with a peak footprint of 16 MB,
    /// four at once at 586 times real time with a peak of 39 MB, so a
    /// 176-track book of about 117 hours converts in about 12 minutes.
    static let maximumConcurrentConversions = 4

    /// How far a converted file's length may differ from its source's and
    /// still be taken: a second, as the task asks. AAC's priming and
    /// padding come to a few dozen milliseconds at most.
    static let lengthTolerance: TimeInterval = 1

    /// What ends the hidden name a file has while it is written and
    /// checked: the reader never lists a hidden file
    /// (`AudioBookParser.audioFiles(in:)` skips them), and a file left
    /// behind by an interrupted conversion is found by it and removed
    /// (`removeLeftovers(in:)`).
    static let temporarySuffix = ".ogg-conversion.m4a"

    /// The standard AAC bit rates of stereo audio, in bits a second; mono's
    /// are half of each (`standardBitRates(channels:)`).
    static let stereoBitRates = [64_000, 80_000, 96_000, 112_000, 128_000, 160_000, 192_000]

    /// One file converted: where it came from and went, and what that took.
    struct Conversion: Equatable, Sendable {
        /// The Ogg file, which a conversion never changes or removes.
        let source: URL
        /// The .m4a file: under its hidden temporary name until it is
        /// given its final one (`givingFinalName(_:)`).
        var converted: URL
        /// How long the source lasts, in seconds.
        let duration: TimeInterval
        /// How long the conversion took, in seconds.
        let secondsTaken: TimeInterval
        /// The source's size in bytes.
        let bytesBefore: Int64
        /// The converted file's size in bytes.
        let bytesAfter: Int64
        /// The AAC bit rate written, in bits a second, or nil when the
        /// encoder chose its own.
        let bitRate: Int?
    }

    /// Why a file could not be converted, in words a listener can be told.
    enum Failure: LocalizedError, Equatable {
        /// The Ogg file could not be read as audio, or is only in the cloud.
        case unreadable(fileName: String)
        /// The converted file failed its check: it would not play, or its
        /// length was not its source's.
        case checkFailed(fileName: String, reason: String)
        /// The converted file could not be given its final name.
        case cannotName(fileName: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(fileName):
                return "The Ogg audio file \(fileName) could not be read for converting to AAC."
            case let .checkFailed(fileName, reason):
                return "The AAC audio converted from \(fileName) failed its check: \(reason)."
            case let .cannotName(fileName):
                return "The AAC audio converted from \(fileName) could not be given its name."
            }
        }
    }

    // MARK: - Which Files

    /// Whether the file at `url` is Ogg audio, by its extension in any case.
    static func isOgg(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// The Ogg files among the tracks of the folder `folder`, found by the
    /// reader's own rules (`AudioBookParser.audioFiles(in:)`: wrapper
    /// folders count; hidden files, AppleDouble sidecars, and symbolic links
    /// do not), in Finder's order; none when the folder can't be read.
    static func oggFiles(in folder: URL) -> [URL] {
        ((try? AudioBookParser.audioFiles(in: folder)) ?? []).filter(isOgg)
    }

    // MARK: - The Settings

    /// The standard AAC bit rates for `channels` channels, in bits a
    /// second: stereo's for two or more, half of each for mono.
    static func standardBitRates(channels: Int) -> [Int] {
        channels >= 2 ? stereoBitRates : stereoBitRates.map { $0 / 2 }
    }

    /// The bit rate a source of `average` bits a second in `channels`
    /// channels is encoded at: the next standard AAC rate at or above its
    /// average (the highest standard rate for anything above it), so a
    /// track stays about the same size and is no worse. Where the encoder
    /// doesn't take that rate at the sample rate written, `accepted` (the
    /// rates it does take) gives the nearest one above, or its highest;
    /// nil when it names none, so the encoder chooses.
    static func bitRate(averaging average: Double, channels: Int, accepted: [Int]) -> Int? {
        let standard = standardBitRates(channels: channels)
        let chosen = standard.first { Double($0) >= average } ?? standard.last ?? 64_000
        guard !accepted.isEmpty else { return nil }
        if accepted.contains(chosen) { return chosen }
        return accepted.filter { $0 >= chosen }.min() ?? accepted.max()
    }

    /// The sample rate a source at `rate` is encoded at: its own when the
    /// AAC encoder takes it (`RecordingEncoder.aacSampleRates`), otherwise
    /// 44.1 kHz for a rate of that family (a multiple of 11,025 Hz) and
    /// 48 kHz for any other.
    static func sampleRate(for rate: Double) -> Double {
        if RecordingEncoder.aacSampleRates.contains(rate) { return rate }
        let isOfCDFamily = rate > 0 && rate.truncatingRemainder(dividingBy: 11_025) == 0
        return isOfCDFamily ? 44_100 : 48_000
    }

    /// The settings `base`, an Ogg file of `bytes` bytes, is written in:
    /// AAC-LC in an .m4a file, at its own channels (two at most: more are
    /// mixed down to stereo, whose bit rates the task gives), its own sample
    /// rate where AAC takes it, and its average bit rate, bytes × 8 ÷
    /// duration, rounded up to the next standard rate.
    static func settings(for base: AudioEditBase, bytes: Int64) -> AudioRenderSettings {
        let channels = min(max(base.channelCount, 1), 2)
        let rate = sampleRate(for: base.sampleRate)
        let seconds = Double(base.frames) / base.sampleRate
        let average = seconds > 0 ? Double(bytes) * 8 / seconds : 0
        return AudioRenderSettings(
            format: .aacM4A,
            sampleRate: rate,
            channels: channels,
            bitRate: bitRate(
                averaging: average,
                channels: channels,
                accepted: AudioRenderSettings.acceptedAACBitRates(sampleRate: rate, channels: channels)
            ),
            bitsPerSample: 16,
            isFloat: false
        )
    }

    // MARK: - Converting

    /// Converts the Ogg file `source` to AAC in an .m4a file beside it,
    /// under a hidden temporary name, and checks the result: it must play,
    /// and last as long as the source to within `lengthTolerance`. With
    /// `naming`, it then gets its final name (`givingFinalName(_:)`);
    /// without, it keeps the temporary one, for a caller that names a whole
    /// book's files in one step. The source is never changed, and nothing
    /// is left behind by a failure. Nothing is downloaded: a file only in
    /// the cloud is refused.
    /// - Throws: `Failure`, or `CancellationError` when the task is
    ///   cancelled.
    static func convert(_ source: URL, naming: Bool = true) async throws -> Conversion {
        let started = Date()
        let name = source.lastPathComponent
        let base: AudioEditBase
        do {
            base = try await AudioEditBase.load(source, name: name)
        } catch {
            throw Failure.unreadable(fileName: name)
        }
        let bytesBefore = fileSize(of: source)
        let settings = settings(for: base, bytes: bytesBefore)
        let stem = source.deletingPathExtension().lastPathComponent
        let staged = source.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).\(UUID().uuidString)\(temporarySuffix)")
        // The file keeps its own tags: the renderer copies its common
        // metadata and writes the title it is given, so it is given the
        // file's own title, or its name without one.
        let title = await AudioPlaybackService.extractFullMetadata(from: source).title
        let sources = AudioEditComposition.Sources(
            base: base,
            package: source.deletingLastPathComponent(),
            // Only silence and MP3 use a scratch folder, and a whole file
            // converted to AAC uses neither.
            scratch: FileManager.default.temporaryDirectory
        )
        do {
            _ = try await AudioEditRenderer.render(
                base.timeline,
                sources: sources,
                to: staged,
                format: .aacM4A,
                settings: settings,
                metadata: AudioRenderMetadata(title: title.isEmpty ? stem : title, author: nil)
            )
            try await check(staged, against: Double(base.frames) / base.sampleRate, from: name)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        var conversion = Conversion(
            source: source,
            converted: staged,
            duration: Double(base.frames) / base.sampleRate,
            secondsTaken: Date().timeIntervalSince(started),
            bytesBefore: bytesBefore,
            bytesAfter: fileSize(of: staged),
            bitRate: settings.bitRate
        )
        if naming {
            do {
                conversion = try givingFinalName(conversion)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
        }
        return conversion
    }

    /// Checks the converted file at `url`, made from the file named
    /// `sourceName` lasting `duration` seconds: it must open and decode as
    /// audio (`AudioMediaProbe`), and last as long to within
    /// `lengthTolerance`.
    /// - Throws: `Failure.checkFailed`.
    private static func check(_ url: URL, against duration: TimeInterval, from sourceName: String) async throws {
        switch await AudioMediaProbe.duration(of: url) {
        case let .failure(problem):
            throw Failure.checkFailed(fileName: sourceName, reason: problem.reason)
        case let .success(seconds):
            guard abs(seconds - duration) <= lengthTolerance else {
                throw Failure.checkFailed(
                    fileName: sourceName,
                    reason: String(format: "it lasts %.1f seconds, not %.1f", seconds, duration)
                )
            }
        }
    }

    /// `conversion` with its file given its final name: its source's stem
    /// with .m4a, or, when a file has that name already, the first of
    /// "<stem> 2.m4a", "<stem> 3.m4a", … that is free. Each name is taken
    /// with one rename that refuses an existing file (`RENAME_EXCL`), so two
    /// conversions finishing at once never take the same name, and no file
    /// is ever replaced.
    /// - Throws: `Failure.cannotName` when the rename fails otherwise.
    static func givingFinalName(_ conversion: Conversion) throws -> Conversion {
        let folder = conversion.source.deletingLastPathComponent()
        let stem = conversion.source.deletingPathExtension().lastPathComponent
        var number = 1
        while true {
            let name = number == 1 ? "\(stem).m4a" : "\(stem) \(number).m4a"
            let target = folder.appendingPathComponent(name)
            if renamex_np(conversion.converted.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                var named = conversion
                named.converted = target
                return named
            }
            guard errno == EEXIST else {
                throw Failure.cannotName(fileName: conversion.source.lastPathComponent)
            }
            number += 1
        }
    }

    /// Converts each of `sources` as `convert(_:naming:)` does, at most
    /// `maximumConcurrentConversions` at once, telling `progress` how many
    /// are done as each ends. The conversions are returned in the order of
    /// `sources`. Should one fail, the others are stopped, every file
    /// already converted is removed, and its error is thrown.
    static func convertEach(
        _ sources: [URL],
        naming: Bool = true,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Conversion] {
        var results = [Conversion?](repeating: nil, count: sources.count)
        do {
            try await withThrowingTaskGroup(of: (Int, Conversion).self) { group in
                var next = 0
                // The first few start at once; each one that ends starts
                // the next, so at most the maximum run together.
                while next < min(maximumConcurrentConversions, sources.count) {
                    let index = next
                    group.addTask { (index, try await convert(sources[index], naming: naming)) }
                    next += 1
                }
                var done = 0
                do {
                    while let (index, conversion) = try await group.next() {
                        if results.indices.contains(index) { results[index] = conversion }
                        done += 1
                        progress?(done)
                        if next < sources.count {
                            let index = next
                            group.addTask { (index, try await convert(sources[index], naming: naming)) }
                            next += 1
                        }
                    }
                } catch {
                    // The conversions still running stop; any that finished
                    // meanwhile are kept to be removed below.
                    group.cancelAll()
                    while !group.isEmpty {
                        if let (index, conversion) = try? await group.next(), results.indices.contains(index) {
                            results[index] = conversion
                        }
                    }
                    throw error
                }
            }
        } catch {
            discard(results.compactMap { $0 })
            throw error
        }
        return results.compactMap { $0 }
    }

    /// Removes the converted files of `conversions`, leaving their sources.
    static func discard(_ conversions: [Conversion]) {
        for conversion in conversions {
            try? FileManager.default.removeItem(at: conversion.converted)
        }
    }

    /// Removes the files an interrupted conversion left under their hidden
    /// temporary names anywhere in `folder`, so a book converted again
    /// starts clean.
    static func removeLeftovers(in folder: URL) {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix(".")
            && file.lastPathComponent.hasSuffix(temporarySuffix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - A Book's Tracks

    /// Renames each converted track of the book whose folder of tracks is
    /// `folder` in the folder's manifest, wherever the reader finds it,
    /// inside the folder's one folder too (`AudioManifestLocation`), each
    /// spelled as the manifest spells it: its tracks, order, chapter titles,
    /// and sections' clips (`BookManifestFile.renameTrack`). All of them
    /// are renamed in one write, through the one write of a manifest
    /// (`BookManifestFile.change`), which tells an Edit Manifest session of
    /// the book `bookID`, as the audio editor renames a track it renders to
    /// .m4a. A folder without a manifest is left as it is.
    static func renameTracks(of conversions: [Conversion], inManifestOf folder: URL, bookID: UUID?) throws {
        guard !conversions.isEmpty, let location = AudioManifestLocation.find(in: folder) else { return }
        try BookManifestFile.change(manifestAt: location, of: bookID) { object in
            for conversion in conversions {
                BookManifestFile.renameTrack(
                    location.name(ofTrackAt: AudioBookParser.relativeName(of: conversion.source, in: folder)),
                    to: location.name(ofTrackAt: AudioBookParser.relativeName(of: conversion.converted, in: folder)),
                    in: &object
                )
            }
        }
    }

    /// Removes the Ogg files `conversions` were made from, once their
    /// converted files have taken their places.
    static func removeSources(of conversions: [Conversion]) throws {
        for conversion in conversions {
            try FileManager.default.removeItem(at: conversion.source)
        }
    }

    /// The size of the file at `url` in bytes, or 0 when it can't be read.
    static func fileSize(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
