import AVFoundation
import Combine
import Foundation
import os

/// The voices installed on this Mac, listed once and shared (TODO PERF07).
///
/// Listing the voices (`AVSpeechSynthesisVoice.speechVoices()`) enumerates
/// every installed voice afresh on each call, 65 to 114 ms, since the system
/// keeps no list. Settings listed them on the main thread at launch, before
/// the first window, and again at every change of the voice language; the
/// reader's voice sheet listed them twice each time its body ran, which
/// during playback is eight times a second. The catalog lists them once,
/// off the main thread, after the first Library window shows
/// (`loadIfNeeded()`), and again only when the system says the installed
/// voices changed (`AVSpeechSynthesizer.availableVoicesDidChangeNotification`),
/// as when a voice finishes downloading. Only the first launch, which must
/// choose a default voice before anything else runs, lists them at once
/// (`listNow()`). Everything that offers voices reads `voices` and observes
/// the catalog, so it shows the list when it arrives and whenever it
/// changes.
@MainActor
final class VoiceCatalog: ObservableObject {
    /// The app's catalog.
    static let shared = VoiceCatalog()

    /// The voices offered: every installed voice except novelty voices,
    /// sorted by name. Empty until the voices are first listed.
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    /// The two-letter language codes of `voices`, sorted: the languages the
    /// voice pickers filter by.
    @Published private(set) var languages: [String] = []
    /// Whether the voices have been listed at least once.
    @Published private(set) var isLoaded = false
    /// Sent after each new list is published, once `voices` and
    /// `languages` both hold it, for models that keep a list of their own.
    let didList = PassthroughSubject<Void, Never>()
    /// How many lists have been published: tests and benchmarks count it.
    private(set) var listingCount = 0

    /// Lists the installed voices, off the main thread.
    private let listVoices: @Sendable () -> [AVSpeechSynthesisVoice]
    /// The queue this catalog's listings run on, one at a time. Each catalog has its own, so a listing that never
    /// returns stops no other catalog (a test's, or the app's) and the queue gives up on it after `listingDeadline`.
    private nonisolated let listingQueue = DispatchQueue(label: "com.textmouth.VoiceCatalog.listing", qos: .utility)
    /// How long the queue waits for one listing before it goes on to the next, in seconds. Listing takes tens of
    /// milliseconds on a Mac; a machine without the speech service (a GitHub runner) never gets an answer.
    private let listingDeadline: TimeInterval
    /// The listing under way, if any.
    private var listing: Task<Void, Never>?
    /// Counts the listings started, so that a listing which gave up clears `listing` only if it is still the newest.
    private var listingGeneration = 0
    /// Lists the voices again when the installed voices change.
    private var changeSubscription: AnyCancellable?

    /// A catalog that lists voices with `listVoices`.
    /// - Parameters:
    ///   - notificationCenter: Where the system announces that the installed
    ///     voices changed: the app's center, unless a test passes its own.
    ///   - listVoices: Lists the voices offered; the installed ones, unless a
    ///     test passes its own.
    ///   - listingDeadline: How long one listing may take before the catalog gives up on it and lists the next.
    init(
        notificationCenter: NotificationCenter = .default,
        listVoices: @escaping @Sendable () -> [AVSpeechSynthesisVoice] = { VoiceCatalog.installedVoices() },
        listingDeadline: TimeInterval = 10
    ) {
        self.listVoices = listVoices
        self.listingDeadline = listingDeadline
        changeSubscription = notificationCenter
            .publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
    }

    /// Lists the voices off the main thread, unless they have been listed or
    /// are being listed. The first Library window asks once it shows, and
    /// each view that offers voices asks as it appears, in case it comes
    /// first.
    func loadIfNeeded() {
        guard !isLoaded, listing == nil else { return }
        reload()
    }

    /// Lists the voices now, on the calling thread, and publishes them; a
    /// listing under way is abandoned. Only for the one launch that must
    /// choose a default voice before anything else runs: one where neither
    /// config.json nor the preferences name a voice, which is the first.
    /// Every other launch leaves the listing to `loadIfNeeded()`, off the
    /// main thread.
    func listNow() {
        listing?.cancel()
        publish(listVoices())
    }

    /// Lists the voices again off the main thread, and publishes the new
    /// list once it is ready. A listing under way is abandoned for this one:
    /// if it has not started yet, it is skipped on the queue.
    func reload() {
        listing?.cancel()
        listingGeneration += 1
        let generation = listingGeneration
        let (queue, deadline, listVoices) = (listingQueue, listingDeadline, listVoices)
        listing = Task { [weak self] in
            let listed = await Self.list(on: queue, deadline: deadline, with: listVoices)
            guard !Task.isCancelled, let self else { return }
            if let listed {
                publish(listed)
            } else if generation == listingGeneration {
                // The listing gave up (the speech service never answered): nothing is listed yet, and a later
                // `loadIfNeeded()` or `reload()` tries again on a queue that has moved on.
                listing = nil
            }
        }
    }

    /// Lists the voices with `listVoices` on `queue` and returns them, or nil when the listing was cancelled before
    /// it started or did not finish within `deadline` seconds.
    ///
    /// It never holds a thread of Swift's concurrency pool while it waits. The pool has one thread for each core and
    /// a task that blocks in it takes one for good: on a 3-core runner where the listing never came back, three
    /// listings blocked all three, and every other task in the process (a download's, a reader's, a test's) waited
    /// behind them for ever, as the spindumps of two tests that hung in the run of November 10, 2026 show. The
    /// listing runs on a thread of its own, so the queue can give up on one that never returns (the thread is left
    /// to end whenever it does) and go on to the next; a listing cancelled while it waited on the queue is skipped.
    private nonisolated static func list(
        on queue: DispatchQueue,
        deadline: TimeInterval,
        with listVoices: @escaping @Sendable () -> [AVSpeechSynthesisVoice]
    ) async -> [AVSpeechSynthesisVoice]? {
        let skipped = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !skipped.withLock({ $0 }) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let listed = OSAllocatedUnfairLock<[AVSpeechSynthesisVoice]?>(initialState: nil)
                    let finished = DispatchSemaphore(value: 0)
                    let thread = Thread {
                        let voices = listVoices()
                        listed.withLock { $0 = voices }
                        finished.signal()
                    }
                    thread.qualityOfService = .utility
                    thread.start()
                    let done = finished.wait(timeout: .now() + deadline) == .success
                    continuation.resume(returning: done ? listed.withLock { $0 } : nil)
                }
            }
        } onCancel: {
            skipped.withLock { $0 = true }
        }
    }

    /// Waits until the listing under way, if any, has been published,
    /// following a newer listing that replaced it meanwhile, but for no more
    /// than `limit` seconds. Returns whether it waited the listing out: false
    /// when the limit passed first, which a speech service that never answers
    /// makes happen; the caller then goes on with the voices it has (none) and
    /// `isLoaded` false, and the catalog lists again when it is next asked.
    @discardableResult
    func waitUntilListed(limit: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while let current = listing {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, await Self.finishes(current, within: remaining) else { return false }
            // A finished listing clears itself, and an abandoned one has a
            // successor; should neither hold, stop rather than spin.
            guard listing != current else { return true }
        }
        return true
    }

    /// Whether `task` ends within `seconds`. The task is awaited from a task of its own, which waits on for ever if
    /// the task never ends: only the answer is given up on.
    private nonisolated static func finishes(_ task: Task<Void, Never>, within seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Bool) -> Void = { value in
                let first = answered.withLock { already -> Bool in
                    defer { already = true }
                    return !already
                }
                if first { continuation.resume(returning: value) }
            }
            Task {
                await task.value
                answer(true)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { answer(false) }
        }
    }

    /// The voices offered for `language`, a two-letter code such as "en":
    /// every voice for nil or "".
    func voices(forLanguage language: String?) -> [AVSpeechSynthesisVoice] {
        guard let language, !language.isEmpty else { return voices }
        return voices.filter { $0.language.hasPrefix(language) }
    }

    /// Makes `listed` the catalog's list, and its languages.
    private func publish(_ listed: [AVSpeechSynthesisVoice]) {
        listing = nil
        listingCount += 1
        voices = listed
        languages = Set(listed.map { String($0.language.prefix(2)) }).sortedStably()
        isLoaded = true
        didList.send()
    }

    /// Every installed voice the app offers: novelty voices left out, sorted
    /// by name. Lists them afresh, which takes tens of milliseconds, so the
    /// catalog calls it off the main thread.
    nonisolated static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sortedStably { $0.name < $1.name }
    }
}
