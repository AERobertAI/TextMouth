import Foundation
import ZIPFoundation

#if canImport(TextMouth)
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

func testSegmentEndTime(
    for segmentClip: DAISYAudioClip,
    clips: [DAISYAudioClip],
    smilPath: String,
    nextClipAndPath: (clip: DAISYAudioClip, smilPath: String)?
) -> Double {
    DAISYAudioConverter.segmentEndTime(
        for: segmentClip,
        clips: clips,
        smilPath: smilPath,
        nextClipAndPath: nextClipAndPath
    )
}
#endif

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

// DAISY audio file detection
test("Fire Safety DAISY 2.02 has audio — optional") {
    let path = testFilePath("fire-safety-d202-audio.zip")
    guard FileManager.default.fileExists(atPath: path) else { return }
    let url = URL(fileURLWithPath: path)
    let archive = try Archive(url: url, accessMode: .read)
    let hasAudio = archive.contains { entry in
        let ext = (entry.path as NSString).pathExtension.lowercased()
        return ext == "mp3" || ext == "wav" || ext == "aac"
    }
    try assertTrue(hasAudio, "Fire Safety should contain audio files")
}

test("Are You Ready DAISY 3 has audio — optional") {
    let path = testFilePath("are-you-ready-d3-audio.zip")
    guard FileManager.default.fileExists(atPath: path) else { return }
    let url = URL(fileURLWithPath: path)
    let archive = try Archive(url: url, accessMode: .read)
    let hasAudio = archive.contains { entry in
        let ext = (entry.path as NSString).pathExtension.lowercased()
        return ext == "mp3" || ext == "wav" || ext == "aac"
    }
    try assertTrue(hasAudio, "Are You Ready should contain audio files")
}

test("Fire Safety SMIL files contain audio references — optional") {
    let path = testFilePath("fire-safety-d202-audio.zip")
    guard FileManager.default.fileExists(atPath: path) else { return }
    let url = URL(fileURLWithPath: path)
    let archive = try Archive(url: url, accessMode: .read)
    var foundAudioClips = false
    for entry in archive where entry.path.lowercased().hasSuffix(".smil") {
        var data = Data()
        _ = try archive.extract(entry) { chunk in data.append(chunk) }
        guard let smilXML = String(data: data, encoding: .utf8) else { continue }
        let clips = try parseDAISYAudioSMIL(smilXML)
        if !clips.isEmpty {
            foundAudioClips = true
            break
        }
    }
    try assertTrue(foundAudioClips, "Should find audio clips in SMIL files")
}

test("Text-only DAISY does not have audio") {
    let url = try requireFile("hyperion_daisy.zip")
    let archive = try Archive(url: url, accessMode: .read)
    let hasAudio = archive.contains { entry in
        let ext = (entry.path as NSString).pathExtension.lowercased()
        return ext == "mp3" || ext == "wav" || ext == "aac"
    }
    try assertTrue(!hasAudio, "Hyperion (text-only) should not have audio files")
}

test("DAISY audio boundary compares resolved paths, not basenames") {
    let smil = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="a"><audio src="dirA/shared.mp3" clipBegin="10.0" clipEnd="60.0"/></par>
      <par id="b"><audio src="dirB/shared.mp3" clipBegin="5.0" clipEnd="45.0"/></par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smil.data(using: .utf8)!, file: "test.smil")
    let clips = try parser.parse()
    let currentClip = parser.clip(forFragment: "a")!
    let nextClip = parser.clip(forFragment: "b")!

    let currentPath = testResolvedAudioPath(for: currentClip, smilPath: "OPS/nav.smil")
    let nextPath = testResolvedAudioPath(for: nextClip, smilPath: "OPS/nav.smil")
    try assertEqual((currentPath as NSString).lastPathComponent,
                    (nextPath as NSString).lastPathComponent,
                    "Basenames intentionally match")
    try assertTrue(currentPath != nextPath, "Resolved paths should distinguish directories")

    let endTime = testSegmentEndTime(
        for: currentClip,
        clips: clips,
        smilPath: "OPS/nav.smil",
        nextClipAndPath: (clip: nextClip, smilPath: "OPS/nav.smil")
    )

    try assertTrue(abs(endTime - 60.0) < 0.001,
                   "Different resolved audio files should not use next clip start as boundary")
    try assertTrue(endTime > currentClip.startTime, "Segment should not be truncated by basename collision")
}

test("DAISY audio boundary uses canonical same-file next clip") {
    let smil = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="a"><audio src="./audio/../audio/book.mp3" clipBegin="0.0" clipEnd="25.0"/></par>
      <par id="b"><audio src="audio/book.mp3" clipBegin="25.0" clipEnd="50.0"/></par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smil.data(using: .utf8)!, file: "test.smil")
    let clips = try parser.parse()
    let currentClip = parser.clip(forFragment: "a")!
    let nextClip = parser.clip(forFragment: "b")!

    let currentPath = testResolvedAudioPath(for: currentClip, smilPath: "OPS/nav.smil")
    let nextPath = testResolvedAudioPath(for: nextClip, smilPath: "OPS/nav.smil")
    try assertEqual(currentPath, nextPath, "Dot segments should canonicalize to the same package path")

    let endTime = testSegmentEndTime(
        for: currentClip,
        clips: clips,
        smilPath: "OPS/nav.smil",
        nextClipAndPath: (clip: nextClip, smilPath: "OPS/nav.smil")
    )

    try assertTrue(abs(endTime - 25.0) < 0.001,
                   "Same resolved audio file should end at the next segment start")
}

test("DAISY audio boundary defaults to current audio file last clip") {
    let smil = """
    <?xml version="1.0"?>
    <smil><body><seq>
      <par id="a1"><audio src="partA.mp3" clipBegin="0.0" clipEnd="20.0"/></par>
      <par id="b1"><audio src="partB.mp3" clipBegin="0.0" clipEnd="90.0"/></par>
    </seq></body></smil>
    """
    let parser = TestFragmentAwareSMILParser(data: smil.data(using: .utf8)!, file: "test.smil")
    let clips = try parser.parse()
    let currentClip = parser.clip(forFragment: "a1")!
    let nextClip = parser.clip(forFragment: "b1")!

    let endTime = testSegmentEndTime(
        for: currentClip,
        clips: clips,
        smilPath: "OPS/nav.smil",
        nextClipAndPath: (clip: nextClip, smilPath: "OPS/nav.smil")
    )

    try assertTrue(abs(endTime - 20.0) < 0.001,
                   "A segment should end at the current audio file's last clip, not the SMIL's last clip")
}

}

// MARK: - Test helpers

#if !canImport(TextMouth)

/// Parse a DAISY time string to seconds (test implementation)
func parseDAISYTimeString(_ timeStr: String) -> Double {
    var cleaned = timeStr.trimmingCharacters(in: .whitespaces)
    if cleaned.lowercased().hasPrefix("npt=") { cleaned = String(cleaned.dropFirst(4)) }
    if cleaned.lowercased().hasSuffix("s") { cleaned = String(cleaned.dropLast()) }
    if let seconds = Double(cleaned) { return seconds }
    let parts = cleaned.components(separatedBy: ":")
    if parts.count >= 2 {
        var hours: Double = 0, minutes: Double = 0, seconds: Double = 0
        if parts.count == 3 {
            hours = Double(parts[0]) ?? 0
            minutes = Double(parts[1]) ?? 0
            seconds = Double(parts[2]) ?? 0
        } else {
            minutes = Double(parts[0]) ?? 0
            seconds = Double(parts[1]) ?? 0
        }
        return hours * 3600 + minutes * 60 + seconds
    }
    return 0
}

/// Audio clip from SMIL (test version)
struct TestDAISYAudioClip {
    var file: String
    var startTime: Double
    var endTime: Double
}

/// Parse SMIL XML for audio clips (test implementation)
func parseDAISYAudioSMIL(_ xml: String) -> [TestDAISYAudioClip] {
    guard let data = xml.data(using: .utf8) else { return [] }
    let parser = TestDAISYAudioSMILParser(data: data)
    return parser.parse()
}

private class TestDAISYAudioSMILParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var clips: [TestDAISYAudioClip] = []

    init(data: Data) { self.data = data }

    func parse() -> [TestDAISYAudioClip] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return clips
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
        if local == "audio" {
            guard let src = attributes["src"], !src.isEmpty else { return }
            var startTime: Double = 0, endTime: Double = 0
            if let b = attributes["clipBegin"] { startTime = parseDAISYTimeString(b) }
            else if let b = attributes["clip-begin"] { startTime = parseDAISYTimeString(b) }
            if let e = attributes["clipEnd"] { endTime = parseDAISYTimeString(e) }
            else if let e = attributes["clip-end"] { endTime = parseDAISYTimeString(e) }
            clips.append(TestDAISYAudioClip(file: src, startTime: startTime, endTime: endTime))
        }
    }
}

/// Test-only AudioManifest (mirrors the app's struct)
struct TestAudioManifest: Codable {
    var title: String?
    var author: String?
    var chapters: [String: String]?
    var order: [String]?
    var segments: [TestAudioSegment]?
}

struct TestAudioSegment: Codable {
    var title: String
    var file: String
    var startTime: Double
    var endTime: Double
}

// MARK: - Fragment-Aware SMIL Parser (test version)

/// Audio clip with parent <par> ID for fragment lookup
struct TestFragmentAudioClip {
    var file: String
    var startTime: Double
    var endTime: Double
    var parID: String
}

/// Test version of the fragment-aware SMIL parser.
/// Mirrors DAISYAudioSMILParser from the production code: records the
/// enclosing <par>/<seq> ID on each audio clip so callers can look up
/// clips by SMIL fragment reference.
class TestFragmentAwareSMILParser: NSObject, XMLParserDelegate {
    private let data: Data
    private(set) var clips: [TestFragmentAudioClip] = []
    private var currentParID: String = ""

    init(data: Data) {
        self.data = data
        super.init()
    }

    @discardableResult
    func parse() -> [TestFragmentAudioClip] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
        return clips
    }

    /// Find the first clip whose parID matches the given fragment
    func clip(forFragment fragmentID: String) -> TestFragmentAudioClip? {
        guard !fragmentID.isEmpty else { return nil }
        return clips.first(where: { $0.parID == fragmentID })
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()

        if local == "par" || local == "seq" {
            if let id = attributes["id"], !id.isEmpty {
                currentParID = id
            }
        }

        if local == "audio" {
            guard let src = attributes["src"], !src.isEmpty else { return }
            var startTime: Double = 0, endTime: Double = 0
            if let b = attributes["clipBegin"] { startTime = parseDAISYTimeString(b) }
            else if let b = attributes["clip-begin"] { startTime = parseDAISYTimeString(b) }
            if let e = attributes["clipEnd"] { endTime = parseDAISYTimeString(e) }
            else if let e = attributes["clip-end"] { endTime = parseDAISYTimeString(e) }
            clips.append(TestFragmentAudioClip(
                file: src, startTime: startTime, endTime: endTime, parID: currentParID
            ))
        }
    }
}

func testResolvedAudioPath(for clip: TestFragmentAudioClip, smilPath: String) -> String {
    ParserUtilities.resolvedPackagePath(
        clip.file,
        relativeTo: smilPath,
        preserveFragment: false
    )
}

func testSegmentEndTime(
    for segmentClip: TestFragmentAudioClip,
    clips: [TestFragmentAudioClip],
    smilPath: String,
    nextClipAndPath: (clip: TestFragmentAudioClip, smilPath: String)?
) -> Double {
    let currentAudioPath = testResolvedAudioPath(for: segmentClip, smilPath: smilPath)
    let sameAudioClips = clips.filter {
        testResolvedAudioPath(for: $0, smilPath: smilPath) == currentAudioPath
    }

    var endTime = sameAudioClips.last?.endTime ?? segmentClip.endTime
    if let nextClipAndPath,
       testResolvedAudioPath(for: nextClipAndPath.clip, smilPath: nextClipAndPath.smilPath) == currentAudioPath {
        endTime = nextClipAndPath.clip.startTime
    }

    return endTime
}
#endif
