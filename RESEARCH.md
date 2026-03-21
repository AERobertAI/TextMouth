# TextMouth - API Research Findings

## TTS Engine: Dual Synthesizer Approach

**Decision**: Use AVSpeechSynthesizer for normal speeds (≤380 WPM) and NSSpeechSynthesizer for high speeds (>380 WPM).

### Why Dual Approach
- AVSpeechSynthesizer rate 0.0-1.0 caps at ~380 WPM. Cannot go faster.
- NSSpeechSynthesizer (deprecated but functional) accepts WPM directly: `synth.rate = 650` works perfectly.
- The macOS `say` command uses NSSpeechSynthesizer internally; `say -r 650` works fine.
- Both synthesizers share the same voice identifiers, so switching between them is seamless.
- NSSpeechSynthesizer can generate audio files: `synth.startSpeaking(text, to: url)` — useful for future audio-file-based playback.

### Future: Audio-File-Based Approach
For even better skip/rewind, pre-generate audio per chapter using NSSpeechSynthesizer `startSpeaking(_:to:)` or `say -v Voice -r WPM -o file.aiff "text"`. Then play with AVAudioPlayer for instant seek. This would eliminate synthesis latency on skip.

### Key APIs
- **Rate**: Float 0.0–1.0 (not WPM directly). Default 0.5 ≈ 180-200 WPM. Scale linearly: `rate = 0.5 * (desiredWPM / baselineWPM)`
- **Word tracking**: `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` delegate
- **Voices**: `AVSpeechSynthesisVoice.speechVoices()` - filter by quality (.default/.enhanced/.premium), language, traits
- **Pause/Resume**: `pauseSpeaking(at: .word)` / `continueSpeaking()`
- **Audio isolation**: `usesApplicationAudioSession = true` (default) keeps speech separate from VoiceOver

### Media Controls (AirPods, Media Keys)
- `MPRemoteCommandCenter.shared()` for play/pause/skip commands
- `MPNowPlayingInfoCenter.default()` for track info
- **macOS-specific**: Must explicitly set `.playbackState = .playing/.paused`

### WPM Calibration Strategy
- Speak known text at rate 0.5, measure elapsed time → baseline WPM
- Scale: `rate = 0.5 * (targetWPM / baselineWPM)`, clamp to [0.0, 1.0]
- For extreme speeds (600+ WPM), may hit API ceiling

## Document Parsing

### Dependencies
| Need | Library | SPM URL |
|------|---------|---------|
| ZIP/EPUB extraction | ZIPFoundation | github.com/weichsel/ZIPFoundation |
| HTML/XHTML parsing | SwiftSoup | github.com/scinfu/SwiftSoup |
| Markdown parsing | swift-markdown | github.com/swiftlang/swift-markdown |
| XML (OPF, NCX) | XMLDocument | Built-in macOS |
| MD5 hashing | CryptoKit | Built-in |

### EPUB Structure
- ZIP archive containing: mimetype, META-INF/container.xml → OPF file
- OPF has: metadata, manifest (all files), spine (reading order)
- v2 TOC: NCX file (`<navMap>/<navPoint>`)
- v3 TOC: XHTML nav document (`<nav epub:type="toc">`)
- Use `local-name()` XPath to avoid namespace issues

### Heading Extraction
- EPUB/HTML: SwiftSoup `doc.select("h1, h2, h3, h4, h5, h6")`
- Markdown: swift-markdown `MarkupWalker` visiting `Heading` nodes
- Plain text: Pattern-based (lines in ALL CAPS, or `#` prefixed)

## Accessibility (SwiftUI)

### Key Patterns
- `.accessibilityElement(children: .combine)` on list rows
- `.accessibilityAddTraits(.isHeader)` on section headers
- `.accessibilityAction(.magicTap)` for play/pause
- `@AccessibilityFocusState` for focus management
- Custom `.accessibilityRotor` for heading/bookmark navigation
- `NSAccessibility.post(notification: .announcementRequested)` for VoiceOver announcements

### Settings Window
- SwiftUI `Settings` scene auto-creates Cmd+, menu item
- TabView inside Settings for organized preferences

### Tabbed Windows
- `NSWindow.addTabbedWindow(_:ordered:)` for programmatic tab creation
- WindowGroup supports automatic tabbing

## File Management
- App Support: `~/Library/Application Support/TextMouth/`
- Security-scoped resources for file imports
- Streaming MD5 via `Insecure.MD5` hasher for large files
