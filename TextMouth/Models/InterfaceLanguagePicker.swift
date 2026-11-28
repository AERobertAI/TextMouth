import Foundation

/// What the Interface Language picker shows and says, on the Mac (the top of the Miscellaneous tab) and on the iPhone (its
/// Language section), in one place so the words on screen, VoiceOver, and braille agree and tests can pin them (FR39).
enum InterfaceLanguagePickerWording {
    /// The group's title, and the picker's label.
    static var title: String {
        // Translators: Title of the group in Settings where the person picks the language of TextMouth's own words (menus, windows, messages), and the label of its pop-up. Appears on the Mac in the Miscellaneous tab and on the iPhone in its own section.
        InterfaceText.line("interfaceLanguage.title", "Interface Language")
    }

    /// The picker's hint: what choosing does.
    static var hint: String {
        // Translators: VoiceOver hint of the interface language picker. It says that the choice applies at once.
        InterfaceText.line("interfaceLanguage.hint", "Chooses the language of TextMouth's menus, windows, and messages. The change applies at once.")
    }

    /// The short line under the picker: what changes only at the next launch, said in the system's own name for itself.
    static var launchNote: String {
        #if os(macOS)
        // Translators: A short note under the interface language picker on the Mac: some of the words macOS itself supplies (the standard menu items, the open and save panels) change only the next time TextMouth opens.
        return InterfaceText.line("interfaceLanguage.launchNote.mac", "Some of macOS's own words change the next time TextMouth opens.")
        #else
        // Translators: A short note under the interface language picker on the iPhone: some of the words iOS itself supplies (system panels and alerts) change only the next time TextMouth opens.
        return InterfaceText.line("interfaceLanguage.launchNote.phone", "Some of iOS's own words change the next time TextMouth opens.")
        #endif
    }

    /// The first choice: follow the system, named with the language that gives.
    static func systemChoice(language: String) -> String {
        // Translators: The first choice of the interface language picker, which follows the system's language. %@ is the name of the language the system gives, such as English, written in its own language.
        withoutIsolates(InterfaceText.line("interfaceLanguage.systemChoice", "System (\(language))"))
    }

    /// One language's choice: its own name first, then its name in the interface language, so that someone who switched
    /// to a language they cannot read still finds their own.
    static func languageChoice(ownName: String, interfaceName: String) -> String {
        // Translators: One choice of the interface language picker. The first %@ is the language's name in that language (Español); the second is its name in the language the interface now speaks (Spanish). Keep the own name first.
        withoutIsolates(InterfaceText.line("interfaceLanguage.languageChoice", "\(ownName), \(interfaceName)"))
    }

    /// What VoiceOver announces after a switch, in the language switched to.
    static func announcement(language: String) -> String {
        // Translators: VoiceOver announcement after the person switches the interface language, spoken in the new language. %@ is the new language's name in its own language.
        withoutIsolates(InterfaceText.line("interfaceLanguage.announcement", "Interface language: \(language)"))
    }

    /// `text` without the invisible isolates (U+2066 to U+2069: the left-to-right, right-to-left, and first-strong isolates and their end) that Foundation wraps around an argument holding
    /// right-to-left text. The picker's labels are names alone, which show in the right order in both directions without
    /// them, and a label that began with an invisible mark would defeat a pop-up's type-select (how someone who switched
    /// to a language they cannot read finds their own by its first letter) and could show as a mark on a braille display.
    /// Every other interface text keeps Foundation's isolates, as before: this is the one place the picker removes them.
    static func withoutIsolates(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }))
    }
}

/// One choice of the picker.
struct InterfaceLanguageOption: Equatable, Identifiable {
    /// What choosing it stores.
    let choice: InterfaceLanguageChoice
    /// The words shown and spoken: "System (English)", or "Español, Spanish".
    let label: String

    var id: InterfaceLanguageChoice { choice }
}

/// The picker's choices and what a change does (FR39). The Mac's group and the iPhone's section both read these, so the
/// two apps list and word the choices the same way.
enum InterfaceLanguagePicker {
    /// The choices, in the order the picker lists them: System first, then the 25 languages sorted by their own names.
    ///
    /// - Parameters:
    ///   - interfaceLanguage: The language the interface speaks now, whose names the second half of each label uses.
    ///   - systemLanguage: The language System gives, named in System's own label.
    static func options(
        interfaceLanguage: String = InterfaceLanguage.current.language,
        systemLanguage: String = systemLanguageNow()
    ) -> [InterfaceLanguageOption] {
        let system = InterfaceLanguageOption(
            choice: .system,
            label: InterfaceLanguagePickerWording.systemChoice(language: ownName(of: systemLanguage))
        )
        let languages = PluralRules.categories.keys
            .map { (code: $0, own: ownName(of: $0)) }
            .sorted(by: isOrderedBefore)
            .map { language in
                InterfaceLanguageOption(choice: .language(language.code), label: label(for: language.code, ownName: language.own, interfaceLanguage: interfaceLanguage))
            }
        return [system] + languages
    }

    /// The language System gives now: English under hosted tests, as everywhere else System is there.
    static func systemLanguageNow(preferredLanguages: [String] = InterfaceLanguage.globalLanguages()) -> String {
        InterfaceLanguage.liveState(for: .system, preferredLanguages: preferredLanguages).language
    }

    /// The picker's choice for what is stored now, with the label that choice shows.
    static func option(for choice: InterfaceLanguageChoice, in options: [InterfaceLanguageOption]) -> InterfaceLanguageOption? {
        options.first { $0.choice == choice }
    }

    /// A language's label: its own name, then its name in the interface language, the own name alone when the two are
    /// the same ("English" in an English interface).
    private static func label(for code: String, ownName: String, interfaceLanguage: String) -> String {
        let inInterface = name(of: code, in: interfaceLanguage)
        guard inInterface.caseInsensitiveCompare(ownName) != .orderedSame else { return ownName }
        return InterfaceLanguagePickerWording.languageChoice(ownName: ownName, interfaceName: inInterface)
    }

    /// The language's name in its own language (`Español`), Foundation's own: Apple's names stay Apple's.
    static func ownName(of code: String) -> String {
        name(of: code, in: code)
    }

    /// The language `code`'s name in the language `language`, with its first letter capital (Foundation answers `español`
    /// in Spanish, for a name in running text; the picker lists names).
    static func name(of code: String, in language: String) -> String {
        let locale = Locale(identifier: language)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Whether `first` sorts before `second` by own name, ignoring case and accents, with the code to break a tie so the
    /// order never varies. Compared in English's order, so the list is the same whatever the interface language is.
    private static func isOrderedBefore(_ first: (code: String, own: String), _ second: (code: String, own: String)) -> Bool {
        let order = first.own.compare(second.own, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: Locale(identifier: "en"))
        return order == .orderedSame ? first.code < second.code : order == .orderedAscending
    }

    /// The name an announcement gives a choice: a language's own name, or System's label.
    private static func announcedName(of choice: InterfaceLanguageChoice, options: [InterfaceLanguageOption]) -> String {
        switch choice {
        case .language(let code): return ownName(of: code)
        case .system: return option(for: .system, in: options)?.label ?? ""
        }
    }

    /// Makes `choice` the person's and switches the interface to it at once, then announces the new language through
    /// VoiceOver in that language.
    ///
    /// - Parameters:
    ///   - choice: System, or a language the app carries.
    ///   - store: Where the choice is kept: the app's own domain, or the sandbox under hosted tests.
    ///   - region: The region to format in; the system's when nil.
    ///   - preferredLanguages: The system's languages after the choice is saved; the system's own when nil.
    @MainActor
    @discardableResult
    static func apply(
        _ choice: InterfaceLanguageChoice,
        store: InterfaceLanguageStore = InterfaceLanguageStore(),
        region: String? = nil,
        preferredLanguages: [String]? = nil
    ) -> InterfaceLanguage.State {
        let state = InterfaceLanguage.choose(choice, store: store, region: region, preferredLanguages: preferredLanguages)
        let name = announcedName(of: choice, options: options(interfaceLanguage: state.language, systemLanguage: systemLanguageNow(preferredLanguages: preferredLanguages ?? InterfaceLanguage.globalLanguages())))
        // Read in the language now in use, which is the new one: the lookup follows the state just swapped.
        VoiceOverAnnouncer.announce(InterfaceLanguagePickerWording.announcement(language: name))
        return state
    }
}
