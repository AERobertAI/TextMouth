import Foundation

// MARK: - Selecting Without a Waveform (FR04)

/// The selection and the markers: In and Out at the cursor, the stretch
/// from the cursor to the next or previous pause, the chapter the cursor
/// is in, everything, or nothing; and markers dropped at the cursor
/// (`AudioEditMarker`), which the file's edit list keeps. Every change to
/// the selection is announced briefly, by its length, and the whole of it
/// is said on request.
extension AudioEditorModel {
    // MARK: In and Out

    /// Marks In at the cursor: the selection's start. An Out at or before it
    /// is cleared, since a selection runs forward.
    func markIn() {
        let time = cursor
        selectionStart = time
        if let end = selectionEnd, end <= time + Self.timeTolerance {
            selectionEnd = nil
        }
        announce(AudioEditorWording.markedIn(at: time, selection: selection))
    }

    /// Marks Out at the cursor: the selection's end. An In at or after it is
    /// cleared.
    func markOut() {
        let time = cursor
        selectionEnd = time
        if let start = selectionStart, start >= time - Self.timeTolerance {
            selectionStart = nil
        }
        announce(AudioEditorWording.markedOut(at: time, selection: selection))
    }

    /// Selects `range`, kept inside the audio, saying how long it is, with
    /// `sentence` said in place of that when given.
    func select(_ range: AudioTimeRange, saying sentence: String? = nil) {
        selectionStart = clamped(range.start)
        selectionEnd = clamped(range.end)
        if let selection {
            announce(sentence ?? AudioEditorWording.selected(selection))
        } else {
            announce(AudioEditorWording.noSelection)
        }
    }

    // MARK: Whole Stretches

    /// Selects from the cursor to where the sound after the next pause
    /// begins: the phrase the cursor starts, with the pause after it.
    func selectToNextPause() {
        guard let pauses = pausesFound() else { return }
        guard let pause = pauses.first(where: { $0.end > cursor + Self.timeTolerance }) else {
            return announce(AudioEditorWording.noPauseAfter)
        }
        select(AudioTimeRange(start: cursor, end: pause.end))
    }

    /// Selects from where the sound after the previous pause begins to the
    /// cursor: the phrase before the cursor, from its start.
    func selectToPreviousPause() {
        guard let pauses = pausesFound() else { return }
        guard let pause = pauses.last(where: { $0.end < cursor - Self.timeTolerance }) else {
            return announce(AudioEditorWording.noPauseBefore)
        }
        select(AudioTimeRange(start: pause.end, end: cursor))
    }

    /// Selects the chapter the cursor is in, from its marker to the next or
    /// the end; before the first marker, the audio before it.
    func selectChapter() {
        guard let first = chapters.first else { return announce(AudioEditorWording.noChapters) }
        guard let index = chapterIndex(at: cursor), chapters.indices.contains(index) else {
            return select(AudioTimeRange(start: 0, end: first.start), saying: AudioEditorWording.selectedBeforeFirstChapter(first.start))
        }
        let end = chapters.indices.contains(index + 1) ? chapters[index + 1].start : duration
        let range = AudioTimeRange(start: chapters[index].start, end: end)
        select(range, saying: AudioEditorWording.selectedChapter(number: index + 1, title: chapters[index].title, length: range.duration))
    }

    /// Selects all of the audio.
    func selectAll() {
        select(AudioTimeRange(start: 0, end: duration), saying: AudioEditorWording.selectedAll(duration))
    }

    /// Clears the selection.
    func clearSelection() {
        guard selectionStart != nil || selectionEnd != nil else { return announce(AudioEditorWording.noSelection) }
        selectionStart = nil
        selectionEnd = nil
        announce(AudioEditorWording.selectionCleared)
    }

    /// Says the selection as a sentence: where it starts and ends, and how
    /// long it lasts.
    func speakSelection() {
        guard let selection else { return announce(AudioEditorWording.noSelection) }
        announce(AudioEditorWording.selectionSentence(selection))
    }

    /// Plays the selection, stopping at its end; the cursor follows it, and
    /// Stop goes back to its start.
    func playSelection() {
        guard let selection else { return announce(AudioEditorWording.noSelection) }
        guard hasPreview else { return announce(AudioEditorWording.notReadyToPlay) }
        cursor = selection.start
        playing = .listening(from: selection.start)
        isPlaying = true
        player.play(from: selection.start, until: selection.end)
    }

    // MARK: Markers

    /// The markers in time order, as the list shows and numbers them.
    var orderedMarkers: [AudioEditMarker] {
        markers.sortedStably { ($0.time, $0.id.uuidString) < ($1.time, $1.id.uuidString) }
    }

    /// The number the list gives `marker`, counting from 1 in time order.
    func number(of marker: AudioEditMarker) -> Int {
        (orderedMarkers.firstIndex { $0.id == marker.id } ?? 0) + 1
    }

    /// Drops a marker at the cursor, at once, so it can be dropped while
    /// listening; it can be named in the list.
    func addMarker() {
        let marker = AudioEditMarker(id: UUID(), time: cursor, name: "")
        markers.append(marker)
        announce(AudioEditorWording.markerAdded(number(of: marker), at: marker.time))
    }

    /// Moves the cursor to the marker `id`.
    func goToMarker(_ id: UUID) {
        guard let marker = markers.first(where: { $0.id == id }) else { return }
        sheet = nil
        move(to: marker.time, saying: AudioEditorWording.marker(number(of: marker), named: marker.name, at: marker.time))
    }

    /// Names the marker `id` `name`, trimmed; empty takes its name away.
    func renameMarker(_ id: UUID, to name: String) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = markers[index]
        announce(AudioEditorWording.markerRenamed(number(of: marker), named: marker.name))
    }

    /// Deletes the marker `id`, saying which went.
    func deleteMarker(_ id: UUID) {
        guard let marker = markers.first(where: { $0.id == id }) else { return }
        let number = number(of: marker)
        markers.removeAll { $0.id == id }
        announce(AudioEditorWording.markerDeleted(number, named: marker.name))
    }

    // MARK: Pauses in the List

    /// Moves the cursor to where the sound after `pause` begins.
    func goToPause(_ pause: AudioEditorPause) {
        sheet = nil
        move(to: pause.end, saying: AudioEditorWording.afterPause(pause))
    }

    /// Selects `pause` itself, as for cutting it out or shortening it.
    func selectPause(_ pause: AudioEditorPause) {
        sheet = nil
        cursor = clamped(pause.start)
        select(AudioTimeRange(start: pause.start, end: pause.end))
    }
}
