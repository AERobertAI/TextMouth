import AppKit
import SwiftUI

// MARK: - The Feed Downloads Section (FR10)

/// The Library window's feed downloads section (FR10's feed half), shown
/// below the list while feed downloads run: its title and a Cancel button,
/// a bar counting every download of the run (the one under way by its
/// bytes), then its lines: the downloads done of the total, the download
/// under way with its feed and how far its file has come, the time left
/// once a download has finished, and the newest-N rule's downloads waiting
/// for a network or for room, counted apart.
///
/// A section rather than an overlay like the import's: downloads can run
/// for many minutes, at launch by themselves, and it must hide nothing of
/// the list while they do. For VoiceOver it is a container labelled with
/// every line it shows, as the import overlay is, holding its header, bar,
/// lines, and Cancel button as elements of their own. Each line keeps to
/// one line on screen, so the section's height, and the list's above it,
/// changes only as lines come and go, never as the bytes come; VoiceOver
/// and a braille display read every line whole.
struct FeedDownloadProgressSection: View {
    /// What the section shows.
    let state: FeedDownloadProgressState
    /// The moment it shows it at, which the time left counts from.
    let now: Date
    /// What VoiceOver says the Cancel button does, as Cancel would act now:
    /// what it stops, and how that comes back, promising only what the
    /// newest-N rule will download again (`FeedCenter.cancelButtonHint()`,
    /// REV14 feeds 5).
    let cancelHint: String
    /// Stops the downloads, from the Cancel button.
    let onCancel: @MainActor () -> Void

    var body: some View {
        let _ = ViewBodyCounter.record("FeedDownloadProgressSection")
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(FeedDownloadProgressWording.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // No Escape key: the section stays while the listener uses
                // the list, where Escape has other work. Dimmed once pressed,
                // while a download already being added finishes.
                Button(FeedDownloadProgressWording.cancelButtonTitle, action: onCancel)
                    .disabled(state.isCancelling)
                    .accessibilityLabel(FeedDownloadProgressWording.cancelButtonLabel)
                    .accessibilityHint(cancelHint)
            }
            ProgressView(value: state.fractionDone)
                .progressViewStyle(.linear)
                .accessibilityLabel(FeedDownloadProgressWording.overallBarLabel)
            // By position, as the import overlay's details: a line's words
            // change as the downloads move, and its place stays the same.
            ForEach(Array(state.lines(at: now).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        // A container, not one combined element: combining would fold the
        // Cancel button into the status, out of VoiceOver's reach.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.spokenStatus(at: now))
    }
}

extension LibraryWindowView {
    /// The feed downloads section a Library window shows for `library`'s
    /// feed downloads, as they are at `now`, whose Cancel stops them
    /// (`LibraryViewModel.cancelFeedDownloads()`), its hint saying how what
    /// Cancel would stop now comes back (REV14 feeds 5). The window shows
    /// exactly this section, made here so tests can press the very button
    /// the window shows.
    static func feedDownloadSection(for library: LibraryViewModel, at now: Date = Date()) -> FeedDownloadProgressSection {
        FeedDownloadProgressSection(
            state: library.feedDownloadProgress.state,
            now: now,
            cancelHint: library.feeds.cancelButtonHint()
        ) {
            cancelFeedDownloads(of: library, in: NSApp.keyWindow)
        }
    }

    /// Stops `library`'s feed downloads, as the section's Cancel does (FR14),
    /// moves VoiceOver's focus from the section, which goes once the run
    /// ends, to the list of the Library window `window`, where Cancel was
    /// pressed, so focus is never left on nothing (feed review item 19), and
    /// only then says what Cancel did, so the window's focus change never
    /// talks over it (REV13 item 3).
    @MainActor
    static func cancelFeedDownloads(of library: LibraryViewModel, in window: NSWindow?) {
        let said = library.cancelFeedDownloads()
        focusListAfterCancel(window) {
            VoiceOverAnnouncer.announce(said, from: window)
        }
    }

    /// Moves VoiceOver's focus to the list of the Library window given, a
    /// moment after Cancel, once the section has gone, to the element the
    /// window first focuses (`StandardVoiceOverFocusTriggerView`), then runs
    /// `then` once the focus attempts have been posted: they come 0.3
    /// seconds apart (`StandardVoiceOverFocusTriggerView.focusAttemptCount`),
    /// within the moment waited again. With no window, `then` runs at once.
    /// A test listens in its place.
    @MainActor
    static var focusListAfterCancel: @MainActor (NSWindow?, @escaping @MainActor () -> Void) -> Void = { window, then in
        guard let window else {
            then()
            return
        }
        VoiceOverAnnouncer.afterSheetCloses {
            StandardVoiceOverFocusTriggerView.staticFindAndFocus(in: window)
            VoiceOverAnnouncer.afterSheetCloses(then)
        }
    }
}

/// The feed downloads section of a Library window, shown only while feed
/// downloads run, and redrawn alone (FR10): it observes the downloads'
/// progress through `ProgressObserver`, as the import and text overlays
/// observe theirs, never the library model or the feed engine, so neither
/// the list nor its feed rows redraw for it (PERF12). It also shows itself
/// anew every `FeedDownloadProgressWording.refreshInterval` seconds,
/// counted from the run's start, which brings the bytes of the download
/// under way, kept by the progress without publishing, and the time left.
struct FeedDownloadProgressObserver: View {
    /// The library whose feed downloads the section shows and cancels; not
    /// observed here.
    let library: LibraryViewModel
    /// The feed downloads' progress, the library's feed engine's own,
    /// observed by the `ProgressObserver` below alone.
    let progress: FeedDownloadProgress

    var body: some View {
        ProgressObserver(progress: progress) { progress in
            if progress.state.isRunning {
                TimelineView(.periodic(from: progress.state.runStartedAt ?? Date(), by: FeedDownloadProgressWording.refreshInterval)) { context in
                    LibraryWindowView.feedDownloadSection(for: library, at: context.date)
                }
            }
        }
    }
}
