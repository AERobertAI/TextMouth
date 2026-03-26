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

                        if viewModel.currentChapterIndex < content.chapters.count {
                            let chapter = content.chapters[viewModel.currentChapterIndex]
                            if !chapter.title.isEmpty {
                                Text(chapter.title)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("Chapter \(viewModel.currentChapterIndex + 1) of \(content.chapters.count)")
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
                       viewModel.currentChapterIndex < content.chapters.count {
                        let chapterText = content.chapters[viewModel.currentChapterIndex].text
                        Text(viewModel.visibleTextWindow(chapterText))
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityLabel("Book content")
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
                sleepTimerService: viewModel.sleepTimerService,
                onStartPlayback: {
                    if !viewModel.isCurrentlyPlaying || viewModel.isCurrentlyPaused {
                        viewModel.togglePlayPause()
                    }
                }
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
                        Text("Pitch: \(pitchLabel(viewModel.speechService.pitchMultiplier))")
                            .accessibilityLabel("Pitch: \(pitchLabel(viewModel.speechService.pitchMultiplier))")

                        Slider(
                            value: Binding(
                                get: { viewModel.speechService.pitchMultiplier },
                                set: { newPitch in
                                    let clamped = max(0.5, min(newPitch, 2.0))
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
                        .accessibilityValue(pitchLabel(viewModel.speechService.pitchMultiplier))
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
        utterance.pitchMultiplier = Float(max(0.5, min(viewModel.speechService.pitchMultiplier, 2.0)))
        previewSynthesizer.speak(utterance)
    }

    /// Format pitch multiplier for display
    private func pitchLabel(_ value: Double) -> String {
        if abs(value - 1.0) < 0.05 { return "Normal (1.0x)" }
        return String(format: "%.1fx", value)
    }
}

// MARK: - Book Info Bar

struct BookInfoBar: View {
    @ObservedObject var viewModel: ReaderViewModel

    var body: some View {
        HStack(spacing: 16) {
            // Progress percentage
            Label {
                Text(viewModel.formattedPercentComplete)
            } icon: {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(viewModel.formattedPercentComplete) through the book")

            // Time remaining
            Label {
                Text("\(viewModel.formattedTimeRemaining) left")
            } icon: {
                Image(systemName: "clock")
                    .foregroundColor(.green)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(TimeFormatting.spoken(viewModel.timeRemaining)) remaining at current speed")

            // Total book time
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

            // Sleep timer status
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
        .background(Color.secondary.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
