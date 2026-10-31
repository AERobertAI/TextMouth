import Foundation
import ZIPFoundation

@testable import TextMouth

typealias TestDAISYAudioClip = DAISYAudioClip
typealias TestAudioManifest = AudioManifest
typealias TestAudioSegment = AudioSegment
typealias TestFragmentAudioClip = DAISYAudioClip
typealias TestFragmentAwareSMILParser = DAISYAudioSMILParser

func parseDAISYTimeString(_ value: String) -> Double {
    DAISYAudioSMILParser.parseTime(value)
}

func parseDAISYAudioSMIL(_ xml: String) throws -> [DAISYAudioClip] {
    try DAISYAudioSMILParser(data: Data(xml.utf8), file: "test.smil").parse()
}

func testResolvedAudioPath(for clip: DAISYAudioClip, smilPath: String) -> String {
    DAISYAudioConverter.resolvedAudioPath(for: clip, smilPath: smilPath)
}

/// The sections of `fragments` (one heading per SMIL fragment) in the SMIL
/// file `smil`, read from "OPS/nav.smil": each heading's clips as
/// "path start-end" lines, joined as the converter joins them, or nil for a
/// heading with no audio of its own.
func testSections(ofFragments fragments: [String], in smil: String) throws -> [[String]?] {
    let parser = TestFragmentAwareSMILParser(data: Data(smil.utf8), file: "OPS/nav.smil")
    _ = try parser.parse()
    let references = fragments.map {
        DAISYNavigationReference(title: $0, target: "nav.smil#\($0)", in: "OPS/nav.ncx")
    }
    let sequence = DAISYPlaybackSequence(playing: ["OPS/nav.smil"], parsedFiles: ["OPS/nav.smil": parser])
    return sequence.sections(for: references).map { section in
        section.map { clips in
            DAISYAudioConverter.joiningContinuousClips(clips).map { "\($0.audioPath) \($0.startTime)-\($0.endTime)" }
        }
    }
}

@MainActor
func runDAISYAudioTests() {
print("\n--- DAISY Audio Tests ---")

// SMIL time parsing tests
test("Parse DAISY 2.02 time format: npt=38.228s") {
    let seconds = parseDAISYTimeString("npt=38.228s")
    try assertTrue(abs(seconds - 38.228) < 0.001, "Should parse to 38.228, got \(seconds)")
}

test("Parse DAISY 2.02 time format: npt=0.000s") {
    let seconds = parseDAISYTimeString("npt=0.000s")
    try assertTrue(abs(seconds - 0.0) < 0.001, "Should parse to 0.0, got \(seconds)")
}

test("Parse DAISY 3 time format: 0:02:43.650") {
    let seconds = parseDAISYTimeString("0:02:43.650")
    let expected = 2 * 60 + 43.650
    try assertTrue(abs(seconds - expected) < 0.001, "Should parse to \(expected), got \(seconds)")
}

test("Parse DAISY 3 time format: 0:00:00") {
    let seconds = parseDAISYTimeString("0:00:00")
    try assertTrue(abs(seconds - 0.0) < 0.001, "Should parse to 0.0, got \(seconds)")
}

test("Parse DAISY 3 time format: 1:30:15.500") {
    let seconds = parseDAISYTimeString("1:30:15.500")
    let expected = 1 * 3600 + 30 * 60 + 15.5
    try assertTrue(abs(seconds - expected) < 0.001, "Should parse to \(expected), got \(seconds)")
}

test("Parse plain seconds: 123.456") {
    let seconds = parseDAISYTimeString("123.456")
    try assertTrue(abs(seconds - 123.456) < 0.001, "Should parse to 123.456, got \(seconds)")
}

// SMIL audio clip extraction tests
test("Extract audio clips from DAISY 2.02 SMIL") {
    let smil = """
    <?xml version="1.0" encoding="utf-8"?>
    <smil>
    <body>
    <seq>
    <par id="txt_1">
    <text src="content.html#p_1" />
    <audio src="chapter01.mp3" clip-begin="npt=0.000s" clip-end="npt=5.500s" />
    </par>
    <par id="txt_2">
    <text src="content.html#p_2" />
    <audio src="chapter01.mp3" clip-begin="npt=5.500s" clip-end="npt=12.300s" />
    </par>
    </seq>
    </body>
    </smil>
    """
    let clips = try parseDAISYAudioSMIL(smil)
    try assertEqual(clips.count, 2, "Should find 2 audio clips")
    try assertEqual(clips[0].file, "chapter01.mp3")
    try assertTrue(abs(clips[0].startTime - 0.0) < 0.001)
    try assertTrue(abs(clips[0].endTime - 5.5) < 0.001)
    try assertTrue(abs(clips[1].startTime - 5.5) < 0.001)
    try assertTrue(abs(clips[1].endTime - 12.3) < 0.001)
}

test("Extract audio clips from DAISY 3 SMIL") {
    let smil = """
    <?xml version="1.0" encoding="UTF-8"?>
    <smil xmlns="http://www.w3.org/2001/SMIL20/">
    <body>
    <seq id="mseq">
    <par id="tcp1">
    <text src="book.xml#dtb1"/>
    <audio clipBegin="0:00:00" clipEnd="0:00:04.065" src="speech001.mp3"/>
    </par>
    <par id="tcp2">
    <text src="book.xml#dtb2"/>
    <audio clipBegin="0:00:04.065" clipEnd="0:00:10.200" src="speech001.mp3"/>
    </par>
    </seq>
    </body>
    </smil>
    """
    let clips = try parseDAISYAudioSMIL(smil)
    try assertEqual(clips.count, 2, "Should find 2 audio clips")
    try assertEqual(clips[0].file, "speech001.mp3")
    try assertTrue(abs(clips[0].startTime - 0.0) < 0.001)
    try assertTrue(abs(clips[0].endTime - 4.065) < 0.001)
    try assertTrue(abs(clips[1].startTime - 4.065) < 0.001)
    try assertTrue(abs(clips[1].endTime - 10.2) < 0.001)
}

// AudioManifest segment encoding/decoding
test("AudioManifest encodes and decodes segments") {
    let manifest = TestAudioManifest(
        title: "Test Book",
        author: "Test Author",
        segments: [
            TestAudioSegment(title: "Chapter 1", file: "audio01.mp3", startTime: 0, endTime: 45.5),
            TestAudioSegment(title: "Chapter 2", file: "audio01.mp3", startTime: 45.5, endTime: 120.3),
            TestAudioSegment(title: "Chapter 3", file: "audio02.mp3", startTime: 0, endTime: 60.0)
        ]
    )
    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(TestAudioManifest.self, from: data)
    try assertEqual(decoded.title, "Test Book")
    try assertEqual(decoded.segments?.count, 3)
    try assertEqual(decoded.segments?[0].title, "Chapter 1")
    try assertTrue(abs((decoded.segments?[0].endTime ?? 0) - 45.5) < 0.001)
    try assertEqual(decoded.segments?[2].file, "audio02.mp3")
}

// DAISY audio file detection. The two DAISY audio books' scenarios are
// DAISYAudioFixtureTests (TextMouthProductionTests), which find the books
// from a linked worktree too and skip, saying why, when no checkout has them.
test("Text-only DAISY does not have audio") {
    let url = try requireFile("hyperion_daisy.zip")
    let archive = try Archive(url: url, accessMode: .read)
    // The fixture itself holds no audio file, so the app's check below
    // must find none.
    let hasAudio = archive.contains { entry in
        let ext = (entry.path as NSString).pathExtension.lowercased()
        return ext == "mp3" || ext == "wav" || ext == "aac"
    }
    try assertTrue(!hasAudio, "Hyperion (text-only) should not have audio files")
    try assertTrue(!DAISYAudioConverter.hasAudio(in: ArchiveFileProvider(archive: archive)), "Hyperion is a text-only DAISY book")
}

test("DAISY sections compare resolved audio paths, not basenames") {
    let smil = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="a"><audio src="dirA/shared.mp3" clipBegin="10.0" clipEnd="60.0"/></par>
      <par id="b"><audio src="dirB/shared.mp3" clipBegin="5.0" clipEnd="45.0"/></par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smil.data(using: .utf8)!, file: "test.smil")
    _ = try parser.parse()
    let currentPath = testResolvedAudioPath(for: parser.clip(forFragment: "a")!, smilPath: "OPS/nav.smil")
    let nextPath = testResolvedAudioPath(for: parser.clip(forFragment: "b")!, smilPath: "OPS/nav.smil")
    try assertEqual((currentPath as NSString).lastPathComponent,
                    (nextPath as NSString).lastPathComponent,
                    "Basenames intentionally match")
    try assertTrue(currentPath != nextPath, "Resolved paths should distinguish directories")

    // Each heading keeps its own file's clip whole; nothing is cut at the
    // other file's times or joined across the two files.
    try assertEqual(try testSections(ofFragments: ["a", "b"], in: smil), [
        ["OPS/dirA/shared.mp3 10.0-60.0"],
        ["OPS/dirB/shared.mp3 5.0-45.0"]
    ])
    try assertEqual(try testSections(ofFragments: ["a"], in: smil), [
        ["OPS/dirA/shared.mp3 10.0-60.0", "OPS/dirB/shared.mp3 5.0-45.0"]
    ])
}

test("DAISY section ends where the next heading starts in the same canonical file") {
    let smil = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="a"><audio src="./audio/../audio/book.mp3" clipBegin="0.0" clipEnd="25.0"/></par>
      <par id="b"><audio src="audio/book.mp3" clipBegin="25.0" clipEnd="50.0"/></par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smil.data(using: .utf8)!, file: "test.smil")
    _ = try parser.parse()
    let currentPath = testResolvedAudioPath(for: parser.clip(forFragment: "a")!, smilPath: "OPS/nav.smil")
    let nextPath = testResolvedAudioPath(for: parser.clip(forFragment: "b")!, smilPath: "OPS/nav.smil")
    try assertEqual(currentPath, nextPath, "Dot segments should canonicalize to the same package path")

    try assertEqual(try testSections(ofFragments: ["a", "b"], in: smil), [
        ["OPS/audio/book.mp3 0.0-25.0"],
        ["OPS/audio/book.mp3 25.0-50.0"]
    ])
    // With no heading at b, the two continuous clips play as one.
    try assertEqual(try testSections(ofFragments: ["a"], in: smil), [["OPS/audio/book.mp3 0.0-50.0"]])
}

test("DAISY section runs on into the next file until the next heading") {
    let smil = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="a1"><audio src="partA.mp3" clipBegin="0.0" clipEnd="20.0"/></par>
      <par id="b1"><audio src="partB.mp3" clipBegin="0.0" clipEnd="90.0"/></par>
    </seq></body></smil>
    """
    // A heading at b1 ends the first section with its own file's clip.
    try assertEqual(try testSections(ofFragments: ["a1", "b1"], in: smil), [
        ["OPS/partA.mp3 0.0-20.0"],
        ["OPS/partB.mp3 0.0-90.0"]
    ])
    // Without one, the first heading's narration continues into partB.
    try assertEqual(try testSections(ofFragments: ["a1"], in: smil), [
        ["OPS/partA.mp3 0.0-20.0", "OPS/partB.mp3 0.0-90.0"]
    ])
}

}
