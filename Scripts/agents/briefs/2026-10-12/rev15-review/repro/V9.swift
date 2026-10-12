import Foundation

// V9 verifier probe (written independently of the finder's probe).
//
// Claim under test: the slide-back loop in PlaceRelocator.verdict(forOldWord:)
// (PlaceRelocator.swift:553-561) has no chapter boundary. A book of separate
// chapters loses one chapter in its new text. Every place inside the removed
// chapter should go "where the text after the removal begins" (type doc,
// lines 41-42; inline comment, lines 548-552; PlaceRelocatorTests.swift:292-309):
// the start of the next chapter. When the removed chapter ends with the same
// word(s) as the chapter before it, the slide is suspected to carry those
// places back onto the previous chapter's last word(s) instead.

// MARK: - Helpers (all take their inputs as parameters; no shared globals)

/// The text of old/new word `word` in `words`.
func text(ofWord word: Int, in words: BookWords) -> String {
    guard word >= 0, word < words.count else { return "<none>" }
    let chapter = words.chapter(ofWord: word)
    let range = NSRange(location: words.starts[word], length: words.ends[word] - words.starts[word])
    return (words.texts[chapter] as NSString).substring(with: range)
}

/// Up to `length` UTF-16 units of `words`' text from `place`, newlines shown as "/".
func snippet(at place: TextPlace, in words: BookWords, length: Int = 34) -> String {
    guard place.chapter >= 0, place.chapter < words.chapterCount else { return "<past the book>" }
    let chapterText = words.texts[place.chapter] as NSString
    let start = min(max(place.offset, 0), chapterText.length)
    let piece = chapterText.substring(with: NSRange(location: start, length: min(length, chapterText.length - start)))
    return piece.isEmpty ? "<chapter end>" : piece.replacingOccurrences(of: "\n", with: "/")
}

/// The UTF-16 offset of the first `phrase` in `text` (crashes the probe when missing).
func offset(of phrase: String, in text: String) -> Int {
    let found = (text as NSString).range(of: phrase)
    precondition(found.location != NSNotFound, "phrase not found: \(phrase)")
    return found.location
}

/// Relocates a place saved at `saved` in `oldTexts` (its anchor captured
/// there, as the app captures it) and prints where it lands in `newTexts`
/// against where it should land.
func check(_ label: String, at saved: TextPlace, relocator: PlaceRelocator, expected: TextPlace) {
    let anchor = TextAnchor(capturingAt: saved, in: relocator.old)!
    let result = relocator.relocate(anchor, savedAt: saved)
    let verdict = result.place == expected ? "OK   " : "WRONG"
    print("  \(verdict) \(label) (old \(saved.chapter),\(saved.offset)) -> new (\(result.place.chapter),\(result.place.offset)) "
        + "\(result.finding)  lands on: \"\(snippet(at: result.place, in: relocator.new))\"")
}

/// Prints the diff's partner for each old word around the removal, to show
/// which alignment the patience diff chose.
func showPartners(old: BookWords, new: BookWords, around words: [Int]) {
    let partners = PatienceDiff.partners(of: old.keys, in: new.keys)
    for word in words where word >= 0 && word < old.count {
        let partner = partners[word]
        let partnerText = partner >= 0 ? "new #\(partner) \"\(text(ofWord: partner, in: new))\" (ch \(new.chapter(ofWord: partner)))" : "unpaired"
        print("    old #\(word) \"\(text(ofWord: word, in: old))\" (ch \(old.chapter(ofWord: word))) -> \(partnerText)")
    }
}

// MARK: - Book 1: a canal-barge restoration, chapter VII removed

let six = """
CHAPTER VI.

The barge had lain in the reeds below Copthorne Lock for eleven winters before Ffion bought it for the price of a secondhand bicycle. Its hull was sound below the waterline, though the cabin roof sagged like a wet hat.

Bramwell walked its length twice, tapping the planks with a coin, and declared it worth saving. "We start on Monday," Ffion said.
"""

/// Chapter VII without its closing sentence; each variant adds one.
let sevenBody = """
CHAPTER VII.

The engine was a two-cylinder Lister that had last run when decimal coins were new. Bramwell drained a sludge of diesel and pond water from its sump, cleaned the injectors in a jam jar of paraffin, and coaxed it into a cough on the third evening.

By Friday it idled steadily enough to frighten the moorhens. Ffion chalked the date on the bulkhead and went below to fetch the torch.
"""

let eight = """
CHAPTER VIII.

They took the barge out on the first Sunday in May, as far as the swing bridge at Ashby Parva and back again. A lock-keeper's grandson ran alongside on the towpath, shouting the depth markers, until his mother called him in for lunch.
"""

/// Chapter VII's closing sentence in each variant, and what it shares with VI's last words.
let endings: [(name: String, ending: String)] = [
    ("CONTROL: VII ends 'Bramwell warned.' (no final word shared with VI)", " \"Mind the rotten step,\" Bramwell warned."),
    ("VII ends 'Bramwell said.' (final word 'said' shared with VI)", " \"Mind the rotten step,\" Bramwell said."),
    ("VII ends 'Ffion said.' (final words 'Ffion said' shared with VI)", " \"Mind the rotten step,\" Ffion said."),
]

print("BOOK 1: old [VI, VII, VIII] -> new [VI, VIII]; every place in VII should land at new (1,0) = \"CHAPTER VIII.\"")
for (name, ending) in endings {
    let seven = sevenBody + ending
    let relocator = PlaceRelocator(oldTexts: [six, seven, eight], newTexts: [six, eight])
    let startOfEight = TextPlace(chapter: 1, offset: 0)
    print("\n- \(name)")
    for phrase in ["CHAPTER VII.", "Lister", "sludge", "moorhens", "torch", "Mind the rotten"] {
        check("place at '\(phrase)'", at: TextPlace(chapter: 1, offset: offset(of: phrase, in: seven)), relocator: relocator, expected: startOfEight)
    }
    // Controls outside the removed chapter: they must keep their own words.
    check("[control] place at 'Copthorne' in VI", at: TextPlace(chapter: 0, offset: offset(of: "Copthorne", in: six)),
          relocator: relocator, expected: TextPlace(chapter: 0, offset: offset(of: "Copthorne", in: six)))
    check("[control] place at 'swing' in VIII", at: TextPlace(chapter: 2, offset: offset(of: "swing", in: eight)),
          relocator: relocator, expected: TextPlace(chapter: 1, offset: offset(of: "swing", in: eight)))
    // Which alignment did the diff choose? VI's last 3 words, VII's first 2 and last 3, VIII's first 2.
    let old = relocator.old
    let sevenFirst = old.chapterFirstWords[1], eightFirst = old.chapterFirstWords[2]
    print("  diff partners at the removal:")
    showPartners(old: old, new: relocator.new, around: [sevenFirst - 3, sevenFirst - 2, sevenFirst - 1, sevenFirst, sevenFirst + 1,
                                                       eightFirst - 3, eightFirst - 2, eightFirst - 1, eightFirst, eightFirst + 1])
}

// MARK: - Book 1 through the whole-book API: what would be saved

do {
    let seven = sevenBody + " \"Mind the rotten step,\" Bramwell said."
    let oldTexts = [six, seven, eight]
    let relocator = PlaceRelocator(oldTexts: oldTexts, newTexts: [six, eight])
    let oldWords = relocator.old
    let lister = TextPlace(chapter: 1, offset: offset(of: "Lister", in: seven))
    let torch = TextPlace(chapter: 1, offset: offset(of: "torch", in: seven))
    let position = ReadingPosition(chapterIndex: 1, characterOffset: lister.offset,
                                   globalCharacterOffset: oldWords.globalOffset(of: lister),
                                   anchor: TextAnchor(capturingAt: lister, in: oldWords))
    let bookmark = Bookmark(number: 1, chapterIndex: 1, characterOffset: torch.offset, label: "engine runs",
                            anchor: TextAnchor(capturingAt: torch, in: oldWords))
    let outcome = relocator.relocate(PlaceRelocator.Places(position: position, bookmarks: [bookmark], skippedHeadings: []))
    let moved = outcome.places.position!
    let mark = outcome.places.bookmarks[0]
    print("\nBOOK 1 (VII ends 'Bramwell said.') via relocate(Places):")
    print("  position: chapterIndex \(moved.chapterIndex), characterOffset \(moved.characterOffset), "
        + "globalCharacterOffset \(moved.globalCharacterOffset.map(String.init) ?? "nil"), finding \(outcome.positionFinding!)")
    print("  bookmark: chapterIndex \(mark.chapterIndex), characterOffset \(mark.characterOffset), finding \(outcome.bookmarkFindings[0])")
    print("  new chapter 0 (VI) is \(relocator.new.length(ofChapter: 0)) units long; new chapter 1 (VIII) starts at global \(relocator.new.chapterStarts[1])")
}

// MARK: - Book 2: letters that each end with the same sign-off, letter VII removed

let letterSix = """
LETTER VI.

Dear Hettie,

The surveyor came on Tuesday and walked the boundary with a measuring wheel that squeaked at every turn. He says the hedge is ours as far as the stile, which settles the quarrel with the vicarage at last.

Your brother as ever,
Tobias
"""

let letterSeven = """
LETTER VII.

Dear Hettie,

The orchard flooded after the thaw and the ewes have taken to sleeping in the cart shed. Mother wants to know whether you still have her recipe for damson cheese, as she has lost the card again.

Your brother as ever,
Tobias
"""

let letterEight = """
LETTER VIII.

Dear Hettie,

We sold the bay mare at Hereford for less than she was worth and more than we expected. The auctioneer remembered Father, which helped.

Your brother as ever,
Tobias
"""

print("\nBOOK 2: letters [VI, VII, VIII] each signed 'Your brother as ever, Tobias' -> new [VI, VIII]; places in VII should land at (1,0) = \"LETTER VIII.\"")
do {
    let relocator = PlaceRelocator(oldTexts: [letterSix, letterSeven, letterEight], newTexts: [letterSix, letterEight])
    for phrase in ["LETTER VII.", "orchard", "ewes", "damson", "card again"] {
        check("place at '\(phrase)'", at: TextPlace(chapter: 1, offset: offset(of: phrase, in: letterSeven)),
              relocator: relocator, expected: TextPlace(chapter: 1, offset: 0))
    }
}
