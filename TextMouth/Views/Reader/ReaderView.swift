import SwiftUI
import AVFoundation

struct ReaderView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @EnvironmentObject var soundEffectService: SoundEffectService
    @State private var showHeadingNavigator = false
    @State private var showBookmarks = false
    @State private var showSleepTimer = false
    @State private var showMetadataEditor = false
    @State private var showVoicePicker = false
    @State private var showSearch = false
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                ProgressView("Loading book...")
                    .accessibilityLabel("Loading \(viewModel.book.title)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                        .accessibilityHidden(true)
                    Text("Failed to load book")
                        .font(.headline)
                    Text(error)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                // Book info header
                VStack(alignment: .leading, spacing: 4) {
                    if let content = viewModel.content {
                        Text(viewModel.book.title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .accessibilityAddTraits(.isHeader)

                        if viewModel.displayChapterIndex < content.chapters.count {
                            let chapter = content.chapters[viewModel.displayChapterIndex]
                            if !chapter.title.isEmpty {
                                Text(chapter.title)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Chapter \(viewModel.displayChapterIndex + 1) of \(content.chapters.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Info bar with progress, time remaining, sleep timer
                BookInfoBar(viewModel: viewModel)

                Divider()

                // Text display area — only render a window of text around the
                // current position. The full chapter text lives in the model for
                // TTS; rendering hundreds of thousands of characters in a SwiftUI
                // Text view freezes the main thread.
                ScrollView {
                    if let content = viewModel.content,
                       viewModel.displayChapterIndex < content.chapters.count {
                        if viewModel.isPlaybackActivelyAdvancing {
                            // Keep selection disabled while the playback
                            // window is still capable of moving. A
                            // constantly replaced selectable Text view was
                            // the most likely trigger for the huge
                            // VoiceOver/AppKit memory spike during live
                            // playback.
                            Text(viewModel.displayVisibleTextWindow)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.disabled)
                                .accessibilityLabel("Book content")
                        } else {
                            Text(viewModel.displayVisibleTextWindow)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .accessibilityLabel("Book content")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Playback controls
                PlaybackControlsView(viewModel: viewModel)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if viewModel.hasSavedPosition {
                    Button {
                        viewModel.returnToSavedPosition()
                    } label: {
                        Label("Return", systemImage: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Return to previous reading position")
                    .accessibilityHint("Go back to where you were before browsing headings or bookmarks")
                }

                Button {
                    viewModel.whereAmI()
                } label: {
                    Label("Where Am I?", systemImage: "location.circle")
                }
                .accessibilityLabel(viewModel.isWhereAmISpeaking ? "Stop Where Am I announcement" : "Where Am I? Announces current position in the book")

                Button {
                    showHeadingNavigator.toggle()
                } label: {
                    Label("Headings", systemImage: "list.bullet")
                }
                .accessibilityLabel("Show heading navigator")

                Button {
                    showBookmarks.toggle()
                } label: {
                    Label("Bookmarks", systemImage: "bookmark")
                }
                .accessibilityLabel("Show bookmarks")

                Button {
                    showSleepTimer.toggle()
                } label: {
                    Label("Sleep Timer", systemImage: "moon")
                }
                .accessibilityLabel("Sleep timer")

                if !viewModel.isAudioBook {
                    Button {
                        showSearch.toggle()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .accessibilityLabel("Search in book")
                }

                Button {
                    showVoicePicker.toggle()
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .accessibilityLabel("Change voice for this book")

                Button {
                    showMetadataEditor.toggle()
                } label: {
                    Label("Book Info", systemImage: "info.circle")
                }
                .accessibilityLabel("Edit book metadata")

                if viewModel.isAudioBook {
                    Text(String(format: "%.2fx", viewModel.audioSpeed))
                        .font(.caption)
                        .foregroundColor(viewModel.book.localWPM != nil ? .accentColor : .secondary)
                        .accessibilityLabel(String(format: "%.2f times speed", viewModel.audioSpeed))
                } else {
                    Text("\(Int(viewModel.speechService.wordsPerMinute)) WPM")
                        .font(.caption)
                        .foregroundColor(viewModel.book.localWPM != nil ? .accentColor : .secondary)
                        .accessibilityLabel("\(Int(viewModel.speechService.wordsPerMinute)) words per minute\(viewModel.book.localWPM != nil ? ", book-specific speed" : "")")
                }
            }
        }
        .onAppear {
            viewModel.soundEffectService = soundEffectService
        }
        .sheet(isPresented: $showHeadingNavigator) {
            HeadingNavigatorView(viewModel: viewModel)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarkPanelView(viewModel: viewModel)
        }
        .sheet(isPresented: $showSleepTimer) {
            SleepTimerView(
                viewModel: viewModel,
                sleepTimerService: viewModel.sleepTimerService,
                onStartPlayback: {
                    if !viewModel.isCurrentlyPlaying || viewModel.isCurrentlyPaused {
                        viewModel.togglePlayPause()
                    }
                },
                autoClose: viewModel.settingsViewModel.sleepTimerAutoClose
            )
        }
        .sheet(isPresented: $showMetadataEditor) {
            if let metadata = viewModel.epubMetadata {
                MetadataEditorView(
                    metadata: metadata,
                    isEPUB: viewModel.book.format == .epub,
                    onSave: { updated, writeToFile in
                        viewModel.saveEPUBMetadata(updated, writeToFile: writeToFile)
                    }
                )
            } else if let audioMeta = viewModel.audioMetadata {
                MetadataEditorView(
                    audioMetadata: audioMeta,
                    onSave: { updated in
                        viewModel.saveAudioMetadata(updated)
                    }
                )
            } else {
                // Plain text, markdown, HTML — use the simple info editor
                LibraryBookInfoSheet(
                    book: viewModel.book,
                    libraryViewModel: viewModel.libraryViewModel
                )
            }
        }
        .sheet(isPresented: $showVoicePicker) {
            BookVoicePickerView(viewModel: viewModel)
        }
        .sheet(isPresented: $showSearch) {
            if let content = viewModel.content {
                BookSearchView(
                    chapterTexts: content.chapters.map { $0.text },
                    chapterTitles: content.chapters.map { $0.title },
                    totalCharacterCount: content.totalCharacterCount,
                    totalWordCount: content.totalWordCount,
                    currentWPM: viewModel.speechService.wordsPerMinute,
                    onNavigate: { chapterIndex, charOffset in
                        viewModel.navigateToSearchResult(chapterIndex: chapterIndex, characterOffset: charOffset)
                        showSearch = false
                    }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHeadingList)) { notification in
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard sourceWindow === viewModel.hostWindow else { return }
            } else {
                guard viewModel.hostWindow == nil || viewModel.hostWindow?.isKeyWindow == true else { return }
            }
            showHeadingNavigator.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBookmarkList)) { notification in
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard sourceWindow === viewModel.hostWindow else { return }
            } else {
                guard viewModel.hostWindow == nil || viewModel.hostWindow?.isKeyWindow == true else { return }
            }
            showBookmarks.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSleepTimer)) { notification in
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard sourceWindow === viewModel.hostWindow else { return }
            } else {
                guard viewModel.hostWindow == nil || viewModel.hostWindow?.isKeyWindow == true else { return }
            }
            showSleepTimer.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchInBook)) { _ in
            // Only open search in the focused reader window
            guard viewModel.hostWindow == nil || viewModel.hostWindow?.isKeyWindow == true else { return }
            showSearch = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBookInfo)) { notification in
            // Only open in the focused reader window
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard sourceWindow === viewModel.hostWindow else { return }
            } else {
                guard viewModel.hostWindow == nil || viewModel.hostWindow?.isKeyWindow == true else { return }
            }
            showMetadataEditor = true
        }
    }
}

// MARK: - Per-Book Voice Picker

struct BookVoicePickerView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedLanguage: String = ""
    @State private var previewSynthesizer = AVSpeechSynthesizer()

    var body: some View {
        VStack(spacing: 16) {
            Text("Voice & Speed for This Book")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                Section {
                    Picker("Language", selection: $selectedLanguage) {
                        Text("All").tag("")
                        ForEach(availableLanguages, id: \.self) { lang in
                            Text(Locale.current.localizedString(forLanguageCode: lang) ?? lang)
                                .tag(lang)
                        }
                    }
                    .accessibilityLabel("Voice language filter")

                    Picker("Voice", selection: Binding(
                        get: { viewModel.speechService.currentVoice?.identifier ?? "" },
                        set: { id in
                            if let voice = AVSpeechSynthesisVoice(identifier: id) {
                                viewModel.setLocalVoice(voice)
                            }
                        }
                    )) {
                        ForEach(filteredVoices, id: \.identifier) { voice in
                            HStack {
                                Text(voice.name)
                                Text("(\(voiceQualityLabel(voice)))")
                                    .foregroundColor(.secondary)
                            }
                            .tag(voice.identifier)
                            .accessibilityLabel("\(voice.name), \(voiceQualityLabel(voice)) quality")
                        }
                    }
                    .accessibilityLabel("Select voice for this book")

                    Button("Preview Voice") {
                        previewVoice()
                    }
                    .accessibilityLabel("Preview selected voice")
                } header: {
                    Text("Voice")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speed: \(Int(viewModel.speechService.wordsPerMinute)) WPM")
                            .accessibilityLabel("Speed: \(Int(viewModel.speechService.wordsPerMinute)) words per minute")

                        Slider(
                            value: Binding(
                                get: { viewModel.speechService.wordsPerMinute },
                                set: { newWPM in
                                    let clamped = max(50, min(newWPM, 650))
                                    let delta = clamped - viewModel.speechService.wordsPerMinute
                                    if abs(delta) >= 1 {
                                        viewModel.adjustSpeed(delta: delta)
                                    }
                                }
                            ),
                            in: 50...650,
                            step: 25
                        ) {
                            Text("Words per minute")
                        }
                        .accessibilityLabel("Speed slider")
                        .accessibilityValue("\(Int(viewModel.speechService.wordsPerMinute)) words per minute")
                    }
                } header: {
                    Text("Speed")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pitch: \(SpeechService.pitchLabel(viewModel.speechService.pitchMultiplier))")
                            .accessibilityLabel("Pitch: \(SpeechService.pitchLabel(viewModel.speechService.pitchMultiplier))")

                        Slider(
                            value: Binding(
                                get: { viewModel.speechService.pitchMultiplier },
                                set: { newPitch in
                                    let clamped = SpeechService.clampedPitch(newPitch)
                                    if abs(clamped - viewModel.speechService.pitchMultiplier) >= 0.05 {
                                        viewModel.adjustPitch(to: clamped)
                                    }
                                }
                            ),
                            in: 0.5...2.0,
                            step: 0.1
                        ) {
                            Text("Pitch")
                        }
                        .accessibilityLabel("Pitch slider")
                        .accessibilityValue(SpeechService.pitchLabel(viewModel.speechService.pitchMultiplier))
                    }
                } header: {
                    Text("Pitch")
                }

                Section {
                    Picker("When this book ends", selection: Binding(
                        get: { viewModel.effectiveEndOfBookBehavior },
                        set: { viewModel.setLocalEndOfBookBehavior($0) }
                    )) {
                        ForEach(EndOfBookBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.rawValue).tag(behavior)
                        }
                    }
                    .accessibilityLabel("End of book behavior for this book")

                    if viewModel.book.localEndOfBookBehavior != nil {
                        Button("Use Global Default") {
                            viewModel.setLocalEndOfBookBehavior(nil)
                        }
                        .accessibilityLabel("Reset to global end-of-book setting")
                    }
                } header: {
                    Text("End of Book")
                }

                Section {
                    Button("Save to Global Settings") {
                        viewModel.saveSettingsToGlobal()
                    }
                    .accessibilityLabel("Save this book's voice and speed as the global defaults")
                    .accessibilityHint("Updates the default voice and speed for all books that don't have their own settings")

                    if viewModel.hasLocalSettings {
                        Button("Reset to Global Settings") {
                            viewModel.resetToGlobalSettings()
                        }
                        .accessibilityLabel("Reset to global voice and speed settings")
                        .accessibilityHint("Removes book-specific voice and speed, uses global defaults instead")
                    }
                }
            }

            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding()
        .frame(width: 450, height: 600)
        .navigationTitle("Voice & Speed: \(viewModel.book.title)")
        .onAppear {
            // Default to the current voice's language
            if let voice = viewModel.speechService.currentVoice {
                selectedLanguage = String(voice.language.prefix(2))
            }
        }
    }

    private var availableLanguages: [String] {
        let voices = SpeechService.availableVoices()
        let languages = Set(voices.map { String($0.language.prefix(2)) })
        return languages.sorted()
    }

    private var filteredVoices: [AVSpeechSynthesisVoice] {
        if selectedLanguage.isEmpty {
            return SpeechService.availableVoices()
        }
        return SpeechService.availableVoices().filter { $0.language.hasPrefix(selectedLanguage) }
    }

    private func voiceQualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        voice.qualityLabel
    }

    private func previewVoice() {
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Hello! This is how I'll read for you.")
        utterance.voice = viewModel.speechService.currentVoice
        utterance.rate = SpeechService.rateForWPM(viewModel.speechService.wordsPerMinute)
        utterance.pitchMultiplier = Float(SpeechService.clampedPitch(viewModel.speechService.pitchMultiplier))
        previewSynthesizer.speak(utterance)
    }
}

// MARK: - Book Info Bar

/// The strip above the reader text showing progress, time-remaining,
/// total time, and (when active) the sleep timer. The percent and the
/// time-remaining labels are now buttons — clicking either one
/// expands a collapsible jump panel below the bar with input fields
/// for jumping to a specific point. The "Total" label and the sleep
/// timer indicator are non-interactive (no jump UI; that would just
/// duplicate the percent / time-remaining flows).
struct BookInfoBar: View {
    @ObservedObject var viewModel: ReaderViewModel

    /// Mutually-exclusive expansion state — clicking percent collapses
    /// any open time panel and vice-versa, so the bar never grows by
    /// two panel-heights at once. Nil means everything collapsed.
    @State private var expandedPanel: ExpandedPanel?

    enum ExpandedPanel {
        case percent
        case time
    }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            if expandedPanel == .percent {
                JumpToPercentPanel(
                    viewModel: viewModel,
                    onJump: { expandedPanel = nil },
                    onCancel: { expandedPanel = nil }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if expandedPanel == .time {
                JumpToTimePanel(
                    viewModel: viewModel,
                    onJump: { expandedPanel = nil },
                    onCancel: { expandedPanel = nil }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    /// The status row — percent / time-remaining / total / sleep
    /// timer. The first two are buttons; the rest are read-only.
    private var statusRow: some View {
        HStack(spacing: 16) {
            // Progress percentage — click to open jump-to-percent
            Button {
                togglePanel(.percent)
            } label: {
                Label {
                    Text(viewModel.displayFormattedPercentComplete)
                } icon: {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(.blue)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(viewModel.displayFormattedPercentComplete) through the book")
            .accessibilityHint(percentButtonHint)

            // Time remaining — click to open jump-to-time
            Button {
                togglePanel(.time)
            } label: {
                Label {
                    Text("\(viewModel.displayFormattedTimeRemaining) left")
                } icon: {
                    Image(systemName: "clock")
                        .foregroundColor(.green)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(TimeFormatting.spoken(viewModel.displayTimeRemaining)) remaining at current speed")
            .accessibilityHint(timeButtonHint)

            // Total book time — non-interactive
            Label {
                Text("Total: \(viewModel.formattedTotalTime)")
            } icon: {
                Image(systemName: "book.closed")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Total time: \(TimeFormatting.spoken(viewModel.totalEstimatedTime))")

            Spacer()

            // Sleep timer status — non-interactive (managed via the
            // sleep timer sheet; clicking it would duplicate that flow).
            if viewModel.sleepTimerService.isActive {
                Label {
                    Text(viewModel.sleepTimerService.formattedRemaining)
                } icon: {
                    Image(systemName: "moon.fill")
                        .foregroundColor(.orange)
                }
                .font(.caption)
                .foregroundColor(.orange)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sleep timer: \(viewModel.sleepTimerService.formattedRemaining) remaining")
                .accessibilityValue(viewModel.sleepTimerService.formattedRemaining)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// Mutual-exclusion expand/collapse with a small animation. Tapping
    /// the same panel that's already open collapses it.
    private func togglePanel(_ panel: ExpandedPanel) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedPanel == panel {
                expandedPanel = nil
            } else {
                expandedPanel = panel
            }
        }
    }

    /// VoiceOver hint for the percent button. Three states — closed,
    /// percent already open, the OTHER (time) panel open — each with a
    /// distinct sentence so the user always hears what activating the
    /// button will actually do. Previously the "open / hide" wording
    /// alone left the cross-switch case ambiguous: focusing the
    /// percent button while the time panel was open would say "Opens
    /// jump-to-percent" without acknowledging the side effect of
    /// closing the time panel.
    private var percentButtonHint: String {
        switch expandedPanel {
        case nil: return "Opens jump to percent controls"
        case .percent: return "Hides jump to percent controls"
        case .time: return "Switches to jump to percent controls"
        }
    }

    /// Same three-state pattern as `percentButtonHint`, mirrored for
    /// the time button.
    private var timeButtonHint: String {
        switch expandedPanel {
        case nil: return "Opens jump to time controls"
        case .time: return "Hides jump to time controls"
        case .percent: return "Switches to jump to time controls"
        }
    }
}

// MARK: - Jump-To Panels

/// Expanded panel below the info bar offering a single text input for
/// jumping to a percent through the book.
/// Stripped to a plain TextField — earlier iterations layered on
/// auto-focus, character filtering, and accessibility overrides, but
/// each piece of "special handling" turned out to compromise how
/// VoiceOver classified the field (announcing it as "text" instead
/// of "edit text"). Validation now happens on submit; bad input
/// surfaces an inline error instead of being silently clamped or
/// stripped while typing.
private struct JumpToPercentPanel: View {
    @ObservedObject var viewModel: ReaderViewModel
    let onJump: () -> Void
    let onCancel: () -> Void

    @State private var percentInput: String = ""
    /// Inline error message shown after a failed submit. Cleared on
    /// the next successful submit or when the user starts editing
    /// the field. Empty string means no error.
    @State private var errorMessage: String = ""
    /// Drives the auto-focus on appear. A plain Bool @FocusState on
    /// just this single field — no other accessibility overrides on
    /// the TextField — so VoiceOver still classifies it correctly.
    @FocusState private var inputFocused: Bool
    /// Cancellable Task for the focus-after-animation delay so a
    /// quick dismiss doesn't fire focus against a vanishing view.
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Jump to:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Percent", text: $percentInput)
                    .frame(width: 80)
                    .focused($inputFocused)
                    .onSubmit(performJump)
                    // Clear stale error as soon as the user starts
                    // editing — the message refers to the previous
                    // submit, not the current text.
                    .onChange(of: percentInput) { _, _ in
                        if !errorMessage.isEmpty { errorMessage = "" }
                    }
                Text("%")
                    .foregroundColor(.secondary)
                Button("Jump", action: performJump)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityLabel("Error: \(errorMessage)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .onAppear {
            // Pre-fill with the current percent so the user can edit
            // an offset rather than typing from scratch when fine-
            // tuning their position.
            percentInput = String(format: "%.1f", viewModel.displayPercentComplete)
            errorMessage = ""

            // Auto-focus the input after the panel-appearance
            // animation (~150ms) settles. Earlier focus changes get
            // reverted as SwiftUI finalises the layout.
            focusTask?.cancel()
            focusTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                inputFocused = true
            }
        }
        .onDisappear {
            focusTask?.cancel()
            focusTask = nil
        }
    }

    /// Validate the input on submit and either jump or surface an
    /// error. Empty input is rejected (the user typed nothing OR
    /// erased the pre-fill — either way, asking them to be explicit
    /// beats silently jumping to 0%). Out-of-range and non-numeric
    /// input both produce inline errors AND a VoiceOver announcement
    /// so blind users hear the failure even without focus on the
    /// error text.
    private func performJump() {
        let trimmed = percentInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            showError("Enter a percent.")
            return
        }
        guard let value = Double(trimmed) else {
            showError("\"\(trimmed)\" is not a number.")
            return
        }
        guard value >= 0, value <= 100 else {
            showError("Percent must be between 0 and 100.")
            return
        }
        errorMessage = ""
        viewModel.jumpToPercent(value)
        onJump()
    }

    private func showError(_ msg: String) {
        errorMessage = msg
        viewModel.announceToVoiceOver(msg)
    }
}

/// Expanded panel offering hours / minutes / seconds inputs to jump to
/// a wall-clock time within the book.
///
/// ## Why three plain TextFields
/// Earlier iterations had auto-focus, an NSEvent monitor for arrow
/// keys, a digit-only onChange filter, and overridden accessibility
/// label/value. The combination broke VoiceOver's classification —
/// fields announced as "text" instead of "edit text" — and the arrow
/// monitor ran into stale-state issues across re-renders. Stripped
/// back to bare TextFields so each behaves exactly like a normal
/// macOS text input. Validation runs once on submit; bad input
/// produces an inline error AND a VoiceOver announcement.
///
/// ## Validation rules
/// - Empty / non-numeric in any field → error.
/// - Hours, minutes, seconds individually must be non-negative
///   integers. Minutes / seconds capped at 59 with an explicit
///   error rather than silent clamp.
/// - Total must not exceed the book's estimated total time. This
///   is the "jump past end of book" check the user asked about.
private struct JumpToTimePanel: View {
    @ObservedObject var viewModel: ReaderViewModel
    let onJump: () -> Void
    let onCancel: () -> Void

    @State private var hoursText: String = "0"
    @State private var minutesText: String = "0"
    @State private var secondsText: String = "0"
    @State private var errorMessage: String = ""
    /// Auto-focus drives ONLY the hours field. Plain Bool focus
    /// state without per-field overrides keeps VoiceOver's text-
    /// field classification intact — the previous design used a
    /// per-field enum @FocusState plus an arrow-key NSEvent monitor,
    /// and those layered customizations were what broke VO's
    /// classification. Tab still works to move between fields
    /// because that's the SwiftUI default for focusable inputs.
    @FocusState private var hoursFocused: Bool
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Jump to:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Hours", text: $hoursText)
                    .frame(width: 50)
                    .focused($hoursFocused)
                    .onSubmit(performJump)
                    .onChange(of: hoursText) { _, _ in clearError() }
                Text("h")
                    .foregroundColor(.secondary)

                TextField("Minutes", text: $minutesText)
                    .frame(width: 50)
                    .onSubmit(performJump)
                    .onChange(of: minutesText) { _, _ in clearError() }
                Text("m")
                    .foregroundColor(.secondary)

                TextField("Seconds", text: $secondsText)
                    .frame(width: 50)
                    .onSubmit(performJump)
                    .onChange(of: secondsText) { _, _ in clearError() }
                Text("s")
                    .foregroundColor(.secondary)

                Button("Jump", action: performJump)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .accessibilityLabel("Error: \(errorMessage)")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .onAppear {
            // Pre-fill with current elapsed (totalTime - timeRemaining)
            // so the user can adjust by a delta rather than typing
            // from zero.
            let elapsed = max(0, viewModel.totalEstimatedTime - viewModel.displayTimeRemaining)
            let total = Int(elapsed)
            hoursText = "\(total / 3600)"
            minutesText = "\((total % 3600) / 60)"
            secondsText = "\(total % 60)"
            errorMessage = ""

            // Auto-focus the hours field after the panel-appearance
            // animation (~150ms) settles. Same rationale as the
            // matching code in JumpToPercentPanel.
            focusTask?.cancel()
            focusTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                hoursFocused = true
            }
        }
        .onDisappear {
            focusTask?.cancel()
            focusTask = nil
        }
    }

    private func clearError() {
        if !errorMessage.isEmpty { errorMessage = "" }
    }

    /// Parse one of the H/M/S fields. Empty input is treated as zero
    /// (typing only minutes shouldn't fail because the seconds field
    /// is blank). Non-numeric input returns nil so the caller can
    /// surface a precise error.
    private func parseField(_ text: String, name: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        guard let value = Int(trimmed), value >= 0 else { return nil }
        return value
    }

    /// Validate H/M/S and jump or surface an error. The error message
    /// is mirrored to VoiceOver so blind users hear the failure even
    /// when their cursor stays in the input field.
    private func performJump() {
        guard let h = parseField(hoursText, name: "hours") else {
            showError("Hours must be a whole number.")
            return
        }
        guard let m = parseField(minutesText, name: "minutes") else {
            showError("Minutes must be a whole number.")
            return
        }
        guard let s = parseField(secondsText, name: "seconds") else {
            showError("Seconds must be a whole number.")
            return
        }
        guard m < 60 else {
            showError("Minutes must be less than 60.")
            return
        }
        guard s < 60 else {
            showError("Seconds must be less than 60.")
            return
        }

        let total = TimeInterval(h * 3600 + m * 60 + s)
        let bookLength = viewModel.totalEstimatedTime
        guard total <= bookLength else {
            let max = TimeFormatting.spoken(bookLength)
            showError("Time exceeds book length. Maximum is \(max).")
            return
        }

        errorMessage = ""
        viewModel.jumpToTime(seconds: total)
        onJump()
    }

    private func showError(_ msg: String) {
        errorMessage = msg
        viewModel.announceToVoiceOver(msg)
    }
}
