import Foundation

/// The sections cue sheets make of a book's audio (FMT24): a heading per
/// track, each a stretch of the files the sheets name, written as a
/// manifest's segments, so the book plays as a DAISY book's sections do
/// (`AudioBookParser.parseDirectory`).
///
/// A sheet's files are found as a playlist's are (FMT10,
/// `M3UPlaylist.resolve(inFolder:)`): only files inside the sheet's own
/// folder are used, and every name skipped is told with its reason. A name
/// that is not found there, lies outside the folder, or is not audio falls
/// back to an audio file of the same stem beside the sheet, since sheets
/// often name the .wav a ripper wrote, later compressed to .flac; and a
/// sheet of one file falls back to an audio file of the sheet's own stem
/// ("Album.cue" beside "Album.flac" naming "CDImage.wav").
///
/// A track begins at its `INDEX 01` and runs to the next track's, across the
/// end of its file when the next track begins in another; the last runs to
/// the end of the last file. The first track takes in everything before it,
/// so every moment of the audio is under a heading, as a file's own chapters
/// are (`NeroChapterReader.bookChapters(from:fileDuration:)`). A track that
/// does not begin after the track before it is passed over, as is one whose
/// file was skipped.
struct CueSheetArrangement: Equatable, Sendable {
    /// The names one sheet gave that are no file of the book, with why.
    struct SkippedNames: Equatable, Sendable {
        /// The sheet's file name, as a notice names it.
        let sheet: String
        /// Its names skipped, in its order.
        let entries: [M3UPlaylist.Skipped]
    }

    /// A sheet or label file of a folder or archive that arranges nothing,
    /// and why.
    struct UnusedSheet: Equatable, Sendable {
        /// The file's path from the folder.
        let name: String
        /// A cue sheet's, or an Audacity label file's.
        var kind: CueSheetWording.ListKind = .cueSheet
        let reason: CueSheetWording.UnusedReason
    }

    /// The book's title: the one every sheet used gives, or nil.
    var title: String?
    /// The book's author: the one every sheet used gives (its performer, or
    /// the performer all its tracks share), or nil.
    var author: String?
    /// The sections, in the order the book plays them, each clip naming its
    /// file by its path from the folder the arrangement was made in.
    var segments: [AudioSegment]
    /// The audio files the sheets' and label files' sections play, each
    /// once, in the order first played, with their paths from that folder (a
    /// folder's track that no list plays, a section of its own, is not one).
    var files: [M3UPlaylist.Track]
    /// The names each sheet used gave that are no file of the book, sheet by
    /// sheet; a sheet that skipped nothing is not listed.
    var skipped: [SkippedNames]
    /// The sheets of a folder or archive that arrange nothing, in the order
    /// found.
    var unusedSheets: [UnusedSheet]
    /// The sheets and label files whose sections are used, by their paths
    /// from the folder, in the order found.
    var usedLists: [String] = []

    /// Whether the sheets make any section at all.
    var arrangesAnything: Bool {
        !segments.isEmpty
    }

    /// What the import tells when the book's parse finds a section of these
    /// past its file's end after all, and the tracks import without them
    /// (`FileImportService.publishTracks`): that the headings of the lists
    /// used run past the end of the audio, then each list not used, with
    /// why.
    var noticeWithoutItsSections: String? {
        let sentences = (usedLists.isEmpty ? [] : [CueSheetWording.headingsDidNotFit(usedLists)])
            + unusedSheets.map { CueSheetWording.sheetUnused($0.name, kind: $0.kind, because: $0.reason) }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// What the import tells of the sheets: the names each sheet used
    /// skipped (`PlaylistImportWording.notice`, as a playlist's import tells
    /// its own, a name outside the folder "outside the cue sheet's folder"),
    /// then each sheet not used, with why; nil when there is nothing to
    /// tell. (A label file names no file, so only a cue sheet skips names.)
    var notice: String? {
        let list = CueSheetWording.ListKind.cueSheet.name
        let skippedNames = skipped.compactMap {
            PlaylistImportWording.notice(playlistName: $0.sheet, skipped: $0.entries, listedIn: list)
        }
        let sentences = skippedNames + unusedSheets.map { CueSheetWording.sheetUnused($0.name, kind: $0.kind, because: $0.reason) }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The manifest that arranges the book as these sections do, to be
    /// written at `location` in the book's audio folder (the folder the
    /// sections' paths are taken from), each clip's file spelled from the
    /// manifest's own folder, as every manifest spells its names.
    func manifest(at location: AudioManifestLocation) -> AudioManifest {
        var manifest = AudioManifest()
        manifest.title = title
        manifest.author = author
        manifest.segments = segments.map { segment in
            segment.mappingClips { clip in
                var named = clip
                named.file = location.name(ofTrackAt: clip.file)
                return named
            }
        }
        return manifest
    }

    // MARK: - A Book's Folder

    /// What measures the files a sheet's sections play: the length, in
    /// seconds, of each file it can measure, by the file's path. The import
    /// measures every file, never through Apple's decoders unless the book
    /// plays the file as it is (`FileImportService.measuredLengths(of:)`); a
    /// test passes its own.
    typealias Measure = (_ files: [M3UPlaylist.Track]) -> [String: TimeInterval]

    /// The files that give the audiobook folder `folder` its headings: its
    /// cue sheets (FMT24) and its Audacity label files (FMT06, a .txt file
    /// that holds labels and nothing else, `AudacityLabels.isLabelFile`), at
    /// any depth, found by the walk that finds its tracks
    /// (`AudioBookParser.regularFiles`), in Finder's order by their paths
    /// from it; none when it cannot be walked, which the tracks' own walk
    /// then reports. A .txt of anything else (a track's lyrics, a book's
    /// notes) is no such file.
    static func chapterLists(in folder: URL) -> [URL] {
        (try? AudioBookParser.regularFiles(in: folder) { file in
            CueSheet.isCueSheet(file) || isLabelFile(file)
        }) ?? []
    }

    /// Whether the file at `url` is an Audacity label file: a .txt file, in
    /// any case, that holds labels and nothing else.
    private static func isLabelFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == AudacityLabels.fileExtension && AudacityLabels.labels(inFileAt: url) != nil
    }

    /// How the cue sheets and label files in `folder`, a folder of tracks
    /// being imported (a ZIP's extraction or the copy of a folder), arrange
    /// it; nil when it holds neither.
    ///
    /// Each, in Finder's order, gives the sections of the files it names
    /// among the folder's tracks (`sections(of:at:base:allowed:)`), its
    /// files found inside its own folder; a label file names the one audio
    /// file it is paired with (`labelSheet(at:labels:base:tracks:)`). One is
    /// not used, and is named in `unusedSheets` with why, when it cannot be
    /// read, gives no section, or has a track or label that begins or ends
    /// past the end of its file as `measure` measures it
    /// (`fits(_:durations:)`), since the book's parse would refuse the whole
    /// book for it; the tracks it names then import as they would without
    /// it. One that plays a file an earlier one plays (a second copy of a
    /// sheet, a ripper's sheet for the same files, a label file beside a
    /// sheet) is passed over. When any gives sections, the book plays in its
    /// tracks' Finder order, as it would without them: each list's sections
    /// at the place of the first of its files, and each track none plays,
    /// whole, at its own place, a section titled by its file's name, as the
    /// track would be, so no audio is left out of the book and none moves.
    /// The title and the author are those every sheet used agrees on.
    static func arranging(folder: URL, measure: Measure) -> CueSheetArrangement? {
        let listURLs = chapterLists(in: folder)
        guard !listURLs.isEmpty else { return nil }
        let tracks = (try? AudioBookParser.trackPaths(in: folder, scan: .importing)) ?? []
        let allowed = Set(tracks)

        // Each file's sections, then every file they play measured at once.
        let made: [(name: String, kind: CueSheetWording.ListKind, sections: SheetSections?)] = listURLs.map { url in
            let name = AudioBookParser.relativeName(of: url, in: folder)
            guard !CueSheet.isCueSheet(url) else {
                guard let sheet = try? CueSheet.read(at: url) else { return (name, .cueSheet, nil) }
                return (name, .cueSheet, sections(of: sheet, at: url, base: folder, allowed: allowed))
            }
            guard let labels = AudacityLabels.labels(inFileAt: url) else { return (name, .labelFile, nil) }
            // A label file paired with no audio makes no section.
            let sheet = labelSheet(at: url, labels: labels, base: folder, tracks: tracks)
                ?? CueSheet(title: nil, performer: nil, files: [], tracks: [])
            return (name, .labelFile, sections(of: sheet, at: url, base: folder, allowed: allowed))
        }
        var everyFile: [M3UPlaylist.Track] = []
        var listed = Set<String>()
        for file in made.flatMap({ $0.sections?.files ?? [] }) where listed.insert(file.path).inserted {
            everyFile.append(file)
        }
        let durations = everyFile.isEmpty ? [:] : measure(everyFile)

        var arrangement = CueSheetArrangement(
            title: nil, author: nil, segments: [], files: [], skipped: [], unusedSheets: []
        )
        // The sections of each list used, and which of them plays each file.
        var used: [SheetSections] = []
        var listPlaying: [String: Int] = [:]
        for (name, kind, sheetSections) in made {
            guard let sheetSections else {
                arrangement.unusedSheets.append(UnusedSheet(name: name, kind: kind, reason: .unreadable))
                continue
            }
            guard !sheetSections.segments.isEmpty else {
                arrangement.unusedSheets.append(UnusedSheet(name: name, kind: kind, reason: .namesNoAudio))
                continue
            }
            guard fits(sheetSections.segments, durations: durations) else {
                arrangement.unusedSheets.append(UnusedSheet(name: name, kind: kind, reason: .timesPastAudio))
                continue
            }
            let files = sheetSections.files.map(\.path)
            guard files.allSatisfy({ listPlaying[$0] == nil }) else { continue }
            for file in files { listPlaying[file] = used.count }
            if !sheetSections.skipped.isEmpty {
                arrangement.skipped.append(SkippedNames(sheet: name, entries: sheetSections.skipped))
            }
            arrangement.usedLists.append(name)
            used.append(sheetSections)
        }
        guard !used.isEmpty else { return arrangement }
        // The tracks in Finder's order, each list's sections at the first of
        // its files, every track no list plays whole at its own.
        var placed = Set<Int>()
        for path in tracks {
            guard let list = listPlaying[path] else {
                arrangement.segments.append(AudioSegment(
                    title: AudioTrackPlan.fileTitle(of: path), file: path, startTime: 0, endTime: 0
                ))
                continue
            }
            guard placed.insert(list).inserted else { continue }
            arrangement.segments += used[list].segments
            arrangement.files += used[list].files
        }
        // Every list's files are among the tracks, so each was placed; one
        // that somehow was not follows, so none of its audio is lost.
        for (list, sections) in used.enumerated() where !placed.contains(list) {
            arrangement.segments += sections.segments
            arrangement.files += sections.files
        }
        arrangement.title = agreed(used.map(\.title))
        arrangement.author = agreed(used.map(\.author))
        return arrangement
    }

    /// The sections the one sheet at `sheetURL` makes of the files it names
    /// inside its own folder, the paths taken from that folder: what a sheet
    /// chosen on its own imports (`FileImportService.importCueSheetWithReport`),
    /// with no other track of the folder.
    /// - Throws: what reading the sheet throws (`CueSheet.read(at:)`);
    ///   `CueSheetError.noTracks` for a sheet that places no audio track;
    ///   `CueSheetError.noAudio` naming the names skipped when none is a
    ///   file TextMouth can import, as a playlist's import refuses one;
    ///   and `CueSheetError.timesPastAudio` when a track runs past the end
    ///   of its file as `measure` measures it.
    static func arranging(sheetAt sheetURL: URL, measure: Measure) throws -> CueSheetArrangement {
        let sheet = try CueSheet.read(at: sheetURL)
        guard !sheet.tracks.isEmpty else { throw CueSheetError.noTracks }
        let made = sections(of: sheet, at: sheetURL, base: sheetURL.deletingLastPathComponent())
        guard !made.segments.isEmpty else { throw CueSheetError.noAudio(skipped: made.skipped) }
        guard fits(made.segments, durations: measure(made.files)) else { throw CueSheetError.timesPastAudio }
        return CueSheetArrangement(
            title: made.title,
            author: made.author,
            segments: made.segments,
            files: made.files,
            skipped: made.skipped.isEmpty ? [] : [SkippedNames(sheet: sheetURL.lastPathComponent, entries: made.skipped)],
            unusedSheets: [],
            usedLists: [sheetURL.lastPathComponent]
        )
    }

    /// Whether every clip of `segments` fits its file as the book's parse
    /// bounds it (`AudioBookParser.parseDirectory`): it begins before the
    /// file's end, and any end it gives (other than 0, the file's end) lies
    /// within the file and the parse's tolerance for encoder padding
    /// (`AudioBookParser.endTolerance(forFileLasting:)`). `durations` gives
    /// the files measured, by path; a file not measured is taken to fit, and
    /// the parse checks it.
    static func fits(_ segments: [AudioSegment], durations: [String: TimeInterval]) -> Bool {
        segments.flatMap(\.clips).allSatisfy { clip in
            guard let duration = durations[clip.file] else { return true }
            return clip.startTime < duration
                && (clip.endTime == 0 || clip.endTime <= duration + AudioBookParser.endTolerance(forFileLasting: duration))
        }
    }

    // MARK: - An Audacity Label File (FMT06)

    /// The labels of the Audacity label file at `url` as a sheet of one
    /// file, for its folder to be arranged as a cue sheet arranges it: the
    /// audio file beside it (among `tracks`, paths from `base`) of the label
    /// file's own stem, in any letter case, or, without one, the only audio
    /// file beside it. Each label is a track beginning at its start, to the
    /// nearest frame of 1/75 second, a CUE sheet's unit (6.7 milliseconds at
    /// most from the label's time), titled by its text, or "Label N" without
    /// one (`CueSheetWording.untitledLabel`), N its place in the file; the
    /// labels are taken in the order of their starts, a region's end making
    /// no heading of its own. Nil when no audio file is paired with it.
    static func labelSheet(at url: URL, labels: [AudacityLabels.Label], base: URL, tracks: [String]) -> CueSheet? {
        let prefix = relativePrefix(of: url.deletingLastPathComponent(), in: base)
        // The tracks lying in the label file's own folder, by their names
        // there.
        let beside = tracks.compactMap { path -> String? in
            guard path.hasPrefix(prefix) else { return nil }
            let name = String(path.dropFirst(prefix.count))
            return name.contains("/") ? nil : name
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let sameStem = beside.first {
            ($0 as NSString).deletingPathExtension.caseInsensitiveCompare(stem) == .orderedSame
        }
        guard let audio = sameStem ?? (beside.count == 1 ? beside.first : nil) else { return nil }
        let ordered = labels.enumerated().sortedStably { $0.element.start < $1.element.start }
        let sheetTracks = ordered.map { place, label in
            CueSheet.Track(
                number: place + 1,
                title: label.text.nonBlank ?? CueSheetWording.untitledLabel(number: place + 1),
                performer: nil,
                fileIndex: 0,
                startFrame: CueSheet.frames(ofSeconds: label.start)
            )
        }
        return CueSheet(title: nil, performer: nil, files: [audio], tracks: sheetTracks)
    }

    /// The one value every entry of `values` is, or nil when any is nil or
    /// two differ.
    private static func agreed(_ values: [String?]) -> String? {
        guard let first = values.first ?? nil, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    // MARK: - One Sheet

    /// What one sheet makes: its sections, the files they play, and the
    /// names it skipped, with paths taken from a folder at or above it.
    struct SheetSections: Equatable, Sendable {
        var title: String?
        var author: String?
        var segments: [AudioSegment]
        var files: [M3UPlaylist.Track]
        var skipped: [M3UPlaylist.Skipped]
    }

    /// The sections `sheet`, read from the file at `sheetURL`, makes of the
    /// files it names, found inside its folder (see the type's description),
    /// with every path taken from `base`, the sheet's folder or a folder that
    /// holds it. With `allowed`, only files at those paths from `base` are
    /// used, and any other is skipped as not found: what a folder's import
    /// passes, so no file outside the book's tracks is ever named.
    static func sections(
        of sheet: CueSheet,
        at sheetURL: URL,
        base: URL,
        allowed: Set<String>? = nil
    ) -> SheetSections {
        let found = resolvedFiles(of: sheet, at: sheetURL)
        // The sheet's folder as seen from `base`: "" when they are the same.
        let prefix = relativePrefix(of: sheetURL.deletingLastPathComponent(), in: base)
        var skipped = found.skipped
        var paths: [String?] = []
        // Each found file by its path from `base`, the first name's for a
        // path two names found.
        var trackOfPath: [String: M3UPlaylist.Track] = [:]
        for (name, track) in zip(sheet.files, found.tracks) {
            guard let track else {
                paths.append(nil)
                continue
            }
            let path = prefix + track.path
            if let allowed, !allowed.contains(path) {
                skipped.append(M3UPlaylist.Skipped(location: name, reason: .missing))
                paths.append(nil)
                continue
            }
            paths.append(path)
            if trackOfPath[path] == nil {
                trackOfPath[path] = M3UPlaylist.Track(url: track.url, path: path, title: nil)
            }
        }
        let author = sheet.performer ?? sharedPerformer(of: sheet, playing: paths)
        let segments = sections(of: sheet, files: paths, author: author)
        // The files the sections play, in the order first played.
        var played: [M3UPlaylist.Track] = []
        var seen = Set<String>()
        for clip in segments.flatMap(\.clips) where seen.insert(clip.file).inserted {
            if let track = trackOfPath[clip.file] { played.append(track) }
        }
        return SheetSections(title: sheet.title, author: author, segments: segments, files: played, skipped: skipped)
    }

    /// The sections `sheet` makes when the file of its `FILE` line number `i`
    /// is `files[i]`, a path, or nil when that file was skipped; `author`
    /// is the book's, which a track's heading leaves out (see `heading`).
    static func sections(of sheet: CueSheet, files: [String?], author: String?) -> [AudioSegment] {
        /// The path of the file at `index`, when it was found.
        func path(_ index: Int) -> String? {
            files.indices.contains(index) ? files[index] : nil
        }
        // The tracks that can play: each in a file that was found, and each
        // beginning after the one before (in a later file, or later in the
        // same file).
        var placed: [CueSheet.Track] = []
        for track in sheet.tracks where path(track.fileIndex) != nil {
            if let last = placed.last,
               (track.fileIndex, track.startFrame) <= (last.fileIndex, last.startFrame) { continue }
            placed.append(track)
        }
        // The found files by their place, which every clip comes from.
        let foundFiles = files.indices.filter { files[$0] != nil }

        var segments: [AudioSegment] = []
        for (position, track) in placed.enumerated() {
            guard let file = path(track.fileIndex) else { continue }
            let next = placed.indices.contains(position + 1) ? placed[position + 1] : nil
            var clips: [AudioClip] = []
            // The first track takes in the whole files before its own, and
            // the start of its own.
            if position == 0 {
                for index in foundFiles where index < track.fileIndex {
                    if let earlier = path(index) { clips.append(AudioClip(file: earlier, startTime: 0, endTime: 0)) }
                }
            }
            let start = position == 0 ? 0 : track.startTime
            if let next, next.fileIndex == track.fileIndex {
                clips.append(AudioClip(file: file, startTime: start, endTime: next.startTime))
            } else {
                // To the end of its file, then every found file before the
                // next track's (or, for the last track, every one after), and
                // the next track's file up to where that track begins.
                clips.append(AudioClip(file: file, startTime: start, endTime: 0))
                let stop = next?.fileIndex ?? files.count
                for index in foundFiles where index > track.fileIndex && index < stop {
                    if let between = path(index) { clips.append(AudioClip(file: between, startTime: 0, endTime: 0)) }
                }
                if let next, next.startFrame > 0, let nextFile = path(next.fileIndex) {
                    clips.append(AudioClip(file: nextFile, startTime: 0, endTime: next.startTime))
                }
            }
            if let segment = AudioSegment(title: heading(of: track, author: author), clips: clips) {
                segments.append(segment)
            }
        }
        return segments
    }

    /// The heading `track` gets: its title, or "Track N" without one
    /// (`CueSheetWording.untitledTrack`), followed by its own performer when
    /// that is not the book's author (`author`), as a compilation names each
    /// track's singer (`CueSheetWording.trackHeading`).
    static func heading(of track: CueSheet.Track, author: String?) -> String {
        let title = track.title ?? CueSheetWording.untitledTrack(number: track.number)
        guard let performer = track.performer, !samePerson(performer, author) else { return title }
        return CueSheetWording.trackHeading(title: title, performer: performer)
    }

    /// Whether `performer` and `author` name the same person, as a sheet
    /// writes names: with no regard to letter case or the spaces around them.
    private static func samePerson(_ performer: String, _ author: String?) -> Bool {
        guard let author else { return false }
        let trimmed = { (name: String) in name.trimmingCharacters(in: .whitespaces) }
        return trimmed(performer).caseInsensitiveCompare(trimmed(author)) == .orderedSame
    }

    /// The performer every track of `sheet` in a found file (`paths`) gives,
    /// when they all give the same one; nil otherwise. A sheet that names no
    /// performer of its own often names one on each track.
    private static func sharedPerformer(of sheet: CueSheet, playing paths: [String?]) -> String? {
        let performers = sheet.tracks
            .filter { paths.indices.contains($0.fileIndex) && paths[$0.fileIndex] != nil }
            .map(\.performer)
        guard let first = performers.first ?? nil,
              performers.allSatisfy({ $0.map { samePerson($0, first) } ?? false }) else { return nil }
        return first
    }

    // MARK: - Finding a Sheet's Files

    /// What became of one name of a sheet.
    private enum Found {
        case track(M3UPlaylist.Track)
        case skipped(M3UPlaylist.SkipReason)
    }

    /// The reasons a name may fall back to a file of the same stem beside
    /// the sheet: it names nothing there, something outside the folder (an
    /// absolute path of the Mac it was made on, or a Windows drive), or a
    /// file that is not audio (a CD image's .bin, since converted).
    private static let fallbackReasons: Set<M3UPlaylist.SkipReason> = [.missing, .outsideFolder, .notAudio]

    /// Each file `sheet` (read from `sheetURL`) names, found inside the
    /// sheet's folder (see the type's description), in the order of
    /// `sheet.files`: the track, or nil for a name skipped, which `skipped`
    /// tells with its reason. A file found for an earlier name is skipped
    /// as listed before (the same name in another case included, which a
    /// Mac's disk takes for the same file).
    static func resolvedFiles(of sheet: CueSheet, at sheetURL: URL) -> (tracks: [M3UPlaylist.Track?], skipped: [M3UPlaylist.Skipped]) {
        let folder = sheetURL.deletingLastPathComponent()
        var tracks: [M3UPlaylist.Track?] = []
        var skipped: [M3UPlaylist.Skipped] = []
        var seen = Set<String>()
        // The names at the top of the sheet's folder, listed once for the
        // whole sheet, when a name first falls back to one of them.
        var listed: [String]?
        func namesBeside() -> [String] {
            if let listed { return listed }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            listed = names
            return names
        }
        for name in sheet.files {
            let found = find(
                name, beside: sheetURL, inFolder: folder, sheetNamesOneFile: sheet.files.count == 1, namesBeside: namesBeside
            )
            switch found {
            case .track(let track):
                if seen.insert(track.path.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                    tracks.append(track)
                } else {
                    tracks.append(nil)
                    skipped.append(M3UPlaylist.Skipped(location: name, reason: .listedBefore))
                }
            case .skipped(let reason):
                tracks.append(nil)
                skipped.append(M3UPlaylist.Skipped(location: name, reason: reason))
            }
        }
        return (tracks, skipped)
    }

    /// The file `name` names for the sheet at `sheetURL` in `folder`, or why
    /// none is used, with the fallbacks the type describes, looked for among
    /// `namesBeside()`, the names at the folder's top.
    private static func find(
        _ name: String,
        beside sheetURL: URL,
        inFolder folder: URL,
        sheetNamesOneFile: Bool,
        namesBeside: () -> [String]
    ) -> Found {
        let direct = resolve(name, inFolder: folder)
        guard case .skipped(let reason) = direct, fallbackReasons.contains(reason) else { return direct }
        // The name's own stem, from its last path part, a Windows path's too.
        let lastPart = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        var stems = [(lastPart as NSString).deletingPathExtension]
        if sheetNamesOneFile {
            stems.append(sheetURL.deletingPathExtension().lastPathComponent)
        }
        for stem in stems where !stem.isEmpty {
            if let track = firstAudioFile(withStem: stem, among: namesBeside(), inFolder: folder) {
                return .track(track)
            }
        }
        return direct
    }

    /// The one name `name` resolved inside `folder` by the playlist rules.
    private static func resolve(_ name: String, inFolder folder: URL) -> Found {
        let entry = M3UPlaylist.Entry(location: name, title: nil, line: 1)
        let resolution = M3UPlaylist(title: nil, entries: [entry], isStreaming: false).resolve(inFolder: folder)
        if let track = resolution.tracks.first { return .track(track) }
        return .skipped(resolution.skipped.first?.reason ?? .missing)
    }

    /// The first audio file of `names`, the names at the top of `folder`,
    /// in Finder's order, whose name without its extension is `stem`, in any
    /// letter case, that the playlist rules take; nil when there is none.
    private static func firstAudioFile(withStem stem: String, among names: [String], inFolder folder: URL) -> M3UPlaylist.Track? {
        let wanted = stem.precomposedStringWithCanonicalMapping
        let audio = Set(BookFormat.audio.fileExtensions)
        let candidates = names
            .filter { name in
                let file = name as NSString
                return audio.contains(file.pathExtension.lowercased())
                    && file.deletingPathExtension.precomposedStringWithCanonicalMapping
                        .caseInsensitiveCompare(wanted) == .orderedSame
            }
            .sortedStably { $0.localizedStandardCompare($1) == .orderedAscending }
        for candidate in candidates {
            if case .track(let track) = resolve(candidate, inFolder: folder) { return track }
        }
        return nil
    }

    /// The path from `base` to `folder`, ending in a slash ("Disc 1/"), or
    /// "" when `folder` is `base` itself or not inside it.
    private static func relativePrefix(of folder: URL, in base: URL) -> String {
        let folderParts = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let baseParts = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard folderParts.count > baseParts.count, folderParts.starts(with: baseParts) else { return "" }
        return folderParts.dropFirst(baseParts.count).joined(separator: "/") + "/"
    }
}
