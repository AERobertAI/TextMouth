import Foundation
// Gap probe 2: in the rewritten-sentence case, where do places in the
// rewritten run land, relative to where the replacement begins?
let millrace = "CHAPTER I. The Millrace\n\n"
    + "The volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup that Hesketh guarded as if it were the parish silver. "
    + "The millrace had silted to the height of a boot, and frogspawn floated in the shallows by the sluice.\n\n"
    + "By noon they had cleared forty yards of channel. Nell measured the fall with a spirit level and a length of string, and wrote the figures on the back of a seed packet, which she lost by teatime."
let wheel = "CHAPTER II. The Wheel\n\n"
    + "The wheel itself was oak, eleven feet across, its paddles split where the frost had worked into them. "
    + "A carpenter from the valley came on Tuesdays to fit new ones, steaming each plank over a tin bath until it would bend.\n\n"
    + "He charged nothing, but asked to keep the offcuts, which he turned into spoons and sold at the Thursday market under a hand-painted sign."
let stones = "CHAPTER III. The Stones\n\n"
    + "Nobody knew where the upper millstone had gone. The parish records listed a pair of French burrs bought in 1871, "
    + "and a photograph from the war showed both of them leaning against the granary wall.\n\n"
    + "In June a farmer ploughing above the weir struck something that rang like a dropped pan. It was the missing stone, face down in the clay, with a hawthorn growing through its eye."
let flour = "CHAPTER IV. First Flour\n\n"
    + "They ground their first sack of wheat on the longest day of the year. The flour came out warm and speckled, and Hesketh baked it into loaves as heavy as paving slabs, which were gone within the hour.\n\n"
    + "The miller's grandson, who was ninety, sat on an upturned crate by the hopper and told them, kindly, that they were running the stones too close."
let mill = [millrace, wheel, stones, flour]
let photograph = "a photograph from the war showed both of them leaning against the granary wall"
let replacement = "a dealer in Ludlow claimed he had sold one of them to a garden centre near the bypass"
let ninety = "who was ninety, sat on an upturned crate by the hopper"
let ninetyRepl = "whose knees would not let him crouch, leaned on the doorframe with his stick"
let new = [millrace, wheel, stones.replacingOccurrences(of: photograph, with: replacement), flour.replacingOccurrences(of: ninety, with: ninetyRepl)]
let oldWords = BookWords(texts: mill)
let r = PlaceRelocator(old: oldWords, new: BookWords(texts: new))
func show(_ chapter: Int, _ phrase: String, _ text: String, _ repl: String) {
    let base = (mill[chapter] as NSString).range(of: phrase).location
    let replStart = (new[chapter] as NSString).range(of: repl).location
    for w in FineWords.words(in: phrase) {
        let saved = TextPlace(chapter: chapter, offset: base + w.start)
        let a = TextAnchor(capturingAt: saved, in: oldWords)!
        let res = r.relocate(a, savedAt: saved)
        let landedAt = res.place.offset - replStart
        let snippet = (new[chapter] as NSString).substring(with: NSRange(location: res.place.offset, length: min(18, (new[chapter] as NSString).length - res.place.offset)))
        print(String((phrase as NSString).substring(with: NSRange(location: w.start, length: w.end - w.start))).padding(toLength: 10, withPad: " ", startingAt: 0),
              "-> +\(landedAt) into replacement: \"\(snippet)\" \(res.finding)")
    }
}
show(2, photograph, stones, replacement)
print("---")
show(3, ninety, flour, ninetyRepl)
