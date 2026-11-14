import AVFoundation
import Foundation

// MARK: - The Mac's words

/// The words of the Mac's book voice sheet that sit inline in its view,
/// `BookVoicePickerView` in `ReaderView.swift`, held here for the phone's
/// Voice & Speed sheet, which is rebuilt for the phone, since a `Picker` in
/// a Mac sheet is a menu on the phone (the iPhone interface spec, "The Voice
/// & Speed sheet"). The words the Mac keeps in `BookSettingsWording` are
/// called there. `PhoneVoiceVocabularyTests` reads the Mac's source and
/// requires each word to be there as it is.
enum PhoneVoiceVocabulary {
    /// The Language row's label.
    static let languageFilterLabel = "Voice language filter"
    /// The language choice that lists every voice.
    static let allLanguages = "All"
    /// The Voice row's label.
    static let voiceLabel = "Select voice for this book"
    /// Preview Voice's visible word.
    static let previewTitle = "Preview Voice"
    /// What VoiceOver calls Preview Voice.
    static let previewLabel = "Preview selected voice"
    /// What Preview Voice says, in the voice, speed, and pitch chosen.
    static let previewSentence = "Hello! This is how I'll read for you."
    /// The speed slider's label.
    static let speedLabel = "Speed"
    /// The pitch slider's label.
    static let pitchLabel = "Pitch"
    /// The When this book ends row's visible words.
    static let endOfBookTitle = "When this book ends"
    /// What VoiceOver calls the When this book ends row.
    static let endOfBookLabel = "End of book behavior for this book"
    /// The end-of-book choice that follows the global setting.
    static let useGlobalDefault = "Use Global Default"

    /// A voice's choice as VoiceOver reads it, as in "Samantha, Enhanced
    /// quality".
    static func voiceChoice(name: String, quality: String) -> String {
        "\(name), \(quality) quality"
    }

    /// The speed slider's value, as in "200 words per minute".
    static func speedValue(wordsPerMinute: Double) -> String {
        "\(Int(wordsPerMinute)) words per minute"
    }
}

// MARK: - The phone's own words

/// The Voice & Speed sheet's words the Mac doesn't have, from the spec.
enum PhoneVoiceWording {
    /// What the voice list says once the voices have loaded and none is
    /// installed. **Unverified:** the path's wording on an iPhone.
    static let noVoices = "No voices are installed. Add voices in Settings, Accessibility, Read & Speak."
}

// MARK: - A voice

/// One installed voice as the sheet offers it: a plain value, so the choice
/// list can be tested without the voices a machine happens to have.
struct PhoneVoiceOption: Hashable, Sendable {
    /// The voice's identifier, which sets it.
    let identifier: String
    /// The voice's name, as "Samantha".
    let name: String
    /// The Mac's word for its quality: "Standard", "Enhanced", or "Premium".
    let qualityLabel: String
    /// Its language, as "en-US".
    let language: String
    /// Whether it's a Personal Voice, which the phone doesn't list, since
    /// the app can't render one.
    let isPersonalVoice: Bool

    /// The voice as its choice and the Voice row say it: "Samantha, Enhanced
    /// quality".
    var choiceLabel: String {
        PhoneVoiceVocabulary.voiceChoice(name: name, quality: qualityLabel)
    }

    /// The two-letter code the language filter goes by, as "en".
    var languageCode: String {
        String(language.prefix(2))
    }
}

extension PhoneVoiceOption {
    /// The option for an installed `voice`.
    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(
            identifier: voice.identifier,
            name: voice.name,
            qualityLabel: voice.qualityLabel,
            language: voice.language,
            isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice)
        )
    }
}

// MARK: - The sheet

/// What the phone's Voice & Speed sheet, or an audiobook's Audio Settings,
/// offers and decides (the iPhone interface spec, "The Voice & Speed
/// sheet"): the language and voice choices, the sliders' limits and values,
/// and the end-of-book choices, in the Mac's words. The settings themselves
/// are the reader's, set through its own functions, as the Mac's sheet does.
///
/// Main-actor isolated because the reader's speed step it uses is.
@MainActor
struct PhoneVoiceModel {
    /// The voices offered, Personal Voices left out, in the catalog's order.
    let voices: [PhoneVoiceOption]
    /// The language the voice list is filtered by: a two-letter code, or ""
    /// for every language.
    var selectedLanguage: String

    /// A model offering `installed` voices, Personal Voices left out, with
    /// the list filtered by `selectedLanguage`.
    init(installed: [PhoneVoiceOption], selectedLanguage: String) {
        voices = installed.filter { !$0.isPersonalVoice }
        self.selectedLanguage = selectedLanguage
    }

    /// The language the sheet opens filtered by: the current voice's, as on
    /// the Mac, or every language when the book has no voice yet.
    static func openingLanguage(currentVoiceLanguage: String?) -> String {
        currentVoiceLanguage.map { String($0.prefix(2)) } ?? ""
    }

    /// The languages of the voices offered, as two-letter codes, sorted.
    var languageCodes: [String] {
        Set(voices.map(\.languageCode)).sortedStably()
    }

    /// The Language choices: "All", then each language by the name
    /// `name(code)` gives it, as the Mac names them from the locale.
    func languageChoices(naming name: (String) -> String = PhoneVoiceModel.languageName) -> [PhoneChoice<String>] {
        [PhoneChoice(id: "", label: PhoneVoiceVocabulary.allLanguages)]
            + languageCodes.map { PhoneChoice(id: $0, label: name($0)) }
    }

    /// The Language row's value: the language chosen, by name, or "All".
    func languageValue(naming name: (String) -> String = PhoneVoiceModel.languageName) -> String {
        selectedLanguage.isEmpty ? PhoneVoiceVocabulary.allLanguages : name(selectedLanguage)
    }

    /// The Mac's name for the language `code`: the current locale's, else
    /// the code itself.
    nonisolated static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// The voices of the language chosen, every voice when it's "All".
    var filteredVoices: [PhoneVoiceOption] {
        selectedLanguage.isEmpty ? voices : voices.filter { $0.language.hasPrefix(selectedLanguage) }
    }

    /// The Voice choices, each read as "Samantha, Enhanced quality".
    var voiceChoices: [PhoneChoice<String>] {
        filteredVoices.map { voice in
            PhoneChoice(
                id: voice.identifier,
                label: PhoneVoiceVocabulary.voiceChoice(name: voice.name, quality: voice.qualityLabel)
            )
        }
    }

    /// The Voice row's value: the voice with `identifier`, as its choice is
    /// read; nil for a voice not offered.
    func voiceValue(identifier: String?) -> String? {
        guard let identifier, let voice = voices.first(where: { $0.identifier == identifier }) else { return nil }
        return PhoneVoiceVocabulary.voiceChoice(name: voice.name, quality: voice.qualityLabel)
    }

    /// Whether the voice list says that no voice is installed: only once the
    /// voices have loaded, so a list still filling says nothing yet.
    func saysNoVoices(isLoaded: Bool) -> Bool {
        isLoaded && voices.isEmpty
    }

    // MARK: The sliders

    /// A text book's speed slider's limits and step, the Mac's.
    static let speedRange: ClosedRange<Double> = 50...650
    /// The step a text book's speed slider moves by, the reader's own.
    static let speedStep = ReaderViewModel.speechSpeedStep
    /// The pitch slider's limits and step, the Mac's.
    static let pitchRange: ClosedRange<Double> = 0.5...2.0
    /// The step the pitch slider moves by.
    static let pitchStep = 0.1

    /// `wordsPerMinute` on the slider's steps, within its limits, as the
    /// slider sets it.
    static func steppedSpeed(_ wordsPerMinute: Double) -> Double {
        let stepped = (wordsPerMinute / speedStep).rounded() * speedStep
        return min(max(stepped, speedRange.lowerBound), speedRange.upperBound)
    }

    /// `pitch` on the slider's steps, within its limits.
    static func steppedPitch(_ pitch: Double) -> Double {
        SpeechService.clampedPitch((pitch / pitchStep).rounded() * pitchStep)
    }

    // MARK: When this book ends

    /// The When this book ends choices: the Mac's behaviors, in its order,
    /// then "Use Global Default", which the Mac offers as a button of its
    /// own, as a choice here (the spec). Nil stands for the global default.
    static let endOfBookChoices: [PhoneChoice<EndOfBookBehavior?>] =
        EndOfBookBehavior.allCases.map { PhoneChoice<EndOfBookBehavior?>(id: $0, label: $0.rawValue) }
            + [PhoneChoice<EndOfBookBehavior?>(id: nil, label: PhoneVoiceVocabulary.useGlobalDefault)]

    /// The When this book ends row's value: the behavior in force, as the
    /// Mac's picker shows it.
    static func endOfBookValue(effective: EndOfBookBehavior) -> String {
        effective.rawValue
    }
}

// MARK: - From a reader

extension PhoneVoiceModel {
    /// The model for `reader`'s sheet, offering the catalog's voices,
    /// filtered by the current voice's language.
    init(reader: ReaderViewModel, catalog: VoiceCatalog = .shared) {
        self.init(
            installed: catalog.voices.map(PhoneVoiceOption.init),
            selectedLanguage: Self.openingLanguage(currentVoiceLanguage: reader.speechService.currentVoice?.language)
        )
    }
}
