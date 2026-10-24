import Foundation

// MARK: - Synthetic Accented Text

/// Code, notes, product lines, and headings in the languages of Western
/// Europe, built to be Windows-1252 text that looks like another encoding to
/// a guesser (FMT16 review): identifiers with an accented capital after a
/// lowercase word ("zeigeÜbersicht", "afficherÉtat", "hentØstfold"), which
/// read as case flips; product names ("iPhone", "McDonald’s"); headings in
/// capitals ("ÉCOLE NORMALE SUPÉRIEURE"); and short files of a line or two.
///
/// Each text draws on a few of its language's accented letters only, as a
/// short note or a list of identifiers does, and sometimes on a capital
/// without its small letter, because a reading in another encoding looks
/// cleanest when the text holds few kinds of accent. Every text is Windows-1252
/// and has at least one byte beyond ASCII, so every one reaches the guesser.
/// The same seed gives the same text (`SeededGenerator`).
///
/// A known limit: Windows-1252 text that holds nothing but a few capitals
/// whose Mac Roman images are plain punctuation or a fitting letter ("Õ" and
/// "Ñ" read as an apostrophe and a dash, "Œ" as "å") in identifiers is
/// guessed to be Mac Roman, as the capitals are what the text offers to tell
/// the two apart by. These capitals are left out of the lists below.
enum SyntheticAccentedText {

    /// One language's words and the pieces identifiers and headings are made of.
    private struct Language: Sendable {
        let words: [String]
        let prefixes: [String]
        let suffixes: [String]
        let headings: [String]
        let products: [String]
    }

    /// The words of `text`, separated by spaces.
    private static func split(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

    /// Prefixes that need no language: the verbs of code.
    private static let verbs = "get set is show update load render"

    private static let languages: [Language] = [
        Language(
            words: split("die der das und ist nicht ein eine für über prüft Größe Fenster öffnet schließt Änderungen Übersicht Datei Zähler Wörter müssen können wählen löschen Bücher Mädchen schön zurück früher später größer äußerst Öl Ärzte Überraschung fünf zwölf Straße Käse Brötchen Grüße Blätter Länder Märchen Förderung Süden Norden hören gehört wäre würde könnte Mäuse Füße Bäume Jahr Mann Frau Haus Zeit Welt Wasser Brot Stadt Buch Leben mit auf den dem von zu im bei nach auch noch wenn dann aber oder wir sie"),
            prefixes: split("zeige lade speichere hole setze prüfe öffne schließe lösche wähle " + verbs),
            suffixes: split("Übersicht Änderung Öffnen Ärger Überschrift Ölstand Äpfel Übung Ökonomie Ärztin Übersetzung Äußerung Öffentlich Überprüfung Ändern Übergabe"),
            headings: split("ÜBERSICHT ZUSAMMENFASSUNG ÄNDERUNGEN ÖFFNEN ÜBER GRÖSSE ÄRGER"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube LinkedIn WhatsApp BlackBerry München Zürich Köln Düsseldorf")
        ),
        Language(
            words: split("de het een en is niet voor één ideeën reële coördinatie café financiën Zoë geïnteresseerd vreemd hoeveel kunnen willen gaan huis water brood stad boek leven tijd jaar man vrouw kind school werk dag nacht met van op in te dat die zijn ook nog als maar wij zij"),
            prefixes: split("toon haal laad sla open zet " + verbs),
            suffixes: split("ÉénRegel ÉchtGeld Éducatie ÉénKeer ÉchteWaarde"),
            headings: split("INHOUDSOPGAVE ÉÉN ÉCHT"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube Citroën Zoë")
        ),
        Language(
            words: split("le la les un une des et est pas pour être avoir fenêtre fichier modifié écran état élève à où déjà très après première dernière français garçon leçon coût île noël hôtel théâtre œuvre cœur sœur bœuf dans sur avec sans comme mais ou nous vous ils elle plus tout"),
            prefixes: split("afficher charger enregistrer obtenir définir " + verbs),
            suffixes: split("État Élève ÀPropos Écran Éditeur Évènement Île Épreuve Éléments Érosion"),
            headings: split("ÉCOLE NORMALE SUPÉRIEURE ÉTÉ ÉTAT À PROPOS ÉLÈVE CAFÉ"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube Citroën Renault Café Crème Brûlée Hôtel")
        ),
        Language(
            words: split("och det att en är inte för på från där här över åt väl står lägger söker hämta välj ändra översikt stäng öppna fönster år två tre säga kvällar mjölk smör bröd kött gård lång själv ålder måndag fredag med av som har till jag du vi de"),
            prefixes: split("vis hämta spara öppna " + verbs),
            suffixes: split("Årsstatistik Översikt Ändring Åldersgrupp Ögonblick Ändelse Överföring Ångest Östra"),
            headings: split("ÅRSBERETNING ÖVERSIKT ÄNDRING ÅLDER"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube Västerås Göteborg Malmö Åre")
        ),
        Language(
            words: split("og er ikke på før være højre venstre måned år hænder kød brød øl æble ærlig øje først tæt stå gå få læse søge åbne luk vælg størrelse oversigt med af som har til jeg du vi de"),
            prefixes: split("hent vis gem åbn " + verbs),
            suffixes: split("Økonomi Ændring Årstal Ærinde Øvelse Åbning Østfold Ølkort Ånd"),
            headings: split("ÅRSBERETNING ØKONOMI ÆNDRING ØVERSIGT"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube København Århus Ålborg Ærø")
        ),
        Language(
            words: split("ja on ei että kun mutta tämä myös näyttää päivä yö työ käyttäjä äänet öljy mäki lähellä vähän ääni hyvää kiitos älä vaihda kuin niin sitten vielä jo ole olla"),
            prefixes: split("näytä lataa tallenna avaa " + verbs),
            suffixes: split("Ääniasetukset Äiti Ääri Ärsytys Äänet Östersund"),
            headings: split("ÄÄNIASETUKSET ÖLJY ÄITI"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube Nokia Jyväskylä Tampere")
        ),
        Language(
            words: split("og er ekki að það sem fyrir þetta þáttur þjóð ágætur dóttir góðan dag bróðir íslenska Ísland ég þú hún hann við þið þeir hæð æði öll ör með til á"),
            prefixes: split("sýna hlaða vista opna " + verbs),
            suffixes: split("Þættir Ágæti Íbúðir Óvænt Úthlutun Ýta Þjóð Ævi Ísland"),
            headings: split("ÞÆTTIR ÍSLAND ÁGÆTI ÚTHLUTUN"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube Reykjavík Akureyri Þingvellir")
        ),
        Language(
            words: split("el la los las un una y es no para por que señor niño año mañana pequeño canción corazón también más está qué cómo dónde árbol fácil difícil útil teléfono música médico rápido último según después con de en del al se lo su"),
            prefixes: split("mostrar cargar guardar obtener " + verbs),
            suffixes: split("Área Último Índice Ópera Útil Éxito Árbol Última Ángel"),
            headings: split("ÓRDENES DEL DÍA ÁREA ÍNDICE ÚLTIMO AÑO"),
            products: split("iPhone MacBook eBay McDonald’s PlayStation YouTube Málaga Cádiz Alicante")
        ),
    ]

    // MARK: Choosing

    /// The characters of `text` beyond ASCII.
    private static func accents(in text: String) -> Set<Character> { Set(text.filter { !$0.isASCII }) }

    /// An element of `items` chosen at random (`items` must not be empty).
    private static func choice<Element>(of items: [Element], using rng: inout SeededGenerator) -> Element {
        items[Int.random(in: 0..<items.count, using: &rng)]
    }

    /// `language` with only the items whose accents all belong to `allowed`,
    /// so that a text holds a few kinds of accent. A list left empty keeps
    /// its first item, which holds the accents it holds.
    private static func restricted(_ language: Language, to allowed: Set<Character>) -> Language {
        func keep(_ items: [String]) -> [String] {
            let kept = items.filter { accents(in: $0).isSubset(of: allowed) }
            return kept.isEmpty ? Array(items.prefix(1)) : kept
        }
        return Language(
            words: keep(language.words), prefixes: keep(language.prefixes), suffixes: keep(language.suffixes),
            headings: keep(language.headings), products: keep(language.products)
        )
    }

    /// `language` as one text draws on it: all of it for one text in four, and
    /// otherwise two to five of its accented letters, each with its other case
    /// half of the time.
    private static func profile(of language: Language, using rng: inout SeededGenerator) -> Language {
        guard Int.random(in: 0..<4, using: &rng) != 0 else { return language }
        let inventory = accents(in: (language.words + language.prefixes + language.suffixes + language.headings + language.products).joined())
            .sorted { String($0) < String($1) }
        var allowed = Set<Character>()
        for _ in 0..<Int.random(in: 2...5, using: &rng) {
            let letter = choice(of: inventory, using: &rng)
            allowed.insert(letter)
            if Bool.random(using: &rng) {
                let swapped = String(letter) == String(letter).lowercased() ? String(letter).uppercased() : String(letter).lowercased()
                allowed.formUnion(swapped)
            }
        }
        return restricted(language, to: allowed)
    }

    // MARK: Lines

    /// A sentence of `count` words, the first capitalized.
    private static func sentence(_ language: Language, words count: Int, using rng: inout SeededGenerator) -> String {
        let words = (0..<count).map { _ in choice(of: language.words, using: &rng) }
        guard let first = words.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ") + "."
    }

    /// An identifier: a lowercase prefix and a capitalized suffix.
    private static func identifier(_ language: Language, using rng: inout SeededGenerator) -> String {
        choice(of: language.prefixes, using: &rng) + choice(of: language.suffixes, using: &rng)
    }

    /// A line of code with identifiers and comments.
    private static func codeLine(_ language: Language, using rng: inout SeededGenerator) -> String {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: return "// " + sentence(language, words: Int.random(in: 3...9, using: &rng), using: &rng)
        case 1: return "func \(identifier(language, using: &rng))() { // " + sentence(language, words: Int.random(in: 2...6, using: &rng), using: &rng)
        case 2:
            let call = "    \(identifier(language, using: &rng))(\(choice(of: language.words, using: &rng)))"
            return call + "  // " + sentence(language, words: Int.random(in: 2...6, using: &rng), using: &rng)
        case 3:
            let name = identifier(language, using: &rng)
            return "    let \(name) = \"\(choice(of: language.words, using: &rng)) \(choice(of: language.words, using: &rng))\""
        case 4: return "/* " + sentence(language, words: Int.random(in: 4...12, using: &rng), using: &rng) + " */"
        default:
            let comment = sentence(language, words: Int.random(in: 3...9, using: &rng), using: &rng)
            return "    // " + comment + " " + identifier(language, using: &rng) + "."
        }
    }

    /// A line of prose.
    private static func proseLine(_ language: Language, using rng: inout SeededGenerator) -> String {
        sentence(language, words: Int.random(in: 5...16, using: &rng), using: &rng)
    }

    /// A line of prose with a product name in it.
    private static func productLine(_ language: Language, using rng: inout SeededGenerator) -> String {
        let before = String(sentence(language, words: Int.random(in: 3...7, using: &rng), using: &rng).dropLast())
        let product = choice(of: language.products, using: &rng)
        return before + " \(product) " + sentence(language, words: Int.random(in: 2...5, using: &rng), using: &rng)
    }

    /// A heading in capitals.
    private static func headingLine(_ language: Language, using rng: inout SeededGenerator) -> String {
        (0..<Int.random(in: 1...3, using: &rng)).map { _ in choice(of: language.headings, using: &rng) }.joined(separator: " ")
    }

    // MARK: Making a Text

    /// The kinds of text: code, prose with the odd identifier, prose with
    /// product names, prose with headings, a line or two, and a mixture.
    private enum Kind: CaseIterable { case code, prose, products, headings, short, mixed }

    /// The text for `seed`.
    static func text(seed: UInt64) -> String {
        var rng = SeededGenerator(state: seed)
        let language = profile(of: choice(of: languages, using: &rng), using: &rng)
        let kind = choice(of: Kind.allCases, using: &rng)
        var lines: [String] = []
        switch kind {
        case .code:
            for _ in 0..<Int.random(in: 4...40, using: &rng) { lines.append(codeLine(language, using: &rng)) }
        case .prose:
            for _ in 0..<Int.random(in: 3...20, using: &rng) {
                lines.append(Int.random(in: 0..<5, using: &rng) == 0 ? codeLine(language, using: &rng) : proseLine(language, using: &rng))
            }
        case .products:
            for _ in 0..<Int.random(in: 3...20, using: &rng) {
                lines.append(Bool.random(using: &rng) ? productLine(language, using: &rng) : proseLine(language, using: &rng))
            }
        case .headings:
            for _ in 0..<Int.random(in: 3...20, using: &rng) {
                lines.append(Int.random(in: 0..<3, using: &rng) == 0 ? headingLine(language, using: &rng) : proseLine(language, using: &rng))
            }
        case .short:
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: lines.append(identifier(language, using: &rng))
                case 1: lines.append(proseLine(language, using: &rng))
                case 2: lines.append(headingLine(language, using: &rng))
                case 3: lines.append(productLine(language, using: &rng))
                default: lines.append(codeLine(language, using: &rng))
                }
            }
        case .mixed:
            for _ in 0..<Int.random(in: 4...30, using: &rng) {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: lines.append(codeLine(language, using: &rng))
                case 1: lines.append(headingLine(language, using: &rng))
                case 2: lines.append(productLine(language, using: &rng))
                default: lines.append(proseLine(language, using: &rng))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
