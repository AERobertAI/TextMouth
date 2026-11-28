import CryptoKit
import Foundation

/// A named filter chain the editor offers (FR04): one of TextMouth's premade
/// presets, edited or not, or one the user made, in ffmpeg's syntax
/// (`AudioFilterChain`), which serves TextMouth's own filters and ffmpeg
/// alike.
struct AudioFilterPreset: Codable, Equatable, Identifiable, Sendable {
    /// Its identity, kept through renames.
    var id: UUID
    /// Its name, as the editor lists it.
    var name: String
    /// Its chain.
    var chain: String

    /// What the editor shows and VoiceOver reads for the preset: a premade
    /// preset that still has its premade name is shown by its title in the
    /// interface language; every other preset by the name it was given. The
    /// `name` is what audio-filters.json keeps, so a file shared between
    /// Macs and languages never changes.
    var title: String {
        PremadeFilterPreset.allCases.first { $0.id == id && $0.englishName == name }?.title ?? name
    }
}

/// The presets TextMouth comes with (FR04): each one's stored English name,
/// its title in the interface language, and its chain. The stored name makes
/// the preset's identity (`id`), so it is the same on every Mac, in every
/// language, and after every reset.
enum PremadeFilterPreset: CaseIterable, Sendable {
    case removeRumble, clearerVoice, evenOutTheLevel, audiobookLoudness, shortenLongPauses
    case trimSilenceAtBothEnds, fadeIn, fadeOut, aLittleFaster, louder, quieter, reverse

    /// The name audio-filters.json keeps for the preset, and its identity's
    /// seed: never translated, so a saved file means the same everywhere.
    var englishName: String {
        switch self {
        case .removeRumble: return "Remove Rumble" // l10n: no (stored name; `title` is shown)
        case .clearerVoice: return "Clearer Voice" // l10n: no (stored name; `title` is shown)
        case .evenOutTheLevel: return "Even Out the Level" // l10n: no (stored name; `title` is shown)
        case .audiobookLoudness: return "Audiobook Loudness" // l10n: no (stored name; `title` is shown)
        case .shortenLongPauses: return "Shorten Long Pauses" // l10n: no (stored name; `title` is shown)
        case .trimSilenceAtBothEnds: return "Trim Silence at Both Ends" // l10n: no (stored name; `title` is shown)
        case .fadeIn: return "Fade In" // l10n: no (stored name; `title` is shown)
        case .fadeOut: return "Fade Out (Select the Last Second)" // l10n: no (stored name; `title` is shown)
        case .aLittleFaster: return "A Little Faster" // l10n: no (stored name; `title` is shown)
        case .louder: return "Louder" // l10n: no (stored name; `title` is shown)
        case .quieter: return "Quieter" // l10n: no (stored name; `title` is shown)
        case .reverse: return "Reverse" // l10n: no (stored name; `title` is shown)
        }
    }

    /// The preset's name in the interface language, as the editor lists it.
    var title: String {
        switch self {
        case .removeRumble:
            // Translators: Title of a premade audio filter preset: cuts the lowest rumble from a recording.
            return InterfaceText.line("premadeFilterPreset.title.removeRumble", "Remove Rumble")
        case .clearerVoice:
            // Translators: Title of a premade audio filter preset: cuts the rumble and lifts the voice's presence.
            return InterfaceText.line("premadeFilterPreset.title.clearerVoice", "Clearer Voice")
        case .evenOutTheLevel:
            // Translators: Title of a premade audio filter preset: compresses the audio so loud and quiet parts are closer in volume.
            return InterfaceText.line("premadeFilterPreset.title.evenOutTheLevel", "Even Out the Level")
        case .audiobookLoudness:
            // Translators: Title of a premade audio filter preset: sets the whole audio's loudness to a level for audiobooks.
            return InterfaceText.line("premadeFilterPreset.title.audiobookLoudness", "Audiobook Loudness")
        case .shortenLongPauses:
            // Translators: Title of a premade audio filter preset: makes every pause longer than a second one second long.
            return InterfaceText.line("premadeFilterPreset.title.shortenLongPauses", "Shorten Long Pauses")
        case .trimSilenceAtBothEnds:
            // Translators: Title of a premade audio filter preset: removes the silence at the start and at the end of the audio.
            return InterfaceText.line("premadeFilterPreset.title.trimSilenceAtBothEnds", "Trim Silence at Both Ends")
        case .fadeIn:
            // Translators: Title of a premade audio filter preset: fades the audio in over one second.
            return InterfaceText.line("premadeFilterPreset.title.fadeIn", "Fade In")
        case .fadeOut:
            // Translators: Title of a premade audio filter preset: fades out over one second, so it is used on a selection of the last second.
            return InterfaceText.line("premadeFilterPreset.title.fadeOut", "Fade Out (Select the Last Second)")
        case .aLittleFaster:
            // Translators: Title of a premade audio filter preset: plays the audio a quarter faster without raising its pitch.
            return InterfaceText.line("premadeFilterPreset.title.aLittleFaster", "A Little Faster")
        case .louder:
            // Translators: Title of a premade audio filter preset: raises the volume by 6 decibels.
            return InterfaceText.line("premadeFilterPreset.title.louder", "Louder")
        case .quieter:
            // Translators: Title of a premade audio filter preset: lowers the volume by 6 decibels.
            return InterfaceText.line("premadeFilterPreset.title.quieter", "Quieter")
        case .reverse:
            // Translators: Title of a premade audio filter preset: plays the audio backwards.
            return InterfaceText.line("premadeFilterPreset.title.reverse", "Reverse")
        }
    }

    /// The filter chain the preset runs, in ffmpeg's syntax.
    var chain: String {
        switch self {
        case .removeRumble: return "highpass=f=80"
        case .clearerVoice: return "highpass=f=80,equalizer=f=3000:t=q:w=1:g=3"
        case .evenOutTheLevel: return "acompressor=threshold=-20dB:ratio=3:attack=10:release=200:makeup=2"
        case .audiobookLoudness: return "loudnorm=I=-18:TP=-3"
        // Every pause longer than a second becomes a second long.
        case .shortenLongPauses: return "silenceremove=stop_periods=-1:stop_duration=1:stop_threshold=-50dB"
        case .trimSilenceAtBothEnds:
            return "silenceremove=start_periods=1:start_threshold=-50dB,areverse,"
                + "silenceremove=start_periods=1:start_threshold=-50dB,areverse"
        case .fadeIn: return "afade=t=in:d=1"
        case .fadeOut: return "afade=t=out:d=1"
        case .aLittleFaster: return "atempo=1.25"
        case .louder: return "volume=6dB"
        case .quieter: return "volume=-6dB"
        case .reverse: return "areverse"
        }
    }

    /// The preset's identity, made from its stored name, so it is the same
    /// on every Mac and after every reset.
    var id: UUID {
        let digest = Array(SHA256.hash(data: Data("TextMouth premade filter: \(englishName)".utf8))) // l10n: no (the seed of a stored identity)
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// The preset as the file keeps it: its stored name, and its chain.
    var preset: AudioFilterPreset {
        AudioFilterPreset(id: id, name: englishName, chain: chain)
    }
}

/// The filter presets (FR04), kept in audio-filters.json in the data
/// directory, so another Mac sharing the library has the same ones, and
/// shown like the substitution rules: premade entries the user can edit,
/// remove, reorder, add to, and reset.
///
/// The file is read and written as substitutions.json is: with no file, as
/// at first, the premade presets stand in, unsaved, until a change copies
/// them into it; a file that can't be read or decoded is preserved beside
/// itself (`SavedFile.preserveUnusable`) and the premade presets stand in;
/// a file only in the cloud is never read, which would download it, nor
/// written over: the premade presets stand in, the sync service is asked
/// for it, and a save waits until it is on this Mac. One AUDIO_FILTERS_FILE
/// line in the debug log tells of each.
@MainActor
final class AudioFilterPresetLibrary: ObservableObject {
    /// The presets, in the order the editor lists them.
    @Published private(set) var presets: [AudioFilterPreset]
    /// Whether the presets stand in for a file that isn't there: the
    /// premade ones, unsaved.
    private(set) var standsInForMissingFile = false
    /// Whether the presets stand in for a file only in the cloud.
    private(set) var awaitsFileInCloud = false

    /// The file's name in the data directory.
    nonisolated static let fileName = "audio-filters.json"
    /// The tag of the debug log's lines about the file.
    nonisolated static let logTag = "AUDIO_FILTERS_FILE"

    /// The file a test chose, or nil for the data directory's own, which is
    /// looked up at each read and write: a Filter Presets pane stays open
    /// through a data-directory move, and its next save belongs in the
    /// library then in use, not in the one it began in.
    private let chosenURL: URL?
    /// How the file is read: without downloading it, unless a test stands
    /// in a reader of its own.
    private let reader: SavedFile.Reader

    /// The file, where the library lives now unless a test chose one.
    private var url: URL {
        chosenURL ?? TextMouthPaths.audioFiltersFile
    }

    /// The presets of the file at `url`, read at once through `reader`. With
    /// no `url`, the file is the data directory's own, wherever the data
    /// directory is when it is read or written.
    init(url: URL? = nil, reader: @escaping SavedFile.Reader = SavedFile.readWithoutDownloading) {
        self.chosenURL = url
        self.reader = reader
        presets = Self.standard
        load()
    }

    // MARK: The Premade Presets

    /// The presets TextMouth comes with, each made of filters its own engine
    /// runs, so they work without ffmpeg, and do the same through it, but
    /// for loudnorm: ffmpeg runs it in one pass, changing its gain as it
    /// goes, where TextMouth applies the one gain that reaches the target.
    /// Silence is trimmed at the end by reversing the sound: ffmpeg's
    /// silenceremove stops at the first silence after the start, not at the
    /// end, when told to stop once (stop_periods=1).
    nonisolated static let standard: [AudioFilterPreset] = PremadeFilterPreset.allCases.map(\.preset)

    // MARK: Changing

    /// Adds a preset named `name` running `chain`, at the end, and saves.
    /// - Throws: `AudioFilterPresetError` for a blank name or chain, or the
    ///   save's error.
    @discardableResult
    func add(name: String, chain: String) throws -> AudioFilterPreset {
        let preset = AudioFilterPreset(id: UUID(), name: try Self.checkedName(name), chain: try Self.checkedChain(chain))
        try change { $0.append(preset) }
        return preset
    }

    /// Puts `preset` in place of the preset of the same identity, and saves.
    func update(_ preset: AudioFilterPreset) throws {
        let name = Self.storedName(of: preset, checking: try Self.checkedName(preset.name))
        let checked = AudioFilterPreset(id: preset.id, name: name, chain: try Self.checkedChain(preset.chain))
        try change { presets in
            guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
            presets[index] = checked
        }
    }

    /// Removes the preset `id`, and saves.
    func remove(_ id: UUID) throws {
        try change { $0.removeAll { $0.id == id } }
    }

    /// Moves the preset `id` one place in `direction`, as the substitution
    /// rules move, and saves; nothing at either end.
    func move(_ id: UUID, _ direction: SubstitutionRuleMoveDirection) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              let destination = direction.destination(from: index, count: presets.count) else { return }
        try change { $0.swapAt(index, destination) }
    }

    /// Puts the premade presets back, and saves.
    func resetToDefaults() throws {
        try change { $0 = Self.standard }
    }

    /// Makes `edit` to the presets and saves them.
    private func change(_ edit: (inout [AudioFilterPreset]) -> Void) throws {
        var edited = presets
        edit(&edited)
        try save(edited)
    }

    /// `name` trimmed, or the error refusing a blank one.
    private static func checkedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioFilterPresetError.blankName }
        return trimmed
    }

    /// The name to keep for `preset` when its name field held `typed`: a
    /// premade preset edited under the title it was shown by keeps its
    /// stored English name, so the file doesn't change with the language;
    /// any other name is kept as typed.
    private static func storedName(of preset: AudioFilterPreset, checking typed: String) -> String {
        guard let premade = PremadeFilterPreset.allCases.first(where: { $0.id == preset.id }),
              typed == premade.title else { return typed }
        return premade.englishName
    }

    /// `chain` trimmed, or the error refusing a blank one. Its filters are
    /// checked where it runs, by the engine running it: ffmpeg has filters
    /// TextMouth's own engine doesn't.
    private static func checkedChain(_ chain: String) throws -> String {
        let trimmed = chain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioFilterError.empty }
        return trimmed
    }

    // MARK: The File

    /// How the file is laid out: its version, then the presets in order.
    private struct File: Codable {
        var version: Int
        var presets: [AudioFilterPreset]
    }

    /// The layout this version writes.
    private static let currentVersion = 1

    /// Reads the file into `presets`, as the type describes.
    func load() {
        guard !TextMouthPaths.isDataDirectoryUnavailable else {
            presets = Self.standard
            standsInForMissingFile = false
            return
        }
        takeUp(SavedFile.read(url, using: reader))
    }

    /// Takes up what a read of the file found.
    private func takeUp(_ read: SavedFile.Read) {
        let wasAwaitingCloud = awaitsFileInCloud
        standsInForMissingFile = false
        awaitsFileInCloud = false
        switch read {
        case .missing:
            presets = Self.standard
            standsInForMissingFile = true
        case .contents(let bytes):
            do {
                presets = try JSONDecoder().decode(File.self, from: bytes).presets
            } catch {
                standIn(bytes: bytes, because: TranscriptStore.describe(error))
            }
        case .unreadable(let reason):
            standIn(bytes: nil, because: reason)
        case .inCloud:
            presets = Self.standard
            awaitsFileInCloud = true
            guard !wasAwaitingCloud else { return }
            SavedFile.requestDownload(of: url)
            DiagnosticLog.event(
                .storage,
                "\(Self.logTag): \(url.lastPathComponent) is only in the cloud, so it was not read; "
                    + "asked the sync service for it, and the premade presets stand in until it is on this Mac"
            )
        }
    }

    /// Preserves the unusable file and puts the premade presets in its place.
    private func standIn(bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            url,
            bytes: bytes,
            because: reason,
            logging: Self.logTag,
            in: .storage,
            standIn: "the premade presets stand in" // l10n: no (a log line)
        )
        presets = Self.standard
    }

    /// Writes `edited` to the file and makes them the presets. A file that
    /// arrived since the premade presets stood in for a missing one is taken
    /// up instead, dropping the change, as substitutions.json's is: it holds
    /// the presets made on another Mac.
    /// - Throws: `SavedFile.InCloudError` while the file is only in the
    ///   cloud, with nothing written over it; `AudioFilterPresetError.libraryUnavailable`
    ///   while the data directory can't be used; or the write's error.
    private func save(_ edited: [AudioFilterPreset]) throws {
        guard !TextMouthPaths.isDataDirectoryUnavailable else { throw AudioFilterPresetError.libraryUnavailable }
        if awaitsFileInCloud || standsInForMissingFile {
            let read = SavedFile.read(url, using: reader)
            switch read {
            case .inCloud:
                takeUp(read)
                throw SavedFile.InCloudError(fileName: url.lastPathComponent)
            case .contents, .unreadable:
                takeUp(read)
                throw AudioFilterPresetError.fileArrived
            case .missing:
                break
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(File(version: Self.currentVersion, presets: edited))
        try Self.write(bytes, to: url)
        presets = edited
        standsInForMissingFile = false
        // A save made while a data-directory move copies the library lands in
        // the folder being copied, which the copy may have passed (a first
        // save, which has no file to be copied, is missed whole). The move
        // writes these bytes again once it has ended, in the library then in
        // use, as it does for the rules (`StorageBoundary.isProvisionalSave`).
        // The bytes, not this library, are kept: its pane may be closed by
        // then. A file a test chose is no part of any data directory.
        if chosenURL == nil {
            _ = StorageBoundary.shared.isProvisionalSave(of: Self.fileName) {
                do {
                    try Self.write(bytes, to: TextMouthPaths.audioFiltersFile)
                } catch {
                    DiagnosticLog.event(
                        .storage,
                        "\(Self.logTag): could not save \(Self.fileName) again after the data directory moved: "
                            + TranscriptStore.describe(error)
                    )
                }
            }
        }
    }

    /// Writes `bytes` atomically to the file at `url`, making its folder
    /// first.
    private static func write(_ bytes: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}

/// Why a preset change wasn't made.
enum AudioFilterPresetError: LocalizedError, Equatable {
    /// A preset needs a name.
    case blankName
    /// The data directory can't be used, so nothing can be saved.
    case libraryUnavailable
    /// audio-filters.json arrived from another Mac while the premade presets
    /// stood in for it: its presets are in use now, and the change was not
    /// made.
    case fileArrived

    var errorDescription: String? {
        switch self {
        case .blankName:
            // Translators: Said when a filter preset is saved with a blank name.
            return InterfaceText.line("audioFilterPresetError.blankName", "A filter preset needs a name.")
        case .libraryUnavailable:
            // Translators: Said when the filter presets can't be saved because the library's data folder can't be used.
            return InterfaceText.line("audioFilterPresetError.libraryUnavailable", "The library isn't available, so the filter presets can't be saved.")
        case .fileArrived:
            // Translators: Said when a filter preset change is not made because the presets file synced in from another Mac while the premade presets stood in for it.
            return InterfaceText.line("audioFilterPresetError.fileArrived", "Presets from another Mac just arrived and replaced these. Make the change again.")
        }
    }
}

extension TextMouthPaths {
    /// The filter presets' file in the data directory (FR04,
    /// `AudioFilterPresetLibrary`), beside substitutions.json.
    static var audioFiltersFile: URL {
        root.appendingPathComponent(AudioFilterPresetLibrary.fileName)
    }
}
