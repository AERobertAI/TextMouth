import Foundation

/// One stretch of one audio file, the unit a segmented audiobook's
/// sections are made of. A DAISY book's synchronization files list one per
/// phrase; the DAISY converter joins the phrases that follow one another in
/// a file, so a clip is usually all that a section plays of that file.
struct AudioClip: Codable, Hashable, Sendable {
    /// The audio file's path, relative to the book's audio folder.
    var file: String
    /// Where the clip starts in its file, in seconds.
    var startTime: Double
    /// Where the clip ends in its file, in seconds; 0 plays to the end of
    /// the file.
    var endTime: Double
}

/// A section of a segmented audiobook, such as a DAISY book's heading: its
/// title and the clips it plays, one after another. Most sections play one
/// stretch of one file. A section whose narration continues into other
/// files, or skips from place to place within one, plays several clips.
///
/// `file`, `startTime`, and `endTime` describe the first clip, as they
/// described a section's only clip before a section could hold several,
/// so code and manifests that know one clip per section keep working.
struct AudioSegment: Hashable, Sendable {
    /// The section's title, which its heading shows.
    var title: String
    /// The clips the section plays, in order. Never empty: every way of
    /// making a section gives it at least one clip, and none removes one.
    private(set) var clips: [AudioClip]

    /// A section that plays one clip: `file` from `startTime` to `endTime`
    /// seconds, where an end of 0 plays to the end of the file.
    init(title: String, file: String, startTime: Double, endTime: Double) {
        self.title = title
        clips = [AudioClip(file: file, startTime: startTime, endTime: endTime)]
    }

    /// A section that plays `clips` in order, or nil when there are none:
    /// a section always plays something.
    init?(title: String, clips: [AudioClip]) {
        guard !clips.isEmpty else { return nil }
        self.title = title
        self.clips = clips
    }

    /// The first clip's audio file, relative to the book's audio folder.
    var file: String { clips[0].file }

    /// Where the first clip starts in its file, in seconds.
    var startTime: Double { clips[0].startTime }

    /// Where the first clip ends in its file, in seconds; 0 plays to the
    /// end of the file.
    var endTime: Double { clips[0].endTime }

    /// This section with each clip replaced by what `transform` makes of
    /// it, in the same order. Every clip is kept, so the section still
    /// plays something.
    func mappingClips(_ transform: (AudioClip) throws -> AudioClip) rethrows -> AudioSegment {
        var mapped = self
        mapped.clips = try clips.map(transform)
        return mapped
    }
}

// MARK: - Coding

extension AudioSegment: Codable {
    /// The keys of a section in manifest.json.
    private enum CodingKeys: String, CodingKey {
        case title, file, startTime, endTime, clips
    }

    /// Read a section as manifest.json stores it. `clips`, when present
    /// and not empty, lists every clip. Otherwise `file`, `startTime`, and
    /// `endTime` give the only one, as in every manifest written before a
    /// section could hold several clips.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        if let listed = try container.decodeIfPresent([AudioClip].self, forKey: .clips), !listed.isEmpty {
            clips = listed
        } else {
            clips = [AudioClip(
                file: try container.decode(String.self, forKey: .file),
                startTime: try container.decode(Double.self, forKey: .startTime),
                endTime: try container.decode(Double.self, forKey: .endTime)
            )]
        }
    }

    /// Write a section for manifest.json: its first clip as `file`,
    /// `startTime`, and `endTime`, where every manifest has kept a
    /// section's clip, and, only for a section of several clips, every clip
    /// under `clips`. A one-clip section is therefore written exactly as it
    /// always was, and a reader that knows one clip per section still finds
    /// the first clip of every section.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(file, forKey: .file)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        if clips.count > 1 {
            try container.encode(clips, forKey: .clips)
        }
    }
}
