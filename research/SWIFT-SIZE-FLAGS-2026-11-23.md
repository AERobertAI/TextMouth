# Compiler and linker settings for a smaller app: research (November 23, 2026)

Part of [the research folder](README.md).
Written before any change; no setting or code on main was touched.

## The question

The user wants the installed app light for other users and marketable as lightweight, and asked which Swift build optimizations, experimental ones included, make the machine code smaller.

## How it was measured

- Xcode 26.0.1 (Swift 6.2, ld 1221.4), arm64 only, commit 224989da3.
- Mac: `xcodebuild -configuration Release` with `CODE_SIGNING_ALLOWED=NO`, `CODE_SIGN_IDENTITY=`, `CLANG_COVERAGE_MAPPING=NO`, and `SWIFT_OPTIMIZATION_LEVEL=-Osize`, as the Makefile's build rule passes them.
- iPhone: the command `Scripts/ios/app-size.py` builds with (target `TextMouthiOS`, device SDK, unsigned).
- One build at a time, under the heavy-work lock, each variant a full rebuild.
- Each size is the sum of the regular files in the app, as `make check` counts it.
- The baseline is 22,295,720 bytes (executable 18,430,024; `__text` 14,283,484) for the Mac, and 17,171,842 for the iPhone, which is the size `make check` reports.
- Nothing was run or launched: a build's size is measured, its behavior is not.

## The table

Savings are in bytes against the baseline; "over LTO" is against full LTO alone.
Every row is one build, except where it says otherwise.

| Setting | What it does | Mac saved | iPhone saved | Risk | Verify | Recommendation |
|---|---|---|---|---|---|---|
| `SWIFT_LTO=YES_THIN` | Thin LTO for Swift | 1,693,264 | not built | Optimizer miscompile | Release goldens | Reject for full LTO |
| `SWIFT_LTO=YES` | Full LTO (`-lto=llvm-full`) for Swift and its packages | 3,852,848 | 2,827,168 | Optimizer miscompile; longer link, more memory | Release goldens; full suite | Adopt after verifying |
| `-enable-llvm-vfe`, `-enable-llvm-wme` | Remove unused class and protocol witness entries | 0 over LTO (+64) | not built | None seen | None | Reject: no effect here |
| `-conditional-runtime-records`, `-internalize-at-link` | Drop unreferenced runtime records, internalize public symbols | 151,712 over LTO (measured with the two above) | in the combination | The app links no client of its public API, so none seen | Release goldens | Adopt after verifying |
| `LLVM_LTO=YES`, `GCC_OPTIMIZATION_LEVEL=z` | LTO and `-Oz` for the C code | 67,072 over LTO (braille helper 17,184 of it) | in the combination | `-Oz` slows LAME and liblouis a little | Release goldens, braille tests | Adopt after verifying |
| `SWIFT_REFLECTION_METADATA_LEVEL=without-names` | Drops field and case names from reflection metadata (`-disable-reflection-names`) | 132,096 alone; 4,170,640 for the combination below | 3,337,648 for the combination | `Mirror` and `String(describing:)` lose labels | Debug suite plus a search for `Mirror`; Release goldens | Adopt after verifying |
| `SWIFT_REFLECTION_METADATA_LEVEL=none` | Drops all reflection metadata (`-disable-reflection-metadata`) | 581,888 alone; 7,444,528 for the combination below | 5,478,944 for the combination | SwiftUI may need field metadata: see below | Needs hands on the real app | Reject until a person checks the app |
| `-Xllvm -enable-machine-outliner=always` (through the linker, with LTO) | Machine outliner | 0 | not built | None | None | Reject: no effect |
| `SWIFT_ENFORCE_EXCLUSIVE_ACCESS=off` with `-remove-runtime-asserts` (one build) | Removes exclusivity checks and runtime safety checks | 282,928 | not built | Removes checks: a bug becomes memory corruption | Not recommended | Reject without the user's say |
| `-Ounchecked` | Unchecked arithmetic and preconditions | -4,961,392 (larger) | not built | Removes checks | None | Reject: it is the `-O` pipeline, not `-Osize` |

## Totals

Recommended together, built as one:
`SWIFT_LTO=YES`, `LLVM_LTO=YES`, `GCC_OPTIMIZATION_LEVEL=z`, `SWIFT_REFLECTION_METADATA_LEVEL=without-names`, and `OTHER_SWIFT_FLAGS = -Xfrontend -conditional-runtime-records -Xfrontend -internalize-at-link` (the build also carried `-enable-llvm-vfe` and `-enable-llvm-wme`, which changed nothing).

| Build | Mac app | Mac saved | iPhone app | iPhone saved |
|---|---|---|---|---|
| Baseline | 22,295,720 | | 17,171,842 | |
| Full LTO alone | 18,442,872 | 3,852,848 | 14,344,674 | 2,827,168 |
| Recommended together | 18,125,080 | 4,170,640 (18.7%) | 13,834,194 | 3,337,648 (19.4%) |
| Same with reflection `none` | 14,851,192 | 7,444,528 (33.4%) | 11,692,898 | 5,478,944 (31.9%) |

Under `none` the Mac executable is 11,002,824 bytes, from 18,430,024.
Under LTO, `none` saves 3.3 MB, far more than the 0.58 MB it saves alone: the field descriptors had kept types and their code alive that nothing else reached.

## Per setting

### Reflection metadata
`without-names` removes `__swift5_reflstr` (129,208 to 5,423 bytes) and nothing else.
`none` removes `__swift5_fieldmd`, `__swift5_reflstr`, `__swift5_capture`, `__swift5_assocty` and `__swift5_builtin`.
Xcode's own build setting passes `-Xfrontend -disable-reflection-names` and `-Xfrontend -disable-reflection-metadata` (read in Xcode's `Swift.xcspec`).
Apple's engineers call it the heavy hammer, and no source measures SwiftUI under `none`.
SwiftUI reads a view's stored properties (`@State`, `@Environment`, `@Binding`) through the runtime's field metadata to find them, so `none` could leave state unconnected without a compile error.
I could not test this, since the app may not be launched here, so the recommendation is to reject until the user or an interface test run on GitHub shows the app working.
The run on GitHub settled it (November 23, `experiment/reflection-none`, a full Mac suite with `none` in Debug and Release): no test ran, because the app trapped at launch with "SwiftUICore/EnvironmentObject.swift:93: Fatal error: No ObservableObject of type LibraryViewModel found".
SwiftUI found no `@EnvironmentObject` in the view without the field metadata, so `none` is rejected for good while SwiftUI works this way.
Sources: [SE-0379 opt-in reflection metadata](https://forums.swift.org/t/se-0379-opt-in-reflection-metadata/61714), [Apple Developer Forums on disabling the level](https://developer.apple.com/forums/thread/720932), [a report of a 2 MB saving](https://developer.apple.com/forums/thread/748600).

### Link-time optimization
Xcode's `SWIFT_LTO` passes `-lto=llvm-full` (`YES`) or `-lto=llvm-thin` (`YES_THIN`), read in `Swift.xcspec`.
Full beat thin by 2.2 MB.
The 4-hour full-LTO build another team reported did not happen here: each full build took about 6 to 9 minutes, like the others, since the app is one module and a few small packages.
Sources: [Pitch: Support LTO for Swift](https://forums.swift.org/t/pitch-support-lto-for-swift/67379), [Using -lto with xcodebuild](https://forums.swift.org/t/using-lto-llvm-full-thin-with-xcodebuild/79931), [a thread on internalize-at-link and full LTO](https://forums.swift.org/t/how-do-i-put-my-swift-libraries-on-a-diet/82785).

### Dead-code flags
The four flags are in the compiler's own help (`swiftc -frontend -help-hidden`), and no document describes them.
VFE and WME changed 64 bytes: TextMouth's classes and protocols are few and the app's code is already stripped by `DEAD_CODE_STRIPPING`.
The pair of `-conditional-runtime-records` and `-internalize-at-link` saved 151,712 bytes more.
They are experimental; the combination built and linked on both platforms.

### The C code
LTO and `-Oz` took 67,072 bytes from the Mac app, 17,184 of them in the braille helper (168,640 to 151,456).
The FFmpeg helper moved by 144 bytes only: FFmpeg is built by its own script, with `--enable-small`, not by these settings.

### Merging, folding, and unwind data
- LLVM's function merging is on by default (`-disable-llvm-merge-functions-pass` exists, so the pass runs).
- Apple's linker folds identical code by default (`-no_deduplicate` turns it off).
- The machine outliner changed nothing.
- `__eh_frame` (308,472 bytes) and `__unwind_info` (178,248) shrink by 48,000 and 12,000 under LTO, and no setting drops them safely.
- `-no_function_starts` was measured by the November 13 audit (95,472 bytes); it stays with the user's yes.

### Strings
`__cstring` holds 567,904 bytes, none of them a path of the build machine (no `/Users/`).
It holds 234 file names such as `TextMouth/AddFeedSheet.swift`, about 8 KB, from `#fileID` in precondition messages.
Cutting them would make crash reports lose the file, so it is not worth the saving.

### Other toolchains
No newer toolchain is installed and none was installed.
Xcode 26.0.1's Swift 6.2 is what ships, and it is what every figure here uses.

## Code patterns

Measured from the dSYM of the baseline, by the size between each symbol and the next.

| Group | Bytes | Functions |
|---|---|---|
| Closures | 2,278,464 | 7,680 |
| Specializations | 1,356,956 | 6,479 |
| Property getters | 670,544 | 2,653 |
| `…Wording` functions | 328,016 | 1,150 |
| Witnesses | 199,204 | 2,560 |
| `Equatable`, `Hashable`, `Codable`, and `CodingKeys` together | 447,000 | about 4,600 |

- **`Book`.** Its own functions are 99,148 bytes, not the 280 KB of the brief: `Book.init` 7,704, `==` 5,788, `encode` 3,824, `hash` 3,208.
  Writing `Equatable` and `Hashable` by hand over fewer fields could save perhaps 10 KB, with a risk of a missed field; not recommended.
- **The `…Wording` calls.** The interface-text format already keeps a plain line at 32 bytes (`InterfaceTextFormat.swift`); the 328,016 bytes are mostly the lines with a value, each with an array of arguments.
  Moving those to a lookup that takes the values as a plain array would save perhaps 40 to 60 KB; it touches thousands of call sites.
- **Generic specializations (1.36 MB).** `-Osize` already limits them.
  Marking the few heavy generic helpers `@_semantics("optimize.sil.specialize.generic.never")` would save little and costs speed.
- **SwiftUI view bodies** are in the closures; no single type stands out, and no change would pay.
- The code is not where the size is: settings that remove it from the link do far more than any pattern here.

## Verification

- **LTO, the dead-code flags, and the C settings.** Run `Scripts/test/release-goldens.sh` on a Release build made with them (the orchestrator, not an agent here), then the full suite, and run the iPhone interface tests on GitHub.
- **`without-names`.** Search the code for `Mirror`, `String(describing:)`, and `String(reflecting:)` of enums and types shown to a person or written to disk; run the Debug suite and the goldens.
- **`none`.** Open the real app on the Mac and the iPhone and check that every view's state works (toolbar buttons, the library list, settings), with VoiceOver on, before it is considered.
- **Disk used by these builds:** 1.7 GB in the worktree's `build/` (one Mac and one iPhone DerivedData folder, reused by every build).

## What to do

1. Adopt full LTO with `-conditional-runtime-records` and `-internalize-at-link`, and the C settings: about 4.0 MB less on the Mac and 3.3 MB less on the iPhone, after the goldens pass.
2. Add `without-names` once the search for `Mirror` is clean.
3. Leave `none` for a person to check; it would give a Mac app of 14.9 MB and an iPhone app of 11.7 MB.
4. Reject the machine outliner, `-enable-llvm-vfe`, `-enable-llvm-wme`, `-Ounchecked`, and the removal of checks.

## Questions for the user

- Do you want the settings that remove runtime checks (`-enforce-exclusivity=unchecked`, `-remove-runtime-asserts`) measured further? They saved 282,928 bytes; the recommendation is no.
- Do you want to check the app built with reflection `none` yourself? The recommendation is yes, since it is the largest saving.
