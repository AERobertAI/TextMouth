import SwiftUI

// MARK: - The Languages to Choose From

/// One language of the Transcription group's pop-up (FR05): its locale
/// identifier, and its name with its model's status, as shown and spoken.
struct TranscriptionLanguageChoice: Identifiable, Equatable {
    /// The language as the setting keeps it, a BCP 47 identifier.
    let identifier: String
    /// The pop-up's words: "English (United States), installed".
    let label: String

    var id: String { identifier }
}

/// The languages the Transcription group offers (FR05): every language the
/// recognizer supports, by name, each marked installed or needing a
/// download, found off the main thread. Nothing here downloads a model or
/// reserves a language; the Transcribe Audio sheet downloads one only when
/// asked.
@MainActor
final class TranscriptionLanguageChoices: ObservableObject {
    /// The languages the recognizer supports.
    @Published private(set) var supported: [Locale] = []
    /// The languages whose models are on this Mac.
    @Published private(set) var installed: [Locale] = []
    /// Why this Mac cannot transcribe, when it cannot.
    @Published private(set) var unavailableReason: String?

    /// Whether this Mac's system can transcribe.
    private let systemSupport: @MainActor () -> TranscriptionAvailability.SystemSupport
    /// The languages the recognizer supports.
    private let supportedLocales: @Sendable () async -> [Locale]
    /// The languages whose models are on this Mac.
    private let installedLocales: @Sendable () async -> [Locale]

    /// Languages as this Mac's system reports them, unless a test passes
    /// its own.
    init(
        systemSupport: @escaping @MainActor () -> TranscriptionAvailability.SystemSupport = {
            TranscriptionAvailability.systemSupport
        },
        supportedLocales: @escaping @Sendable () async -> [Locale] = { await TranscriptionAvailability.supportedLocales() },
        installedLocales: @escaping @Sendable () async -> [Locale] = { await TranscriptionAvailability.installedLocales() }
    ) {
        self.systemSupport = systemSupport
        self.supportedLocales = supportedLocales
        self.installedLocales = installedLocales
    }

    /// Finds the languages, or why this Mac cannot transcribe.
    func load() async {
        switch systemSupport() {
        case .needsNewerSystem:
            unavailableReason = TranscriptionWording.failed(TranscriptionError.needsNewerSystem)
            return
        case .unavailableOnThisMac:
            unavailableReason = TranscriptionWording.failed(TranscriptionError.unavailableOnThisMac)
            return
        case .available:
            break
        }
        supported = await supportedLocales()
        installed = await installedLocales()
    }

    /// The pop-up's choices: each supported language by name, in the order
    /// of their names, marked installed or needing a download; and
    /// `current`, the language the setting holds, when the list lacks it,
    /// marked not supported once the list is known, so the pop-up always
    /// shows the setting in force.
    func choices(including current: String) -> [TranscriptionLanguageChoice] {
        let listed: [TranscriptionLanguageChoice] = supported.map { locale in
            let identifier = locale.identifier(.bcp47)
            let isInstalled = installed.contains { TranscriptionAvailability.isSameLocale($0, locale) }
            return TranscriptionLanguageChoice(
                identifier: identifier,
                label: TranscriptionWording.languageChoice(
                    name: TranscriptionLanguage.name(of: identifier),
                    status: isInstalled ? TranscriptionWording.modelInstalled : TranscriptionWording.modelNeedsDownload
                )
            )
        }
        var choices = listed.sortedStably { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let currentLocale = Locale(identifier: current)
        if !supported.contains(where: { TranscriptionAvailability.isSameLocale($0, currentLocale) }) {
            choices.insert(TranscriptionLanguageChoice(
                identifier: current,
                label: TranscriptionWording.languageChoice(
                    name: TranscriptionLanguage.name(of: current),
                    status: supported.isEmpty ? nil : TranscriptionWording.modelUnsupported
                )
            ), at: 0)
        }
        return choices
    }
}

// MARK: - The Group

/// Playback settings' Transcription group (FR05): the language audiobooks
/// are transcribed in, each language marked installed or needing a
/// download, and whether TextMouth offers to transcribe each audiobook just
/// imported. Both are mirrored in config.json (`transcriptionLocale`,
/// `offerTranscriptionAfterImport`). On a Mac that cannot transcribe, the
/// group says why below the pop-up.
struct TranscriptionSettingsSection: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// The languages the pop-up offers.
    @StateObject private var languages: TranscriptionLanguageChoices

    /// The group, offering the languages this Mac's system reports, or
    /// `languages` (a test's own, which asks no recognizer). Made once, for
    /// the view's lifetime, as any state object is.
    init(languages: @autoclosure @escaping () -> TranscriptionLanguageChoices = TranscriptionLanguageChoices()) {
        _languages = StateObject(wrappedValue: languages())
    }

    var body: some View {
        Section {
            Picker(TranscriptionWording.languageLabel, selection: Binding(
                get: { settingsViewModel.transcriptionLanguage },
                set: { settingsViewModel.transcriptionLanguage = $0 }
            )) {
                ForEach(languages.choices(including: settingsViewModel.transcriptionLanguage)) { choice in
                    Text(choice.label).tag(choice.identifier)
                }
            }
            .accessibilityLabel(TranscriptionWording.languageLabel)
            .accessibilityHint(TranscriptionWording.languagePickerHint)

            if let reason = languages.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // An explicit binding, so the settings model announces the
            // change and config.json follows it.
            Toggle(TranscriptionWording.offerTitle, isOn: Binding(
                get: { settingsViewModel.offerTranscriptionAfterImport },
                set: { settingsViewModel.offerTranscriptionAfterImport = $0 }
            ))
            .accessibilityLabel(TranscriptionWording.offerTitle)
            .accessibilityHint(TranscriptionWording.offerHint)
        } header: {
            Text(TranscriptionWording.settingsSection)
        }
        .task {
            await languages.load()
        }
    }
}
