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
    /// file's chapter track, an MP3's ID3 chapter frames (`MP3Tag`), and a
    /// WAVE, AIFF, or CAF file's markers (FMT11, `AudioMarkerList`), which
    /// the renderer writes once the audio is. Every format the editor writes
    /// keeps them; the warning that a file leaves them out
    /// (`AudioEditorWording.chaptersLeftOut`) stays for a format that would
    /// not.
    var holdsChapterMarkers: Bool {
        isMPEG4 || self == .mp3 || isPCM
    }

    /// Whether a book whose file is saved in this format keeps its chapter
    /// markers as its chapters: as `holdsChapterMarkers`, except a CAF
    /// file's markers, which a save writes but TextMouth never reads back as
    /// a book's chapters (`FileChapterReaders` reads WAVE and AIFF markers
    /// alone), so a save in place of a CAF book still warns.
    var keepsBookChapters: Bool {
        holdsChapterMarkers && self != .pcmCAF
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
            + chapterWarning(for: format, savingInPlace: true)
        let fileBefore = session.audioFile
        let markerCount = chapters.count
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
            announce(AudioEditorWording.saved(outcome.duration, renamedTo: renamed)
                + markersLeftOut(outcome.chapterMarkersLeftOut, count: markerCount))
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
    /// of a file in `format`, which has no place for them, or, `savingInPlace`
    /// a CAF book, that the book will not read them back
    /// (`AudioRenderFormat.keepsBookChapters`); empty when there are none,
    /// or the file keeps them, or the format isn't known.
    func chapterWarning(for format: AudioRenderFormat?, savingInPlace: Bool = false) -> String {
        guard let format, !chapters.isEmpty else { return "" }
        let name = AudioEditorWording.formatName(format)
        if !format.holdsChapterMarkers {
            return " " + AudioEditorWording.chaptersLeftOut(chapters.count, format: name)
        }
        guard savingInPlace, !format.keepsBookChapters else { return "" }
        return " " + AudioEditorWording.chaptersNotReadBack(chapters.count, format: name)
    }

    /// The sentence, after a space, saying a file was written without its
    /// `count` chapter markers, when `leftOut` (FMT11); empty otherwise.
    func markersLeftOut(_ leftOut: Bool, count: Int) -> String {
        guard leftOut, count > 0 else { return "" }
        return " " + AudioEditorWording.chapterMarkersNotWritten(count)
    }

    // MARK: Exporting

    /// Exports the edited audio, saved or not, to a new file at `url` in
    /// `format`, the book's own file left as it is; says the result. With
    /// `exportsLabels`, the chapter markers and the markers go beside it as
    /// an Audacity label file (FMT06, `exportLabels(beside:)`).
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
            let outcome = try await session.export(to: url, as: format, progress: progressReporter())
            endProgress()
            announce(exportLabelsIfAsked(beside: url) + markersLeftOut(outcome.chapterMarkersLeftOut, count: chapters.count))
        } catch {
            DiagnosticLog.event(.storage, "AUDIO_EDITOR: \(bookTitle): the audio couldn't be exported (\(AudioEditorLauncher.describe(error)))")
            endProgress()
            announce(AudioEditorWording.exportFailed(error.localizedDescription))
        }
    }

    // MARK: Labels Beside an Export (FMT06)

    /// What an export says once its audio at `url` is written: that alone;
    /// or, with `exportsLabels`, with the label file written beside it, or
    /// why it could not be, or that there was no marker to write.
    private func exportLabelsIfAsked(beside url: URL) -> String {
        let exported = url.lastPathComponent
        guard exportsLabels else { return AudioEditorWording.exported(file: exported) }
        guard !labelEntries.isEmpty else { return AudioEditorWording.exportedWithoutLabels(file: exported) }
        do {
            let labels = try exportLabels(beside: url)
            return AudioEditorWording.exported(file: exported, labels: labels.lastPathComponent)
        } catch {
            DiagnosticLog.event(.storage, "AUDIO_EDITOR: \(bookTitle): the labels couldn't be exported (\(AudioEditorLauncher.describe(error)))")
            return AudioEditorWording.exported(file: exported, labelsFailed: error.localizedDescription)
        }
    }

    /// The labels the editor's places make, in time order: each chapter
    /// marker titled by its title, and each marker by its name, or "Marker
    /// N" without one, as the list numbers it; each a point.
    var labelEntries: [AudacityLabels.Label] {
        let chapterLabels = chapters.map { AudacityLabels.Label(start: $0.start, end: $0.start, text: $0.title) }
        let markerLabels = orderedMarkers.map { marker in
            AudacityLabels.Label(
                start: marker.time,
                end: marker.time,
                text: marker.name.nonBlank ?? AudioEditorWording.markerName(number(of: marker), named: "")
            )
        }
        return (chapterLabels + markerLabels).sortedStably { $0.start < $1.start }
    }

    /// Writes `labelEntries` as an Audacity label file beside the exported
    /// audio at `url`, under its stem with .txt, or, when a file has that
    /// name, "<stem> 2.txt" and on, so no file is ever replaced; Audacity
    /// imports it as a label track beside the audio (File, Import, Labels).
    /// - Returns: the label file.
    /// - Throws: the file system's error.
    @discardableResult
    func exportLabels(beside url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        var number = 1
        var labels = folder.appendingPathComponent("\(stem).\(AudacityLabels.fileExtension)")
        while FileManager.default.fileExists(atPath: labels.path) {
            number += 1
            labels = folder.appendingPathComponent("\(stem) \(number).\(AudacityLabels.fileExtension)")
        }
        try Data(AudacityLabels.text(of: labelEntries).utf8).write(to: labels, options: .withoutOverwriting)
        return labels
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
    /// back; the markers are deleted, and said to be.
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
        let markersDeleted = markers.count
        if markersDeleted > 0 {
            markers = []
        }
        clearSelectionQuietly()
        cursor = clamped(cursor)
        await loadPreview()
        announce(AudioEditorWording.reverted(count, markers: markersDeleted))
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
