import AppKit
import Combine

// MARK: - A Punch-In

/// A punch-in under way (FR04): re-recording over the selection, or
/// recording where nothing is selected, inserted at the cursor.
struct AudioEditorPunchIn: Equatable {
    /// The stretch the take replaces; nil inserts it at `place`.
    let range: AudioTimeRange?
    /// Where the take goes: the selection's start, or the cursor.
    let place: TimeInterval
    /// The microphone it records from, by name.
    let microphone: String
    /// Whether capture has begun, the count-in over; false while it starts
    /// and once it is stopping.
    var isRecording: Bool
}

/// What punch-ins record with (FR04): the recorder the Record window uses,
/// the microphones, and the count-in played before capture begins. The
/// app's own (`system()`), or, in tests, a recorder that needs no
/// microphone and a count-in that makes no sound.
@MainActor
struct AudioEditorRecorder {
    /// The recorder.
    let service: RecordingService
    /// The microphones connected, and their changes.
    let catalog: RecordingInputCatalog
    /// Plays the count-in, and returns once it has ended, so it is never in
    /// the take.
    let countIn: @MainActor () async -> Void
    /// How long the sentence before the count-in is given to be spoken.
    let announcementLead: Duration

    /// The app's: AVFoundation's capture of the microphone chosen, macOS's
    /// permission, and a short system sound for the count-in.
    static func system() -> AudioEditorRecorder {
        AudioEditorRecorder(
            service: .system(),
            catalog: SystemRecordingInputCatalog(),
            countIn: { await beep() },
            announcementLead: .milliseconds(1_500)
        )
    }

    /// The count-in: one short system sound, and a moment for it to end.
    static func beep() async {
        NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)?.play()
        try? await Task.sleep(for: .milliseconds(600))
    }
}

// MARK: - Punching In (FR04)

/// Re-recording a stretch from the microphone chosen: Punch In (R) says
/// what it will record and from which microphone, plays the count-in, and
/// records; Stop, or Punch In again, ends the take, which replaces the
/// selection (`AudioEditSession.punchIn`), or is inserted at the cursor
/// when nothing was selected, and is selected, so Play Selection plays it.
/// Clear Selection discards a take under way. Nothing here mutes or ducks
/// VoiceOver: capture records the microphone alone, and the editor plays
/// nothing while it records. Where Am I says the time recorded and the
/// level.
extension AudioEditorModel {
    // MARK: Microphones

    /// Follows the recorder and the microphones: a take that ends on its
    /// own is kept, and the microphones are read again as they come and go.
    func followRecorder() {
        recorder.catalog.onChange = { [weak self] in self?.refreshMicrophones() }
        refreshMicrophones()
        recorderSubscriptions = []
        recorder.service.$state
            .dropFirst()
            .sink { [weak self] state in
                // Published before the change: let it land, then respond.
                Task { @MainActor in self?.recorderChanged(to: state) }
            }
            .store(in: &recorderSubscriptions)
        // The time and level the status line shows while recording.
        recorder.service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &recorderSubscriptions)
    }

    /// Reads the microphones again: the one TextMouth remembers when it is
    /// connected, otherwise macOS's default input, while nothing records.
    func refreshMicrophones() {
        microphones = RecordingInputChoice.distinctlyNamed(recorder.catalog.devices())
        guard punchIn == nil else { return }
        let resolution = RecordingInputChoice.resolve(
            remembered: RecordingInputChoice.preference.read(from: store),
            among: microphones,
            systemDefault: recorder.catalog.systemDefaultDeviceID()
        )
        microphoneID = resolution.device?.id ?? ""
    }

    /// Uses the microphone `id` for punch-ins and remembers it, as the
    /// Record window does.
    func chooseMicrophone(_ id: String) {
        guard microphones.contains(where: { $0.id == id }), punchIn == nil else { return }
        microphoneID = id
        RecordingInputChoice.preference.write(id, to: store)
    }

    /// The microphone a punch-in records from, if one is connected.
    var chosenMicrophone: AudioInputDevice? {
        microphones.first { $0.id == microphoneID }
    }

    // MARK: Recording

    /// Starts a punch-in, or ends the one recording, keeping its take.
    func togglePunchIn() async {
        if punchIn?.isRecording == true {
            await stopPunchIn()
        } else if punchIn == nil {
            await startPunchIn()
        }
    }

    /// Records from the chosen microphone, over the selection or at the
    /// cursor: says what and from which microphone, then the count-in, then
    /// capture. A refusal of the microphone's permission, or a failure, is
    /// said.
    func startPunchIn() async {
        guard punchIn == nil else { return }
        guard !isWorking else { return announce(AudioEditorWording.stillWorking) }
        refreshMicrophones()
        guard let device = chosenMicrophone else { return announce(AudioEditorWording.noMicrophone) }
        stopPlayingForEdit()
        let range = selection
        let punch = AudioEditorPunchIn(range: range, place: range?.start ?? cursor, microphone: device.name, isRecording: false)
        punchIn = punch
        let lead = recorder.announcementLead
        let countIn = recorder.countIn
        await recorder.service.start(from: device) { [weak self] in
            self?.announce(AudioEditorWording.punchInStarting(punch))
            try? await Task.sleep(for: lead)
            await countIn()
        }
        switch recorder.service.state {
        case .recording:
            if punchIn == punch {
                punchIn?.isRecording = true
            } else {
                // Cancelled during the count-in, or the window closed: the
                // take that began is discarded at once.
                await recorder.service.stop()
                recorder.service.discard()
            }
        case .failed(let failure, _):
            punchIn = nil
            recorder.service.reset()
            announce(failure.errorDescription ?? "")
        default:
            break
        }
    }

    /// Ends the take under way and keeps it: it replaces the selection, or
    /// goes in at the cursor.
    func stopPunchIn() async {
        guard var punch = punchIn, punch.isRecording else { return }
        punch.isRecording = false
        punchIn = punch
        await recorder.service.stop()
        switch recorder.service.state {
        case .finished(let take):
            await keep(take, for: punch)
        case .failed(let failure, let take?):
            announce(failure.errorDescription ?? "")
            await keep(take, for: punch)
        case .failed(let failure, nil):
            endPunchIn(saying: failure.errorDescription)
        default:
            endPunchIn(saying: nil)
        }
    }

    /// Discards the take under way, saying so.
    func cancelPunchIn() async {
        guard let punch = punchIn else { return }
        punchIn = AudioEditorPunchIn(range: punch.range, place: punch.place, microphone: punch.microphone, isRecording: false)
        if recorder.service.isRecording {
            await recorder.service.stop()
        }
        recorder.service.discard()
        endPunchIn(saying: AudioEditorWording.punchInDiscarded)
    }

    /// Discards a take under way as the window closes, without waiting.
    func abandonPunchIn() {
        guard punchIn != nil else { return }
        punchIn = nil
        let service = recorder.service
        Task { @MainActor in
            if service.isRecording {
                await service.stop()
            }
            service.discard()
        }
    }

    /// What Where Am I says while recording: the time recorded and the
    /// level; nil while nothing records.
    var punchInStatus: String? {
        guard let punch = punchIn else { return nil }
        guard punch.isRecording else { return AudioEditorWording.punchInStartingStatus }
        return AudioEditorWording.punchInStatus(
            elapsed: recorder.service.elapsed,
            level: RecordingWording.levelValue(recorder.service.levels)
        )
    }

    // MARK: Helpers

    /// Responds to the recorder: a take that ended on its own while
    /// recording, as a lost microphone ends one, is said and kept.
    private func recorderChanged(to state: RecordingService.State) {
        // A state already left, or a take this model is stopping itself,
        // needs nothing more.
        guard recorder.service.state == state, let punch = punchIn, punch.isRecording else { return }
        guard case .failed(let failure, let take) = state else { return }
        var stopped = punch
        stopped.isRecording = false
        punchIn = stopped
        announce(failure.errorDescription ?? "")
        if let take {
            Task { await keep(take, for: stopped) }
        } else {
            endPunchIn(saying: nil)
        }
    }

    /// Puts `take` in the audio as `punch` asked, through the edit session,
    /// which keeps it in the book's package; the new audio is selected. The
    /// take's own file goes once the edit holds it.
    private func keep(_ take: RecordedTake, for punch: AudioEditorPunchIn) async {
        // The take is the editor's now; the recorder can start another.
        recorder.service.reset()
        punchIn = nil
        let place = punch.place
        let outcome: AudioEditorEditOutcome?
        if let range = punch.range {
            outcome = await applyEdit({ try await session.punchIn(replacing: range, withTakeAt: take.url) }) { outcome in
                let length = range.duration + outcome.after - outcome.before
                selectQuietly(AudioTimeRange(start: place, end: place + length))
                cursor = place
                return AudioEditorWording.punchedIn(length, replacing: range.duration, now: outcome.after)
            }
        } else {
            outcome = await applyEdit({ try await session.insert(takeAt: take.url, at: place) }) { outcome in
                let length = outcome.after - outcome.before
                selectQuietly(AudioTimeRange(start: place, end: place + length))
                cursor = place
                return AudioEditorWording.recordingInserted(length, now: outcome.after)
            }
        }
        if outcome != nil {
            RecordingTakeFiles.remove(take.url)
        }
    }

    /// Ends the punch-in with nothing kept, saying `sentence` when given.
    private func endPunchIn(saying sentence: String?) {
        punchIn = nil
        recorder.service.reset()
        if let sentence, !sentence.isEmpty {
            announce(sentence)
        }
    }

    /// Selects `range` without saying so, as an edit that announces itself
    /// does.
    func selectQuietly(_ range: AudioTimeRange) {
        selectionStart = clamped(range.start)
        selectionEnd = clamped(range.end)
    }
}
