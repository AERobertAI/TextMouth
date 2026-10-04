import Foundation

// MARK: - Audio Kept for Paste

/// Audio Copy or Cut kept for Paste (FR04).
struct AudioEditorClip: Equatable {
    /// The audio itself, as 32-bit float PCM in the window's clip folder;
    /// nil when it was too long to keep, as a long cut is, which can still
    /// be moved by a Paste right after it.
    let file: URL?
    /// How long it lasts, in seconds.
    let duration: TimeInterval
    /// The cut it came from, if it was cut: the cut's entry, and the stretch
    /// cut, on the audio before the cut. A Paste while that cut is still the
    /// newest edit makes the two one move.
    let cut: Cut?

    /// A cut a clip came from.
    struct Cut: Equatable {
        /// The cut's entry in the edit list.
        let entryID: UUID
        /// The stretch cut, on the audio before the cut.
        let range: AudioTimeRange
    }

    /// The longest stretch kept for Paste, in seconds: ten minutes, about
    /// 210 MB of stereo at 44.1 kHz on a disk that may be nearly full.
    static let longest: TimeInterval = 10 * 60

    /// The space left on a disk below which nothing is kept for Paste.
    static let reserve: Int64 = 1_000_000_000

    /// A new folder for one window's clips in this Mac's caches, which never
    /// sync; made when the first clip is kept.
    static func newFolder() -> URL {
        MachineLocalPaths.caches
            .appendingPathComponent("Audio Editor Clips", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// What an edit did: its entry, and the audio's length around it.
struct AudioEditorEditOutcome {
    /// The edit as the list recorded it.
    let entry: AudioEditEntry
    /// How long the audio lasted before it, in seconds.
    let before: TimeInterval
    /// How long it lasts after it.
    let after: TimeInterval
}

// MARK: - Editing (FR04)

/// The edits: Cut, Copy, and Paste (a Paste right after a Cut makes the two
/// one move), Trim to Selection, Insert Silence, chapter markers, and Undo
/// and Redo, each named as the Edit menu names it. Every edit goes through
/// the edit session, which records it before anything changes; then the
/// markers follow the sound, the cursor and the selection settle where the
/// edit leaves them, the player gets the edited audio at the cursor, and
/// the edit is announced with the audio's new length.
extension AudioEditorModel {
    // MARK: Making an Edit

    /// Notes that work that changes the audio has begun, unless other work
    /// is under way, which is said; the result says whether to go on.
    func beginWork() -> Bool {
        guard !isWorking else {
            announce(AudioEditorWording.stillWorking)
            return false
        }
        guard punchIn == nil else {
            announce(AudioEditorWording.stillRecording)
            return false
        }
        isWorking = true
        return true
    }

    /// Stops whatever the player is doing for an edit, which changes the
    /// audio it plays.
    func stopPlayingForEdit() {
        if playing != .idle {
            player.pause()
            if case .listening = playing {
                cursor = clamped(player.currentTime)
            }
        }
        playing = .idle
        isPlaying = false
        filterPreview = nil
    }

    /// Makes the edit `work` makes through the session, as `performEdit`
    /// does, once other work is done; other work under way is said, and
    /// nothing is made.
    @discardableResult
    func applyEdit(
        _ work: () async throws -> AudioEditEntry,
        settle: (AudioEditorEditOutcome) -> String
    ) async -> AudioEditorEditOutcome? {
        guard beginWork() else { return nil }
        defer { isWorking = false }
        return await performEdit(work, settle: settle)
    }

    /// Makes the edit `work` makes through the session, for a command that
    /// has begun its work (`beginWork()`), then lets `settle` put the cursor
    /// and the selection where the edit leaves them and return what to say,
    /// reloads the preview there, and says it. The markers follow the sound
    /// first. A refusal or a failure is said, and changes nothing.
    @discardableResult
    func performEdit(
        _ work: () async throws -> AudioEditEntry,
        settle: (AudioEditorEditOutcome) -> String
    ) async -> AudioEditorEditOutcome? {
        stopPlayingForEdit()
        let before = duration
        let outcome: AudioEditorEditOutcome
        do {
            let entry = try await work()
            outcome = AudioEditorEditOutcome(entry: entry, before: before, after: duration)
        } catch {
            announce(error.localizedDescription)
            return nil
        }
        followMarkers { AudioEditorTimeMap.forward($0, through: outcome.entry.edit, before: outcome.before, after: outcome.after) }
        let sentence = settle(outcome)
        cursor = clamped(cursor)
        await loadPreview()
        announce(sentence)
        return outcome
    }

    /// Moves every marker by `map`, dropping none: two markers may come to
    /// one place.
    func followMarkers(_ map: (TimeInterval) -> TimeInterval) {
        for index in markers.indices {
            markers[index].time = clamped(map(markers[index].time))
        }
    }

    /// Clears the selection, as an edit that removed or replaced it does.
    func clearSelectionQuietly() {
        selectionStart = nil
        selectionEnd = nil
    }

    // MARK: Cut, Copy, and Paste

    /// Cuts the selection out, keeping it for Paste when it isn't too long;
    /// the cursor goes to where it was.
    func cut() async {
        guard let range = selection else { return announce(AudioEditorWording.noSelection) }
        guard beginWork() else { return }
        defer { isWorking = false }
        let kept = await keepClip(of: range)
        let outcome = await performEdit({ try await session.perform(.cut(range)) }) { outcome in
            clearSelectionQuietly()
            cursor = range.start
            return AudioEditorWording.cut(range.duration, now: outcome.after)
        }
        guard let outcome else {
            kept.map(discardClipFile)
            return
        }
        setClip(AudioEditorClip(file: kept, duration: range.duration, cut: .init(entryID: outcome.entry.id, range: range)))
    }

    /// Copies the selection for Paste, saying how long it is.
    func copy() async {
        guard let range = selection else { return announce(AudioEditorWording.noSelection) }
        guard range.duration <= AudioEditorClip.longest else { return announce(AudioEditorWording.copyTooLong) }
        guard beginWork() else { return }
        defer { isWorking = false }
        guard let file = await keepClip(of: range) else { return }
        setClip(AudioEditorClip(file: file, duration: range.duration, cut: nil))
        announce(AudioEditorWording.copied(range.duration))
    }

    /// Pastes the audio copied or cut: over the selection, which it
    /// replaces, or at the cursor. Right after a Cut, with nothing selected,
    /// the cut and the paste become one move of the audio, undone in one.
    func paste() async {
        guard let clip else { return announce(AudioEditorWording.nothingToPaste) }
        if let cut = clip.cut, selection == nil, session.list.nextUndo?.id == cut.entryID {
            return await moveCut(cut)
        }
        guard let file = clip.file else { return announce(AudioEditorWording.cutTooLongToPaste) }
        if let range = selection {
            await applyEdit({ try await session.punchIn(replacing: range, withTakeAt: file) }) { outcome in
                clearSelectionQuietly()
                cursor = range.start + clip.duration
                return AudioEditorWording.pasted(clip.duration, replacing: range.duration, now: outcome.after)
            }
        } else {
            let place = cursor
            await applyEdit({ try await session.insert(takeAt: file, at: place) }) { outcome in
                cursor = place + clip.duration
                return AudioEditorWording.pasted(clip.duration, replacing: nil, now: outcome.after)
            }
        }
    }

    /// Makes the cut `cut`, still the newest edit, and a Paste at the cursor
    /// one move: the cut is undone and its audio moved to the place the
    /// cursor stands for on the audio before it. At the cut's own place it
    /// stays undone, which puts the audio back where it was.
    private func moveCut(_ cut: AudioEditorClip.Cut) async {
        guard beginWork() else { return }
        defer { isWorking = false }
        stopPlayingForEdit()
        let afterCut = duration
        let beforeCut = afterCut + cut.range.duration
        let place = AudioEditorTimeMap.backward(cursor, through: .cut(cut.range), before: beforeCut, after: afterCut)
        do {
            _ = try await session.undo()
        } catch {
            return announce(error.localizedDescription)
        }
        followMarkers { AudioEditorTimeMap.backward($0, through: .cut(cut.range), before: beforeCut, after: afterCut) }
        guard abs(place - cut.range.start) > Self.timeTolerance else {
            clip = AudioEditorClip(file: clip?.file, duration: cut.range.duration, cut: nil)
            cursor = cut.range.end
            await loadPreview()
            return announce(AudioEditorWording.pastedBack(cut.range.duration))
        }
        await performEdit({ try await session.perform(.move(cut.range, to: place)) }) { outcome in
            let landed = AudioEditorTimeMap.forward(cut.range.start, through: outcome.entry.edit, before: outcome.before, after: outcome.after)
            cursor = landed + cut.range.duration
            return AudioEditorWording.moved(cut.range.duration, to: landed)
        }
        // The clip stays for another Paste, now as audio inserted.
        clip = AudioEditorClip(file: clip?.file, duration: cut.range.duration, cut: nil)
    }

    /// Renders `range` into a new file in the window's clip folder for
    /// Paste; nil, with the reason said, when it is too long, the disk is
    /// too full, or it can't be written.
    private func keepClip(of range: AudioTimeRange) async -> URL? {
        guard range.duration <= AudioEditorClip.longest else { return nil }
        do {
            try FileManager.default.createDirectory(at: clipFolder, withIntermediateDirectories: true)
            // Stereo floats at the audio's rate: as much as a clip can take.
            let needed = Int64(range.duration * session.timeline.sampleRate * 8)
            let free = (try? clipFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? .max
            guard free - needed > AudioEditorClip.reserve else {
                announce(AudioEditorWording.diskTooFullToKeepClip)
                return nil
            }
            let file = clipFolder.appendingPathComponent("\(UUID().uuidString).caf")
            try await session.renderStretch(range, to: file)
            return file
        } catch {
            announce(error.localizedDescription)
            return nil
        }
    }

    /// Makes `newClip` the clip, deleting the file of the one it replaces.
    private func setClip(_ newClip: AudioEditorClip) {
        if let old = clip?.file, old != newClip.file {
            discardClipFile(old)
        }
        clip = newClip
    }

    /// Deletes a clip's file.
    private func discardClipFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Trim, Silence, and Chapter Markers

    /// Keeps only the selection: the audio after it, then the audio before
    /// it, are removed, as one step undone in one.
    func trimToSelection() async {
        guard let range = selection else { return announce(AudioEditorWording.noSelection) }
        let trimsEnd = range.end < duration - Self.timeTolerance
        let trimsStart = range.start > Self.timeTolerance
        guard trimsEnd || trimsStart else { return announce(AudioEditorWording.selectionIsEverything) }
        guard beginWork() else { return }
        defer { isWorking = false }
        var first: UUID?
        if trimsEnd {
            let outcome = await performEdit({ try await session.perform(.trimEnd(at: range.end)) }) { _ in
                AudioEditorWording.trimmed(keeping: range.duration)
            }
            guard let outcome else { return }
            first = outcome.entry.id
        }
        if trimsStart {
            let outcome = await performEdit({ try await session.perform(.trimStart(to: range.start)) }) { outcome in
                cursor = AudioEditorTimeMap.forward(cursor, through: outcome.entry.edit, before: outcome.before, after: outcome.after)
                return AudioEditorWording.trimmed(keeping: range.duration)
            }
            if let outcome, let first {
                pairedEdits[outcome.entry.id] = first
            }
        }
        clearSelectionQuietly()
    }

    /// Inserts `seconds` of silence at the cursor; the cursor goes past it.
    func insertSilence(_ seconds: TimeInterval) async {
        let place = cursor
        await applyEdit({ try await session.perform(.insertSilence(at: place, duration: seconds)) }) { outcome in
            cursor = place + seconds
            return AudioEditorWording.insertedSilence(seconds, now: outcome.after)
        }
    }

    /// Sets a chapter marker titled `title` at the cursor, or renames the
    /// one there.
    func insertChapter(titled title: String) async {
        let place = cursor
        let renaming = chapters.contains { abs($0.start - place) < Self.timeTolerance }
        await applyEdit({ try await session.perform(.setChapter(at: place, title: title)) }) { _ in
            renaming ? AudioEditorWording.chapterRenamed(title) : AudioEditorWording.chapterSet(title, at: place)
        }
    }

    /// Renames the chapter marker at `start` `title`.
    func renameChapter(at start: TimeInterval, to title: String) async {
        await applyEdit({ try await session.perform(.setChapter(at: start, title: title)) }) { _ in
            AudioEditorWording.chapterRenamed(title)
        }
    }

    /// Removes the chapter marker at `start`, titled `title`.
    func removeChapter(at start: TimeInterval, titled title: String) async {
        await applyEdit({ try await session.perform(.removeChapter(at: start)) }) { _ in
            AudioEditorWording.chapterRemoved(title)
        }
    }

    // MARK: Undo and Redo

    /// What Undo would undo, as the Edit menu names it: "Cut 2.5 Seconds",
    /// or "Trim to Selection" for both of its edits; nil when nothing can
    /// be undone.
    var undoName: String? {
        guard let entry = session.list.nextUndo else { return nil }
        return pairedEdits[entry.id] != nil ? AudioEditorWording.trimToSelectionName : AudioEditWording.actionName(entry.edit)
    }

    /// What Redo would redo, as the Edit menu names it.
    var redoName: String? {
        guard let entry = session.list.nextRedo else { return nil }
        return pairedEdits.values.contains(entry.id) ? AudioEditorWording.trimToSelectionName : AudioEditWording.actionName(entry.edit)
    }

    /// Undoes the newest edit, both edits of a Trim to Selection, saying
    /// what was undone; the cursor goes to where it was made, and the
    /// selection is cleared. When nothing can be undone, says why.
    func undo() async {
        guard session.canUndo, let name = undoName else {
            return announce(session.undoLimitExplanation ?? AudioEditWording.undoLimit(.nothingToUndo) ?? "")
        }
        guard beginWork() else { return }
        defer { isWorking = false }
        stopPlayingForEdit()
        do {
            var place: TimeInterval?
            while true {
                // The lengths around the edit as it was made: with it, then
                // without it.
                let edited = duration
                guard let entry = try await session.undo() else { break }
                let unedited = duration
                followMarkers { AudioEditorTimeMap.backward($0, through: entry.edit, before: unedited, after: edited) }
                place = AudioEditorTimeMap.place(of: entry.edit)
                // The first edit of a Trim to Selection goes with the second.
                guard let partner = pairedEdits[entry.id], session.list.nextUndo?.id == partner else { break }
            }
            clearSelectionQuietly()
            cursor = clamped(place ?? cursor)
            await loadPreview()
            announce(AudioEditorWording.undid(name, now: duration))
        } catch {
            announce(error.localizedDescription)
            await loadPreview()
        }
    }

    /// Redoes the oldest undone edit, both edits of a Trim to Selection,
    /// saying what was redone.
    func redo() async {
        guard session.canRedo, let name = redoName else { return announce(AudioEditorWording.nothingToRedo) }
        guard beginWork() else { return }
        defer { isWorking = false }
        stopPlayingForEdit()
        do {
            var place: TimeInterval?
            while true {
                let before = duration
                guard let entry = try await session.redo() else { break }
                let after = duration
                followMarkers { AudioEditorTimeMap.forward($0, through: entry.edit, before: before, after: after) }
                place = AudioEditorTimeMap.place(of: entry.edit)
                // The second edit of a Trim to Selection goes with the first.
                guard let next = session.list.nextRedo, pairedEdits[next.id] == entry.id else { break }
            }
            clearSelectionQuietly()
            cursor = clamped(place ?? cursor)
            await loadPreview()
            announce(AudioEditorWording.redid(name, now: duration))
        } catch {
            announce(error.localizedDescription)
            await loadPreview()
        }
    }
}
