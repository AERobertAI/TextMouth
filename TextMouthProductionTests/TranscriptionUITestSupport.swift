import AppKit
import os
import XCTest
@testable import TextMouth

// MARK: - What the System Reports, Scripted

/// The speech models a test's Mac has, by language: each language's
/// status, which a scripted download changes to installed. Languages not
/// listed are unsupported, as the recognizer would have it.
final class ScriptedModelStatuses: Sendable {
    /// Each language's status, by BCP 47 identifier, guarded by its lock.
    private let statuses: OSAllocatedUnfairLock<[String: TranscriptionAvailability.ModelStatus]>
    /// Every language whose status was asked for, in order.
    private let asked = OSAllocatedUnfairLock(initialState: [String]())

    init(_ statuses: [String: TranscriptionAvailability.ModelStatus]) {
        self.statuses = OSAllocatedUnfairLock(initialState: statuses)
    }

    /// Where the model of `locale` stands, as the system would say.
    @Sendable func status(for locale: Locale) -> TranscriptionAvailability.ModelStatus {
        let identifier = locale.identifier(.bcp47)
        asked.withLock { $0.append(identifier) }
        return statuses.withLock { $0[identifier] ?? .unsupported }
    }

    /// Marks the model of `identifier` installed, as a finished download does.
    func install(_ identifier: String) {
        statuses.withLock { $0[identifier] = .installed(Locale(identifier: identifier)) }
    }

    /// The languages asked about so far, in order.
    var askedLanguages: [String] {
        asked.withLock { $0 }
    }
}

/// A model download that never reaches the network: it reports `steps` of
/// progress, then installs the model in `statuses`, or, when it
/// `waitsForCancel`, waits until its task is cancelled, or fails with
/// `failure`. It records each language it was asked to download.
final class ScriptedModelInstaller: TranscriptionModelInstalling {
    /// The share done it reports, in order, before it finishes.
    let steps: [Double]
    /// Whether it waits for a cancel instead of finishing.
    let waitsForCancel: Bool
    /// What it fails with instead of finishing, if anything.
    let failure: (any Error & Sendable)?
    /// The statuses a finished download installs into.
    let statuses: ScriptedModelStatuses
    /// The languages asked for, in order.
    private let requested = OSAllocatedUnfairLock(initialState: [String]())

    init(
        steps: [Double] = [0.25, 0.75],
        waitsForCancel: Bool = false,
        failure: (any Error & Sendable)? = nil,
        statuses: ScriptedModelStatuses
    ) {
        self.steps = steps
        self.waitsForCancel = waitsForCancel
        self.failure = failure
        self.statuses = statuses
    }

    func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let identifier = locale.identifier(.bcp47)
        requested.withLock { $0.append(identifier) }
        for step in steps {
            progress(step)
            try await Task.sleep(for: .milliseconds(10))
        }
        if waitsForCancel {
            // Sleeps until cancelled: the sleep throws CancellationError.
            while true {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        if let failure { throw failure }
        statuses.install(identifier)
        progress(1)
    }

    /// The languages the download was asked for.
    var requestedLanguages: [String] {
        requested.withLock { $0 }
    }
}

/// What a Transcribe Audio sheet announced through its services, oldest
/// first.
@MainActor
final class SheetAnnouncements {
    /// The words announced.
    private(set) var messages: [String] = []

    /// Records one announcement; pass it as the services' `announce`.
    func record(_ message: String, _ window: NSWindow?) {
        messages.append(message)
    }
}

// MARK: - A Sheet of the Test's Own

extension XCTestCase {
    /// Services for a Transcribe Audio sheet that reach nothing of this Mac:
    /// a system that can transcribe unless `support` says otherwise, US
    /// English to try, the models `statuses` gives, a download that never
    /// leaves the test, the transcript `transcript` gives for every book
    /// (none unless given), the transcriptions of `center` (a center whose
    /// engine hears nothing unless given), and announcements kept in
    /// `announcements`.
    @MainActor
    func makeSheetServices(
        support: TranscriptionAvailability.SystemSupport = .available,
        languages: [String] = ["en-US"],
        statuses: ScriptedModelStatuses = ScriptedModelStatuses(["en-US": .installed(Locale(identifier: "en-US"))]),
        installer: (any TranscriptionModelInstalling)? = nil,
        transcript: TranscriptStore.Lookup = .missing,
        center: TranscriptionJobCenter? = nil,
        announcements: SheetAnnouncements = SheetAnnouncements()
    ) -> TranscriptionSheetServices {
        TranscriptionSheetServices(
            systemSupport: { support },
            languagesToTry: { languages },
            modelStatus: { statuses.status(for: $0) },
            installer: installer ?? ScriptedModelInstaller(statuses: statuses),
            readTranscript: { _ in transcript },
            center: center ?? makeScriptedCenter(script: [:]),
            announce: { message, window in announcements.record(message, window) }
        )
    }

    /// A transcription center whose engine follows `script`, each file's
    /// sentences by the file's name, saying each after `pause`, or refusing
    /// with `refusal`: it never reaches the system's recognizer. It records
    /// transcribed books in `transcribedBooks`, a store of the test's own
    /// unless given, never the app's.
    @MainActor
    func makeScriptedCenter(
        script: [String: [TranscriptSentence]],
        pause: Duration = .zero,
        refusal: TranscriptionError? = nil,
        transcribedBooks: TranscribedBooks = TranscribedBooks()
    ) -> TranscriptionJobCenter {
        TranscriptionJobCenter(
            service: TranscriptionService(
                engine: ScriptedTranscriptionEngine(sentences: script, pause: pause, refusal: refusal),
                languagesToTry: { ["en-US"] }
            ),
            transcribedBooks: transcribedBooks
        )
    }

    /// Waits, yielding the main actor, until `condition` holds or `timeout`
    /// seconds pass, and says whether it held.
    @MainActor
    func eventuallyHolds(timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

// MARK: - Scripted Narration

/// What the scripted engine hears in the two silent tracks of the
/// transcription UI tests' audiobooks: invented sentences, timed within each
/// track, so a line of the debug log that quoted them would stand out.
enum TranscriptionUIScripts {
    /// Two sentences in a 3-second track and one in a 2-second track.
    static let twoTracks: [String: [TranscriptSentence]] = [
        "01.wav": [
            TranscriptFixtures.sentence("Gannet wings fold over the breakwater.", from: 0, to: 1_500),
            TranscriptFixtures.sentence("Rope coils dry on the pier.", from: 1_500, to: 2_940),
        ],
        "02.wav": [
            TranscriptFixtures.sentence("The ferry bell rings twice.", from: 0, to: 1_920),
        ],
    ]

    /// Many short sentences in one 20-second track, for a transcription
    /// slow enough to cancel.
    static var longTrack: [String: [TranscriptSentence]] {
        ["01.wav": (0..<40).map { number in
            TranscriptFixtures.sentence("Buoy number \(number) tilts.", from: number * 480, to: number * 480 + 480)
        }]
    }
}
