# iPhone interface research: VoiceOver and braille

By `iosui-research-vo`, November 7, 2026, for the `iosui` team's spec. Nothing in this report has run on iOS: no simulator, no device, and no test of mine.

## How to read this report

Each claim carries a mark.

- DOCUMENTED: Apple's SDK headers, documentation, user guide, or WWDC sessions say it.
- REPORTED: users, developers, forums, or shipping apps' source code say it. Apple has not confirmed it.
- INFERRED: my reasoning from the above. Nobody has confirmed it.

Short names for the SDK files, all under `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/`:

- `UIAccessibility.h`, `UIAccessibilityConstants.h`, `UIAccessibilityCustomRotor.h`, `UIAccessibilityCustomAction.h`, and `UIAccessibilityContainer.h` are in `UIKit.framework/Headers/`.
- "SwiftUI interface" is `SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`.
- "SwiftUICore interface" is the same file in `SwiftUICore.framework`.
- "Accessibility interface" is the same file in `Accessibility.framework`.
- `AVAudioSessionTypes.h` and `AVSpeechSynthesis.h` are in `AVFAudio.framework/Headers/`.

Limits on the sources:

- AppleVis and nfb.org answered my direct fetches with "403 Forbidden", so I didn't retry them. Every AppleVis quotation here comes from a search tool's excerpt. The link is the page the excerpt came from or, where the tool didn't make that clear, the likeliest thread. Check a quotation against the page before repeating it as exact.
- Reddit and Stack Overflow are closed to these tools, so r/Blind isn't covered.
- Mosen at Large, Living Blindfully, Double Tap, and Blind Bargains gave me only episode pages, except for Jonathan Mosen's own 2013 review.
- The Mac has only the iOS 26 SDK, but iOS 27 shipped on September 14, 2026 and 27.2 is out ([AppleVis summary](https://www.applevis.com/blog/ios-27-ipados-27-summary-voiceover-braille-issues-improvements)). The user's iPhone may be on iOS 27, so the first real run may be on an OS newer than the SDK.
- One source deserves a warning and a recommendation. [Paperback](https://github.com/trypsynth/paperback) is an MIT-licensed reader "designed for screen reader users first", with an iOS app that has both a VoiceOver text mode and a read-aloud mode. Its code comments record what its author found on real phones. I cite them as REPORTED. The team should read `ios/Paperback/UI/Reading/` and `ios/Paperback/UI/Components/TtsControlBar.swift`. Its [AppleVis listing](https://www.applevis.com/apps/ios/books/paperback-mobile) calls it fully accessible, with one recommendation so far.

## The 15 findings that most change how the reader is built

1. No document says what VoiceOver does when a custom rotor's result is the element it already stands on. The closest report is an end-of-list sound and no speech, unresolved. Don't make the rotor the only way to move.
2. Swipe up or down on Play, moving by a chosen unit, is the proven reader pattern: Voice Dream, Speech Central, and Paperback all do it. VoiceOver selects Adjust by itself when focus lands on an adjustable element, so no rotor twist is needed.
3. Only UIKit's `UIAccessibilityCustomRotor` is lazy. SwiftUI's rotors describe every entry, and a field report has a SwiftUI rotor over a `List` being listed by VoiceOver and stepping to none of its rows.
4. For the magic tap, two audio apps override it on a `UIWindow` subclass, because a delegate behind `@UIApplicationDelegateAdaptor` "may never fire". The window is in every responder chain, sheets included.
5. Outside the app, the system's own magic tap plays and pauses the current media app, unless the iOS 26 setting Media Playback is off. Remote commands must therefore be right, as well as the in-app handler.
6. `.startsMediaSession` on Play stops VoiceOver talking over the book when the button is activated (an Apple engineer's accepted answer). It is defined for activating an element, so a magic tap isn't covered.
7. SwiftUI's documentation says a change to an element's label or value can be spoken automatically. So nothing focusable may change its label or value during playback. Compute them when asked, and never use `.updatesFrequently` on the reader.
8. While the book plays, the book is the feedback, so post no announcement after a move. While paused, announce the first words of the new place, about 0.15 seconds later so the layout notification doesn't cut it off.
9. VoiceOver focus must never chase the spoken text. Moving focus is for jumps the user asked for. Apple's criteria say a reading position mustn't reset unexpectedly, and users curse exactly that.
10. No API changes VoiceOver's ducking: it's the user's setting. The session should be `.playback` with mode `.spokenAudio` and no options, activated at Play rather than at launch, with `usesApplicationAudioSession` left true and `prefersAssistiveTechnologySettings` false.
11. The book's text must be exposed. What the app's synthesizer speaks never reaches a braille display. The working designs are one page element with `UIAccessibilityReadingContent`, `causesPageTurn`, and `accessibilityScroll`, or a lazy whole-book container of paragraph elements.
12. On arrival, VoiceOver lands somewhere by itself and may land again later. Careful apps post `.screenChanged` with the element and re-post for a few seconds if VoiceOver lands elsewhere. `AccessibilityFocusState` needs a delay, the Simulator ignores it, and sheets and `Menu` don't return focus by themselves.
13. For braille, iOS 26's Item Overview shows only the first 2 to 7 cells of each item, so labels must differ in their first cells. Announcements are short-lived flash messages, so anything announced must also be readable in an element. Sound Curtain may mute the book.
14. API traps: SwiftUI's `AccessibilityTraits` has no `.adjustable` in the iOS 26 SDK, `accessibilityDefaultFocus` is iOS 26 only, `accessibilityLinkedGroup`'s text behavior starts in iOS 27, and `UIAccessibilityCustomAction.category` is iOS 18.
15. Nobody documents VoiceOver's order for `tabViewBottomAccessory`, whose content can change with the tab bar's size. iOS 26 moves search to the bottom of the screen. Liquid Glass otherwise hardly touches VoiceOver. A plain `NavigationStack`, with the Now Playing row near the top of the library, avoids all of this.

## 1. VoiceOver's mechanics

### 1.1 Custom rotors

The forms that exist:

- `accessibilityRotor(_:entries:)` takes a builder of `AccessibilityRotorEntry`, `ForEach`, and `if` (DOCUMENTED: SwiftUI interface line 15832).
- `accessibilityRotor(_:entries:entryLabel:)` and `accessibilityRotor(_:entries:entryID:entryLabel:)` take arrays (lines 15836 and 15838).
- `accessibilityRotor(_:textRanges:)` takes an array of `Range<String.Index>` on the current element (line 15844).
- Each has a form taking `AccessibilitySystemRotor`, such as `.headings`, `.headings(level:)`, or `.links` (line 15895).
- `AccessibilityRotorEntry(_:id:in:textRange:prepare:)` points at an element tagged with `accessibilityRotorEntry(id:in:)` (lines 14933 and 14985). Its `prepare` closure is for "any manual work needed to bring the Accessibility element on-screen" ([documentation](https://developer.apple.com/documentation/swiftui/accessibilityrotorentry)).
- UIKit has `UIAccessibilityCustomRotor(name:itemSearch:)` and `init(systemType:itemSearch:)`, set through `accessibilityCustomRotors` or `accessibilityCustomRotorsBlock`, iOS 17 (`UIAccessibilityCustomRotor.h` lines 64 to 69 and 83).

Which can serve a book of 50,000 sentences lazily:

- UIKit's can (DOCUMENTED). The search block receives the current item and direction and returns one result, one call per flick (`UIAccessibilityCustomRotor.h` lines 95 to 96; [WWDC20 session 10116](https://developer.apple.com/videos/play/wwdc2020/10116/)).
- SwiftUI's can't, as far as anything shows (INFERRED). Every form takes an array or a builder over all entries. Apple's sample runs `ForEach(messages)` over every message and only the views are lazy ([documentation](https://developer.apple.com/documentation/swiftui/view/accessibilityrotor(_:entries:))). When SwiftUI evaluates the `entries` closure isn't documented.
- REPORTED, [Lumenna's `RowRotor.swift`](https://github.com/emassey0135/lumenna/blob/master/apps/apple/Lumenna/Common/RowRotor.swift), dated October 20, 2026: SwiftUI's rotor with `accessibilityRotorEntry` on each row "was listed by VoiceOver and stepped to none of them", because "a `List` being a collection view whose rows exist only while on the screen". That app switched to UIKit's rotor on the hosting view.
- DOCUMENTED: Apple says custom rotors can "replace system rotors when they don't automatically pick up off-screen elements, like those far down in a LazyVStack or a List" ([Accessible navigation](https://developer.apple.com/documentation/swiftui/accessible-navigation)).

What the search's result must point at:

- A real element (DOCUMENTED): "A UIAccessibilityCustomRotorItemResult references a real element that will be messaged for other accessibility properties" (`UIAccessibilityCustomRotor.h` line 110).
- Within text, a `UITextRange`, with the target adopting `UITextInput` (DOCUMENTED: lines 110 to 114 and WWDC20 session 10116).
- Return `nil` at either end, and "VoiceOver will remain focused on that point of interest" (DOCUMENTED: WWDC20 session 10116). The result is the boundary sound (REPORTED: [FastSM's comment](https://github.com/masonasons/FastSMRW/blob/main/ios/src/MainViewController.swift), "nowhere to jump: VoiceOver plays the boundary sound").
- Shipping apps create or reveal the target before returning it (REPORTED). FastSM scrolls the table to the row and calls `layoutIfNeeded()` first. Paperback vends lazily created elements that compare equal by unit, "so VoiceOver takes a re-created element for the one it saw before the window let it go" ([`BookElements.swift`](https://github.com/trypsynth/paperback/blob/master/ios/Paperback/UI/Reading/BookElements.swift)).

Moving a reading position when the element doesn't change:

- No Apple document covers it.
- The closest report is [forum thread 751012](https://developer.apple.com/forums/thread/751012), May 2024: an audio player's rotor changes a seek speed and returns a newly created `UIAccessibilityElement`. "The returned accessibility element isn't read out, and instead an end-of-list sound is played", even with an announcement posted. An Apple engineer asked for a bug report (FB13797657), and the thread has no answer. That element wasn't in the tree, so this isn't exactly the same-element case.
- There's a positive precedent, with its method unknown. EasyReader's Play button speaks "Use the rotor to access 15 seconds. 2 minutes. 5 minutes. Book Default. Heading one only." ([RNIB transcript](https://yourdolphin.com/support/video?id=1576&transcript=1)). A reviewer is "particularly fond of the rotor features allowing me to navigate through an audio book without even having to turn on the speech" ([App Store](https://apps.apple.com/se/app/dolphin-easyreader/id1161662515?l=en)).
- So whether VoiceOver announces, stays silent, or plays the boundary sound when the result is the same element is unknown until a real run (first on the list in section 6).

Direction: `.previous` when the user flicks up and `.next` when the user flicks down (DOCUMENTED: WWDC20 session 10116). Apple's guide agrees that swipe up is previous or increase and swipe down is next or decrease ([VoiceOver gestures](https://support.apple.com/guide/iphone/use-voiceover-gestures-iph3e2e2281/26.0/ios/26.0)).

When rotors appear:

- Only for the element or an ancestor (DOCUMENTED): "An element (or an element in the ancestor hierarchy) can expose an array of custom rotors" (`UIAccessibilityCustomRotor.h` lines 19 and 64).
- In SwiftUI, attach them to an accessibility container. A `VStack` needs `.accessibilityElement(children: .contain)` ([WWDC21 session 10119](https://developer.apple.com/videos/play/wwdc2021/10119/)).
- A rotor set on the reader's content probably isn't offered while focus is on the navigation bar's Back button or title, because the bar isn't a descendant (INFERRED).
- Use the system types `.heading`, `.link`, and `.table` where they fit: "This will allow VoiceOver to use appropriate gestures and keyboard commands" (DOCUMENTED: `UIAccessibilityCustomRotor.h`, the comment above `UIAccessibilityCustomSystemRotorType`). Paperback offers only the rotors a book has something for (REPORTED: [`BookView.swift`](https://github.com/trypsynth/paperback/blob/master/ios/Paperback/UI/Reading/BookView.swift)).

### 1.2 Adjustable elements

- Trap (DOCUMENTED): SwiftUICore's `AccessibilityTraits` in this SDK has no `.adjustable` (SwiftUICore interface lines 4931 to 4950). WWDC26 session 220's sample uses `.accessibilityAddTraits(.adjustable)`, which won't compile against this SDK. Use `accessibilityAdjustableAction` (SwiftUI interface line 1840). UIKit has `.adjustable`, with `accessibilityIncrement()` and `accessibilityDecrement()` (`UIAccessibilityConstants.h` lines 86 to 90).
- How the rotor interacts (DOCUMENTED by an Apple engineer, accepted answer, [thread 726964](https://developer.apple.com/forums/thread/726964)): "By default, if an element has the adjustable trait, VoiceOver will switch to the "adjust" rotor when that element is focused. However, the actions rotor will still be in the list." Rotating away reaches Actions, and rotating back returns to adjusting.
- So swipe up or down adjusts when focus has just landed, and follows the rotor once the user has rotated. A user who had Headings selected finds Adjust selected on landing (INFERRED from that answer). Older testing agrees: it "breaks the typical swipe up/swipe down VoiceOver gestures" ([Deque, 2015](https://www.deque.com/blog/ios-traits/)).
- What's spoken: the new value alone (DOCUMENTED by demonstration, [WWDC26 session 220](https://developer.apple.com/videos/play/wwdc2026/220/)): "Coffee dispenser, 6 ounces, adjustable." then "7 ounces." "8 ounces." The session says VoiceOver "announces the new value in real time".
- The app chooses only through what the value returns, plus any announcement it posts (INFERRED).
- Stale values are a known risk (REPORTED). If the value updates after the action returns, VoiceOver reads "the previous value again rather than the new value" ([React Native issue 35774](https://github.com/facebook/react-native/issues/35774)). [Thread 699251](https://developer.apple.com/forums/thread/699251) reports a SwiftUI custom slider, built with `accessibilityRepresentation`, not announcing its value. So update the value synchronously inside the action, or use UIKit's `accessibilityValueBlock`, which VoiceOver re-evaluates on each query (DOCUMENTED: [WWDC23 session 10036](https://developer.apple.com/videos/play/wwdc2023/10036/)).
- With no value at all, as on Paperback's Play button, nothing documents what VoiceOver says after an adjustment. Check it (section 6).
- For fine control, a double-tap and hold passthrough starts at `accessibilityActivationPoint`, and the app should announce changes, throttled to about one per 0.3 seconds (DOCUMENTED: WWDC26 session 220).

### 1.3 Actions

- `accessibilityAction(named:_:)`, `accessibilityActions(_:)`, and `accessibilityActions(category:_:)`, with `AccessibilityActionCategory`, `.default` and `.edit`, are iOS 18 for categories (DOCUMENTED: SwiftUI interface lines 654 to 667 and 24772 to 24792). UIKit has `UIAccessibilityCustomAction.category` and `editCategory` (`UIAccessibilityCustomAction.h` lines 65 to 72).
- `.edit` actions appear on VoiceOver's Edit rotor, used for actions on selected text (DOCUMENTED: [WWDC26 session 219](https://developer.apple.com/videos/play/wwdc2026/219/)). A category with your own name is "A localized name that describes the action's category". That it becomes its own rotor item is INFERRED.
- The default action is `accessibilityActivate()`: "return YES" if handled (`UIAccessibility.h` lines 339 to 346). Paperback's text elements return true even with nothing to do, "or VoiceOver taps the middle of the paragraph and may land on a link in it" (REPORTED).
- The "Actions available" verbosity is the user's: Verbosity > Actions offers speak, play sound, change pitch, braille, or nothing, and First Item Only (REPORTED: AppleVis's [deep dive](https://www.applevis.com/guides/deep-dive-voiceover-settings-ios-ipados) and [this thread](https://applevis.com/forum/ios-ipados/stop-saying-actions-available)).
- With hints off, VoiceOver says "Actions available". With hints on, it says "Swipe up or down to select a custom action, then double-tap to activate." (REPORTED: [AppleVis beginner's guide](https://applevis.com/guides/beginners-guide-using-ios-voiceover)).
- The cost of a long list: the user twists to Actions, swipes through them in order, and double-taps. On an adjustable element they must twist first.
- Users like actions for reducing clutter, but hidden actions confuse them (REPORTED: [AppleVis poll](https://www.applevis.com/forum/ios-ipados/voiceover-custom-actions-preferred-or-not), which cites YouTube's Subscribe hidden behind an action).
- "Actions available" after each paragraph is a complaint about Books (REPORTED: [AppleVis](https://www.applevis.com/forum/ios-ipados/turn-actions-available-books-app)). So put no actions on text elements.

### 1.4 The magic tap

Documented behavior:

- "UIKit looks for a method that implements the method corresponding to the gesture. It searches for the method using the responder chain, starting with the element that has the VoiceOver focus. If no object implements the appropriate method, UIKit performs the default system action" (DOCUMENTED, archived: [View Controller Programming Guide](https://developer.apple.com/library/archive/featuredarticles/ViewControllerPGforiPhoneOS/SupportingAccessibility.html)).
- Returning `true` stops the search. "To handle Magic Tap gestures from anywhere in your app, implement the `accessibilityPerformMagicTap` method in your app delegate" (same guide).
- Default system action: "plays and pauses music playback from the Music app if no Magic Tap implementation is found" (same guide). In iOS 26, Settings > Accessibility > VoiceOver > Commands > Magic Tap has a Media Playback switch, on by default. "If you switch this to Off, Magic Tap will no longer start or stop media playback when no other action is available" ([AFB](https://afb.org/blog/entry/ios-26-accessibility-features)).
- The header says to implement it "on an element, or the application" (`UIAccessibility.h` lines 397 to 403).

Audio with Now Playing info:

- Magic tap controls the last media player used, even outside the app (REPORTED). BARD: "It also works outside the app when BARD Mobile is the active audio source" ([NLS guide](https://nlsbard.loc.gov/apidocs/BARDMobile.userguide.iOS.1.2.html)). Voice Dream does the same, "even in another app" ([2024 guide](https://vitalchallengesolutions.wordpress.com/2024/07/26/a-guide-to-using-voice-dream-reader-with-voiceover-for-blind-and-visually-impaired-students/)).
- That this goes through `MPRemoteCommandCenter` is INFERRED. No source confirmed it.

Making it work on every screen of a SwiftUI app:

- `.accessibilityAction(.magicTap)` on the root view is common (REPORTED: [BookPlayer `MainView.swift`](https://github.com/TortugaPower/BookPlayer/blob/develop/BookPlayer/MainView.swift), [AudioDiary](https://github.com/NicParsons/AudioDiary/blob/main/Shared/AudioDiaryApp.swift), [TeamTalk](https://github.com/BearWare/TeamTalk5/blob/master/Client/iTeamTalk/iTeamTalk/Views/MainTabView.swift)). A sheet is a separate presentation, so whether a root modifier covers it isn't documented. Assume not (INFERRED).
- Two apps use a window. Paperback's `AppDelegate` says "with @UIApplicationDelegateAdaptor this may never fire, so UIWindow below is the reliable catch", and "The key window is always in the responder chain, so it reliably catches VoiceOver magic tap" (REPORTED: [`PaperbackApp.swift`](https://github.com/trypsynth/paperback/blob/master/ios/Paperback/App/PaperbackApp.swift)). [FastPlay](https://github.com/masonasons/FastPlay/blob/master/ios/FastPlay/App/SceneDelegate.swift) does the same.
- BookPlayer is a UIKit-lifecycle app, so its own `AppDelegate` overrides the method, the documented route, and it adds the SwiftUI modifier as well (REPORTED: [`AppDelegate.swift`](https://github.com/TortugaPower/BookPlayer/blob/develop/BookPlayer/AppDelegate.swift)).
- How Paperback gets its window under the SwiftUI lifecycle: an `@main` App with `WindowGroup { EmptyView() }`, a delegate adaptor whose `configurationForConnecting` sets `config.delegateClass = SceneDelegate.self`, and a scene delegate creating `MagicTapWindow(windowScene:)` with a `UIHostingController` as root.
- Why the adaptor's delegate may never fire (INFERRED): `accessibilityPerformMagicTap` is implemented on `NSObject`, so SwiftUI's own delegate answers it instead of forwarding it.
- Return `false` when no book is loaded, so the system's default runs (REPORTED: FastPlay; BookPlayer announces "no title" first).

Traps:

- In a text field the gesture starts dictation (REPORTED: the RNIB transcript above, in EasyReader's search field). Apple lists the same chord for "Start dictation when in text field". Check that a window handler doesn't take this over.
- It should also answer and end phone calls (DOCUMENTED: Phone app example, same guide). Check that the app's handler doesn't intercept this.

### 1.5 The escape gesture

- `UINavigationController` "already handles this gesture" (DOCUMENTED: the guide above). `accessibilityPerformEscape` is for overlays, and "return YES" if dismissed (`UIAccessibility.h` lines 388 to 395).
- "The escape action is built into native dialogs and navigation views" (REPORTED: [CVS Health](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/EscapeAction.md)). A developer found the scrub dismissing a SwiftUI `.sheet`: "Cheers that work great dismissing the sheet" (REPORTED: [Hacking with Swift forum, 2022](https://www.hackingwithswift.com/forums/swiftui/accessibility-gesture/13482)).
- `.accessibilityAction(.escape)` handles custom overlays (SwiftUI interface line 24751). A `.fullScreenCover` has no swipe to dismiss, and needs an explicit close button (REPORTED: [CVS Sheets](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/Sheets.md)). Add `.escape` there too (INFERRED).
- Apple's App Store criteria want modal views dismissible with `accessibilityPerformEscape` (DOCUMENTED: [VoiceOver evaluation criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria/)).
- Users check for this: a reviewer of a new podcast app complained of the back gesture not working (REPORTED: [AppleVis](https://applevis.com/forum/ios-ipados/introducing-anytime-podcast-app-seeking-voiceover-feedback)).

### 1.6 `accessibilityRespondsToUserInteraction` and Direct Touch

- `accessibilityRespondsToUserInteraction` is for "technologies such as Switch Control, Voice Control or Full Keyboard Access", and is otherwise inferred from traits, actions, and gestures (DOCUMENTED: [documentation](https://developer.apple.com/documentation/swiftui/view/accessibilityrespondstouserinteraction(_:))). It isn't a VoiceOver tool.
- `accessibilityDirectTouch(_:options:)` passes touches to the app (SwiftUI interface line 12606). `.silentOnTouch` keeps VoiceOver silent, "for apps that provide direct audio feedback". `.requiresActivation` needs a double tap first, and direct touch "stays active until focus moves to another element" (DOCUMENTED: `UIAccessibilityConstants.h` lines 237 to 244; WWDC26 session 220).
- Apple: "not everyone is going to be able to perform direct touch gestures", so offer custom actions too (DOCUMENTED: WWDC26 session 220).
- Users value it for games and music, and its overuse makes apps feel unresponsive, because it disables VoiceOver's gestures. A commenter warns "a blind person can accidentally swipe through the direct touch panel" (REPORTED: excerpts from AppleVis pages, among them the [test plan thread](https://www.applevis.com/forum/accessibility-advocacy/ios-app-voiceover-accessibility-test-plan) and the [developer guide](https://www.applevis.com/blog/ios-developers-taking-your-accessibility-good-great); I couldn't pin each to its page).
- It is a bad idea for a reader (INFERRED). It wouldn't exist on a braille display, it would swallow the flicks, and readers use VoiceOver's own gestures. Custom gestures don't survive VoiceOver either: Voice Dream's two-finger swipes were "hijacked by VoiceOver, so you'll have to find and use the buttons" (REPORTED: [AccessWorld, 2013](https://afb.org/aw/14/8/15662)).

### 1.7 Focus

Defaults:

- Layout changes send the cursor "to the first element displayed on the screen". On a pushed view controller, "the VoiceOver cursor falls on the Back button" (DOCUMENTED, archived and old: the guide above).
- Newer report: "VoiceOver focus will not go to the first element at the top of the new page, it may go to the first element below the page title" (REPORTED: [CVS Navigation](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/Navigation.md)). Treat this as unverified on iOS 26 and 27.
- On a pop, VoiceOver may go to the top rather than the row that was left (REPORTED: AppleVis [bug](https://www.applevis.com/bugs/ios/when-going-back-screen-voiceover-does-not-return-element-previously-focus), and [regressions in iOS 26](https://www.applevis.com/forum/ios-ipados/voiceover-focus-regressions-ios-26)).
- Sheets "will not automatically send focus back to the trigger button" (REPORTED: CVS Sheets). Another project says UIKit does return focus when the user swipes a sheet away (REPORTED: [OneBusAway PR 1629](https://github.com/OneBusAway/onebusaway-ios/pull/1629)). They disagree, so handle it in `onDismiss` either way.
- `Menu` "does not return focus back to the trigger button when closed", and "It is not possible to return focus using `AccessibilityFocusState`" (REPORTED: [CVS Menus](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/Menus.md)).

Choosing focus:

- `UIAccessibility.post(notification: .screenChanged, argument: element)`, "the element that VoiceOver should move to", or `.layoutChanged` for smaller changes (DOCUMENTED: `UIAccessibilityConstants.h` lines 125 to 136). `AccessibilityNotification.ScreenChanged(element).post()` and `LayoutChanged` exist in SwiftUI (Accessibility interface lines 235 to 248).
- `AccessibilityFocusState` with `accessibilityFocused(_:equals:)` (SwiftUI interface lines 21454 and 21499).
- New in iOS 26: `accessibilityDefaultFocus(_:_:)`, evaluated "when a scene appears and an accessibility technology like VoiceOver focuses on its content, when an accessibility focus state binding update moves focus automatically, and when the layout of a scene changes" (DOCUMENTED: line 21494 and [documentation](https://developer.apple.com/documentation/swiftui/view/accessibilitydefaultfocus(_:_:))). I found no report from anyone using it.
- `accessibilitySortPriority` reorders ("Higher numbers are sorted first"). Don't use it to move focus: a developer who tried it found "everything is out of order" ([thread 702375](https://developer.apple.com/forums/thread/702375)).

Known failures of `AccessibilityFocusState`:

- It needs a delay (REPORTED). [Thread 702375](https://developer.apple.com/forums/thread/702375) needed 0.1 seconds and an optional enum. Paperback uses 0.35 seconds on a sheet's `onAppear` ([`AccessibilityHelpers.swift`](https://github.com/trypsynth/paperback/blob/master/ios/Paperback/UI/Components/AccessibilityHelpers.swift)). A UIKit thread needed a second after dismissal ([thread 115594](https://developer.apple.com/forums/thread/115594)).
- "The iOS Simulator does not respect `@AccessibilityFocusState`" (REPORTED: [CVS FocusManagement](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/FocusManagement.md)).
- Apple's advice: request focus only for high-priority events, because moving focus without user action is disruptive, and otherwise post an announcement (DOCUMENTED: WWDC21 session 10119, as summarized by my fetch tool, not word for word).

What a careful app does (REPORTED: Paperback's [`ReadingViewController.swift`](https://github.com/trypsynth/paperback/blob/master/ios/Paperback/UI/Reading/ReadingViewController.swift)):

- "VoiceOver focuses something by itself on appearing and on coming back to the front, often the first element, which mustn't count as the reading position."
- It posts `.screenChanged` with the target in `viewDidAppear`, records a restore target for 3 seconds, and while that holds, a landing more than one unit away re-posts rather than moving the place.
- It restores only after a real return from the background. "becoming active after Control Center or a call banner leaves focus where it is, so Read All carries on."
- A jump the app chose posts `.layoutChanged` with the element. "Keeps the page on what is being read aloud without taking VoiceOver focus there" is its `follow(position:)`.

### 1.8 Announcements

- API: `AccessibilityNotification.Announcement(_:).post()` (iOS 17), or `UIAccessibility.post(notification: .announcement, argument:)` (DOCUMENTED: Accessibility interface line 228; `UIAccessibilityConstants.h` lines 138 to 143).
- Priority: set `accessibilitySpeechAnnouncementPriority` on an `AttributedString` (Accessibility interface line 77). In UIKit, set `UIAccessibilitySpeechAttributeAnnouncementPriority` (`UIAccessibilityConstants.h` line 301).
- `.high`: "Announcements will interrupt other speech and cannot be interrupted once started."
- `.default`: "Announcements will interrupt existing speech, but are interruptible if a new speech utterance is started."
- `.low`: "Announcements are queued and spoken when other speech utterances have completed" (DOCUMENTED: `UIAccessibilityConstants.h` lines 261 to 266). WWDC23 session 10036 adds: "if no new announcements have started", so a low one can be dropped.
- `speechAnnouncementsQueued` is the older form. The attribute is deprecated, renamed to priority (Accessibility interface line 73; `UIAccessibilityConstants.h` line 298). The SwiftUI view modifier remains (SwiftUI interface lines 2441 and 2451).
- A user's swipe interrupts a default-priority announcement (DOCUMENTED: a new utterance). Focus changes do too, because they speak (INFERRED).
- Completion: `UIAccessibility.announcementDidFinishNotification` carries `announcementWasSuccessfulUserInfoKey`. Apple's sample "records whether the reading of an announcement was successful or was interrupted by the user" (DOCUMENTED: the guide above). So an app can know an announcement was cut short.
- A delay is needed after a control's activation (REPORTED). Paperback: "Delayed so SwiftUI's layout-changed notification after a button tap doesn't interrupt it", at 150 ms. CVS: "Use a delay", 0.1 seconds ([AccessibilityNotifications](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/AccessibilityNotifications.md)).
- `AccessibilityNotification.PageScrolled` and `.pageScrolled`: "If the same status is used repeatedly, the assistive technology will indicate a border has been reached" (DOCUMENTED: `UIAccessibilityConstants.h` lines 145 to 152).
- Braille: see section 2. How long one stays and whether it's dropped when VoiceOver is busy isn't documented. Check on the phone.

### 1.9 Traits

- `.startsMediaSession`: "Used when activating an element starts a media session (e.g. playing a movie, recording audio) that should not be interrupted by output from an assistive technology, like VoiceOver" (DOCUMENTED: `UIAccessibilityConstants.h` lines 80 to 84). See section 3 for details.
- `.playsSound`: "Used when the element plays its own sound when activated" (line 54). Apple doesn't say what VoiceOver does differently. TextMouth plays a play sound on the Mac, so this matters if that sound comes across.
- `.updatesFrequently`: "too often to send notifications. Allows an accessibility client to poll for changes" (lines 74 to 78). VoiceOver "will poll the control while it is focused", and reads the current value (REPORTED: Deque, 2015). Don't use it on anything a listener might stand on.
- `.causesPageTurn`: VoiceOver calls `accessibilityScroll` with `.next` when it finishes reading, "and will stop scrolling when it detects the content has not changed" (DOCUMENTED: lines 95 to 100).
- `.isHeader`: heading. The level comes from `accessibilityHeading(_:)` in SwiftUI, or `UIAccessibilityTextAttributeHeadingLevel` in UIKit (line 323).
- `.isSelected`: for a selected item, such as the chosen unit in a list.
- `.isToggle`, iOS 17: "Filter, switch button. Double-tap to toggle setting." (DOCUMENTED: WWDC23 session 10036). Not for Play: Apple's own label guidance uses "Play" (`UIAccessibility.h` lines 56 to 59).
- `.isSummaryElement`: "When the app first loads, the summary element is read off", and "it does not receive focus" (REPORTED: Deque, 2015). Documented as for when the app "first launches" (lines 63 to 69). This fits a one-time "resume" line, but it's untested and old.
- `.allowsDirectInteraction`: see Direct Touch above.
- `.isTabBar`: for a custom tab bar container. The object "should return NO for isAccessibilityElement" (lines 102 to 106).
- `.isModal` and `accessibilityViewIsModal`: "elements outside this view will be ignored" (`UIAccessibility.h` lines 162 to 167). Setting it "may not be enough" when siblings remain ([Orange guidelines](https://a11y-guidelines.orange.com/en/mobile/ios/development/)).
- `UIAccessibilityContainerType`: `.list`, `.landmark`, `.semanticGroup`, and `.dataTable` (`UIAccessibilityConstants.h` lines 229 to 235; `accessibilityLabel` is queried for a semantic group). Paperback sets `.list` on a list block, with a label such as "5 items".
- `AccessibilityChildBehavior`: `.ignore`, `.contain`, `.combine` (SwiftUI interface lines 23742 to 23744). `List` and `LazyVStack` are containers by default. `VStack` and `HStack` aren't (DOCUMENTED: WWDC21 session 10119).

### 1.10 Reading long text

Apple's session on exactly this, [WWDC26 session 219, "Enhance the accessibility of your reading app"](https://developer.apple.com/videos/play/wwdc2026/219/), sets three goals (DOCUMENTED): granular navigation, continuous reading, and text selection.

The routes:

- `UITextView`, `TextEditor`, and `Text` with `.textSelection(.enabled)` adopt `UITextInput`, "that allow for line, word, and character navigation with VoiceOver and Speak Screen, alongside accessible text selection."
- A custom view adopts `UITextInput` in full, including `selectionRects(for:)`, `text(in:)`, and a tokenizer, which handles line, sentence, word, and character movement. "To get all of the accessibility benefits of this protocol, make sure you implement it in its entirety." An element can forward through `accessibilityTextInputResponder`, iOS 18.1 (`UIAccessibility.h` line 508).
- `UIAccessibilityReadingContent` has `accessibilityLineNumber(for:)`, `accessibilityContent(forLineNumber:)`, `accessibilityFrame(forLineNumber:)`, `accessibilityPageContent()`, and attributed versions (`UIAccessibility.h` lines 414 to 441). The session calls it "a great way to make full page content accessible", and focuses on `UITextInput` as "higher fidelity". [WWDC19 session 248](https://developer.apple.com/videos/play/wwdc2019/248/) shows the whole implementation, with attributes for language and IPA.
- A scrolling or paged view of paragraphs needs links between text views: `accessibilityNextTextNavigationElement` and `accessibilityPreviousTextNavigationElement`, iOS 18 (`UIAccessibility.h` lines 496 to 500). Without them, "VoiceOver is stuck navigating by line within the paragraph", with a sound at the end. In SwiftUI, `accessibilityLinkedGroup` does this "starting in iOS 27". The documentation says all elements must be text views.
- Read All across pages: `causesPageTurn` on the last element, `accessibilityScroll(_:)`, and post `.pageScrolled`. Speak Screen also follows it.

Reports on these routes:

- At line granularity, lines with leading spaces are skipped, which an Apple engineer called "a bug" (REPORTED: [thread 807607](https://developer.apple.com/forums/thread/807607), November 2025). Strip leading whitespace from line content.
- `UIAccessibilityReadingContent` gives line-by-line touch exploration, but flicks still move between elements (REPORTED: [thread 821161](https://developer.apple.com/forums/thread/821161), community answer).
- A read-only `UITextView` gets the static-text trait rather than text-entry (REPORTED: [Tapsmith PR 474](https://github.com/tapsmith/tapsmith/pull/474)).
- `.textSelection` on `Text` behaves differently by version: on iOS 26 or earlier, touch and hold gives a system menu for the entire text, and handles arrive in iOS 27 (DOCUMENTED: [documentation](https://developer.apple.com/documentation/swiftui/view/textselection(_:))).
- A whole-book container (REPORTED: Paperback, commit a3a08ef, October 28, 2026, "so Read All no longer stops at the scroll bar"):
  - `accessibilityElementCount()` returns the block count, and `accessibilityElement(at:)` creates an element on demand.
  - Off-page elements get frames whole screen heights away.
  - `accessibilityHitTest(_:event:)`, iOS 18, answers touch exploration from the visible page. "left to itself, VoiceOver would walk every element in the book to find the one under a finger" (`UIAccessibility.h` line 490).
  - `accessibilityScroll` turns pages on three-finger flicks, and `accessibilityScrollStatus(for:)` answers the three-finger tap with page and percent.
  - Its comment: "VoiceOver asks only a scroll view it can scroll for the three-finger tap's status", so the view is a scroll view with its offset pinned.

Other tools:

- `accessibilityTextContentType(.narrative)` or `UIAccessibilityTextualContext.narrative` tells assistive technology how to treat text (DOCUMENTED: SwiftUICore interface line 3810). VoiceOver Activities can switch settings by Context, such as Word Processing (DOCUMENTED: [VoiceOver settings guide](https://support.apple.com/guide/iphone/change-your-voiceover-settings-iphfa3d32c50/26.0/ios/26.0)). Narrative as a Context choice isn't confirmed. Set it anyway, because it costs nothing.
- `speechAlwaysIncludesPunctuation`, `speechSpellsOutCharacters`, and `speechAdjustedPitch` exist for `Text` and `View` (SwiftUI interface lines 2438 to 2451). Not for books: leave punctuation to the user's setting.
- Set language per passage with `accessibilityLanguage` or `UIAccessibilitySpeechAttributeLanguage` (DOCUMENTED: `UIAccessibilityConstants.h` line 288). Books in other languages need this.
- A plain long `Text` is one static element with no selection (INFERRED from the session's "with selection enabled"). Paperback's read-aloud screen uses `ScrollView { Text(currentSegmentText) }` for the segment being read.
- `TextEditor(.constant(text))` is Apple's own sample for text ranges ([documentation](https://developer.apple.com/documentation/swiftui/view/accessibilityrotor(_:textranges:))). It reads as an editor, so it isn't ideal for a book.

### 1.11 VoiceOver's state

- `UIAccessibility.isVoiceOverRunning` and `voiceOverStatusDidChangeNotification` (DOCUMENTED: `UIAccessibility.h` lines 529 to 531). SwiftUI's environment has `accessibilityVoiceOverEnabled` (SwiftUI interface line 980).
- `UIAccessibility.elementFocusedNotification`, with `focusedElementUserInfoKey` and `unfocusedElementUserInfoKey` (`UIAccessibilityConstants.h` lines 181 to 189).
- `UIAccessibility.focusedElement(using: .notificationVoiceOver)` reads the current element (`UIAccessibility.h` lines 324 to 328).
- On an element: `accessibilityElementDidBecomeFocused()`, `accessibilityElementDidLoseFocus()`, and `accessibilityElementIsFocused()` (lines 315 to 319). These must be on the element itself, since overriding them in a view controller doesn't help (REPORTED: Orange guidelines).
- No API tells an app that a Read All is running, that VoiceOver is mid-speech, or what its voice is (INFERRED: I found none in these headers).

### 1.12 Lists

- `List` rows are real elements. "VoiceOver will not speak a "List" trait or "1 of 6" number of items list semantics" (REPORTED: [CVS Lists](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/Lists.md)). iOS 26 adds a verbosity option for list position, spoken, in braille, or off ([ONCE's summary](https://cti-repos.once.es/cti/biblioteca/Accesibilidad/iOS/Novedades_accesibilidad_en_iOS26/Novedades_de_accesibilidad_en_iOS_26.html)).
- `swipeActions` is documented only for touch. Whether it becomes custom actions automatically isn't documented, though users know swipe-to-delete as an action (INFERRED; check). Overcast's swipe to delete under VoiceOver "takes several steps" (REPORTED: [AppleVis podcast threads](https://applevis.com/forum/ios-ipados/overcast-vs-pocket-casts-which-should-i-choose)). Provide explicit `accessibilityAction(named:)` actions on each row, unless the check shows they'd double up.
- `contextMenu`: Apple's criteria say to "consider providing the same behaviors as a custom action using VoiceOver's actions rotor or its equivalent "show context menu" keyboard command" (DOCUMENTED). A triple tap is touch and hold ([VoiceOver gestures](https://support.apple.com/guide/iphone/use-voiceover-gestures-iph3e2e2281/26.0/ios/26.0)).
- Section headers as headings aren't documented for SwiftUI. Add `.accessibilityAddTraits(.isHeader)` if a check shows they aren't (INFERRED).
- Index bar: new in iOS 26, `sectionIndexLabel(_:)` and `listSectionIndexVisibility(_:)` (DOCUMENTED: SwiftUI interface lines 4272 and 4310). VoiceOver users tap the far right edge and flick (REPORTED: [BARD guide](https://nlsbard.loc.gov/apidocs/BARDMobile.userguide.iOS.1.2.html)).
- Search: when suggestions appear, post an announcement of the count (REPORTED: [CVS SearchSuggestions](https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/Documentation/SearchSuggestions.md)).
- Row labels: `.accessibilityElement(children: .combine)` groups a row. Long row labels annoy (REPORTED: the Anytime podcast thread, about each item announcing its controls before the episode's title). Put the title first.
- `LazyVStack` versus `List`: "Headers placed in a LazyVStack don't work when the view isn't visible" on the headings rotor (REPORTED: [thread 756860](https://developer.apple.com/forums/thread/756860)). Use `List` for the library. Sluggishness with new rows is a known complaint in BookPlayer: VoiceOver "takes quite a while to read the titles and sometimes jumps focus back up in the list" (REPORTED: [AppleVis, 2026](https://www.applevis.com/forum/ios-ipados/problems-bookplayer-sluggishness-voiceover)).
- Background refresh of a list mustn't reset the cursor (DOCUMENTED: the criteria, "a VoiceOver user's reading position shouldn't reset unexpectedly"). Feed updates and import rows must keep stable identities (INFERRED).

## 2. Braille

Nearly everything here comes from Apple's guides, but Apple documents no rule for how labels, values, hints, and traits appear on a display.

What the display shows:

- VoiceOver sends an element's label, value, and traits to the display, and shows hints as alert messages (REPORTED: the 2021 podcast below). The exact form and order, with trait abbreviations, isn't documented. Apple only requires that custom text entry "produce correct speech/braille output" (DOCUMENTED: the criteria).
- Short labels help because space is limited, such as "New document" (REPORTED: [AppleVis developer guide](https://www.applevis.com/blog/ios-developers-taking-your-accessibility-good-great)).
- Text the app's synthesizer speaks never reaches the display. "Text that VoiceOver doesn't speak also never reaches a Braille display" (REPORTED: same guide). So the book must be an element.
- Settings that affect output (DOCUMENTED: [Use a braille display](https://support.apple.com/guide/iphone/use-a-braille-display-iph73b8c43/26.0/ios/26.0)):
  - Item Overview, "Adjust the number of cells displayed per item", toggled by dots 6, 7, and 8. AFB: "It shows you the first few cells of items on the screen on a single line", and "from 2 to 7 cells for each item" ([AFB](https://afb.org/blog/entry/ios-26-accessibility-features)).
  - Status Cells: general and text status.
  - Word Wrap, Text Formatting, and Use Underline Cursor.
  - Turn Pages when Panning: "Automatically turn pages when panning."
  - Braille Alert Messages: "your braille display shows an alert message for the specified duration."
  - Auto Advance Duration.
  - Sound Curtain: "When a braille display is connected to iPhone, mute most sounds." AppleVis says this covers apps and music ([deep dive](https://www.applevis.com/guides/deep-dive-voiceover-settings-ios-ipados)). So a braille reader with Sound Curtain on may hear no book at all. Check that.
- Announcements: "Those are VoiceOver announcements or braille alert messages for braille display users", flash messages whose duration the user sets (REPORTED: [AppleVis podcast, 2021](https://www.applevis.com/podcasts/ifeelit-introduction-using-braille-displays-ios-2021-edition)). There's an announcement history, with its own command. That app-posted announcements are included is INFERRED: check it. On the Mac, VoiceOver "stores up to 30 announcements" (DOCUMENTED: [Mac guide](https://support.apple.com/en-ph/guide/voiceover/vo15621/mac)).
- In a text view the display shows the text with a cursor, two cells by default or one underline cell under Use Underline Cursor, and cursor routing keys place it. iOS 26 adds pressing a routing key twice to select a word (REPORTED: AFB). iOS 27 adds Snap to Print Text Cursor under Cursor Routing and a Text Field Labels setting, and keeps a text field's label on the display when it's active (REPORTED: [AFB on iOS 27](https://afb.org/ios-27-accessibility), AppleVis).

Commands (DOCUMENTED: [Common braille commands](https://support.apple.com/en-us/118665); each is pressed with Space):

- Previous item, dot 1. Next item, dot 4.
- First item, dots 1-2-3. Last item, dots 4-5-6.
- Perform simple tap (activate), dots 3-6. A cursor routing key also activates, as far as I know, but no source here says so: check.
- Escape current context, dots 1-2.
- Move by rotor setting, previous dot 3, next dot 6.
- Select rotor setting, previous dots 2-3, next dots 5-6.
- Read from selected item, dots 1-2-3-5. Read from top, dots 2-4-5-6.
- Scroll page up, dots 3-4-5-6. Scroll down, dots 1-4-5-6. Speak page number, dots 3-4.
- Pan left, dot 2. Pan right, dot 5.
- Toggle announcement history, dots 1-3-4-5.
- Pause or continue speech, dots 1-2-3-4. Toggle speech, dots 1-3-4.
- Play/Pause Music and "Start dictation when in text field", both dots 1-5-6. AppleVis calls this "the "Magic Tap" gesture--the equivalent of double-tapping with 2 fingers" (REPORTED: [10 more tips](https://www.applevis.com/blog/10-more-tips-braille-display-users-idevices)).
- Simulated long press, dots 3-6-7-8.
- Custom rotors and actions are rotor settings, so dots 2-3 or 5-6 select them and dots 3 or 6 use them (INFERRED from the commands). A Voice Dream user reports that "Navigation Unit settings can be changed with the display's controls" (REPORTED: [AppleVis](https://www.applevis.com/forum/braille-apple-products/reading-books-braille-display-voicedream-reader)).
- Commands can be reassigned by the user, so spec text must name commands, not only chords (DOCUMENTED: Apple's guide, Braille Commands).

Typing:

- A display types into text fields (DOCUMENTED: Use a braille display). Braille Screen Input is available from the rotor, or by an activation gesture, and it can also run commands, in Command Mode (DOCUMENTED: [Type braille](https://support.apple.com/guide/iphone/type-braille-on-the-screen-iph10366cc30/26.0/ios/26.0)).
- iOS 26 has a bug where letters get lost when typing in Mail and other apps, marginally better by 26.4 (REPORTED: AppleVis summary, excerpt in my [search](https://www.applevis.com/blog/ios-26-ipados-26-summary-voiceover-braille-issues-improvements)).
- A `.searchable` field needs nothing special (INFERRED): check typing there.

Braille Access (DOCUMENTED: [Use Braille Access](https://support.apple.com/guide/iphone/use-braille-access-with-a-braille-display-iph5953d3c7a/26.0/ios/26.0)):

- Pressing dots 7 and 8 opens a system notetaker with Launch App, Choose Item, Braille Notes, BRF Files, Calculator, Live Captions, and Time. iOS 27 adds plain text and PDF (AFB).
- Apps don't integrate with it. It matters because users may read BRF files there, and may return to TextMouth by Launch App. Its chord could collide with nothing of ours, because we define no chords.
- iOS 26.4 adds Touch Curtain for braille displays, which stops touch input while a display is connected (REPORTED: [AppleVis, 26.4](https://applevis.com/blog/apple-releases-ios-264-ipados-264-new-emoji-generative-ai-features-apple-music-accessibility)). So nothing may need touch.

What an app must do so a braille user gets the same as a speech user:

- Everything spoken by the app must also be text on an element (DOCUMENTED principle: the criteria; REPORTED: AppleVis guide).
- Labels need distinct first cells, for Item Overview (INFERRED). "Play", "Move by", "Previous", "Next", and "Speed" are good. Avoid "Go to next", "Go to previous".
- Don't add words a display reader must pan past: no "button", since traits supply it (DOCUMENTED: `UIAccessibility.h` lines 56 to 59).
- Don't use only sound, pitch, or haptics for meaning (INFERRED; project rule).

A time value changing each second:

- A live update moving a braille reader's line was a real bug in Live Captions: "When further text arrives", the reader is "placed at the start of the line" (REPORTED: [AppleVis bug](https://www.applevis.com/bugs/ios/when-using-live-captions-new-text-arrives-braille-display-user-interrupted-where-they-are), fixed 16.6). Braille Access's own live captions don't refresh the display, per [ONCE's summary](https://cti-repos.once.es/cti/biblioteca/Accesibilidad/iOS/Novedades_accesibilidad_en_iOS26/Novedades_de_accesibilidad_en_iOS_26.html), so Apple has met the same problem.
- So a focused element shouldn't change each second (INFERRED). Show place on request: a Where Am I element whose value is computed when focused. A status readout that changes must be hidden from VoiceOver or frozen while focused.

## 3. The hard question: an app that speaks while VoiceOver speaks

### 3.1 Ducking and sessions

- Ducking is a VoiceOver setting (DOCUMENTED): "To temporarily reduce the volume of other iPhone audio while VoiceOver is speaking, go to Settings > Accessibility > VoiceOver > Audio, tap Audio Ducking, then select When Speaking. Drag the Ducking Amount slider" ([settings guide](https://support.apple.com/guide/iphone/change-your-voiceover-settings-iphfa3d32c50/26.0/ios/26.0)). The volume buttons change VoiceOver and all other audio together (same guide).
- The choices are Off, When Speaking, and Always (REPORTED: [AppleVis podcast](https://www.applevis.com/podcasts/how-use-audio-ducking-ios-clearer-voiceover), [deep dive](https://www.applevis.com/guides/deep-dive-voiceover-settings-ios-ipados)). It's reachable from the rotor and Quick Settings. Since iOS 18, VoiceOver volume above 100% drives ducking (REPORTED: [AppleVis](https://www.applevis.com/forum/ios-ipados/could-someone-explain-me-how-vo-volume-works-ios-18)).
- Nothing an app sets changes this (INFERRED, strongly). No header or interface in UIKit's accessibility files, the Accessibility framework, or SwiftUI mentions ducking: I searched them, with zero matches.
- Users complain about audio left low, and many turn ducking off for audiobooks or keep it on the rotor to toggle. One restored BBC catch-up volume by "disabling audio ducking via the rotor" (REPORTED: [AppleVis](https://www.applevis.com/forum/ios-ipados/volume-decrease-bbc-radio-catch-podcasts)). The app can't fix this, so say so in the user guide.

The session options, from Apple's text:

- `.spokenAudio`: "Appropriate for applications which play spoken audio and wish to be paused (via audio session interruption) rather than ducked if another app (such as a navigation app) plays a spoken audio prompt. Examples of apps that would use this are podcast players and audio books." (DOCUMENTED: `AVAudioSessionTypes.h` lines 176 to 179.) [Documentation](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/spokenaudio): "After the interrupting app's audio ends, you can resume your app's audio playback."
- `.mixWithOthers`: lets other apps play beside this one. Wrong for a book (INFERRED).
- `.duckOthers`: "Note that the other audio will be ducked for as long as the current session is active" (lines 436 to 450). Documentation: "Set this option on a temporary basis only. Don't use it to duck the audio of other apps for more than a few seconds."
- `.interruptSpokenAudioAndMixWithOthers`: for "a navigation app that provides prompts to its user" (lines 484 to 499). Wrong for a book.
- So the choice is `.playback` with `.spokenAudio` and no options (INFERRED from these). Paperback uses exactly that, set at playback "not at startup, because `.playback` is not mixable and would interrupt other apps on launch" (REPORTED: [`TtsManager.swift`](https://github.com/trypsynth/paperback/blob/master/ios/Paperback/Model/Speech/TtsManager.swift)). BookPlayer and Pocket Casts name `.spokenAudio` in their players (REPORTED: GitHub search hits, [BookPlayer `PlayerManager.swift`](https://github.com/TortugaPower/BookPlayer/blob/develop/BookPlayer/Player/PlayerManager.swift), [Pocket Casts `PlaybackManager.swift`](https://github.com/Automattic/pocket-casts-ios/blob/trunk/podcasts/PlaybackManager.swift)).

Does VoiceOver speaking pause a `.spokenAudio` session?

- Apple doesn't say so. The mode names apps playing prompts, and `.interruptSpokenAudioAndMixWithOthers` is what triggers it.
- REPORTED no, across years: "You can use VoiceOver to find this or any other control without interrupting the reading" ([AccessWorld on Voice Dream, 2013](https://afb.org/aw/14/8/15662)). VoiceOver users move around Overcast and BookPlayer during playback.
- INFERRED: VoiceOver mixes, and it ducks only if the user asked.

### 3.2 `AVSpeechSynthesizer` beside VoiceOver

- `usesApplicationAudioSession`: "The AVSpeechSynthesizer will use the AVAudioSession sharedInstance when set to YES. The AVSpeechSynthesizer will use a separate AVAudioSession for playback when set to NO. Additionally, the audio session will mix and duck other audio, and its active state will be managed automatically." The separate session "may have a different route". "Default is YES." (DOCUMENTED: `AVSpeechSynthesis.h` lines 259 to 263.) For a book, leave it true so the book plays under the app's session in the background (INFERRED). The other research team owns the details.
- `prefersAssistiveTechnologySettings`: "If an assistive technology is on, like VoiceOver, the user's selected voice, rate and other settings will be used for this speech utterance instead of the default values" (DOCUMENTED: lines 206 to 210). Keep it false for the book, as TextMouth's shared code already does on every utterance (`SpeechService.swift` lines 489 and 1151, `AudioEngineService.swift` line 1182, `ReaderViewModel+WhereAmI.swift` line 454).
- Apple's stance on using both: "AVSpeechSynthesizer is not a replacement for the UIAccessibility APIs and, instead, should be used in conjunction with those APIs". "AVSpeechSynthesizer might be able to provide you with some additional flexibility even if your app is going to be used in conjunction with an assistive technology", with Seeing AI as the example. "no need for you to create your own screen reader" (DOCUMENTED: [WWDC20 session 10022](https://developer.apple.com/videos/play/wwdc2020/10022/)).
- One engine or queue? Not documented. Apple's Seeing AI example has both speaking, and I found no report of one queueing behind the other (INFERRED: separate queues, with the two voices mixed).
- Known bug where VoiceOver cancels or truncates an utterance: I searched and found none. The nearest are a lockup in `stopSpeaking(at:)` ([thread 40075](https://developer.apple.com/forums/thread/40075)) and a crash on stop ([thread 716963](https://developer.apple.com/forums/thread/716963)). Absence of a report isn't proof, so log `didCancel` and `didPause` on the first run.
- `speechVoices()` under VoiceOver: no documented difference. Voices download in Settings > Accessibility, now under Read & Speak in iOS 26 (REPORTED: AppleVis excerpt). Using one voice for both is the user's choice.

### 3.3 Activating Play

- Apple engineer, accepted answer, about "Play button, playing..." spoken over audio: "You want to add the startsMediaSession trait to this button using the accessibilityTraits property. This will tell VoiceOver that audio will be playing as a result of the button press and it will act accordingly" (DOCUMENTED by staff: [thread 699201](https://developer.apple.com/forums/thread/699201)).
- "Applying this trait to a button stops this behavior, canceling any announcement" (REPORTED: [Deque, tested 2015](https://www.deque.com/blog/ios-traits/)). "Use this trait to silence the audio output of an assistive app, such as VoiceOver, during a media session" (DOCUMENTED: [documentation](https://developer.apple.com/documentation/uikit/uiaccessibilitytraits/startsmediasession)).
- For how long: undocumented. Whether the activation sound still plays: undocumented. Whether a later flick is silenced: reports show users moving around during playback, so it isn't lasting (INFERRED).
- A magic tap isn't activating an element, so the trait's definition doesn't reach it (INFERRED). If focus is on Play and the label changes, SwiftUI may speak it: "Announcements can occur automatically when the label or value of an accessibility element changes" (DOCUMENTED: [`speechAnnouncementsQueued`](https://developer.apple.com/documentation/swiftui/view/speechannouncementsqueued(_:))). Check that case first.
- Should the app delay speech? Apple's answer to a developer wanting a delay was the trait instead. Paperback adds no delay before speech. So start at once, and add a short delay only if the real run shows the book's first words being lost (INFERRED). TextMouth's own play sound and VoiceOver's click may overlap: check.
- Should a toggled button re-announce? After Pause, VoiceOver saying "Play" confirms the stop in the silence that follows, and is useful. After Play, the book is the confirmation, so silence is right. So set `.startsMediaSession` only in the Play state (INFERRED). Paperback's `Button` label flips between "Pause" and "Play" (REPORTED). The Music app once had a bug speaking Pause as Play ([AppleVis, fixed 14.5](https://www.applevis.com/bugs/ios/voiceover-incorrectly-speaks-pause-button-play-expanded-mini-player-or-now-playing-screen)), so getting this right is noticed.

### 3.4 Silence and speech

Stay silent while the book plays:

- Page turning, a heading passing, a sentence's progress, percent, time, and a chapter change. Nobody asked, and it talks over the book. Mosen praised Voice Dream for not being interrupted when "VoiceOver can interrupt itself during continuous reading when a notification arrives" ([2013](https://mosen.org/voice-dream-reader-truly-a-dream-app/)).
- A move during playback: Paperback's `stepSegment` speaks the new text and doesn't announce (REPORTED: [`ReadingController.swift`](https://github.com/trypsynth/paperback/blob/master/ios/Paperback/Model/State/ReadingController.swift)).
- Any changing value, per section 2 and the SwiftUI quotation above. Users notice: one says VoiceOver "interrupts what they are listening to every time that the minute advances" (REPORTED: a focus thread in a search excerpt of AppleVis; I couldn't pin the page).

Speak when:

- The user moves while paused: Paperback announces the first five words (REPORTED: `announceNavigationCue`).
- A move hits the book's edge: a delayed "End of document" or "Beginning of document" (REPORTED: `TtsControlBar.swift`). Silence would look like a dead control.
- The user asks: Where Am I, or a focus on a status element.
- An error or stop the listener would otherwise take for silence: end of book, a file that can't be played, or a route change that pauses.
- A long import finishing: `.low` priority, so it doesn't cut in (DOCUMENTED definition above).
- Apple's rule for banners and alerts: "timely but non-disruptive" (DOCUMENTED: the criteria).

### 3.5 Hearing a book and using VoiceOver at once

- The working model in every app: the book keeps playing, and the user flicks. VoiceOver speaks over it, ducked or not as the user chose. The user can two-finger-tap to quiet VoiceOver (DOCUMENTED: gesture list) or mute it with a three-finger double tap, though neither stops the app. A developer was told to suggest exactly this to users of a video app (REPORTED: [AppleVis](https://applevis.com/forum/app-development-programming/how-stop-voiceover-speaking-over-videos)).
- Focus must not move while the book plays. Apps that pull focus are cursed (section 4). Paperback separates `jump` (VoiceOver follows, for places the user chose) from `follow` (only the page follows).
- Reviewing what's read:
  - Pause, flick to the text element, and use Lines, Words, and Characters on the rotor (DOCUMENTED: WWDC26 session 219 for text views; for Voice Dream, the developer: "VO will read the line of text that you tap on, and you can use Word and Character options on the Rotor", [AppleVis](https://www.applevis.com/apps/ios/education/voice-dream-text-voice)).
  - Pausing and then finding the last-spoken word is a known difficulty. An AccessWorld review of Capti says it was hard to locate with VoiceOver after pausing (REPORTED: [AccessWorld](https://www.afb.org/aw/full-issue?id=13968), as excerpted). So when paused, make the text element start at the sentence just spoken.
- Braille while listening: Voice Dream advertises "you can read along in braille while you listen, or instead" ([site](https://www.voicedream.com/)). Its users say braille "generally works when speech isn't running", and that it "does not currently let you switch between voice and Braille while keeping your place" (REPORTED: [AppleVis thread](https://www.applevis.com/forum/braille-apple-products/reading-books-braille-display-voicedream-reader)). This is a chance to do better.

### 3.6 Should the book's text be exposed?

Yes, without doubt.

- "VoiceOver should be able to speak all visible text in your app" (DOCUMENTED: the criteria).
- Braille needs it, per section 2.
- Users choose VoiceOver's own reading for reasons the app can't replace: voice choice, and one reader's better attention to an information book when going line by line or paragraph by paragraph (REPORTED: excerpt of [AppleVis](https://www.applevis.com/forum/ios-ipados/what-everyones-favorite-way-read-ebooks)).
- Apple's own Accessibility Reader, iOS 26, also reads from it (DOCUMENTED: WWDC26 session 219).

How others do it:

- Voice Dream: one text area among the controls. In order: "Library button", Document menu, Controls, Audio settings, Visual settings, Add bookmark, Previous item, Next item, a heading with the document title and section, the document text, Headings/bookmarks/highlights, the text selection tool, play/pause, the navigation rate selector, search, a time and position readout, and go-to-page (REPORTED: [2024 guide](https://vitalchallengesolutions.wordpress.com/2024/07/26/a-guide-to-using-voice-dream-reader-with-voiceover-for-blind-and-visually-impaired-students/)). The user touches near the center of the screen to enter the text. Users pan into it, and report "no paragraph marks".
- EasyReader: a switchable "Screen Reader View", "a linear reading mode", for "braille readers and screen readers" ([App Store](https://apps.apple.com/us/app/dolphin-easyreader/id1161662515), [features](https://yourdolphin.com/EasyReader-App/Features)). A "Play on navigation" setting decides whether reading starts after a jump.
- BARD Mobile: a braille reading window, with Previous, Menu, and Next below it for jumps by line, page, volume, bookmark, or keyword (DOCUMENTED by NLS). AccessWorld's reviewer notes that flicking into the reading area can make it easy to lose your place (REPORTED).
- Paperback: two modes, switched from a menu, with the bar shared.
- Apple News style: "each paragraph as an object, so each VoiceOver flick gesture reads a paragraph". Users in a developer's poll also prefer literal visual lines on the Lines rotor (REPORTED: [AppleVis](https://applevis.com/forum/app-development/question-developer-what-s-your-preference-line-navigation-behaves-when-using)). The same thread: "Voice Dream made a UI element to choose the navigation unit and put paragraph in there, since paragraphs aren't in the standard rotor."

## 4. What blind readers say

Dates vary, and AppleVis quotations are from search excerpts.

### Voice Dream Reader

- Praise: "Voice Dream Reader's "now reading" screen is very well thought-out", and its buttons can be swiped "for incremental changes" ([Mosen, 2013](https://mosen.org/voice-dream-reader-truly-a-dream-app/)).
- Praise: "swipe up and down on the play/pause button to rewind and fast forward", with a navigation rate selector that sets the unit ([2024 guide](https://vitalchallengesolutions.wordpress.com/2024/07/26/a-guide-to-using-voice-dream-reader-with-voiceover-for-blind-and-visually-impaired-students/)). The unit list includes "sentence, paragraph, page, chapter, highlights, bookmarks, 15, 30, and 60 seconds" ([AppleVis listing](https://www.applevis.com/apps/ios/education/voice-dream-text-voice)).
- Curse: braille. "the text box is not optimized to be used with a Braille display" ([AppleVis](https://www.applevis.com/forum/braille-apple-products/reading-books-braille-display-voicedream-reader)), and a commenter's "total disaster for Braille display users" ([AppleVis](https://www.applevis.com/comment/165309)).
- Curse: the first line or so skipped at a page turn ([AppleVis](https://applevis.com/forum/ios-ipados/turning-pages-using-bookshare-voice-dream-reader)).
- The 2024 subscription turnaround: existing buyers were told they'd keep what they bought, were then moved to a subscription, and after the outcry the owner reversed it ([Michael Tsai's summary](https://mjtsai.com/blog/2024/04/08/voice-dream-reader-switches-to-subscriptions/), [Double Tap](https://doubletaponair.com/voice-dream-reader-changes-direction-making-websites-accessible/)). What it shapes: readers rely on these apps daily and treat loss of access to their library as a serious harm. Their library and places must stay theirs and work offline (INFERRED).
- Changelog signals: "The speed slider & stepper will now work as expected with VoiceOver, and read out the current speed in WPM", and "Folders in your library will now read out the amount of items inside them" ([App Store](https://apps.apple.com/us/app/voice-dream-natural-reader/id496177674)).

### Dolphin EasyReader

- Praise: the review quoted in 1.1, about rotor features. "VoiceOver reads all of the buttons and labels, it's well laid out and uncluttered" ([2017](https://alternatevisionscoaching.org/2017/08/25/dolphin-easy-reader-app-for-ios-review/)). In the AppleVis Hall of Fame ([Dolphin](https://yourdolphin.com/news?id=521)).
- Layout: a top bar with Search, the title, percent, Text Settings, and Audio Settings, and a bottom bar with Book Navigation, Navigation Modes, Previous, Play, Next, Sleep Timer, and Bookmarks (2017 review and [Dolphin](https://yourdolphin.com/support/article?id=32)). "it's taken the focus straight to the Play button" ([RNIB](https://yourdolphin.com/support/video?id=1576&transcript=1)).
- Curse: "trying to swipe left or right to go to the previous or next control off and landed me on the control which was not labeled, or which was far too easy to inadvertently change that's losing my position within the book. Yet trying to change the voice speed was excruciatingly tedious" ([App Store, 2018](https://apps.apple.com/us/app/dolphin-easyreader/id1161662515)).

### Apple Books

- Praise: Read All: "swipe down with two fingers, the Read All gesture" ([AppleVis](https://www.applevis.com/forum/ios-ipados/apple-books)). Recommended, with Kindle, for braille ([AppleVis](https://www.applevis.com/forum/braille-apple-products/reading-books-braille-display-voicedream-reader)).
- Curse: continuous reading that stops after a couple of pages, so the reader must find the place and restart ([AppleVis](https://applevis.com/forum/ios-ipados/applebooks-continuous-reading)).
- Curse: "VoiceOver announces, "Actions available" after each paragraph, heading, etc." ([AppleVis](https://www.applevis.com/forum/ios-ipados/turn-actions-available-books-app)).
- Curse: Speak Screen stops at chapter ends ([AppleVis](https://www.applevis.com/forum/ios-ipados/apple-books-speak-screen)).

### Audible

- Praise: an AppleVis review on iOS 18.5 calls it a model, with labeled buttons and hints for the play controls ([listing](https://www.applevis.com/apps/ios/books/audible-audiobooks-podcasts)).
- Curse: the player is hard to navigate, the sleep timer and chapters are hard to find, and "most of the screen seems to be blank" ([AppleVis, older](https://www.applevis.com/forum/ios-ipados/painfully-slow-audible-app)).
- Curse, iOS 26.2.1: the player wouldn't activate, with a workaround of double-tapping and holding the mini player, and the play and jump-back buttons moved from the mini player into its actions ([AppleVis](https://applevis.com/forum/ios-ipados/issue-latest-audible-app)). Chapter controls were hidden behind a double tap on the cover art ([AppleVis listing](https://www.applevis.com/apps/ios/books/audible-audiobooks-podcasts)).

### Overcast

- Praise: Hall of Fame 2021 for "excellent VoiceOver support" ([AppleVis](https://www.applevis.com/blog/applevis-community-inducts-cash-reader-overcast-its-ios-app-hall-fame)).
- Curse: "the playback window is really laggy with VoiceOver" ([AppleVis](https://applevis.com/forum/ios-ipados/overcast-vs-pocket-casts-which-should-i-choose)). Reordering labels were confusing. One user "finally couldn't handle the accessibility issues".

### BARD Mobile

- Praise: "BARD Mobile is a fantastic app that performs extremely well", with a layout that resembles the physical player ([AccessWorld, 2014](https://afb.org/aw/15/2/15607)).
- Design points ([NLS guide](https://nlsbard.loc.gov/apidocs/BARDMobile.userguide.iOS.1.2.html)): a position slider moving 10 percent per flick; pressing the opposite Next or Previous within 5 seconds returns to the prior place; the magic tap works outside the app; a Speed button adjustable by flick, with triple tap to reset; in braille, single-letter keys such as M for Jump By and W for volume, page, and line.
- Curse: "VoiceOver focus is particularly flaky", sometimes stuck on Play and unable to flick to Rewind or Fast Forward ([AppleVis](https://www.applevis.com/forum/ios-ipados/bard-mobile-rewind-fast-forward)).

### Others

- Bookshare's readers: I found little. Bookshare Reader has only a few comments. One EasyReader review is titled "Best option for reading Bookshare books as a Blind person".
- Capti: praised early for developer responsiveness. AccessWorld faulted its navigation, since indexing wasn't an option. Pulled from the App Store and reinstated, and reported broken in several areas in 2025 ([AppleVis](https://www.applevis.com/forum/ios-ipados/capti-voice-has-been-pulled-app-store)).
- Libby: long complained of, with "does not remember reading position in read-aloud mode" ([AppleVis](https://www.applevis.com/forum/ios-ipados/libby-overdrive-secret-message-screen-reader-users)). Later reports are that it is usable, better for audio than for ebooks. A "Read From Here" mode came in 2021 ([OverDrive](https://company.overdrive.com/2021/12/16/announcing-accessibility-enhancements-in-the-libby-app/)).
- Speechify: won an Apple Design Award for inclusive design in 2025 ([AppleVis](https://www.applevis.com/blog/speechify-art-fauna-cozy-puzzles-win-2025-apple-design-awards-inclusive-design)). Users complain of price, and I found no VoiceOver audit.
- Speech Central: its developer says "if you swipe up or down when the play button has the focus the app performs forward and rewind functions", customizable to sentences or paragraphs ([AppleVis](https://www.applevis.com/forum/macos-mac-apps/voice-dream-reader-mac-now-available-how-i-think-it-compares-my-app-speech)). A user found that a VoiceOver Read All stops at the next paragraph ([AppleVis](https://www.applevis.com/forum/ios-ipados/my-opinion-speech-central-app-so-far)).
- Readify, a new reading app, December 2025: wanted rotor options; users asked for rotor "to skip forward and backwards through the text". Chapter jump "doesn't always start reading from the first sentence", and a slider "unresponsive", "very clunky" ([AppleVis](https://www.applevis.com/forum/ios-ipados/seeking-voiceover-feedback-new-reading-app-readify)).
- Anytime podcast player: "rotor support allows a voiceover user to get things done quickly" ([AppleVis](https://applevis.com/forum/ios-ipados/introducing-anytime-podcast-app-seeking-voiceover-feedback)).
- There's also an AppleVis thread titled ["I hate the Rotor"](https://www.applevis.com/forum/ios-ipados/i-hate-rotor). Not everyone will twist.
- "Say all" habits: I found nothing specific to NVDA users on phones. On iPhone the habit is the two-finger swipe down: "Just swipe down with two fingers for continuous reading, and it'll turn the pages automatically" (Kindle; [AppleVis](https://www.applevis.com/forum/ios-ipados/kindle-app-not-working-voiceover)). Its limit: "Kindle's two-finger method is fine if you want to keep your screen on" ([AppleVis](https://www.applevis.com/forum/other-apple-chat/changing-voice-assisted-reader-kindle-app)). So Read All with VoiceOver and listening with the screen locked are two habits, and the app needs to serve both.

### The patterns

Loved:

- Swipe up and down on Play to move by a chosen unit.
- A unit chooser that is itself adjustable.
- Rate as a swipe, with the value spoken in words per minute.
- The two-finger double tap working anywhere, and from outside the app.
- Landing on Play when a book opens.
- A short, stable, labeled control set.
- Read All that keeps going across pages.
- An undo for a jump, as in BARD's 5 seconds.

Cursed:

- Focus jumping to the top when media controls are used. "focus resumes on the first item on the screen when using media playback controls" ([AppleVis](https://www.applevis.com/forum/ios-ipados/has-anyone-noticed-voiceover-returns-first-item-screen-when-we-control-media)). Spotify: focus wandering can "skip all the way back to the first song" ([AppleVis](https://www.applevis.com/forum/ios-ipados/strange-issue-spotify-app-switching-between-songs)).
- Back going to the top rather than the row left.
- Unlabeled controls beside controls that are too easy to change, which lose the place.
- A slider that moves too far or doesn't respond. On a slider, flicks commonly move 10 percent, with slow drag for 1 or 2 percent ([AppleVis](https://www.applevis.com/forum/ios-ipados/using-sliders-voiceover)). Files app's seek slider broke in iOS 26 ([AppleVis](https://www.applevis.com/forum/ios-ipados/voiceover-seek-slider-bug-files-app-ios-261-beta)).
- Controls moved into Actions, or vanishing with the UI.
- "Actions available" repeating in text.
- VoiceOver talking over a video because focus sits on a live control.
- Read All stopping at a page or paragraph.
- Losing the last-read place when pausing or switching between voice and braille.
- Lag: screens made sluggish by frequent updates under VoiceOver.

## 5. iOS 26's design, as far as it touches VoiceOver

- Liquid Glass "does not have a significant impact on VoiceOver functionality", with toolbar targets "a bit smaller" and search relocated to the bottom in many apps (REPORTED: [AppleVis on iOS 26](https://www.applevis.com/blog/ios-26-ipados-26-summary-voiceover-braille-issues-improvements)).
- Reduce Transparency makes the glass frostier automatically, and Increased Contrast and Reduce Motion also apply, "available automatically whenever you use the new material" (DOCUMENTED: [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)).
- Apple's notes say only "Test with VoiceOver" (`UIKit-Implementing-Liquid-Glass-Design.md` lines 203 to 205). There's no VoiceOver text in the SwiftUI note.
- `tabBarMinimizeBehavior(_:)`: `.automatic`, `.onScrollDown`, `.onScrollUp`, `.never` (DOCUMENTED: SwiftUI interface lines 8978 to 9001). A minimized tab bar "becomes smaller". Nothing covers VoiceOver. VoiceOver's scrolling could trigger it (INFERRED). Use `.never` if a tab bar is used at all.
- `tabViewBottomAccessory(content:)` is iOS 26, iPhone and iPad. "when the tab bar is normal size, the accessory appears above it; when the tab bar is collapsed, the accessory displays inline", read through the environment's `tabViewBottomAccessoryPlacement`, `.inline` or `.expanded` (DOCUMENTED: lines 13709, 5515, and 5537; [documentation](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:))). Apple's example swaps views on placement, which could destroy focus (INFERRED).
- Is it reachable, and in what order? No document says, and I found no iOS 26 report. Older AFB reviews put Music's MiniPlayer just above the tabs, reached by flicking near the tab bar ([AccessWorld](https://afb.org/aw/22/5/17558)). INFERRED order: after the content, before the tabs. A developer forum post reports an empty container left behind when it's hidden conditionally (REPORTED). Unknown until a real run.
- `ToolbarSpacer` is only visual (DOCUMENTED: line 22880), though an item's order and grouping could affect order (INFERRED).
- `.searchable`: `.searchToolbarBehavior(.minimize)` "renders the search field as a button-like control that expands when tapped", and `DefaultToolbarItem(kind: .search, placement: .bottomBar)` repositions it (DOCUMENTED: `SwiftUI-New-Toolbar-Features.md` lines 44 to 86). NFB reports search moved to the bottom of apps, so VoiceOver reaches it last, by flicking past a whole list, or with a four-finger tap near the bottom (INFERRED).
- `safeAreaBar` keeps a custom bar in the safe area, beside `safeAreaInset` (DOCUMENTED: lines 17362 to 17367).
- VoiceOver's order for a `NavigationStack`: reading order, top to bottom, leading to trailing (DOCUMENTED: [HIG](https://developer.apple.com/design/human-interface-guidelines/voiceover)). So Back, the title, trailing toolbar items, content, the bottom toolbar, and tabs, with accessories before tabs (INFERRED). Apple's HIG: "The title is the first information someone receives from an assistive technology when arriving on a page".
- New accessibility in iOS 26:
  - Accessibility Reader, a system full-screen reader opened from Control Center, which benefits from accessible text (DOCUMENTED: WWDC26 session 219; [AFB](https://afb.org/blog/entry/ios-26-accessibility-features)).
  - Braille Access, Item Overview, underline cursor, one-handed Braille Screen Input.
  - Magic Tap's Media Playback switch.
  - Cursor Output, under Typing.
  - App Store labels: [Accessibility Nutrition Labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/voiceover-evaluation-criteria/). Its VoiceOver criteria make a good checklist.
  - A rotor item for copied speech, and a search field in rotor settings (ONCE).
- iOS 26 and 27 bugs to expect, none ours to fix:
  - Loss of speech, fixed in 26.0.1.
  - Flicks not reaching every element in 26.1 ([AppleVis](https://www.applevis.com/forum/apple-beta-releases/critical-voiceover-bug-ios-261-swiping-fails-find-elements-eg-cancel)).
  - Focus regressions in iOS 26.
  - In iOS 27, VoiceOver "fails to announce screen changes or stops reading mid-sentence" and intermittent silence, per AppleVis's summary.
- New in iOS 27, because the phone may run it (REPORTED: [AFB](https://afb.org/ios-27-accessibility); the last item DOCUMENTED: WWDC26 session 219):
  - Text Navigation, for what a one-finger swipe moves through: Element, Paragraph, Sentence, or Line.
  - Text Exploration, for what's read under the finger: Paragraph, Sentence, or Line. These only work with real text elements, and will reward using them (INFERRED).
  - Hints: Always, App-Specific, or None, with a delay of 0.05 to 2 seconds (default 0.8). Keep app hints useful, since a user may keep only these.
  - Use Edit Rotor in Text Fields.
  - `accessibilityLinkedGroup` for text; selection handles on `Text`; Text Field Labels and Cursor Routing in braille.

## 6. Recommendations for TextMouth

All are mine, and INFERRED from the above unless marked. The first run may overturn any of them.

### The reader screen's elements and order

Two screens for two habits, as Paperback has. Name them with the Mac's words when the spec is written.

The Listening screen has few elements, and this order:

1. Back: the system's button, going to the Library. Scrub does the same.
2. The book's title: a heading, from the navigation title.
3. The text: one element, label equal to the current passage, trait static text, `.narrative`, language set, no actions. One flick left from Play. When paused, it starts at the sentence just spoken. It doesn't change while focused during playback.
4. Play or Pause: the arrival element. Label "Play" or "Pause", no value, adjustable (moves by the unit), `.startsMediaSession` in the Play state only. Short hint: "Swipe up or down to move by sentence."
5. Move By: adjustable, value the unit: Sentence, Paragraph, Heading, Page, Bookmark, and for audiobooks Chapter and time steps. Cycling wraps, per Paperback. No `Menu` under it, because focus doesn't return.
6. Previous and Next: buttons labeled with the unit, "Previous Sentence", "Next Sentence". A setting can hide them, as in Paperback.
7. Speed: adjustable, value in words per minute, using the Mac's word for it.
8. Where Am I: a button whose value is computed when focused: chapter, page, percent, and time left. Braille readers get the same facts here without waiting for an announcement. Activating posts the Mac's summary as an announcement.
9. Bookmark: adds one, and confirms by announcement.
10. Contents and Bookmarks, Go To, Sleep Timer (value "Off" or time left, computed on focus), and More: each opens a sheet.

The Read Text screen comes second, as its own slice:

- A lazy whole-book container of paragraph elements, in Paperback's design: `accessibilityElementCount`, `accessibilityElement(at:)`, equal by unit, `accessibilityHitTest`, `accessibilityScroll` with `.pageScrolled`, `accessibilityScrollStatus`, and system-typed UIKit rotors for Headings, Links, and Tables, plus Pages, Bookmarks, and Sections. Its MIT license permits adapting it, with its notice.
- Here VoiceOver focus is the place. Keep a small bar of controls, and don't count the jump VoiceOver makes on arrival as a move.
- Why this over one page element: flicks move by paragraph, rotors land on real elements, Read All never runs out, and panning keeps going.
- Lines rotor quality on plain labels is unknown. `UITextInput` is Apple's "higher fidelity" route and can come later.

For tonight's build, the Listening screen's text element is the cheap first step: one element showing the current passage, with `UIAccessibilityReadingContent`, `causesPageTurn`, and `accessibilityScroll`. That is Apple's documented route with the least code. While paused, a Read All's page turns move the book's place. While the book plays, they move only the text element, so VoiceOver reading can't drag the book away.

Why two screens: a whole book placed among controls means a four-finger tap near the bottom lands on the last paragraph, and flicks can't get past the text.

In the Library, put a Now Playing row right after the title, not in a bar at the bottom, so it's one flick from the top of a long list. Double-tapping it opens the reader. The magic tap already plays and pauses from anywhere. Search sits where iOS puts it, last in the order, so a four-finger tap near the bottom reaches it.

Rejected:

- SwiftUI `Text` views in a `LazyVStack` as the book. Offscreen elements aren't reliable, and SwiftUI's rotors don't scale.
- `TextEditor` as the book, since it reads as an editor.
- A time readout as a live element, since it talks over the book and moves braille.
- A TabView, since a reader needs one stack, and `tabViewBottomAccessory` is undocumented for VoiceOver.

### Changing unit and moving by it

Do both, in this priority:

- First, adjustable: Move By chooses, and Play moves. It needs no twist, works from braille with dots 3 and 6, matches three shipping readers, and can be built tonight with `accessibilityAdjustableAction`. Prefer UIKit elements if the value must be current inside the action.
- Second, buttons: Previous and Next, for anyone who doesn't want swipes.
- Third, rotors: UIKit rotors for Headings, Pages, and Bookmarks on the Read Text screen, landing on real elements. On the Listening screen, offer them only after the first run shows what same-element or swapped-element results do. Build that as a small removable piece. If tried, return a distinct element per unit that compares equal by unit, not the same object.

Rejected, and why:

- A SwiftUI rotor per unit, with entries or text ranges: every entry is built, and a report shows it fails on `List`.
- Rotor as the only route: unknown boundary behavior, VoiceOver reselects Adjust on adjustable elements, and some users dislike twisting.
- A gesture area with Direct Touch: it disables VoiceOver there, has no braille equivalent, and Apple says always offer alternatives.
- Actions as the main route: too many steps for a repeated move. Keep actions few: bookmark, Where Am I.
- A position slider on the Listening screen: too easy to change by accident, and it moves too far. Put it in Go To, with page and percent fields, and add "Back to where I was" after any jump.

### The magic tap

- A `UIWindow` subclass overriding `accessibilityPerformMagicTap`, installed by a scene delegate through `UIApplicationDelegateAdaptor`, as in Paperback and FastPlay. Works over sheets, since the window is in the chain.
- It toggles the current book. If no book is loaded, return `false`, so the system's fallback runs. It says nothing itself, since the book starting or stopping is the feedback. Reconsider if the user wants a cue after the first run.
- Register `togglePlayPauseCommand`, `playCommand`, and `pauseCommand`, so the same gesture works from the lock screen and other apps.
- Share one action for Play, the window, and remote commands (the code's single entry point).

### The escape gesture

- `NavigationStack` and sheets should give it for free. Add `.accessibilityAction(.escape)` to anything full-screen or custom.
- Scrub on the reader returns to the Library with the book still playing, and focus lands on that book's row. The Now Playing row keeps it in reach.

### Announcements

- One announcer type, shared, with three rules: never during playback unless the user asked; `.default` for answers to a user's action; `.low` for background results such as an import finishing. Reserve `.high` for a stop the user must know about, such as a book that can't be played.
- Post about 0.15 seconds after an activation. Use `AccessibilityNotification.Announcement` with an attributed string.
- Keep each short, starting with what matters. Every announced fact must also be readable in an element.
- Where Am I on the iPhone: an announcement when VoiceOver is running, so it reaches braille, rather than the Mac's second synthesizer. Keep the Mac's pause-and-resume logic. Use `announcementDidFinishNotification` to resume, with a time limit, because it can fail to fire.

### Focus on arrival and return

- Opening a book: Play. Post `.screenChanged` with its element after the view appears, and re-post for up to 3 seconds if VoiceOver lands elsewhere, stopping once the user moves, per Paperback. `accessibilityDefaultFocus` is worth adding, but nobody has reported using it.
- If the app opens a sheet: the sheet's first heading, by delayed `AccessibilityFocusState`. On dismiss: the control that opened it, in `onDismiss` with a delay.
- Back to the Library: the row of the book just left, by id, after a delay. Don't depend on the system.
- Return from the background: restore only after a true background, not after Control Center or a banner.
- During playback: never move focus. A chapter change, the end of a segment, or an interruption doesn't touch it.
- At a jump the user asked for from a sheet: focus returns to the opener, and a paused jump announces the first words of the new place.

### What a braille display should show

- Short labels with distinct first cells. Traits supply the rest. Values short, ordered from most useful.
- The text element: the current passage, starting at the last sentence spoken.
- Where Am I's value: chapter, page, percent, and time.
- Nothing updating while focused. A later setting, Follow in Braille, could advance the text element by passage during playback, for users with speech muted. Test it first.
- Rate: words per minute as digits.
- Say in the user guide that custom rotors and adjusting use dots 3 and 6, activate is dots 3-6, scrub is dots 1-2, and the magic tap is dots 1-5-6, all with Space.

### The audio session

- `.playback`, mode `.spokenAudio`, no options, activated when playback starts. Deactivate with `.notifyOthersOnDeactivation` when stopping.
- Handle interruptions with `.shouldResume`, since spoken prompts pause the book by design.
- `AVSpeechSynthesizer.usesApplicationAudioSession` stays true. `prefersAssistiveTechnologySettings` stays false on book utterances.
- Say in the guide that VoiceOver's ducking is the user's own setting, and where it lives.

### What the first real run must check

Order matters: the first few decide the most.

1. Rotor same-element behavior. On the Listening screen, a test rotor returning the element VoiceOver is on, then a different object equal by unit, then a truly different element. Listen for speech, silence, or the boundary sound.
2. Swipe up and down on Play, playing and paused, with hints on and off. What's spoken with no value? Is there a boundary sound? Does the rotor return to Adjust after leaving and coming back?
3. Double-tap Play, then Pause. Does VoiceOver stay silent on Play? Is the first word lost? Does the app's play sound or VoiceOver's click overlap? Does Pause speak "Play"?
4. Magic tap: focus on Play with the label changing. Is "Pause" spoken over the book? Also in the Library, in a sheet, in an alert, in the search field (dictation must win), with no book loaded, on the lock screen, from another app, during a phone call, and with iOS 26's Media Playback off. Does the window subclass get it in sheets?
5. Flick during both speech paths, `speak()` and the engine, with Audio Ducking Off, When Speaking, and Always. Does anything pause? Log `didCancel`, `didPause`, and session interruptions. Do the two voices interfere?
6. Does a Maps prompt pause and resume the book under `.spokenAudio`? Siri? A call?
7. Focus: arrival on Play; the 3-second guard; return to the row; sheets opening and closing; alerts; Control Center; true background; lock and unlock. Does `accessibilityDefaultFocus` do anything useful?
8. A focused element whose label or value changes: how often is it spoken? Does a braille display's line move? Try it in both a SwiftUI view and a UIKit element with a value block.
9. Text element: Lines, Words, and Characters on the rotor; Read All; `causesPageTurn`; the three-finger tap; leading-space lines; iOS 27's Text Navigation and Exploration.
10. Read All while the book is playing: what should happen, and is it bearable?
11. Braille, end to end with a display:
    - every label in Item Overview at 2 to 7 cells;
    - adjusting with dots 3 and 6;
    - activating with dots 3-6 and a router key;
    - the magic chord;
    - scrub with dots 1-2;
    - panning through the text and Turn Pages when Panning;
    - announcements and their duration;
    - announcement history for app-posted announcements;
    - Sound Curtain with the book playing;
    - Touch Curtain.
12. Typing in `.searchable` with a display and with Braille Screen Input, and where search sits in the order on iOS 26 and 27.
13. Whole-book container with a long book: element creation, hit-testing, rotors, and memory.
14. `List` under VoiceOver: swipe actions as custom actions; section headers as headings; the index bar; a long library's speed.
15. Whatever OS the phone runs: if it's iOS 27, repeat the top items on an iOS 26 device if one can be found, or say which was tested.
