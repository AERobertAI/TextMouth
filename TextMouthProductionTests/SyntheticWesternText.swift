import Foundation

// MARK: - Synthetic Western Text

/// English prose built to look odd to an encoding guesser, though every
/// character of it is ordinary Windows-1252 (FMT16): curly quotation marks,
/// dashes, bullets, and symbols; loanwords from seven languages; and the
/// Windows-1252 characters a plausibility check once took for signs of a
/// wrong reading ("¦", "¬", "¤", accents that stand alone, "ƒ", "µ", a lone
/// "Ñ", "Ô", or "Ç", Irish capitals after a prefix, "þ", "ð", "ÿ", "Š", "œ").
/// Each text mixes one to two of those with up to three kinds of punctuation
/// and one language of loanwords, so that a text that Windows-1252 reads
/// correctly, as every one of these does, can be tried against the guesser
/// by the thousand. The same seed always gives the same text
/// (`SeededGenerator` is the test target's SplitMix64).
enum SyntheticWesternText {

    /// Makes a piece of text from the random numbers it is given.
    private typealias Maker = @Sendable (inout SeededGenerator) -> String

    /// The words the prose is made of: the commonest English words.
    private static let words: [String] = """
        the of and to in is was for on that with as by at from his her they this have are not but had which one all were when \
        we there can an your more so if out about who get would up what make their time no just him know take people into year \
        good some could them see other than then now look only come its over think also back after use two how our work first \
        well way even new want because any these give day most us
        """.split(separator: " ").map(String.init)

    /// A word chosen at random.
    private static func word(_ rng: inout SeededGenerator) -> String {
        choice(of: words, using: &rng)
    }

    /// An element of `items` chosen at random (`items` must not be empty).
    private static func choice<Element>(of items: [Element], using rng: inout SeededGenerator) -> Element {
        items[Int.random(in: 0..<items.count, using: &rng)]
    }

    /// `count` different elements of `items`, chosen at random.
    private static func sample<Element>(of items: [Element], count: Int, using rng: inout SeededGenerator) -> [Element] {
        Array(items.shuffled(using: &rng).prefix(count))
    }

    // MARK: Pieces

    /// Pieces that Windows-1252 reads with nothing odd in them: curly
    /// punctuation, dashes, bullets, and the usual symbols.
    private static let punctuationPieces: [Maker] = [
        { rng in choice(of: ["it’s", "don’t", "isn’t", "we’re", "they’ll", "Tom’s", "can’t"], using: &rng) },
        { rng in "“" + word(&rng) + "”" },
        { rng in "“" + word(&rng).capitalized + ",” he said" },
        { rng in word(&rng) + "—" + word(&rng) },
        { _ in "1990–1995" },
        { _ in "–" },
        { rng in word(&rng) + "…" },
        { rng in "‘" + word(&rng) + "’" },
        { rng in "\n• " + word(&rng) },
        { rng in "€\(Int.random(in: 1...99, using: &rng))" },
        { rng in "£\(Int.random(in: 1...99, using: &rng))" },
        { rng in "\(Int.random(in: 1...99, using: &rng))°" },
        { _ in "©" },
        { _ in "1½" },
        { _ in "m²" },
        { _ in "\u{00A0}" },
        { rng in word(&rng) + "†" },
        { rng in "§ \(Int.random(in: 1...30, using: &rng))" },
        { _ in "3 × 4" },
    ]

    /// Loanwords by language: one language's words are mixed into a text.
    private static let loanwords: [[String]] = [
        ["café", "crème", "brûlée", "naïve", "façade", "déjà", "à", "élan", "rôle", "fiancée", "œuvre"],
        ["Zürich", "über", "Köln", "Straße", "Mädchen", "schön"],
        ["señor", "año", "Málaga", "jalapeño", "niño", "¿qué?", "¡olé!"],
        ["São", "coração", "não", "Brasília"],
        ["smörgåsbord", "Øresund", "Bjørn", "Ålesund", "fjörd", "Þór"],
        ["één", "België", "café", "ideeën"],
        ["città", "perché", "così", "più", "è"],
    ]

    /// Pieces holding a Windows-1252 character that the plausibility check
    /// once counted as a surprise, in the places such characters stand.
    private static let oddPieces: [Maker] = [
        { _ in "¦" },
        { _ in "¬" },
        { _ in "¤" },
        { _ in "¨" },
        { _ in "¯" },
        { _ in "¸" },
        { _ in "˜" },
        { rng in "ƒ \(Int.random(in: 1...99, using: &rng))" },
        { _ in "ƒ/2.8" },
        { rng in "\(Int.random(in: 1...9, using: &rng))º" },
        { rng in "\(Int.random(in: 1...9, using: &rng))ª" },
        { rng in "\(Int.random(in: 1...99, using: &rng)) µg" },
        { _ in "Ô" },
        { _ in "Ç" },
        { _ in "Ñ" },
        { _ in "Ñ. García" },
        { _ in "an˜o" },
        { _ in "cafe´" },
        { _ in "fac¸ade" },
        { rng in choice(of: ["na hÉireann", "i nÉirinn", "an tÉireannach", "na hÁrainn"], using: &rng) },
        { rng in choice(of: ["ÉTÉ", "CAFÉ", "DÉJÀ", "ÇA", "CRÈME", "ÉCOLE"], using: &rng) },
        { _ in "þ" },
        { _ in "ð" },
        { _ in "ÿ" },
        { rng in choice(of: ["Škoda", "šnaps", "Žižek"], using: &rng) },
        { rng in choice(of: ["œuvre", "cœur", "Œdipus"], using: &rng) },
        { rng in "‚" + word(&rng) + "‘" },
        { _ in "ˆ" },
        { rng in word(&rng) + "¹" },
        { _ in "¼" },
        { _ in "¿" },
        { _ in "¶" },
    ]

    // MARK: Making a Text

    /// The text for `seed`: 20 to 400 pieces, each a word or one of the kinds
    /// of piece above, with sentence ends and line breaks here and there.
    static func text(seed: UInt64) -> String {
        var rng = SeededGenerator(state: seed)
        // Up to three kinds of punctuation, one or two odd characters, and
        // (in five texts of seven) one language of loanwords.
        let punctuationCount = Int.random(in: 0...3, using: &rng)
        let punctuation = sample(of: punctuationPieces, count: punctuationCount, using: &rng)
        let oddCount = Int.random(in: 1...2, using: &rng)
        let odd = sample(of: oddPieces, count: oddCount, using: &rng)
        let languageIndex = Int.random(in: 0..<(loanwords.count + 2), using: &rng)
        let language = languageIndex < loanwords.count ? loanwords[languageIndex] : nil

        let oddShare = 0.03 * Double(odd.count)
        var pieces: [String] = []
        for _ in 0..<Int.random(in: 20...400, using: &rng) {
            let roll = Double.random(in: 0..<1, using: &rng)
            if !punctuation.isEmpty, roll < 0.08 {
                pieces.append(choice(of: punctuation, using: &rng)(&rng))
            } else if roll < 0.08 + oddShare {
                pieces.append(choice(of: odd, using: &rng)(&rng))
            } else if let language, roll < 0.2 {
                pieces.append(choice(of: language, using: &rng))
            } else {
                let next = word(&rng)
                pieces.append(Double.random(in: 0..<1, using: &rng) < 0.08 ? next.capitalized : next)
            }
            if Double.random(in: 0..<1, using: &rng) < 0.07 {
                pieces.append(Bool.random(using: &rng) ? ".\n" : ".")
            }
        }
        return pieces.joined(separator: " ") + "\n"
    }
}
