import Darwin
import AVFoundation
import XCTest
@testable import TextMouth

/// Opt-in profiling against a copied cache from the user's production library.
/// Normal test runs skip this class unless TEXTMOUTH_PROFILE_LIBRARY_ROOT is set.
@MainActor
final class ProductionPlaybackProfilingTests: XCTestCase {
    func testCopiedProductionBookParseDerivationsRenderAndMutedPlayback() throws {
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle(for: Self.self)
        let bundledRoot = bundle.object(forInfoDictionaryKey: "TextMouthProfileLibraryRoot") as? String
        let rootPath = environment["TEXTMOUTH_PROFILE_LIBRARY_ROOT"]
            ?? bundledRoot.flatMap { value in
                value.isEmpty || value.contains("$(") ? nil : value
            }
        guard let rootPath, !rootPath.isEmpty else {
            throw XCTSkip("Set TEXTMOUTH_PROFILE_LIBRARY_ROOT to run production-library profiling")
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let library = try loadLibrary(at: root.appendingPathComponent("library.json"))
        let candidates = library.books.compactMap { book -> Candidate? in
            guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return nil }
            let cache = root
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent(book.folderPath, isDirectory: true)
                .appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
                .appendingPathComponent("content.md")
            guard let size = try? cache.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0 else { return nil }
            return Candidate(book: book, cacheURL: cache, cacheBytes: size)
        }.sorted { $0.cacheBytes < $1.cacheBytes }
        guard !candidates.isEmpty else {
            throw XCTSkip("No cached text books found under \(root.path)")
        }

        let selection = environment["TEXTMOUTH_PROFILE_SELECTION"]
            ?? bundle.object(forInfoDictionaryKey: "TextMouthProfileSelection") as? String
            ?? "random"
        let candidateIndex = selectedIndex(selection: selection, count: candidates.count)
        let candidate = candidates[candidateIndex]
        let profileBook = try copiedProfileBook(from: candidate)
        defer { try? FileManager.default.removeItem(at: profileBook.tmbDirectory) }

        var peakRSS = residentBytes()
        let baselineRSS = peakRSS
        let loadStart = ContinuousClock.now
        var coldContent: DocumentContent? = try MarkdownCacheService.loadFromCache(for: profileBook)
        let loadMilliseconds = milliseconds(since: loadStart)
        peakRSS = max(peakRSS, residentBytes())
        let rssAfterLoad = residentBytes()

        let generatedIndex = try XCTUnwrap(coldContent?.contentIndex)
        let indexEncoder = JSONEncoder()
        indexEncoder.dateEncodingStrategy = .iso8601
        let indexEncodeStart = ContinuousClock.now
        let encodedIndex = try indexEncoder.encode(generatedIndex)
        let indexEncodeMilliseconds = milliseconds(since: indexEncodeStart)
        let indexDecoder = JSONDecoder()
        indexDecoder.dateDecodingStrategy = .iso8601
        let indexDecodeStart = ContinuousClock.now
        let decodedIndex = try indexDecoder.decode(BookContentIndex.self, from: encodedIndex)
        let indexDecodeMilliseconds = milliseconds(since: indexDecodeStart)
        coldContent = nil
        let indexedLoadStart = ContinuousClock.now
        let content = try MarkdownCacheService.loadFromCache(
            for: profileBook,
            contentIndex: decodedIndex
        )
        let indexedLoadMilliseconds = milliseconds(since: indexedLoadStart)

        let repetitions = max(1, Int(environment["TEXTMOUTH_PROFILE_DERIVATION_REPETITIONS"] ?? "5") ?? 5)
        let derivationStart = ContinuousClock.now
        var derivationChecksum = 0
        for _ in 0..<repetitions {
            derivationChecksum &+= content.totalWordCount
            derivationChecksum &+= content.totalCharacterCount
            derivationChecksum &+= content.allHeadings.count
        }
        let derivationMilliseconds = milliseconds(since: derivationStart)
        peakRSS = max(peakRSS, residentBytes())
        let rssAfterDerivations = residentBytes()

        let preferredChapter = candidate.book.readingPosition?.chapterIndex ?? 0
        guard let chapterIndex = renderableChapterIndex(in: content, preferred: preferredChapter) else {
            throw XCTSkip("Selected cache has no non-empty chapter")
        }
        let chapter = content.chapters[chapterIndex]
        let configuredRenderCharacters = environment["TEXTMOUTH_PROFILE_RENDER_CHARACTERS"]
            ?? bundle.object(forInfoDictionaryKey: "TextMouthProfileRenderCharacters") as? String
            ?? "5000"
        let renderCharacterLimit = max(1, Int(configuredRenderCharacters) ?? 5_000)
        let renderEnd = chapter.text.index(
            atUTF16Offset: min(chapter.text.utf16Length, renderCharacterLimit)
        )
        let profileText = String(chapter.text[..<renderEnd])

        let engine = AudioEngineService()
        engine.setVolume(0)
        let rendered = expectation(description: "production TTS render completed")
        var renderSucceeded = false
        let renderStart = ContinuousClock.now
        let renderSampler = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            peakRSS = max(peakRSS, residentBytes())
        }
        engine.render(
            SpeechRenderRequest(text: profileText, voice: AVSpeechSynthesisVoice(language: "en-US"))
        ) { success in
            renderSucceeded = success
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: 125)
        renderSampler.invalidate()
        let renderMilliseconds = milliseconds(since: renderStart)
        peakRSS = max(peakRSS, residentBytes())
        let rssAfterRender = residentBytes()
        XCTAssertTrue(renderSucceeded, "System TTS failed to render the selected production chapter")

        let configuredPlaybackSeconds = environment["TEXTMOUTH_PROFILE_PLAY_SECONDS"]
            ?? bundle.object(forInfoDictionaryKey: "TextMouthProfilePlaySeconds") as? String
            ?? "15"
        let requestedPlaybackSeconds = max(
            0,
            Double(configuredPlaybackSeconds) ?? 15
        )
        let playbackStart = Date()
        var didSeek = false
        var rssAfterSeek: UInt64 = 0
        var scheduledAudioBytesAfterSeek = 0
        var charOffsetBeforeRewind = 0
        var rewindTargetCharOffset = 0
        engine.play()
        while Date().timeIntervalSince(playbackStart) < requestedPlaybackSeconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            peakRSS = max(peakRSS, residentBytes())
            if !didSeek,
               requestedPlaybackSeconds >= 2,
               Date().timeIntervalSince(playbackStart) >= requestedPlaybackSeconds / 3 {
                charOffsetBeforeRewind = engine.currentCharOffset()
                rewindTargetCharOffset = max(1, charOffsetBeforeRewind / 2)
                engine.seek(toCharOffset: rewindTargetCharOffset)
                didSeek = true
                peakRSS = max(peakRSS, residentBytes())
                rssAfterSeek = residentBytes()
                scheduledAudioBytesAfterSeek = engine.scheduledSegmentAudioByteCount
            }
        }
        engine.stop()

        let finalRSS = residentBytes()
        let report: [String: Any] = [
            "selection": selection,
            "candidateIndex": candidateIndex,
            "candidateCount": candidates.count,
            "cacheBytes": candidate.cacheBytes,
            "metadataCharacterCount": candidate.book.totalCharacterCount ?? 0,
            "parsedChapterCount": content.chapters.count,
            "parsedCharacterCount": content.totalCharacterCount,
            "profileChapterIndex": chapterIndex,
            "profileChapterCharacters": chapter.text.utf16Length,
            "productionChapterRenderEligible": chapter.text.utf16Length
                <= SpeechRenderCoordinator.maximumTextLength,
            "profileRenderedCharacters": profileText.utf16Length,
            "renderedAudioBytes": engine.renderedAudioByteCount,
            "scheduledAudioBytesAfterSeek": scheduledAudioBytesAfterSeek,
            "logicalRetainedPCMBytesAfterSeek": didSeek
                ? engine.renderedAudioByteCount + scheduledAudioBytesAfterSeek
                : engine.renderedAudioByteCount,
            "renderedAudioSeconds": engine.renderedDuration,
            "loadMilliseconds": loadMilliseconds,
            "indexedLoadMilliseconds": indexedLoadMilliseconds,
            "contentIndexBytes": encodedIndex.count,
            "contentIndexEncodeMilliseconds": indexEncodeMilliseconds,
            "contentIndexDecodeMilliseconds": indexDecodeMilliseconds,
            "derivationRepetitions": repetitions,
            "derivationMilliseconds": derivationMilliseconds,
            "derivationChecksum": derivationChecksum,
            "renderMilliseconds": renderMilliseconds,
            "playbackSeconds": requestedPlaybackSeconds,
            "seekDuringPlayback": didSeek,
            "charOffsetBeforeRewind": charOffsetBeforeRewind,
            "rewindTargetCharOffset": rewindTargetCharOffset,
            "baselineRSSBytes": baselineRSS,
            "rssAfterLoadBytes": rssAfterLoad,
            "rssAfterDerivationsBytes": rssAfterDerivations,
            "rssAfterRenderBytes": rssAfterRender,
            "rssAfterSeekBytes": rssAfterSeek,
            "peakRSSBytes": peakRSS,
            "finalRSSBytes": finalRSS,
            "peakRSSDeltaBytes": peakRSS >= baselineRSS ? peakRSS - baselineRSS : 0
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PERF_PROFILE \(String(decoding: data, as: UTF8.self))")
    }

    private struct Candidate {
        let book: Book
        let cacheURL: URL
        let cacheBytes: Int
    }

    private func loadLibrary(at url: URL) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: Data(contentsOf: url))
    }

    private func selectedIndex(selection: String, count: Int) -> Int {
        switch selection.lowercased() {
        case "smallest": return 0
        case "median": return count / 2
        case "p95": return min(count - 1, Int(Double(count - 1) * 0.95))
        case "largest": return count - 1
        default: return Int.random(in: 0..<count)
        }
    }

    private func copiedProfileBook(from candidate: Candidate) throws -> Book {
        let packageName = "PerformanceProfile-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: candidate.cacheURL,
            to: package.appendingPathComponent("content.md")
        )
        var book = candidate.book
        book.folderPath = ""
        book.tmbDirectoryName = packageName
        return book
    }

    private func renderableChapterIndex(in content: DocumentContent, preferred: Int) -> Int? {
        guard !content.chapters.isEmpty else { return nil }
        let start = min(max(preferred, 0), content.chapters.count - 1)
        let orderedIndices = Array(start..<content.chapters.count) + Array(0..<start)
        let renderable = orderedIndices.filter { content.chapters[$0].text.utf16Length > 0 }
        return renderable.first { content.chapters[$0].text.utf16Length >= 1_000 }
            ?? renderable.first
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
        infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                rebound,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
