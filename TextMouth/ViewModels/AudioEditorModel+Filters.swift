import Foundation

/// What a filter is applied to (FR04).
enum AudioEditorFilterTarget: String, CaseIterable, Identifiable, Sendable {
    /// The selection.
    case selection
    /// All of the audio.
    case wholeFile

    var id: String { rawValue }
}

/// What Apply Filter's Preview is playing (FR04): a preset, on a target.
struct AudioEditorFilterPreview: Equatable {
    /// The preset previewed.
    let presetID: UUID
    /// What it was previewed on.
    let target: AudioEditorFilterTarget
}

// MARK: - Filters (FR04)

/// Apply Filter: a preset's chain, in ffmpeg's syntax, run over the
/// selection or the whole file through the edit session, which renders it
/// with TextMouth's own filters or the installed ffmpeg. Preview plays the
/// processed sound without applying anything: the selection's first
/// stretch, or, for the whole file, a stretch from the cursor, so even a
/// long book previews at once; the edited audio comes back when the
/// preview ends or is stopped.
extension AudioEditorModel {
    /// The longest stretch Preview processes and plays, in seconds.
    static let longestFilterPreview: TimeInterval = 20

    /// Whether a filter can run on `target`: always on the whole file, and
    /// on the selection once there is one.
    func canFilter(_ target: AudioEditorFilterTarget) -> Bool {
        target == .wholeFile || selection != nil
    }

    /// The stretch a filter on `target` runs over, as the session takes it:
    /// the selection, or nil for the whole file.
    func filterRange(for target: AudioEditorFilterTarget) -> AudioTimeRange? {
        target == .selection ? selection : nil
    }

    /// Whether Apply previews a filter before applying it: the setting in
    /// the Audio Editing group, on until turned off.
    var previewsFiltersFirst: Bool {
        AudioEditorPreferences.previewFiltersFirst.read(from: store)
    }

    /// Apply Filter's Apply: with the setting on, the first Apply of a
    /// preset on a target previews it, saying to choose Apply again; the
    /// next applies it. With the setting off, it applies at once.
    func chooseApply(_ preset: AudioFilterPreset, to target: AudioEditorFilterTarget) async {
        let asked = AudioEditorFilterPreview(presetID: preset.id, target: target)
        if previewsFiltersFirst, previewedFilter != asked {
            await previewFilter(preset, on: target, saying: AudioEditorWording.previewingBeforeApplying(preset.name))
            return
        }
        await applyFilter(preset, to: target)
    }

    /// Plays `preset` on `target` without applying it: the selection's
    /// first stretch, or a stretch from the cursor for the whole file;
    /// says `sentence` as it begins, or that it is previewing.
    func previewFilter(_ preset: AudioFilterPreset, on target: AudioEditorFilterTarget, saying sentence: String? = nil) async {
        guard canFilter(target) else { return announce(AudioEditorWording.noSelection) }
        let range = filterRange(for: target)
        let start = range?.start ?? cursor
        let end = min(range?.end ?? duration, start + Self.longestFilterPreview)
        guard end - start > Self.timeTolerance else { return announce(AudioEditorWording.nothingToPreview) }
        let stretch = AudioTimeRange(start: start, end: end)
        guard beginWork() else { return }
        defer { isWorking = false }
        stopPlayingForEdit()
        announce(sentence ?? AudioEditorWording.previewingFilter(preset.name))
        do {
            let preview = try await session.makePreview(applying: .filter(chain: preset.chain, range: stretch))
            // The processed stretch may be longer or shorter, as a change of
            // tempo makes it.
            let processed = stretch.duration + Double(preview.frames) / preview.sampleRate - duration
            // No load of the edited audio still under way may replace it.
            previewLoads += 1
            player.load(preview, at: start)
            playing = .previewing
            filterPreview = AudioEditorFilterPreview(presetID: preset.id, target: target)
            previewedFilter = filterPreview
            player.play(from: start, until: start + max(0, processed))
        } catch {
            announce(error.localizedDescription)
            await loadPreview(measuring: false)
        }
    }

    /// Ends a filter's preview, and gives the player back the edited audio
    /// at the cursor.
    func endFilterPreview() {
        guard playing == .previewing || filterPreview != nil else { return }
        player.pause()
        playing = .idle
        isPlaying = false
        filterPreview = nil
        Task { await loadPreview(measuring: false) }
    }

    /// Applies `preset` to `target`: the processed selection stays selected,
    /// and a long run is said before it begins and when it ends.
    func applyFilter(_ preset: AudioFilterPreset, to target: AudioEditorFilterTarget) async {
        guard canFilter(target) else { return announce(AudioEditorWording.noSelection) }
        let range = filterRange(for: target)
        // A preview playing stops as the edit begins (`stopPlayingForEdit`),
        // and the edit reloads the edited audio.
        sheet = nil
        announce(AudioEditorWording.applyingFilter(preset.name))
        await applyEdit({ try await session.perform(.filter(chain: preset.chain, range: range)) }) { outcome in
            if let range {
                let length = range.duration + outcome.after - outcome.before
                selectQuietly(AudioTimeRange(start: range.start, end: range.start + length))
                cursor = range.start
            }
            return AudioEditorWording.appliedFilter(preset.name, to: range?.duration, now: outcome.after)
        }
    }
}
