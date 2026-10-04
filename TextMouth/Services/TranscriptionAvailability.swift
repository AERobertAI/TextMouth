import Foundation
import Speech

/// What this Mac offers for transcription (FR05): whether its system can
/// transcribe at all, which languages the recognizer supports, and which of
/// their models are installed, downloading, or would need a download.
///
/// Transcription uses SpeechAnalyzer's SpeechTranscriber, which macOS 26
/// introduced; TextMouth still runs on macOS 14 and 15, where it reports
/// that transcription needs macOS 26. Each language's model is a system
/// asset that macOS downloads, updates, and shares between apps. Everything
/// here only asks: nothing downloads a model or reserves a language, which
/// waits for the user's consent (the transcription settings ask for it).
///
/// Whether a model is installed is decided by the recognizer's list of
/// installed languages, never by the asset inventory's status alone, which
/// can report an installed model as merely "supported" while an update to
/// it waits (TRANSCRIPTION-RESEARCH-2026-10-03.md).
enum TranscriptionAvailability {
    /// Whether this Mac's system can transcribe.
    enum SystemSupport: Equatable, Sendable {
        /// It can, given an installed model for the language.
        case available
        /// The system is older than macOS 26, which transcription needs.
        case needsNewerSystem
        /// The system is new enough, but this Mac cannot run the
        /// recognizer's model.
        case unavailableOnThisMac
    }

    /// Where one language's model stands on this Mac.
    enum ModelStatus: Equatable, Sendable {
        /// The recognizer cannot transcribe the language, or this Mac
        /// cannot transcribe at all.
        case unsupported
        /// The recognizer supports the language, as the locale given, whose
        /// model must be downloaded before it can be used.
        case needsDownload(Locale)
        /// The language's model, for the locale given, is downloading.
        case downloading(Locale)
        /// The language's model is on this Mac: transcription can use it
        /// now, as the locale given, the one the model serves.
        case installed(Locale)
    }

    /// Whether this Mac's system can transcribe.
    static var systemSupport: SystemSupport {
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable ? .available : .unavailableOnThisMac
        }
        return .needsNewerSystem
    }

    /// The languages the recognizer can transcribe, each as the locale its
    /// model serves; none where the system cannot transcribe.
    static func supportedLocales() async -> [Locale] {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales
    }

    /// The languages whose models are on this Mac; none where the system
    /// cannot transcribe.
    static func installedLocales() async -> [Locale] {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.installedLocales
    }

    /// Where the model for `locale` stands: unsupported, needing a
    /// download, downloading, or installed, with the locale the model
    /// serves (the recognizer's equivalent of `locale`, such as "en-GB" for
    /// "en_GB").
    static func modelStatus(for locale: Locale) async -> ModelStatus {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return .unsupported }
        return await SpeechTranscriberCatalog.modelStatus(for: locale)
    }

    /// Whether `locale` and `other` name the same language and region, as
    /// BCP 47 spells them, so "en_US" and "en-US" are the same.
    static func isSameLocale(_ locale: Locale, _ other: Locale) -> Bool {
        locale.identifier(.bcp47) == other.identifier(.bcp47)
    }
}

/// The recognizer's lists of languages, on systems that have it.
@available(macOS 26.0, *)
enum SpeechTranscriberCatalog {
    /// Where the model for `locale` stands, as
    /// `TranscriptionAvailability.modelStatus(for:)` describes.
    static func modelStatus(for locale: Locale) async -> TranscriptionAvailability.ModelStatus {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupported
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { TranscriptionAvailability.isSameLocale($0, supported) }) {
            return .installed(supported)
        }
        switch await assetStatus(for: supported) {
        case .installed:
            return .installed(supported)
        case .downloading:
            return .downloading(supported)
        case .unsupported:
            return .unsupported
        default:
            return .needsDownload(supported)
        }
    }

    /// What the asset inventory reports for the model of `locale`, asked
    /// with a transcriber made for it: asking reserves and downloads nothing.
    static func assetStatus(for locale: Locale) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [makeTranscriber(for: locale)])
    }

    /// The asset inventory's status as transcript.json records it
    /// (`TranscriptSpeechModel.assetStatus`).
    static func describe(_ status: AssetInventory.Status) -> String {
        switch status {
        case .unsupported: return "unsupported"
        case .supported: return "supported"
        case .downloading: return "downloading"
        case .installed: return "installed"
        @unknown default: return "unknown"
        }
    }

    /// A transcriber for `locale` as TextMouth transcribes with it: final
    /// results only, each run of their text carrying its stretch of the
    /// audio and the recognizer's confidence.
    static func makeTranscriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }
}
