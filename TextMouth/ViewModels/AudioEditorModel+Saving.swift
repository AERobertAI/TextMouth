import Foundation
import os

// MARK: - A Save or an Export Under Way

/// A save or an export under way, as its sheet shows it (FR04).
struct AudioEditorProgress: Equatable {
    /// What is under way: "Saving" or "Exporting".
    let title: String
    /// What it writes, in a sentence: the length and the format.
    let detail: String
    /// How far it is, from 0 to 1.
    var fraction: Double
}

/// The Original audio choice of Audio Info (FR04): the global setting, or a
/// policy of the book's own.
enum AudioEditorPolicyChoice: String, CaseIterable, Identifiable, Sendable {
    /// Follow the global setting in Storage settings.
    case global
    /// Keep the original for good.
    case keep
    /// Keep no original.
    case delete
    /// Keep it for a number of days.
    case deleteAfterDays

    var id: String { rawValue }
}

extension AudioRenderFormat {
    /// Whether a file in this format keeps chapter markers: an MPEG-4
    /// file's chapter track, or the ID3 chapter frames ffmpeg writes into an
    /// MP3 (`AudioEditRenderer`); WAVE, AIFF, and CAF have no place for
    /// them.
    var holdsChapterMarkers: Bool {
        isMPEG4 || self == .mp3
    }
}

/// What closing the editor window needs first (FR04).
enum AudioEditorCloseNeed: Equatable {
    /// Nothing: it can close.
    case nothing
    /// An edit, a save, or an export is under way: wait for it.
    case working
    /// A punch-in records: stop it first.
    case recording
    /// Edits wait to be saved into the book's file: ask Save, Discard, or
    /// Cancel.
    case unsavedEdits
}

// MARK: - Saving and Closing (FR04)

/// Save writes the edits into the book's file, in the format the book
/// keeps, with a sheet showing how far it is, announced at each quarter of
/// a long one; Export writes the edited audio to a file outside the
/// library in a format chosen; Revert to Original undoes every edit back to
/// the original, which Redo brings back; Audio Info gives the book an
/// original policy of its own. Closing with unsaved edits asks first.
extension AudioEditorModel {
    // MARK: Saving

    /// Saves the edits into the book's file, saying the length and format
    /// first and the result after; returns whether the file holds them now.
    @discardableResult
    func save() async -> Bool {
        guard session.hasUnsavedEdits else {
            announce(AudioEditorWording.nothingToSave)
            return true
        }
        guard beginWork() else { return false }
        defer { isWorking = false }
        if playing == .previewing {
            endFilterPreview()
        }
        stopPlayingForEdit()
        let format = await readSaveFormat()
        let detail = AudioEditorWording.savingDetail(duration, format: format.map(AudioEditorWording.formatName))
            + chapterWarning(for: format)
        let fileBefore = session.audioFile
        progress = AudioEditorProgress(title: AudioEditorWording.savingTitle, detail: detail, fraction: 0)
        sheet = .progress
        announce(detail)
        defer { endProgress() }
        do {
            let outcome = try await session.save(progress: progressReporter())
            endProgress()
            cursor = clamped(cursor)
            await loadPreview()
            // A file written in a format of another extension has a new name.
            let renamed = outcome.audioFile == fileBefore ? nil : (outcome.audioFile as NSString).lastPathComponent
            announce(AudioEditorWording.saved(outcome.duration, renamedTo: renamed))
            return true
        } catch {
            DiagnosticLog.event(.storage, "AUDIO_EDITOR: \(bookTitle): the edits couldn't be saved (\(AudioEditorLauncher.describe(error)))")
            endProgress()
            announce(AudioEditorWording.saveFailed(error.localizedDescription))
            return false
        }
    }

    /// Reads the format a save writes the book's file in, for the save's
    /// sheet, keeping its name for Audio Info; nil when the file can't be
    /// read.
    @discardableResult
    func readSaveFormat() async -> AudioRenderFormat? {
        let format = try? await session.saveFormat()
        saveFormatName = format.map(AudioEditorWording.formatName)
        return format
    }

    /// The sentence, after a space, saying the chapter markers are left out
    /// of a file in `format`, which has no place for them; empty when there
    /// are none, or the format keeps them, or it isn't known.
    func chapterWarning(for format: AudioRenderFormat?) -> String {
        guard let format, !chapters.isEmpty, !format.holdsChapterMarkers else { return "" }
        return " " + AudioEditorWording.chaptersLeftOut(chapters.count, format: AudioEditorWording.formatName(format))
    }

    // MARK: Exporting

    /// Exports the edited audio, saved or not, to a new file at `url` in
    /// `format`, the book's own file left as it is; says the result.
    func export(as format: AudioExportFormat, to url: URL) async {
        guard beginWork() else { return }
        defer { isWorking = false }
        if playing == .previewing {
            endFilterPreview()
        }
        stopPlayingForEdit()
        let detail = AudioEditorWording.exportingDetail(duration, format: format.title, file: url.lastPathComponent)
            + chapterWarning(for: format.renderFormat)
        progress = AudioEditorProgress(title: AudioEditorWording.exportingTitle, detail: detail, fraction: 0)
        sheet = .progress
        announce(detail)
        defer { endProgress() }
        do {
            try await session.export(to: url, as: format, progress: progressReporter())
            endProgress()
            announce(AudioEditorWording.exported(file: url.lastPathComponent))
        } catch {
            DiagnosticLog.event(.storage, "AUDIO_EDITOR: \(bookTitle): the audio couldn't be exported (\(AudioEditorLauncher.describe(error)))")
            endProgress()
            announce(AudioEditorWording.exportFailed(error.localizedDescription))
        }
    }

    /// The name an export offers its file: the book's title, and the
    /// track's, with `format`'s extension.
    func exportFileName(for format: AudioExportFormat) -> String {
        let name = trackTitle.map { "\(bookTitle) - \($0)" } ?? bookTitle
        return TextImportPolicy.fileName(for: name, extension: format.fileExtension)
    }

    // MARK: Progress

    /// What a save or an export tells of how far it is: on the main actor,
    /// once for each whole percent, however often the render reports.
    private func progressReporter() -> @Sendable (Double) -> Void {
        let started = Date()
        let lastPercent = OSAllocatedUnfairLock(initialState: -1)
        return { [weak self] fraction in
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
            let isNew = lastPercent.withLock { last -> Bool in
                guard percent > last else { return false }
                last = percent
                return true
            }
            guard isNew else { return }
            Task { @MainActor in self?.progressed(to: Double(percent) / 100, since: started) }
        }
    }

    /// Shows `fraction` in the sheet, and announces each quarter passed
    /// once the work has taken a few seconds, so a short save stays quiet.
    private func progressed(to fraction: Double, since started: Date) {
        guard var current = progress else { return }
        let quarterBefore = Int(current.fraction * 4)
        let quarterNow = Int(fraction * 4)
        current.fraction = fraction
        progress = current
        if quarterNow > quarterBefore, (1...3).contains(quarterNow), Date().timeIntervalSince(started) >= 3 {
            announce(AudioEditorWording.percentDone(quarterNow * 25))
        }
    }

    /// Closes the progress sheet.
    private func endProgress() {
        progress = nil
        if sheet == .progress {
            sheet = nil
        }
    }

    // MARK: Reverting

    /// Whether Revert to Original can act: some edit can be undone, back to
    /// the original as imported or recorded.
    var canRevert: Bool {
        session.canUndo && session.list.baseCursor == 0
    }

    /// Asks to confirm Revert to Original, or says why it can't act.
    func askToRevert() {
        guard canRevert else {
            return announce(session.canUndo ? AudioEditorWording.revertNoOriginal : AudioEditorWording.nothingToRevert)
        }
        confirmingRevert = true
    }

    /// Undoes every edit, back to the original, saying how many Redo brings
    /// back.
    func revertToOriginal() async {
        confirmingRevert = false
        guard canRevert else { return announce(AudioEditorWording.nothingToRevert) }
        guard beginWork() else { return }
        defer { isWorking = false }
        stopPlayingForEdit()
        var count = 0
        do {
            while session.canUndo, try await stepBack() != nil {
                count += 1
            }
        } catch {
            announce(error.localizedDescription)
        }
        clearSelectionQuietly()
        cursor = clamped(cursor)
        await loadPreview()
        announce(AudioEditorWording.reverted(count))
    }

    /// Undoes, or redoes, back to the edits the book's file holds, as
    /// Discard does when the window closes; false when the file holds edits
    /// the history no longer has, which stay to be saved or undone later.
    @discardableResult
    func discardUnsavedEdits() async -> Bool {
        guard let saved = session.list.renderedCursor else { return false }
        stopPlayingForEdit()
        do {
            while session.list.cursor > saved, try await stepBack() != nil {}
            while session.list.cursor < saved, try await stepForward() != nil {}
        } catch {
            announce(error.localizedDescription)
            return false
        }
        return !session.hasUnsavedEdits
    }

    // MARK: The Book's Original Policy

    /// The global original policy, in Storage settings.
    var globalPolicy: AudioOriginalPolicy {
        AudioOriginalPolicy.global(in: store)
    }

    /// The book's Original audio choice, as Audio Info shows it.
    var policyChoice: AudioEditorPolicyChoice {
        switch session.policyOverride {
        case nil: return .global
        case .keep?: return .keep
        case .delete?: return .delete
        case .deleteAfter?: return .deleteAfterDays
        }
    }

    /// The days the book keeps its original under its own "keep for a
    /// number of days", or the global setting's days.
    var policyDays: Int {
        if case .deleteAfter(let days)? = session.policyOverride {
            return Int(days.rounded())
        }
        return Int(AudioOriginalPolicy.daysPreference.read(from: store).rounded())
    }

    /// Gives the book the policy `choice` names, keeping the original
    /// `days` days for a choice of days, saying what it does now.
    func setPolicy(_ choice: AudioEditorPolicyChoice, days: Int) async {
        let policy: AudioOriginalPolicy?
        switch choice {
        case .global: policy = nil
        case .keep: policy = .keep
        case .delete: policy = .delete
        case .deleteAfterDays: policy = .deleteAfter(days: Double(days))
        }
        guard policy != session.policyOverride else { return }
        do {
            try await session.setPolicyOverride(policy)
            announce(AudioEditorWording.policyChanged(policy, global: globalPolicy))
        } catch {
            announce(error.localizedDescription)
        }
    }

    // MARK: Closing

    /// What closing the window needs first, now.
    var closeNeed: AudioEditorCloseNeed {
        if punchIn != nil { return .recording }
        if isWorking { return .working }
        return session.hasUnsavedEdits ? .unsavedEdits : .nothing
    }
}
