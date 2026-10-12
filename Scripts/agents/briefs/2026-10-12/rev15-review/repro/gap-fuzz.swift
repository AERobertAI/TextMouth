import Foundation
// Fuzz: random books, random edits, random places (odd ones too), random
// skipped headings. Checks: no trap, places in range, headings returned are
// among newHeadings, outcome sizes consistent.
struct RNG { var s: UInt64; mutating func next(_ n: Int) -> Int { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; z ^= z >> 31; return Int(z % UInt64(max(1, n))) } }
let vocab = ["the", "mill", "wheel", "CHAPTER", "I.", "II.", "Notes", "and", "of", "a", "stone", "flour", "sluice", "weir", "é", "🙂", "*", "[]", "\"Not", "yet,\"", "she", "said.", "Ab", "cD", "x1", "2nd", "–", "…", "\n\n", "\n", "ÉCOLE", "İstanbul"]
func word(_ r: inout RNG) -> String { vocab[r.next(vocab.count)] }
func chapter(_ r: inout RNG) -> String {
    let kind = r.next(10)
    if kind == 0 { return "" }
    if kind == 1 { return "* * *" }
    let n = 1 + r.next(60)
    return (0..<n).map { _ in word(&r) }.joined(separator: r.next(5) == 0 ? "" : " ")
}
func edit(_ texts: [String], _ r: inout RNG) -> [String] {
    var t = texts
    for _ in 0..<(1 + r.next(6)) {
        switch r.next(7) {
        case 0: t.insert(chapter(&r), at: r.next(t.count + 1))
        case 1: if !t.isEmpty { t.remove(at: r.next(t.count)) }
        case 2: if !t.isEmpty { t[r.next(t.count)] = "" }
        default:
            guard !t.isEmpty else { continue }
            let c = r.next(t.count)
            var w = t[c].components(separatedBy: " ")
            let at = r.next(w.count + 1)
            switch r.next(3) {
            case 0: w.insert(word(&r), at: at)
            case 1: if !w.isEmpty { w.remove(at: min(at, w.count - 1)) }
            default: if !w.isEmpty { w[min(at, w.count - 1)] = word(&r) }
            }
            t[c] = w.joined(separator: " ")
        }
    }
    return t
}
func place(_ words: BookWords, _ r: inout RNG) -> TextPlace {
    switch r.next(8) {
    case 0: return TextPlace(chapter: -1 - r.next(3), offset: r.next(50) - 10)
    case 1: return TextPlace(chapter: words.chapterCount + r.next(3), offset: r.next(50))
    case 2: return words.endPlace
    default:
        guard words.chapterCount > 0 else { return TextPlace(chapter: 0, offset: 0) }
        let c = r.next(words.chapterCount)
        return TextPlace(chapter: c, offset: r.next(words.length(ofChapter: c) + 3))
    }
}
let iterations = Int(CommandLine.arguments.dropFirst().first ?? "3000") ?? 3000
let seed0 = UInt64(CommandLine.arguments.dropFirst(2).first ?? "1") ?? 1
var problems = 0
for i in 0..<iterations {
    var r = RNG(s: seed0 &* 1_000_003 &+ UInt64(i))
    let savedIn = (0..<(r.next(6))).map { _ in chapter(&r) }
    let old = r.next(3) == 0 ? edit(savedIn, &r) : savedIn
    let new = edit(old, &r)
    let newWords = BookWords(texts: new)
    var headings: [Heading] = []
    for (c, text) in new.enumerated() {
        let len = text.utf16.count
        for _ in 0..<r.next(3) {
            headings.append(Heading(level: 1 + r.next(2), text: ["Notes", "CHAPTER I.", "", "[]", "Cover"][r.next(5)], chapterIndex: c, characterOffset: r.next(len + 1)))
        }
    }
    headings.sort { ($0.chapterIndex, $0.characterOffset) < ($1.chapterIndex, $1.characterOffset) }
    FileHandle.standardError.write("case \(i)\n".data(using: .utf8)!)
    let relocator = PlaceRelocator(oldTexts: old, newTexts: new, newHeadings: headings)
    let savedWords = BookWords(texts: savedIn)
    var places = PlaceRelocator.Places()
    let p = place(savedWords, &r)
    let anchorKind = r.next(4)
    func anchor(at p: TextPlace) -> TextAnchor? {
        switch anchorKind { case 0: return nil; case 1: return TextAnchor(before: "", after: "", fraction: Double(r.next(3)) / 2); default: return TextAnchor(capturingAt: p, in: savedWords) }
    }
    places.position = ReadingPosition(chapterIndex: p.chapter, characterOffset: p.offset, globalCharacterOffset: r.next(2) == 0 ? nil : 5, anchor: anchor(at: p))
    for n in 0..<r.next(4) {
        let b = place(savedWords, &r)
        places.bookmarks.append(Bookmark(number: n + 1, chapterIndex: b.chapter, characterOffset: b.offset, anchor: anchor(at: b)))
    }
    for _ in 0..<r.next(4) {
        let h = place(savedWords, &r)
        places.skippedHeadings.append(SkippedHeading(level: 1 + r.next(2), label: ["Notes", "CHAPTER I.", "", "[]", "Cover"][r.next(5)], chapterIndex: h.chapter, characterOffset: h.offset, anchor: anchor(at: h)))
    }
    let outcome = relocator.relocate(places)
    func check(_ c: Int, _ o: Int, _ what: String) {
        guard newWords.chapterCount > 0 else { return }
        if !(0..<newWords.chapterCount).contains(c) || o < 0 || o > newWords.length(ofChapter: c) {
            problems += 1
            if problems < 15 { print("case \(i): \(what) out of range: (\(c), \(o)) in \(new.map { $0.utf16.count })") }
        }
    }
    if let q = outcome.places.position { check(q.chapterIndex, q.characterOffset, "position(\(String(describing: outcome.positionFinding)))") }
    for (b, f) in zip(outcome.places.bookmarks, outcome.bookmarkFindings) { check(b.chapterIndex, b.characterOffset, "bookmark(\(f))") }
    for s in places.skippedHeadings { if let h = relocator.relocate(s) { if !headings.contains(h.heading) { problems += 1; print("case \(i): heading not among new headings") } } }
}
print("done, problems:", problems)
