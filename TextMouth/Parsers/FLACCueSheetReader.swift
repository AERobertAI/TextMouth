import Foundation

/// Reads where the tracks of a CD rip kept as one FLAC file begin, from the
/// file's own bytes (FMT24): its CUESHEET metadata block, which AVFoundation
/// does not read (verified in the research), or, without one, a cue sheet's
/// text kept in its CUESHEET comment, as some rippers embed the sheet.
/// AVFoundation reads a FLAC file's CHAPTER comments, which always win; this
/// reader is asked only when it finds none (`FileChapterReaders`).
///
/// The block (FLAC's format specification, METADATA_BLOCK_CUESHEET) lists
/// each track's offset in samples from the stream's start, its number, its
/// type (audio or data), and its index points, each an offset in samples
/// from the track's own; the last track is the lead-out (number 170 on a CD,
/// 255 otherwise), which ends the disc and is no track. A track begins at
/// its index point 1, as a text sheet's track begins at its INDEX 01, the
/// pregap of index point 0 belonging to the track before. The block holds no
/// titles: a track is titled from the embedded sheet's TITLE of the same
/// number when there is one, and "Track N" otherwise.
///
/// No Apple audio API is used: the metadata blocks are walked by their
/// headers on a `FileHandle`, never reading the audio, and only the blocks
/// wanted are read, each bounded, as `NeroChapterReader` reads an MPEG-4
/// file's atom. Whatever the bytes are, nothing here traps or loops without a
/// bound; a malformed file has no chapters.
enum FLACCueSheetReader {
    /// Where one audio track of the block begins.
    struct TrackStart: Equatable, Sendable {
        /// The track's number, as the block gives it.
        let number: Int
        /// Where it begins, in samples from the stream's start.
        let sample: UInt64
    }

    /// What a FLAC file's own metadata says of its tracks.
    struct Tracks: Equatable, Sendable {
        /// The stream's sample rate, from STREAMINFO.
        let sampleRate: Int
        /// Each audio track's start, in the block's order; none without a
        /// CUESHEET block.
        let starts: [TrackStart]
        /// The cue sheet kept in the file's CUESHEET comment, if any.
        let embeddedSheet: CueSheet?
    }

    // MARK: - Limits

    /// The most metadata blocks walked before the audio.
    static let maxBlocks = 1_000
    /// The largest CUESHEET or VORBIS_COMMENT block read; a larger one (a
    /// comment block holding cover art) is passed over.
    static let maxBlockLength = 1_048_576
    /// The block types this reader reads.
    private enum BlockType {
        static let streamInfo: UInt8 = 0
        static let vorbisComment: UInt8 = 4
        static let cueSheet: UInt8 = 5
    }
    /// The bytes of the block's fixed part before its first track: the media
    /// catalog number (128), the lead-in (8), the CD flag and the reserved
    /// bits (259), and the track count (1).
    private static let cueSheetHeaderLength = 396
    /// A track's fixed part: offset (8), number (1), ISRC (12), flags and
    /// reserved bits (14), and the index point count (1).
    private static let trackLength = 36
    /// One index point: offset (8), number (1), and reserved bytes (3).
    private static let indexPointLength = 12

    // MARK: - Reading a file

    /// Whether `url`'s extension (in any case) names a FLAC file.
    static func mayHoldCueSheet(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "flac"
    }

    /// The chapters the FLAC file at `url` keeps in its cue sheet, in the
    /// shape every chapter list read by hand takes (`NeroChapterReader.Chapter`):
    /// each audio track's start in seconds and its title. Empty when the file
    /// has neither a CUESHEET block nor a CUESHEET comment with a track, or
    /// cannot be read.
    static func chapters(at url: URL) -> [NeroChapterReader.Chapter] {
        guard let tracks = read(at: url) else { return [] }
        return chapters(of: tracks)
    }

    /// The chapters `tracks` gives: the block's tracks, titled from the
    /// embedded sheet, or, without a block, the embedded sheet's own tracks.
    static func chapters(of tracks: Tracks) -> [NeroChapterReader.Chapter] {
        let sheetTracks = tracks.embeddedSheet?.tracks ?? []
        guard !tracks.starts.isEmpty else {
            return sheetTracks.map { track in
                NeroChapterReader.Chapter(
                    title: track.title ?? CueSheetWording.untitledTrack(number: track.number),
                    start: track.startTime
                )
            }
        }
        guard tracks.sampleRate > 0 else { return [] }
        return tracks.starts.map { start in
            let title = sheetTracks.first { $0.number == start.number }?.title
            return NeroChapterReader.Chapter(
                title: title ?? CueSheetWording.untitledTrack(number: start.number),
                start: Double(start.sample) / Double(tracks.sampleRate)
            )
        }
    }

    /// The sample rate and the tracks of the FLAC file at `url`; nil when it
    /// is not a FLAC file (an ID3v2 tag before its "fLaC" is passed over, as
    /// some taggers write one) or its metadata cannot be walked.
    static func read(at url: URL) -> Tracks? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileEnd = try? handle.seekToEnd() else { return nil }
        guard var position = flacStart(handle: handle, fileEnd: fileEnd) else { return nil }

        var sampleRate: Int?
        var starts: [TrackStart] = []
        var embeddedSheet: CueSheet?
        for _ in 0..<maxBlocks {
            guard let header = bytes(handle: handle, at: position, count: 4) else { return nil }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let body = position + 4
            // A block that runs past the file's end stops the walk.
            guard body + UInt64(length) <= fileEnd else { return nil }
            switch type {
            case BlockType.streamInfo:
                if let info = bytes(handle: handle, at: body, count: min(length, 34)) {
                    sampleRate = streamInfoSampleRate(info)
                }
            case BlockType.cueSheet where length <= maxBlockLength:
                if let block = bytes(handle: handle, at: body, count: length) {
                    starts = trackStarts(inCueSheetBlock: block)
                }
            case BlockType.vorbisComment where length <= maxBlockLength:
                if let block = bytes(handle: handle, at: body, count: length),
                   let text = cueSheetComment(inVorbisCommentBlock: block) {
                    embeddedSheet = CueSheet.parse(text)
                }
            default:
                break
            }
            position = body + UInt64(length)
            if isLast { break }
        }
        guard let sampleRate else { return nil }
        return Tracks(sampleRate: sampleRate, starts: starts, embeddedSheet: embeddedSheet)
    }

    /// Where the first metadata block of the FLAC stream in `handle` begins:
    /// just past "fLaC" at the file's start, or past an ID3v2 tag first;
    /// nil when there is no "fLaC" there.
    private static func flacStart(handle: FileHandle, fileEnd: UInt64) -> UInt64? {
        guard let first = bytes(handle: handle, at: 0, count: 10) else { return nil }
        var start: UInt64 = 0
        if Array(first[0..<3]) == Array("ID3".utf8) {
            // The tag's size, after its 10-byte header, in four 7-bit bytes
            // (a "syncsafe" integer), and a 10-byte footer when flag 0x10 is set.
            let size = first[6..<10].reduce(UInt64(0)) { $0 << 7 | UInt64($1 & 0x7F) }
            start = 10 + size + (first[5] & 0x10 != 0 ? 10 : 0)
        }
        guard start + 4 <= fileEnd, let marker = bytes(handle: handle, at: start, count: 4),
              marker == Array("fLaC".utf8) else { return nil }
        return start + 4
    }

    // MARK: - Reading the blocks

    /// The sample rate a STREAMINFO block's bytes give: 20 bits from its
    /// byte 10; nil for a block too short or a rate of 0.
    static func streamInfoSampleRate(_ info: [UInt8]) -> Int? {
        guard info.count >= 13 else { return nil }
        let rate = Int(info[10]) << 12 | Int(info[11]) << 4 | Int(info[12] >> 4)
        return rate > 0 ? rate : nil
    }

    /// Each audio track's number and start, in samples from the stream's
    /// start, that a CUESHEET block's bytes list, in their order: the
    /// track's offset plus its index point 1's (its own offset when it has
    /// none). Data tracks and the lead-out are left out. A block that ends
    /// partway keeps the tracks read whole before the break.
    static func trackStarts(inCueSheetBlock block: [UInt8]) -> [TrackStart] {
        guard block.count >= cueSheetHeaderLength else { return [] }
        let count = Int(block[cueSheetHeaderLength - 1])
        var position = cueSheetHeaderLength
        var starts: [TrackStart] = []
        for _ in 0..<count {
            guard block.count - position >= trackLength else { break }
            let offset = bigEndian64(block, at: position)
            let number = Int(block[position + 8])
            let isAudio = block[position + 21] & 0x80 == 0
            let points = Int(block[position + 35])
            position += trackLength
            guard block.count - position >= points * indexPointLength else { break }
            var indexOne: UInt64?
            for point in 0..<points {
                let start = position + point * indexPointLength
                if block[start + 8] == 1, indexOne == nil { indexOne = bigEndian64(block, at: start) }
            }
            position += points * indexPointLength
            // The lead-out (170 on a CD, 255 otherwise) ends the disc.
            guard isAudio, number != 170, number != 255 else { continue }
            // An offset near the top of the range would overflow when added.
            let (sample, overflow) = offset.addingReportingOverflow(indexOne ?? 0)
            if !overflow { starts.append(TrackStart(number: number, sample: sample)) }
        }
        return starts
    }

    /// The text of the CUESHEET comment a VORBIS_COMMENT block's bytes hold
    /// (its name in any letter case), or nil: the vendor string, then the
    /// comment count, then each comment's length and `NAME=value`, every
    /// number little-endian, as Vorbis comments are in FLAC.
    static func cueSheetComment(inVorbisCommentBlock block: [UInt8]) -> String? {
        /// The length-prefixed field at `index` and the index after it.
        func field(at index: Int) -> (bytes: ArraySlice<UInt8>, next: Int)? {
            guard index >= 0, block.count - index >= 4 else { return nil }
            let length = Int(littleEndian32(block, at: index))
            let start = index + 4
            guard length <= block.count - start else { return nil }
            return (block[start..<(start + length)], start + length)
        }
        guard let vendor = field(at: 0), block.count - vendor.next >= 4 else { return nil }
        let count = Int(littleEndian32(block, at: vendor.next))
        var index = vendor.next + 4
        let name = "CUESHEET="
        for _ in 0..<min(count, 10_000) {
            guard let comment = field(at: index) else { return nil }
            index = comment.next
            // A comment's name is ASCII, matched without regard to case.
            let prefix = String(decoding: comment.bytes.prefix(name.utf8.count), as: UTF8.self)
            guard prefix.uppercased() == name else { continue }
            return String(decoding: comment.bytes.dropFirst(name.utf8.count), as: UTF8.self)
        }
        return nil
    }

    // MARK: - Bytes

    /// Exactly `count` bytes at `offset`, or nil when the file gives fewer.
    private static func bytes(handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }

    /// The 64-bit big-endian value at `offset`; the caller has checked the bounds.
    private static func bigEndian64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The 32-bit little-endian value at `offset`; the caller has checked the bounds.
    private static func littleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}
