import Foundation

// V14 verifier probe: PlaceRelocator.verdict(forOldWord:)'s slide-back loop
// (PlaceRelocator.swift:555-557) tests
//     partners[previous - back] == stretchStart - 1 - back
// When the slide has walked back over every new word before the removal
// (back == stretchStart), the right side is -1, which is also what an UNPAIRED
// old word holds, so the loop slides one word too far and the target becomes
// new word -1. BookWords.start(ofWord: -1) is (0,0): the empty cover chapter,
// not the first word of chapter 1.
//
// Book: chapter 0 is an empty cover (as EPUB covers read), chapter 1 is a
// mill song followed by ordinary prose, chapter 2 is more prose. The edit
// cuts the song's opening "Chorus." label, its first verse and the second
// "Chorus." label (keeping the chorus words themselves as the song's new
// opening), and drops the singer's performance note. The prose after the
// song is identical in both texts.

/// The prose after the song: identical in both texts, so the patience diff
/// strips it as the common end before it looks for fixed points.
let prose = """
Nobody in Ashcombe could remember who first sang it. Okonkwo, who kept the \
ledger at the mill for thirty-one years, claimed his grandmother had brought \
it from the coast, though she had also claimed to have met a duke. The tune \
was older than the words, that much everyone agreed on, and the words had \
changed every time a new family took over the stones.

In the spring of the flood year the race silted up twice. The second time, \
Pellow and the two Abernathy boys dug it out by lantern, and it was then, \
waist-deep in the cold, that somebody started the chorus and the others \
joined in without looking up.
"""

/// The second chapter: identical in both texts.
let chapterTwo = """
The new sluice gate arrived on a cart from Tilbury in late June, three weeks \
after it had been promised and two inches narrower than the drawing. Okonkwo \
wrote both facts in the ledger in red ink, which he otherwise kept for deaths.
"""

/// The chorus: the words kept as the song's new opening.
let chorus = "Turn the wheel and grind the corn, the stones go round from dusk to morn."
/// The first verse, which the edit cuts. It rhymes on the same words as the
/// kept line after the second chorus (as songs do), so no word of the song is
/// once in each text: the patience diff finds no fixed point there and lines
/// the song up by its exact longest common subsequence, which pairs the
/// FIRST copy of the chorus.
let verse = "The river runs both high and low, the miller hums while the waters flow."
/// The line after the second chorus: kept.
let after = "Sing it high and sing it low, and sing it while the waters flow."
/// The singer's note after it, which the edit drops.
let note = "(Sing the last line twice, softer the second time.)"

/// Builds the old song with `secondLabel` before the second chorus.
func oldSong(secondLabel: String) -> String {
    "Chorus.\n\n\(chorus)\n\n\(verse)\n\n\(secondLabel)\n\n\(chorus)\n\n\(after)\n\n\(note)\n\n\(prose)"
}
let newSong = "\(chorus)\n\n\(after)\n\n\(prose)"

/// Prints the relocation of a place at `phrase` in chapter 1 of `oldTexts`.
func relocatePhrase(_ phrase: String, _ r: PlaceRelocator, _ oldText: String) {
    let at = (oldText as NSString).range(of: phrase).location
    precondition(at != NSNotFound, phrase)
    let saved = TextPlace(chapter: 1, offset: at)
    let anchor = TextAnchor(capturingAt: saved, in: r.old)!
    let result = r.relocate(anchor, savedAt: saved)
    let finderAlone = TextAnchorFinder(words: r.new).find(anchor, savedAt: saved)
    print("  place at \"\(phrase)\" (1,\(at)) -> \(result.place) \(result.finding)   [finder alone: \(finderAlone.place)]")
}

/// Runs one case: prints the diff's pairing of the song's words and where
/// places in the cut verse land.
func run(_ title: String, secondLabel: String) {
    let oldTexts = ["", oldSong(secondLabel: secondLabel), chapterTwo]
    let newTexts = ["", newSong, chapterTwo]
    let r = PlaceRelocator(oldTexts: oldTexts, newTexts: newTexts)
    let partners = PatienceDiff.partners(of: r.old.keys, in: r.new.keys)
    // The song's words: old words up to the start of the note's end.
    let songWords = FineWords.words(in: "Chorus. \(chorus) \(verse) \(secondLabel) \(chorus) \(after)").count
    let oldSongText = oldTexts[1] as NSString
    print("== \(title) ==")
    print("old words \(r.old.count), new words \(r.new.count)")
    var line = ""
    for word in 0..<songWords {
        let text = oldSongText.substring(with: NSRange(location: r.old.starts[word], length: r.old.ends[word] - r.old.starts[word]))
        line += "\(word):\(text)->\(partners[word]) "
    }
    print("song partners (old index:word->new index):\n  \(line)")
    print("new word 0 starts at \(r.new.start(ofWord: 0)); landing(beforeWord: 0) = \(r.new.landing(beforeWord: 0)); landing(beforeWord: -1) = \(r.new.landing(beforeWord: -1))")
    for phrase in ["The river runs", "the miller hums", "while the waters flow", "\(secondLabel)\n\n\(chorus)"] {
        relocatePhrase(phrase, r, oldTexts[1])
    }
    // A place in the kept chorus and in the prose, for comparison.
    relocatePhrase("Okonkwo, who kept", r, oldTexts[1])
    print("")
}

run("BUG CASE: second label is 'Chorus.' (old word 0 'chorus' equals the word before the second chorus)", secondLabel: "Chorus.")
run("CONTROL: second label is 'Refrain.' (old word 0 differs), otherwise the same edit", secondLabel: "Refrain.")
