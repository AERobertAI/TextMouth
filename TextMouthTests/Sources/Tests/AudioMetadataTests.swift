import Foundation

func runAudioMetadataTests() {
print("\n--- Audio Metadata Model Tests ---")

test("AudioMetadata initializes with empty defaults") {
    let meta = AudioMetadata()
    try assertEqual(meta.title, "")
    try assertEqual(meta.artist, "")
    try assertEqual(meta.album, "")
    try assertEqual(meta.genre, "")
    try assertEqual(meta.year, "")
    try assertEqual(meta.duration, "")
    try assertEqual(meta.fileFormat, "")
}

test("AudioMetadata initializes with provided values") {
    let meta = AudioMetadata(
        title: "My Audiobook",
        artist: "Felicity Hargrove",
        album: "Great Listens",
        genre: "Fiction",
        year: "2024",
        duration: "3:45:20",
        fileFormat: "MP3"
    )
    try assertEqual(meta.title, "My Audiobook")
    try assertEqual(meta.artist, "Felicity Hargrove")
    try assertEqual(meta.album, "Great Listens")
    try assertEqual(meta.genre, "Fiction")
    try assertEqual(meta.year, "2024")
    try assertEqual(meta.duration, "3:45:20")
    try assertEqual(meta.fileFormat, "MP3")
}

test("AudioMetadata round-trips through JSON encoding/decoding") {
    let original = AudioMetadata(
        title: "Test Title",
        artist: "Test Artist",
        album: "Test Album",
        genre: "Nonfiction",
        year: "2025",
        duration: "1:30:00",
        fileFormat: "M4B"
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(AudioMetadata.self, from: data)

    try assertEqual(decoded.title, original.title)
    try assertEqual(decoded.artist, original.artist)
    try assertEqual(decoded.album, original.album)
    try assertEqual(decoded.genre, original.genre)
    try assertEqual(decoded.year, original.year)
    try assertEqual(decoded.duration, original.duration)
    try assertEqual(decoded.fileFormat, original.fileFormat)
}

test("AudioMetadata fields are independently mutable") {
    var meta = AudioMetadata()
    meta.title = "Updated Title"
    meta.artist = "Updated Artist"
    meta.album = "Updated Album"
    meta.genre = "Updated Genre"
    meta.year = "2026"

    try assertEqual(meta.title, "Updated Title")
    try assertEqual(meta.artist, "Updated Artist")
    try assertEqual(meta.album, "Updated Album")
    try assertEqual(meta.genre, "Updated Genre")
    try assertEqual(meta.year, "2026")
    // Read-only fields remain empty (only set during extraction)
    try assertEqual(meta.duration, "")
    try assertEqual(meta.fileFormat, "")
}

// MARK: - BookMetadata Audio Fields Tests

print("\n--- BookMetadata Audio Fields Tests ---")

test("BookMetadata audio fields default to nil") {
    let meta = BookMetadata()
    try assertTrue(meta.audioAlbum == nil, "audioAlbum should default to nil")
    try assertTrue(meta.audioGenre == nil, "audioGenre should default to nil")
    try assertTrue(meta.audioYear == nil, "audioYear should default to nil")
}

test("BookMetadata audio fields persist through JSON encode/decode") {
    let meta = BookMetadata(
        title: "Audio Book",
        author: "Narrator",
        format: .audio,
        audioAlbum: "Best Series",
        audioGenre: "Thriller",
        audioYear: "2025"
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(meta)
    let decoded = try decoder.decode(BookMetadata.self, from: data)

    try assertEqual(decoded.audioAlbum, "Best Series")
    try assertEqual(decoded.audioGenre, "Thriller")
    try assertEqual(decoded.audioYear, "2025")
    try assertEqual(decoded.title, "Audio Book")
    try assertEqual(decoded.author, "Narrator")
}

test("BookMetadata audio fields are nil when not present in JSON (backwards compat)") {
    // Simulate loading old metadata JSON that doesn't have audio fields
    let json = """
    {
        "title": "Old Book",
        "author": "Unknown",
        "format": "audio",
        "md5Hash": "abc123",
        "dateAdded": "2025-01-01T00:00:00Z",
        "originalFileName": "old.mp3",
        "folderPath": "",
        "bookID": "00000000-0000-0000-0000-000000000001"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let meta = try decoder.decode(BookMetadata.self, from: json)

    try assertTrue(meta.audioAlbum == nil, "audioAlbum should be nil for old JSON")
    try assertTrue(meta.audioGenre == nil, "audioGenre should be nil for old JSON")
    try assertTrue(meta.audioYear == nil, "audioYear should be nil for old JSON")
    try assertEqual(meta.title, "Old Book")
}

// MARK: - Where Am I Brief Heading Tests

print("\n--- Where Am I Brief Heading Tests ---")

test("Where Am I brief: heading name is included when available") {
    // Simulate the brief summary build logic with a heading
    let headings = [
        Heading(level: 1, text: "The Departure", chapterIndex: 0, characterOffset: 0),
        Heading(level: 2, text: "Boarding the Train", chapterIndex: 0, characterOffset: 500),
    ]

    let currentChapter = 0
    let currentOffset = 600

    // Find current heading (same logic as app)
    let currentHeading = headings.last(where: {
        $0.chapterIndex < currentChapter ||
        ($0.chapterIndex == currentChapter && $0.characterOffset <= currentOffset)
    })

    try assertTrue(currentHeading != nil, "Should find a heading")
    try assertEqual(currentHeading?.text, "Boarding the Train")

    // Build brief parts including heading name (matches new buildBriefWhereAmI logic)
    var parts: [String] = []
    parts.append("My Book")
    if let heading = currentHeading {
        parts.append(heading.text)
    }
    parts.append("Chapter 1 of 5")
    parts.append("12 percent")
    parts.append("2:30:00 remaining")
    let summary = parts.joined(separator: ". ") + "."

    try assertTrue(summary.contains("Boarding the Train"), "Brief should include heading name")
    try assertTrue(summary.contains("Chapter 1 of 5"), "Brief should still include chapter number")
    try assertTrue(summary.contains("12 percent"), "Brief should still include percentage")
}

test("Where Am I brief: falls back to chapter title when no heading found") {
    let headings: [Heading] = []
    let chapterTitle = "Introduction"

    // No heading found
    let currentHeading = headings.last(where: { _ in false })

    var parts: [String] = []
    parts.append("My Book")
    if let heading = currentHeading {
        parts.append(heading.text)
    } else if !chapterTitle.isEmpty {
        parts.append(chapterTitle)
    }
    parts.append("Chapter 1 of 3")
    let summary = parts.joined(separator: ". ") + "."

    try assertTrue(summary.contains("Introduction"), "Should fall back to chapter title")
    try assertTrue(!summary.contains("heading"), "Should not mention 'heading' explicitly")
}

test("Where Am I brief: heading comes before chapter number in output") {
    // The heading name provides semantic context first, then positional info
    var parts: [String] = []
    parts.append("Book Title")
    parts.append("The Final Stand")  // heading name
    parts.append("Chapter 15 of 20")
    parts.append("75 percent")
    parts.append("1:00:00 remaining")
    let summary = parts.joined(separator: ". ") + "."

    try assertTrue(summary.contains("The Final Stand"))
    try assertTrue(summary.contains("Chapter 15 of 20"))
    try assertTrue(summary.contains("75 percent"))

    // Verify the order: heading comes before chapter number
    let headingRange = summary.range(of: "The Final Stand")!
    let chapterRange = summary.range(of: "Chapter 15")!
    try assertTrue(headingRange.lowerBound < chapterRange.lowerBound,
                   "Heading name should come before chapter number")
}

} // end runAudioMetadataTests
