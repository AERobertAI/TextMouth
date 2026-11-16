import AudioToolbox
import Foundation

/// A file's markers as Core Audio keeps them (`kAudioFilePropertyMarkerList`):
/// a WAVE or Broadcast Wave file's cue points with their adtl labels, an
/// AIFF file's MARK chunk, and a CAF file's mark chunk. The one helper both
/// ways (FMT17, FMT11): a book of one such file reads its chapters from it
/// when AVFoundation finds none (`FileChapterReaders`), and the audio editor
/// writes its chapters into it once a WAVE, AIFF, or CAF render is written.
///
/// Only files a reader may open are opened (`ImportAudioConverter.isNeverDecodedInApp`):
/// WAVE and AIFF, which TextMouth plays as they are, and TextMouth's own CAF
/// files. A CAF from outside is converted at import, and its markers reach
/// the converted file through `afinfo`, in a child process
/// (`AudioFileInfo.markers`). Opening a file for its markers reads its
/// chunks, not its samples: no decoder runs.
enum AudioMarkerList {
    /// One marker: its name and its place in sample frames.
    struct Marker: Equatable, Sendable {
        /// Its name; empty when it has none.
        let name: String
        /// Where it is, in sample frames from the file's start.
        let frame: Double
    }

    /// The extensions (lowercase) of the files whose markers are read and
    /// written here.
    static let fileExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "caf"]

    /// The most markers read from one file.
    static let maximumMarkers = 10_000

    /// Whether `url`'s extension, in any case, names a file whose markers are
    /// read and written here.
    static func mayHoldMarkers(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Reading

    /// The chapters the file at `url` marks: each marker at its frame's time
    /// in seconds, titled by its name, in the shape every chapter list read
    /// by hand takes (`NeroChapterReader.Chapter`). Empty when the file has no
    /// markers or cannot be read.
    static func chapters(at url: URL) -> [NeroChapterReader.Chapter] {
        guard let read = read(at: url), read.sampleRate > 0 else { return [] }
        return read.markers.map { NeroChapterReader.Chapter(title: $0.name, start: $0.frame / read.sampleRate) }
    }

    /// The markers of the file at `url`, in the file's order, with its sample
    /// rate, which their frames count in; nil for a file this helper never
    /// opens, or one Core Audio cannot open.
    static func read(at url: URL) -> (markers: [Marker], sampleRate: Double)? {
        guard mayHoldMarkers(url), !ImportAudioConverter.isNeverDecodedInApp(url) else { return nil }
        var file: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) // lint-ok: refused above unless WAVE, AIFF, or TextMouth's own CAF, and never Ogg
        guard status == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        guard let sampleRate = sampleRate(of: file) else { return nil }

        var size: UInt32 = 0
        guard AudioFileGetPropertyInfo(file, kAudioFilePropertyMarkerList, &size, nil) == noErr,
              Int(size) >= MemoryLayout<AudioFileMarkerList>.size else {
            return ([], sampleRate)
        }
        let allocated = Int(size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: allocated, alignment: MemoryLayout<AudioFileMarkerList>.alignment)
        defer { buffer.deallocate() }
        // Zeroed first, so a marker Core Audio left unwritten would have no
        // name to release and a frame of 0, never stray bytes.
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: allocated)
        var returned = size
        guard AudioFileGetProperty(file, kAudioFilePropertyMarkerList, &returned, buffer) == noErr else {
            return ([], sampleRate)
        }
        let list = buffer.assumingMemoryBound(to: AudioFileMarkerList.self).pointee
        // The markers follow the list's header, as many as the list says and
        // the bytes allocated hold: the size Core Audio gave for the list,
        // not the size it hands back, which for an AIFF file is 8 bytes short
        // of what it fills (a probe of November 15, 2026: three markers
        // filled whole, 120 of 128 bytes reported), and would lose the last.
        let start = MemoryLayout<AudioFileMarkerList>.offset(of: \AudioFileMarkerList.mMarkers) ?? 0
        let room = max(0, (allocated - start) / MemoryLayout<AudioFileMarker>.stride)
        let count = min(Int(list.mNumberMarkers), room)
        let markers = (buffer + start).bindMemory(to: AudioFileMarker.self, capacity: count)
        var read: [Marker] = []
        for index in 0..<count {
            let marker = markers[index]
            // Core Audio hands the names over retained: each is released here.
            let name = marker.mName?.takeRetainedValue() as String?
            if read.count < maximumMarkers, marker.mFramePosition.isFinite, marker.mFramePosition >= 0 {
                read.append(Marker(name: name ?? "", frame: marker.mFramePosition))
            }
        }
        return (read, sampleRate)
    }

    /// The sample rate of `file`'s audio; nil when it has none.
    private static func sampleRate(of file: AudioFileID) -> Double? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr,
              format.mSampleRate.isFinite, format.mSampleRate > 0 else { return nil }
        return format.mSampleRate
    }

    // MARK: - Writing

    /// Why markers could not be written.
    enum WriteError: Error, Equatable {
        /// The file is of a kind this helper never opens.
        case notMarkable
        /// Core Audio refused, with its status.
        case refused(OSStatus)
    }

    /// Writes `chapters` into the file at `url` as its markers, replacing any
    /// it had: each at its start, in sample frames at the file's own rate
    /// rounded to the nearest frame, named by its title. Core Audio writes a
    /// WAVE file's cue and adtl chunks, an AIFF file's MARK chunk, and a CAF
    /// file's mark chunk (verified in the research for FMT11), and the file
    /// is written when it is closed.
    /// - Throws: `WriteError.notMarkable` for a file this helper never
    ///   opens; `WriteError.refused` with Core Audio's status otherwise.
    static func write(_ chapters: [(title: String, start: TimeInterval)], to url: URL) throws {
        guard mayHoldMarkers(url), !ImportAudioConverter.isNeverDecodedInApp(url) else { throw WriteError.notMarkable }
        var file: AudioFileID?
        let opened = AudioFileOpenURL(url as CFURL, .readWritePermission, 0, &file) // lint-ok: refused above unless WAVE, AIFF, or TextMouth's own CAF, and never Ogg
        guard opened == noErr, let file else { throw WriteError.refused(opened) }
        let set = setMarkers(chapters, of: file)
        // Closing the file writes it, so a failure to close is a failure to
        // write.
        let closed = AudioFileClose(file)
        guard set == noErr else { throw WriteError.refused(set) }
        guard closed == noErr else { throw WriteError.refused(closed) }
    }

    /// Sets `chapters` as the open `file`'s marker list (see `write`), and
    /// gives Core Audio's status.
    private static func setMarkers(_ chapters: [(title: String, start: TimeInterval)], of file: AudioFileID) -> OSStatus {
        guard let sampleRate = sampleRate(of: file) else { return kAudioFileUnsupportedDataFormatError }
        let names = chapters.map { $0.title as CFString }
        let start = MemoryLayout<AudioFileMarkerList>.offset(of: \AudioFileMarkerList.mMarkers) ?? 0
        let size = start + max(1, chapters.count) * MemoryLayout<AudioFileMarker>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioFileMarkerList>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let list = buffer.assumingMemoryBound(to: AudioFileMarkerList.self)
        list.pointee.mSMPTE_TimeType = 0
        list.pointee.mNumberMarkers = UInt32(chapters.count)
        let markers = (buffer + start).bindMemory(to: AudioFileMarker.self, capacity: max(1, chapters.count))
        for (index, chapter) in chapters.enumerated() {
            var marker = AudioFileMarker()
            let frames = chapter.start.isFinite && chapter.start > 0 ? (chapter.start * sampleRate).rounded() : 0
            marker.mFramePosition = frames
            // The names stay alive in `names` until the property is set.
            marker.mName = Unmanaged.passUnretained(names[index])
            marker.mMarkerID = Int32(index + 1)
            markers[index] = marker
        }
        return withExtendedLifetime(names) {
            AudioFileSetProperty(file, kAudioFilePropertyMarkerList, UInt32(size), buffer)
        }
    }
}
