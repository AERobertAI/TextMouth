import Foundation

/// Real reading text kept for the text anchor tests (T06), exactly as
/// TextMouth's own extraction read the repository's fixtures at two versions,
/// from the measurement program the design note describes
/// (TEXT-ANCHORS-RESEARCH-2026-10-10.md, section 3). Generated from those
/// readings, not typed.
enum TextAnchorRealReadings {
    /// sample.md as 3.0.2 read it: its code span left out ("It even handled  with grace.").
    static let sampleMarkdown302 =
        "The Art of Testing\n\n"
        + "This is a sample markdown document for testing TextMouth’s markdown parser.\n\n"
        + "Chapter One: The Beginning\n\n"
        + "Once upon a time, in a land of automated tests, there lived a parser that needed to prove itself worthy. It had to handle headings, paragraphs, and all manner of markdown formatting.\n\n"
        + "The parser was bold in its approach, and sometimes italic in its methods. It even handled  with grace.\n\n"
        + "Section 1.1: Lists\n\n"
        + "Here are some things the parser must handle:\n\n"
        + "Bullet point one\n\n"
        + "Bullet point two\n\n"
        + "Bullet point three\n\n"
        + "And numbered lists:\n\n"
        + "First item\n\n"
        + "Second item\n\n"
        + "Third item\n\n"
        + "Chapter Two: The Middle\n\n"
        + "The story continues with more text to parse. This paragraph contains enough words to test word counting and speech rate calculations. We need several sentences here to make the test meaningful. The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.\n\n"
        + "Section 2.1: Special Characters\n\n"
        + "The parser must handle special characters like & and  and “quotes” and ‘apostrophes’.\n\n"
        + "Chapter Three: The End\n\n"
        + "And so the parser proved itself, handling every heading level and every paragraph with ease. The end.\n\n"
        + "Epilogue\n\n"
        + "A brief afterword to ensure the final heading is captured."

    /// sample.md as 3.0.3 reads it, the code span restored ("inline code", F13).
    static let sampleMarkdown303 =
        "The Art of Testing\n\n"
        + "This is a sample markdown document for testing TextMouth’s markdown parser.\n\n"
        + "Chapter One: The Beginning\n\n"
        + "Once upon a time, in a land of automated tests, there lived a parser that needed to prove itself worthy. It had to handle headings, paragraphs, and all manner of markdown formatting.\n\n"
        + "The parser was bold in its approach, and sometimes italic in its methods. It even handled inline code with grace.\n\n"
        + "Section 1.1: Lists\n\n"
        + "Here are some things the parser must handle:\n\n"
        + "Bullet point one\n\n"
        + "Bullet point two\n\n"
        + "Bullet point three\n\n"
        + "And numbered lists:\n\n"
        + "First item\n\n"
        + "Second item\n\n"
        + "Third item\n\n"
        + "Chapter Two: The Middle\n\n"
        + "The story continues with more text to parse. This paragraph contains enough words to test word counting and speech rate calculations. We need several sentences here to make the test meaningful. The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.\n\n"
        + "Section 2.1: Special Characters\n\n"
        + "The parser must handle special characters like & and  and “quotes” and ‘apostrophes’.\n\n"
        + "Chapter Three: The End\n\n"
        + "And so the parser proved itself, handling every heading level and every paragraph with ease. The end.\n\n"
        + "Epilogue\n\n"
        + "A brief afterword to ensure the final heading is captured."

    /// alice.docx's first licence paragraph as 3.0.2 read it: its link's text written twice.
    static let linkedParagraph302 =
        "This eBook is for the use of anyone anywhere in the United States and most other parts of the world at no cost and with almost no restrictions whatsoever. You may copy it, give it away or re-use it under the terms of the Project Gutenberg License included with this eBook or online at www.gutenberg.orgwww.gutenberg.org. If you are not located in the United States, you will have to check the laws of the country where you are located before using this eBook."

    /// The same paragraph as 3.0.3 reads it, the link's text written once (F15).
    static let linkedParagraph303 =
        "This eBook is for the use of anyone anywhere in the United States and most other parts of the world at no cost and with almost no restrictions whatsoever. You may copy it, give it away or re-use it under the terms of the Project Gutenberg License included with this eBook or online at www.gutenberg.org. If you are not located in the United States, you will have to check the laws of the country where you are located before using this eBook."

    /// alice.docx's second contents list as 3.0.4 read it, its entries run together.
    static let contents304 =
        "Alice’s Adventures in Wonderland\n\n"
        + "by Lewis Carroll\n\n"
        + "THE MILLENNIUM FULCRUM EDITION 3.0\n\n"
        + "Contents\n\n"
        + "CHAPTER I.Down the Rabbit-HoleCHAPTER II.The Pool of TearsCHAPTER III.A Caucus-Race and a Long TaleCHAPTER IV.The Rabbit Sends in a Little BillCHAPTER V.Advice from a CaterpillarCHAPTER VI.Pig and PepperCHAPTER VII.A Mad Tea-PartyCHAPTER VIII.The Queen’s Croquet-GroundCHAPTER IX.The Mock Turtle’s StoryCHAPTER X.The Lobster QuadrilleCHAPTER XI.Who Stole the Tarts?CHAPTER XII.Alice’s Evidence\n\n"
        + "CHAPTER I.\n\n"
        + "Down the Rabbit-Hole"

    /// The same list as 3.0.7 reads it, one entry a paragraph.
    static let contents307 =
        "Alice’s Adventures in Wonderland\n\n"
        + "by Lewis Carroll\n\n"
        + "THE MILLENNIUM FULCRUM EDITION 3.0\n\n"
        + "Contents\n\n"
        + "CHAPTER I. Down the Rabbit-Hole\n\n"
        + "CHAPTER II. The Pool of Tears\n\n"
        + "CHAPTER III. A Caucus-Race and a Long Tale\n\n"
        + "CHAPTER IV. The Rabbit Sends in a Little Bill\n\n"
        + "CHAPTER V. Advice from a Caterpillar\n\n"
        + "CHAPTER VI. Pig and Pepper\n\n"
        + "CHAPTER VII. A Mad Tea-Party\n\n"
        + "CHAPTER VIII. The Queen’s Croquet-Ground\n\n"
        + "CHAPTER IX. The Mock Turtle’s Story\n\n"
        + "CHAPTER X. The Lobster Quadrille\n\n"
        + "CHAPTER XI. Who Stole the Tarts?\n\n"
        + "CHAPTER XII. Alice’s Evidence\n\n"
        + "CHAPTER I.\n\n"
        + "Down the Rabbit-Hole"

    /// test_book.docx's table as 3.0.4 read it, its cells run together.
    static let table304 =
        "Barometer Readings Reference\n\n"
        + "Reading (hPa)TrendExpected Conditions1013-1023SteadyFair weather, light winds1003-1013FallingClouds increasing, rain likely993-1003Falling rapidlyStorm approaching, high windsBelow 993Very lowSevere storm, seek shelter\n\n"
        + "Chapter 3: Communication"

    /// The same table as 3.0.7 reads it, a row a paragraph.
    static let table307 =
        "Barometer Readings Reference\n\n"
        + "Reading (hPa) Trend Expected Conditions\n\n"
        + "1013-1023 Steady Fair weather, light winds\n\n"
        + "1003-1013 Falling Clouds increasing, rain likely\n\n"
        + "993-1003 Falling rapidly Storm approaching, high winds\n\n"
        + "Below 993 Very low Severe storm, seek shelter\n\n"
        + "Chapter 3: Communication"

    /// alice.epub's Lobster Quadrille (CHAPTER X) as 3.0.7 reads it: a refrain sung twice.
    static let quadrille307 =
        "“Will you walk a little faster?” said a whiting to a snail.\n“There’s a porpoise close behind us, and he’s treading on my tail.\nSee how eagerly the lobsters and the turtles all advance!\nThey are waiting on the shingle—will you come and join the dance?\nWill you, won’t you, will you, won’t you, will you join the dance?\nWill you, won’t you, will you, won’t you, won’t you join the dance?\n\n"
        + "“You can really have no notion how delightful it will be\nWhen they take us up and throw us, with the lobsters, out to sea!”\nBut the snail replied “Too far, too far!” and gave a look askance—\nSaid he thanked the whiting kindly, but he would not join the dance.\nWould not, could not, would not, could not, would not join the dance.\nWould not, could not, would not, could not, could not join the dance.\n\n"
        + "“What matters it how far we go?” his scaly friend replied.\n“There is another shore, you know, upon the other side.\nThe further off from England the nearer is to France—\nThen turn not pale, beloved snail, but come and join the dance.\nWill you, won’t you, will you, won’t you, will you join the dance?\nWill you, won’t you, will you, won’t you, won’t you join the dance?”\n\n"
        + "“Thank you, it’s a very interesting dance to watch,” said Alice, feeling very glad that it was over at last: “and I do so like that curious song about the whiting!”"

    /// alice.epub's CHAPTER I as 3.0.4 read its opening, under the heading "[]CHAPTER I.".
    static let chapterOneOpening304 =
        "[]CHAPTER I.\n\n"
        + "Down the Rabbit-Hole\n\n"
        + "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, “and what is the use of a book,” thought Alice “without pictures or conversations?”"

    /// The same opening as 3.0.7 reads it, under the heading "CHAPTER I. Down the Rabbit-Hole".
    static let chapterOneOpening307 =
        "CHAPTER I. Down the Rabbit-Hole\n\n"
        + "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, “and what is the use of a book,” thought Alice “without pictures or conversations?”"

    /// alice.epub's CHAPTER II as 3.0.4 read its opening, under the heading "[]CHAPTER II.".
    static let chapterTwoOpening304 =
        "[]CHAPTER II.\n\n"
        + "The Pool of Tears\n\n"
        + "“Curiouser and curiouser!” cried Alice (she was so much surprised, that for the moment she quite forgot how to speak good English); “now I’m opening out like the largest telescope that ever was! Good-bye, feet!” (for when she looked down at her feet, they seemed to be almost out of sight, they were getting so far off). “Oh, my poor little feet, I wonder who will put on your shoes and stockings for you now, dears? I’m sure I shan’t be able! I shall be a great deal too far off to trouble myself about you: you must manage the best way you can;—but I must be kind to them,” thought Alice, “or perhaps they won’t walk the way I want to go! Let me see: I’ll give them a new pair of boots every Christmas.”"

    /// The same opening as 3.0.7 reads it, under the heading "CHAPTER II. The Pool of Tears".
    static let chapterTwoOpening307 =
        "CHAPTER II. The Pool of Tears\n\n"
        + "“Curiouser and curiouser!” cried Alice (she was so much surprised, that for the moment she quite forgot how to speak good English); “now I’m opening out like the largest telescope that ever was! Good-bye, feet!” (for when she looked down at her feet, they seemed to be almost out of sight, they were getting so far off). “Oh, my poor little feet, I wonder who will put on your shoes and stockings for you now, dears? I’m sure I shan’t be able! I shall be a great deal too far off to trouble myself about you: you must manage the best way you can;—but I must be kind to them,” thought Alice, “or perhaps they won’t walk the way I want to go! Let me see: I’ll give them a new pair of boots every Christmas.”"
}
