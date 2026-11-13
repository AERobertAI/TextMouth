import Combine
import SwiftUI
import UIKit

/// The iPhone's one step before the shared import, for the whole process
/// (the spec's "Importing"): every file a person picks with Add to Library,
/// and every file another app sends, is copied under coordination into a
/// scratch folder of the app's own (`PhoneImportCopyRun`), and only the
/// copy is handed to the library. Files that arrive while a copy runs wait
/// their turn.
///
/// It also does what the shared import can't on a phone:
/// - holds files sent before the library has started, and gives them to it
///   once it has (`PhoneImportHolding`);
/// - never stops a playing book for a file another app sends;
/// - presents the waiting import question itself, since the Mac's presenter
///   never shows one on iOS, and answers at once the two it never shows
///   (`PhoneImportQuestion.automaticAnswer(for:)`);
/// - keeps a background task while anything imports, and the screen awake
///   while the app is in front;
/// - sweeps its scratch copies and the Inbox once nothing imports and no
///   question waits, and at launch;
/// - keeps the names of what imports in a small file, so a close that stops
///   an import is named at the next launch (`PhoneImportRecord`).
@MainActor
final class PhoneImportCopier: ObservableObject {
    /// The process's one copier, over the app's one model.
    static let shared = PhoneImportCopier(model: TextMouthAppDelegate.model)

    /// What a request's books do once copied.
    private enum Destination {
        /// Picked with Add to Library: imported into the folder the Library
        /// showed, and not opened, so focus stays where it was.
        case library(folderPath: String)
        /// Sent by another app: imported at the library's top, as the Mac's
        /// opened files are, and opened or not as the route says.
        case opened(PhoneImportHolding.Route)
    }

    /// One batch of files to copy and import.
    private struct Request {
        let urls: [URL]
        let destination: Destination
    }

    /// The copy under way, for the progress card; nil between copies.
    @Published private(set) var copyStatus: PhoneImportCopyRun.Status?
    /// Whether anything imports: a copy, a copy waiting its turn, or the
    /// shared import. The progress card shows while it does.
    @Published private(set) var isUnderWay = false
    /// The question the sheet asks now, nil while none waits.
    @Published private(set) var question: PhoneImportQuestion?
    /// The folder the Add to Library sheet imports into while it shows; nil
    /// while it doesn't.
    @Published var addToLibraryFolder: PhoneAddToLibraryRequest?

    /// The app's model.
    private let model: PhoneAppModel
    /// What is held, and when the last hand-off was.
    private var holding = PhoneImportHolding()
    /// Requests waiting for the copy under way.
    private var waiting: [Request] = []
    /// The copy under way.
    private var run: PhoneImportCopyRun?
    /// Ends the background task held while anything imports.
    private var endHold: (@MainActor () -> Void)?
    /// Lets go of this copier's hold on the screen's sleep, while it has one.
    private var endScreenHold: (@MainActor () -> Void)?
    /// The pending re-check of the sweep's moment after a quiet period.
    private var sweepCheck: DispatchWorkItem?
    /// Whether `install()` has run.
    private var isInstalled = false
    /// The library's publishers and the notification this copier follows.
    private var subscriptions = Set<AnyCancellable>()
    /// The observer of the library becoming available.
    private var availabilityObserver: NSObjectProtocol?

    /// A copier over `model`'s library and session.
    private init(model: PhoneAppModel) {
        self.model = model
    }

    /// The library imports go to.
    private var library: LibraryViewModel { model.library }

    // MARK: - Installing

    /// Starts the copier, once: it takes the files other apps send from the
    /// life cycle, follows the library's imports and questions, and sweeps
    /// what an earlier run left. Safe before any window exists, so the app
    /// delegate may call it at launch; the root view calls it too, as it
    /// first appears.
    ///
    /// **Not verified:** a file sent at a cold launch arrives in the scene's
    /// connection options, before the root appears, and goes the
    /// foundation's way (imported directly, its scope taken by the shared
    /// import) unless the app delegate has called this first.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        model.lifeCycle.openedFiles = { [weak self] urls in
            self?.receiveOpenedFiles(urls)
        }
        model.lifeCycle.onDidBecomeActive { [weak self] in
            self?.releaseHeldFiles()
        }
        // A batch's quarters are said only while no book plays.
        library.importProgress.isBookPlaying = { [weak session = model.session] in
            session?.isAnyBookPlaying == true
        }
        // The library's own values, delivered on the main queue, a turn
        // after each change, as the team's rule asks.
        library.$isImporting
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.importsChanged() }
            .store(in: &subscriptions)
        library.$importDecisions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.questionsChanged() }
            .store(in: &subscriptions)
        // A library that wasn't there at launch takes the files held for it
        // once Try Again finds it.
        availabilityObserver = NotificationCenter.default.addObserver(
            forName: .dataDirectoryDidBecomeAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseHeldFiles() }
        }
        // Read, then removed, before this run's first import writes its own.
        stoppedAtLastClose = Self.stoppedImports(in: library)
        try? FileManager.default.removeItem(at: Self.recordFile)
        questionsChanged()
        updateUnderWay()
    }

    /// What the last run's close stopped importing, read as the copier is
    /// installed, before anything sweeps the record; said once the first
    /// screen has settled.
    private var stoppedAtLastClose: String?

    /// Whether `rootAppeared()` has run.
    private var hasRootAppeared = false

    /// Takes the first appearance of the root view: the copier is installed
    /// if it wasn't, and once VoiceOver has settled on the first screen,
    /// what a close stopped importing is said.
    func rootAppeared() {
        install()
        guard !hasRootAppeared else { return }
        hasRootAppeared = true
        guard let sentence = stoppedAtLastClose else { return }
        stoppedAtLastClose = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchSentenceDelay) {
            PhoneAnnouncer.say(sentence)
        }
    }

    /// How long after the first screen appears what a close stopped is said:
    /// time for VoiceOver to land on the screen and read it first.
    private static let launchSentenceDelay: TimeInterval = 1.5

    // MARK: - Arriving

    /// Shows the Add to Library sheet, importing into the folder at
    /// `folderPath`: the folder the Library shows, as on the Mac.
    func showAddToLibrary(inFolder folderPath: String) {
        addToLibraryFolder = PhoneAddToLibraryRequest(folderPath: folderPath)
    }

    /// Copies and imports `urls`, picked in the Add to Library sheet, into
    /// the folder at `folderPath`. The sheet has closed first, so VoiceOver
    /// says "Importing Dune" once it has, and the book is not opened.
    func addPicked(_ urls: [URL], toFolder folderPath: String) {
        guard !urls.isEmpty else { return }
        if let sentence = PhoneImportWording.importing(urls.map(PhoneImportWording.displayName(of:))) {
            VoiceOverAnnouncer.afterSheetCloses { PhoneAnnouncer.say(sentence) }
        }
        enqueue(Request(urls: urls, destination: .library(folderPath: folderPath)))
    }

    /// Takes `urls`, sent by another app: held until the library has
    /// started, then copied and imported. With a book playing, the book goes
    /// on and nothing is said until the import ends; otherwise "Importing
    /// Dune" is said, and the book opens once imported.
    func receiveOpenedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard library.hasStartedLibrary else {
            holding.hold(urls)
            return
        }
        let route = PhoneImportHolding.route(isBookPlaying: model.session.isAnyBookPlaying)
        if route == .importAndOpen,
           let sentence = PhoneImportWording.importing(urls.map(PhoneImportWording.displayName(of:))) {
            PhoneAnnouncer.say(sentence)
        }
        enqueue(Request(urls: urls, destination: .opened(route)))
    }

    /// Gives the files held to the library, once it has started.
    private func releaseHeldFiles() {
        guard library.hasStartedLibrary, !holding.heldFiles.isEmpty else { return }
        receiveOpenedFiles(holding.takeHeldFiles())
    }

    // MARK: - Copying

    /// Queues `request` behind any copy under way, and starts it when none is.
    private func enqueue(_ request: Request) {
        waiting.append(request)
        startNextCopy()
        updateUnderWay()
    }

    /// Starts copying the oldest request waiting, when no copy runs.
    private func startNextCopy() {
        guard run == nil, !waiting.isEmpty else { return }
        let request = waiting.removeFirst()
        record(starting: request.urls)
        let copy = PhoneImportCopyRun(sources: request.urls, statusChanged: { [weak self] status in
            self?.copyStatus = status
        })
        run = copy
        copy.start { [weak self] outcome in
            self?.copied(request, outcome: outcome)
        }
    }

    /// Takes how `request`'s copy ended: hands the copies to the library, or
    /// says why nothing was imported; then the next copy starts.
    private func copied(_ request: Request, outcome: PhoneImportCopyRun.Outcome) {
        run = nil
        switch outcome {
        case .copied(let copies):
            removeInboxOriginals(of: request.urls)
            record(copies: copies)
            holding.noteHandOff(at: Date())
            handOver(copies, to: request.destination)
        case .noRoom:
            let names = request.urls.map(\.lastPathComponent)
            let reason = names.count == 1
                ? ImportFailure(fileName: names[0], step: .copying, underlying: CocoaError(.fileWriteOutOfSpace)).errorDescription
                : ImportFailure.outOfSpaceDescription
            presentNothingImported(reason ?? ImportFailure.outOfSpaceDescription)
        case .stalled(let name):
            PhoneAnnouncer.say(PhoneImportWording.downloadFailed(name))
        case .cancelled:
            // Cancel Import's own words were said as it was pressed.
            break
        case .failed(let name, let description):
            let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: description,
            ])
            let failure = ImportFailure(fileName: name, step: .readingSource, underlying: underlying)
            presentNothingImported(failure.errorDescription ?? description)
        }
        startNextCopy()
        updateUnderWay()
    }

    /// Hands `copies` to the shared import, as `destination` says. A
    /// TextMouth package is opened only when the destination opens books:
    /// the Mac's Open Book opens one, which would stop a playing book here.
    private func handOver(_ copies: [URL], to destination: Destination) {
        switch destination {
        case .opened(.importAndOpen):
            library.importAndOpenFiles(urls: copies, from: nil)
        case .opened(.importOnly):
            importWithoutOpening(copies, toFolder: "")
        case .library(let folderPath):
            importWithoutOpening(copies, toFolder: folderPath)
        }
    }

    /// Imports `copies` into the folder at `folderPath`, opening none.
    private func importWithoutOpening(_ copies: [URL], toFolder folderPath: String) {
        let packages = copies.filter(FileImportService.isBookPackage)
        for package in packages {
            library.openTMBPackage(from: package, toFolder: folderPath, opensReader: false)
        }
        let others = copies.filter { !FileImportService.isBookPackage($0) }
        if !others.isEmpty {
            library.importFiles(urls: others, toFolder: folderPath)
        }
    }

    /// Says why nothing was imported in the library's alert, titled as the
    /// spec asks: "Nothing Imported", with OK.
    private func presentNothingImported(_ message: String) {
        library.errorTitle = ImportProgressWording.nothingImportedTitle
        library.errorMessage = message
        library.showError = true
    }

    /// Stops the copy under way and those waiting, and the shared imports:
    /// the progress card's Cancel Import.
    func cancelImports() {
        waiting.removeAll()
        run?.cancel()
        library.cancelImports()
        updateUnderWay()
    }

    // MARK: - Questions

    /// Takes the library's questions as they change: one the phone never
    /// shows is answered at once, and the sheet shows any other.
    private func questionsChanged() {
        if let current = library.importDecisions.current,
           let answer = PhoneImportQuestion.automaticAnswer(for: current.kind) {
            // Settling it publishes the queue again, which brings the next.
            library.answerImportDecision(current.id, with: answer)
            return
        }
        if let current = library.importDecisions.current, let wording = library.currentImportDecisionWording {
            let next = PhoneImportQuestion(decision: current, wording: wording)
            if next != question { question = next }
        } else if question != nil {
            question = nil
        }
        updateUnderWay()
    }

    /// Offers the waiting question to the sheet again, a turn after it is
    /// withdrawn: SwiftUI presents a sheet as its item appears, so a question
    /// that appeared while another sheet showed would otherwise never show.
    func presentQuestionAgain() {
        guard let waiting = question else { return }
        question = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.library.importDecisions.current?.id == waiting.decisionID else { return }
            self.question = waiting
        }
    }

    /// Answers the question the sheet shows with `answer`, off the main actor
    /// where the answer takes long (Replace Existing of a braille book that
    /// is read again).
    /// - Returns: The library's outcome, whose failure the sheet shows.
    func answer(_ question: PhoneImportQuestion, with answer: ImportDecisionAnswer) async -> OperationOutcome {
        await library.answerImportDecisionOffMain(question.decisionID, with: answer)
    }

    // MARK: - Under Way, Held, and Swept

    /// Takes the shared import's start or end.
    private func importsChanged() {
        updateUnderWay()
    }

    /// Works out whether anything imports, and follows it: the background
    /// task and the screen kept awake while it does, and the sweep once
    /// nothing does and no question waits.
    private func updateUnderWay() {
        let copying = run != nil || !waiting.isEmpty
        let underWay = copying || library.isImporting
        if isUnderWay != underWay { isUnderWay = underWay }
        if underWay {
            // A background task while anything imports, ended by its
            // expiry too (the app delegate's `beginBackgroundTask(named:)`).
            if endHold == nil { endHold = model.lifeCycle.beginHold("Importing books") }
            setScreenKeptAwake(true)
        } else {
            endHold?()
            endHold = nil
            setScreenKeptAwake(false)
        }
        considerSweeping()
    }

    /// Keeps the screen from locking while an import runs and the app is in
    /// front, so Auto-Lock doesn't stop it; puts back only what this copier
    /// changed. It holds the screen through `PhoneScreenSleep`, the one keeper
    /// that Book content shares, so neither lets the screen lock under the
    /// other.
    private func setScreenKeptAwake(_ awake: Bool) {
        if awake {
            if endScreenHold == nil { endScreenHold = PhoneScreenSleep.hold() }
        } else {
            endScreenHold?()
            endScreenHold = nil
        }
    }

    /// Sweeps now, later, or not, as `PhoneImportHolding` decides.
    private func considerSweeping() {
        sweepCheck?.cancel()
        sweepCheck = nil
        let decision = holding.sweepDecision(
            isImporting: library.isImporting,
            hasQuestion: library.importDecisions.current != nil,
            isCopying: run != nil || !waiting.isEmpty,
            at: Date()
        )
        switch decision {
        case .now:
            sweep()
        case .after(let seconds):
            let check = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.considerSweeping() }
            }
            sweepCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: check)
        case .notNow:
            break
        }
    }

    /// Removes every scratch copy and every Inbox file past its grace, and
    /// the record of what imported: the app's own files, at run time, which
    /// nothing needs once the import is over. What to remove is listed here,
    /// on the main thread, so a copy that starts a moment later is never in
    /// the list; the removing is done off it.
    private func sweep() {
        let manager = FileManager.default
        try? manager.removeItem(at: Self.recordFile)
        let scratchRoot = PhoneImportCopyPlan.scratchRoot(in: manager.temporaryDirectory)
        var doomed = (try? manager.contentsOfDirectory(at: scratchRoot, includingPropertiesForKeys: nil)) ?? []
        if let inbox = Self.inboxFolder {
            let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey]
            let now = Date()
            for item in (try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: Array(keys))) ?? [] {
                let values = try? item.resourceValues(forKeys: keys)
                if PhoneImportHolding.sweepsInboxFile(addedAt: values?.addedToDirectoryDate ?? values?.creationDate, at: now) {
                    doomed.append(item)
                }
            }
        }
        guard !doomed.isEmpty else { return }
        let removing = doomed
        DispatchQueue.global(qos: .utility).async {
            for item in removing { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Removes each of `sources` that is the app's own copy in its Inbox,
    /// which its scratch copy has now replaced. A file opened in place is
    /// another app's, and is never touched.
    private func removeInboxOriginals(of sources: [URL]) {
        guard let inbox = Self.inboxFolder else { return }
        let ownCopies = sources.filter { PhoneImportCopyPlan.isInside($0, folder: inbox) }
        guard !ownCopies.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for copy in ownCopies { try? FileManager.default.removeItem(at: copy) }
        }
    }

    /// `Documents/Inbox`, where iOS puts a copy of a file Mail and other
    /// apps send; nil if there is no Documents folder.
    private static var inboxFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    // MARK: - The Record of What Imports

    /// The record's file: `Library/Application Support/PhoneImport/importing.json`.
    private static var recordFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PhoneImportRecord.file(in: support.appendingPathComponent(PhoneImportCopyPlan.scratchFolderName, isDirectory: true))
    }

    /// Adds the items of `urls` to the record as their copy starts.
    private func record(starting urls: [URL]) {
        var record = PhoneImportRecord.load(from: Self.recordFile) ?? PhoneImportRecord()
        record.entries += urls.map { PhoneImportRecord.Entry(name: PhoneImportWording.displayName(of: $0), copyPath: nil) }
        try? record.save(to: Self.recordFile)
    }

    /// Notes where each of `copies` was made, on the first entries still
    /// without a copy whose names match.
    private func record(copies: [URL]) {
        guard var record = PhoneImportRecord.load(from: Self.recordFile) else { return }
        for copy in copies {
            let name = PhoneImportWording.displayName(of: copy)
            if let index = record.entries.firstIndex(where: { $0.copyPath == nil && $0.name == name }) {
                record.entries[index].copyPath = copy.path
            }
        }
        try? record.save(to: Self.recordFile)
    }

    /// What to say of the imports a close stopped, from the record an
    /// earlier run left in `library`'s process; nil when there is none. A
    /// book whose copy the library holds was imported before the close, and
    /// isn't named. The record itself goes with the first sweep.
    private static func stoppedImports(in library: LibraryViewModel) -> String? {
        guard let record = PhoneImportRecord.load(from: recordFile) else { return nil }
        let imported = Set(library.library.books.compactMap(\.sourceFilePath))
        return PhoneImportWording.stoppedWhenClosed(record.stoppedNames(importedPaths: imported))
    }
}

/// A request to show the Add to Library sheet, importing into the folder at
/// `folderPath`; identified afresh each time, so the sheet shows again for
/// the same folder.
struct PhoneAddToLibraryRequest: Identifiable, Equatable {
    let id = UUID()
    /// The library folder the books go in.
    let folderPath: String
}
