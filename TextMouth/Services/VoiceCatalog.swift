import AVFoundation
import Combine
import Foundation

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
    /// The listing under way, if any.
    private var listing: Task<Void, Never>?
    /// Lists the voices again when the installed voices change.
    private var changeSubscription: AnyCancellable?

    /// A catalog that lists voices with `listVoices`.
    /// - Parameters:
    ///   - notificationCenter: Where the system announces that the installed
    ///     voices changed: the app's center, unless a test passes its own.
    ///   - listVoices: Lists the voices offered; the installed ones, unless a
    ///     test passes its own.
    init(
        notificationCenter: NotificationCenter = .default,
        listVoices: @escaping @Sendable () -> [AVSpeechSynthesisVoice] = { VoiceCatalog.installedVoices() }
    ) {
        self.listVoices = listVoices
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
    /// list once it is ready. A listing under way is abandoned for this one.
    func reload() {
        listing?.cancel()
        let listVoices = listVoices
        listing = Task { [weak self] in
            let listed = await Task.detached(priority: .utility) { listVoices() }.value
            guard !Task.isCancelled else { return }
            self?.publish(listed)
        }
    }

    /// Waits until the listing under way, if any, has been published,
    /// following a newer listing that replaced it meanwhile.
    func waitUntilListed() async {
        while let current = listing {
            await current.value
            // A finished listing clears itself, and an abandoned one has a
            // successor; should neither hold, stop rather than spin.
            guard listing != current else { return }
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
        languages = Set(listed.map { String($0.language.prefix(2)) }).sorted()
        isLoaded = true
        didList.send()
    }

    /// Every installed voice the app offers: novelty voices left out, sorted
    /// by name. Lists them afresh, which takes tens of milliseconds, so the
    /// catalog calls it off the main thread.
    nonisolated static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { $0.name < $1.name }
    }
}
