# Compressing the language files: research (November 21, 2026)

Part of [the research folder](README.md).
Issue: TL19.
Written before any change; no code was touched.

## The question

The user asked: "would it be possible to build the app with the strings compressed and only extract the one we need at any given time? I don't know if that would work for Xcode catalog format but try researching it, or we could make a new system now that all the strings have identifiers."

One correction first.
The strings do not have identifiers.
A key is the English text itself (`localization.md`, The String Catalog).
That is why every language file repeats the English: each file holds the key and the value of every entry.
The measurements below show how much that costs.

## Short answer

- Xcode, Foundation, and the App Store give no way to ship compressed strings or to leave languages out per device.
  Foundation reads only uncompressed `.strings` and `.stringsdict` files from the app's own `.lproj` folders.
- A custom pack works on paper and measures well: all 23 languages in about 1.1 MB instead of 10.3 MB.
  It needs a hook that routes every lookup to a folder written at launch.
  Whether SwiftUI and `String(localized:)` honor such a hook is not documented, so it needs a probe on GitHub before any design is final.
- Compressing the installed app with the file system (`ditto --hfsCompression`) cuts the disk used by about 64%, signs and verifies fine, and leaves the size gate unchanged, because the gate adds up logical file sizes.
- Recommendation: build the pack, behind a probe that proves the hook. Estimated Mac app 21.9 MB and iPhone app 16.9 MB at 23 languages, 22.0 and 17.0 at 25.

## 1. What Apple ships and looks up

**The build.**
Xcode compiles `Localizable.xcstrings` into `<lang>.lproj/Localizable.strings` and `.stringsdict` files.
WWDC23's "Discover String Catalogs" says it plainly: "at build time, these files compile to .strings and .stringsdict files," and the strings that code supplies as defaults "are not included in the final build" (<https://developer.apple.com/videos/play/wwdc2023/10155/>).
Plurals and device variations go into the `.stringsdict`.
TL16's build step already rewrites both files compact; `compact_packs.py` also leaves out the entries Foundation can do without (TL18).
Apple documents no setting that compresses them or keeps a language out of one device's copy.

**The lookup.**
`Bundle.localizedString(forKey:value:table:)`, `String(localized:)`, and a SwiftUI `Text` with a `LocalizedStringKey` all end at the bundle's string table.
`CFBundle`'s open-source strings code (<https://fuchsia.googlesource.com/third_party/swift-corelibs-foundation/+/refs/tags/swift-3.0-RELEASE/CoreFoundation/PlugIn.subproj/CFBundle_Strings.c>, a mirror of Apple's CoreFoundation, old but the closest public source) does this:
- it checks a per-bundle cache first;
- on a miss it reads the table file of the preferred localization only, builds one `CFDictionary` from the whole file, and caches that;
- a lookup for an explicitly named localization skips the cache.

So at run time one language's table sits in memory, and the other 22 files are never opened.
The cost of a big language count is the disk, not the memory.
Apple's shipping Foundation may differ in detail; the probe below would measure it.

**The size the gate counts.**
`Scripts/check.sh` adds up the logical size (`stat -f %z`) of every regular file in the app.
Apple's own size report agrees for the iPhone: "the uncompressed size is equivalent to the size of the installed app on the device" (<https://developer.apple.com/documentation/xcode/reducing-your-app-s-size>).

**The system's list of languages.**
The folders `de.lproj` and the rest tell the system which languages the app has (the per-app language choice in System Settings and in the iPhone's Settings, and `Bundle.main.preferredLocalizations`).
`Info.plist` has no `CFBundleLocalizations` today.
Any plan that takes the tables out of the bundle must keep a folder for each language.

## 2. Does anything leave out unused languages?

- **App Store thinning** slices by device, and the Xcode pages say nothing of languages (<https://help.apple.com/xcode/mac/9.0/en.lproj/devc961f9b6d.html>).
  A Microsoft engineering write-up says all localizations stay in every variant (<https://medium.com/microsoft-mobile-engineering/app-thinning-syncing-localized-strings-to-outlook-for-ios-98ec2479e9d6>); this is a secondary source, but nothing from Apple contradicts it.
  A developer asked Apple's forum in 2015 whether localized resources can be tagged so only one locale downloads, and got no answer (<https://developer.apple.com/forums/thread/5481>).
- **On-demand resources**: "macOS and watchOS don't support On-Demand Resources," and they are deprecated from iOS 27 in favor of Background Assets (<https://developer.apple.com/help/app-store-connect/reference/on-demand-resources-size-limits/>).
  So not on the Mac, and not worth starting on the iPhone.
- **Background Assets localized asset packs**: new in macOS 27 and iOS 27, with a `language` on each pack and `resolvedLanguage` choosing it (<https://developer.apple.com/documentation/backgroundassets/reducing-download-and-storage-demands-with-localized-asset-packs.md>).
  TextMouth's targets are macOS 14 and iOS 26, and the packs live on App Store Connect and need a network, so they do not apply now.
  Worth revisiting when the deployment targets reach 27.
- **Nothing else** in Apple's documentation drops languages from a device's copy.

## 3. Compressing the installed Mac app with the file system

Measured on this Mac, with the 23 language folders in a signed ad hoc app:

| Copy | Disk used | Logical size | `codesign --verify --deep --strict` |
|---|---|---|---|
| plain copy | 10,236 KB | 10,337,267 B | passes |
| `ditto --hfsCompression` copy | 3,720 KB | 10,337,267 B | passes |

- It is transparent (decmpfs): the file reads as before, so lookups and the signature are unchanged, and notarization hashes the same content.
- It saves disk, not the gate: `stat` still reports the logical size, so the gate reads the same number.
- It does not survive every copy.
  A plain `cp -R` of a compressed copy gave 440 KB for one language folder against 160 KB compressed, and unzipping a zip of it gave 440 KB.
  `cp -c` (a clone) kept the 160 KB.
  So an app installed from a zip or a plain copy is stored uncompressed; only an install made with `ditto --hfsCompression` is compressed.
- It cannot apply on the iPhone, and it is not code: it is how the user installs.

It helps the user's own disk by the same ratio for the whole app, so it is a free install tip, and it does nothing for the size limits.

## 4. A custom system built on the keys

### Measurements

Source: the 23-language catalog on `integrate/l10n-wave2-1120` (0.5.7, not yet on main), compiled with `xcstringstool` and written compact by `compact_packs.py`, in a scratch folder.
The 11-language catalog on main gave the same ratios.

| Measure | 23 languages | 11 languages (main) |
|---|---|---|
| Shipped today, bytes | 10,337,267 | 4,729,541 |
| Average per language | 449,446 | 429,958 |
| The keys repeated in every `.strings` | 3,483,517 (34%) | 1,568,844 (33%) |
| One key list (4,176 keys, English) | 165,231 | 165,222 |
| Values only, raw, all languages | 6,697,910 | 3,011,908 |
| Each language's two files compressed alone: zlib / LZMA / Brotli | 2.80 / 2.17 / 2.16 MB | 1.28 / 0.99 / 0.98 MB |
| Values only, one blob per language: zlib / LZFSE / LZMA / Brotli / zstd 19 | 1.30 / 1.37 / 1.05 / 1.04 / 1.06 MB | 0.61 / 0.63 / 0.49 / 0.49 / 0.50 MB |
| Shared key list, compressed once: zlib / LZFSE / LZMA / Brotli | 47 / 47 / 40 / 39 KB | the same |
| Values for all languages in one stream (LZMA) | 1.01 MB | 0.47 MB |
| Short ids for keys, no compression | 6,887,663 | not measured |

One language, values only, compressed: German 60,938 (zlib), 50,416 (LZMA); Japanese 56,785 (LZFSE), 44,152 (LZMA); Russian 80,849 (LZFSE), 55,932 (LZMA).
Versus 448,124, 441,625, and 576,005 bytes shipped today.

What the numbers say:
- A third of every language file is the English keys, and a key list written once costs 40 KB.
- Compression does the rest: the values compress about 6.4 times (LZMA) to 4.9 times (LZFSE).
- One stream for all languages gains only 3% over one blob each, and a single stream cannot be decoded one language at a time. Use one blob per language.
- Decoding the largest language (Russian, 576 KB raw) took about 1.1 ms with LZFSE and 4.4 ms with LZMA by `compression_tool`, 0.3 ms zlib and 3.8 ms LZMA in Python.
  Either is invisible at launch.

### The format

- One file, `Localizable.pack`, in the app's Resources: a small index, the compressed key list, and one compressed blob for each language.
- A blob holds that language's values in key order.
  An entry equal to its key is empty (as `squeeze_tables` already leaves it out).
  A plural or device entry holds its `.stringsdict` dictionary whole (a binary property list), so every plural rule keeps Apple's own machinery and no code reimplements `one`, `few`, or `many`.
- The pack is built from the output of `compact_packs.py`, so it holds exactly the tables that ship today, squeezed the same way.
- A key with a device suffix is a key like any other in the list, since the list is the union of every table's keys.

### Compressor

Apple's Compression framework decodes all of these: LZFSE, LZMA, zlib, and Brotli (the header lists LZMA and LZFSE from macOS 10.11 and iOS 9, Brotli from macOS 12 and iOS 15).
The decoder for LZMA reads any level, though Apple's encoder writes level 6 only.
Tested here: Python's `lzma.compress` output (the `.xz` form) and its raw-deflate zlib output both decode correctly with Apple's decoder, through `compression_tool`.
`compact_packs.py` uses only the standard library, so LZMA from Python needs no new tool in the build.
Brotli would save 3% more but needs the `brotli` program, which a stock Mac lacks.
LZFSE has no encoder outside Apple's tools and compresses worse.
Choose LZMA.

### Getting a lookup to the pack

Foundation reads only uncompressed tables from `.lproj` folders in a bundle.
The pack must be expanded somewhere, and the lookups must be sent there.
The app cannot expand into its own `.lproj` folders: a signed app's folder is sealed, and writing into it breaks the signature (and is refused where the app is sandboxed or translocated).
A symbolic link from `Resources` to the caches folder fails `codesign --strict`.

The options:

1. **Call-site changes.**
   Give every lookup a bundle: `String(localized: "...", bundle: packBundle)`, and `bundle:` on SwiftUI `Text`.
   There are 4,603 `String(localized:)` calls in 243 files, plus every SwiftUI literal, and `Button`, `Label`, `Toggle`, and `TextField` take no bundle parameter (<https://developer.apple.com/forums/thread/740653>).
   The scanner's rule is that Apple's own call is the only way to write a string.
   Rejected: too large, and it would miss controls.
2. **A `Bundle` subclass for the main bundle** (`object_setClass(Bundle.main, PackBundle.self)`, overriding `localizedString(forKey:value:table:)` to forward to a bundle of the expanded folder).
   A write-up of this known pattern for in-app language switching says it works for UIKit and `NSLocalizedString`, and that SwiftUI may cache what it computed (<https://justdoswift.substack.com/p/switching-app-language-at-runtime>).
   Apple's forum shows `String(localized:)` and SwiftUI's environment locale take separate paths (<https://www.developer.apple.com/forums/thread/797984>).
   Risk: any path that reads the stringsdict by the bundle's URL, and not through the method, bypasses the override and shows English keys.
   The probe settles this.
3. **Method swizzling** of `-[NSBundle localizedStringForKey:value:table:]`.
   Same reach as option 2 with more fragility; the subclass is the lesser hack.
4. **A bundle written to the caches folder at first launch**, which options 2 and 3 forward to.
   The folder holds one language's `Localizable.strings` and `.stringsdict`, written with `PropertyListSerialization`, which Foundation reads as it reads any table.
   Forwarding everything to a real `Bundle` means plural and device handling stay Apple's.
   Stamp the folder with the build and language, write it atomically, check it on each launch, and rewrite it when it is missing, purged (iOS may purge caches), or stale.

The route that fits is 4 behind 2.

### What else it must handle

- **Placeholder folders.**
  Keep an `xx.lproj` for every language in the bundle (a tiny file each), so the system's language lists and `preferredLocalizations` are unchanged.
  A placeholder `Localizable.strings` with no entries would show English keys if the hook failed, so tests must catch that.
- **Install, update, and a new language** change the pack, so the stamp holds the pack's hash.
- **Plural forms and device variations** need nothing of their own: the whole dictionary is stored and expanded.
- **Language change at run time** is a relaunch on the Mac (the per-app language setting) and on the iPhone, so the expansion runs once per launch, and only for the language that wins.
  A fallback to English (the keys) must hold if the pack or the cache is unreadable.
- **First-launch cost**: one language, about 5 ms to decode and a 0.2 to 0.5 MB write.
  The cache is outside the app, so the gate does not count it.
- **Memory**: the same as today, one table.
- **Sandboxed helpers** (the FFmpeg helper) read no strings, so they are unaffected.

### The short-id alternative

If every key became an id, each language drops from about 449 KB to 300 KB (6.89 MB for 23 languages, a saving of 3.45 MB, no hook).
It needs the English literal moved to a `defaultValue:` at 4,603 call sites and the scanner and notes rebuilt around ids, and it saves a third of what the pack saves.
It is the fallback if the probe fails.

## 5. The options side by side

Estimated app sizes use main's 0.5.6 sizes (Mac 25.5 MB, iPhone 20.5 MB, with 11 languages at 4.73 MB), so the rest of the app is Mac 20.8 MB and iPhone 15.8 MB.
A 25th language adds about 0.47 MB today, 0.30 MB with short ids, and 0.05 MB in a pack.

| Option | Language bytes, 23 | Mac at 23 / 25 | iPhone at 23 / 25 | Code risk |
|---|---|---|---|---|
| Today (TL16, TL18) | 10.34 MB | 31.1 / 32.1 MB | 26.1 / 27.1 MB | none |
| File system compression (install only) | 10.34 MB counted | 31.1 / 32.1 counted | not possible | none, install step |
| Short ids | 6.89 MB | 27.7 / 28.3 MB | 22.7 / 23.3 MB | 4,603 call sites |
| Pack, LZMA | 1.09 MB | 21.9 / 22.0 MB | 16.9 / 17.0 MB | the hook (probe) |
| Pack, LZFSE | 1.42 MB | 22.2 / 22.3 MB | 17.2 / 17.3 MB | the hook |

Today's Mac app at 23 languages is over the 30 MB warning line of `check.sh` (the strict limit is 40 MB) and over the 25 MB target.
The iPhone download is smaller than these figures, because the IPA is already zip-compressed; the pack saves most on the installed size, which is the gate's number.
Add about 20 to 30 KB for the loader.

## 6. Recommendation

1. **Probe first** (one small branch, a train on GitHub, with no crash tests on the Mac): a test app that swaps `Bundle.main`'s class and shows what each lookup does.
   It must show that all of these take the override: SwiftUI `Text`, `Button`, `Label`, `Toggle`, `TextField` titles, menu titles (`CommandMenu`), `String(localized:)`, `LocalizedStringResource`, a plural with `%lld`, a device variation, and an accessibility label.
   Run it on a Mac and on an iPhone simulator.
2. **If it passes, build the pack** in this order, each a small commit: the pack writer and its round trip in `compact_packs.py`; the loader and the cache with the failure paths; the build step that replaces the language tables with placeholder folders and the pack; the tests below; docs and size notes.
3. **If it fails, fall back to short ids**, or accept the Mac's size and raise the warning line.
4. **Install tip, now**: copy the app with `ditto --hfsCompression` to save disk on the user's Mac.
   It does not change the gate.

## 7. Tests a change would need

- **The lookup comparison of `verify_packs.py`, extended.**
  For each language: expand the pack, build a bundle from it, and compare every key's text and each plural at the counts 0, 1, 2, 5, 21, 100, 1,000,000 with Apple's compile of the catalog.
  Every comparison must be identical to the present one (the same probe, `pack-probe/main.swift`, with a second source of tables).
- **A byte round trip**: pack then expand gives exactly the dictionaries `compact_packs.py` read back with `plutil`.
- **A hosted test on each app** (`LanguagePackTests` already runs on both): with the hook installed, every key in every language reads as the catalog says, through `Bundle.main` and through a SwiftUI host; the app contains the placeholder folders and no `.strings` with entries.
- **The cache's failure paths**: missing, empty, half-written, stale stamp, read-only folder, purged between launches, and two launches at once.
  In each the language still shows (a rewrite) or English shows (the fallback), never a crash or an empty label.
- **The language list**: `Bundle.main.localizations` and `preferredLocalizations` equal today's for each test language.
- **VoiceOver's text unchanged**: a fixed set of screens in English, Spanish, Arabic, and Japanese, with VoiceOver's spoken text (the `vo-control` skill) captured on main and on the branch and compared line by line, plus a hash of every lookup in every language before and after.
- **The size gate**: `make check` reports the language bytes and fails above a budget, as TL16 does for XML now.
- **Speed**: first-launch expansion under 50 ms for the largest language, measured in CPU time as the l10n tools' tests are.
- **Both apps**: the Mac and iPhone targets share the pack tool and the loader.

## Questions for the user

1. May I start the probe (step 1 of the recommendation)?
   Recommended: yes. It decides everything else and costs one small branch and one train.
2. Is the real limit 30 MB for the Mac, with 25 MB a hope?
   Recommended: yes; keep 25 MB as a hope and plan to land near 22 MB with the pack.
3. Is a folder in the caches that the app rewrites at launch acceptable?
   Recommended: yes. It holds only one language, and a purge only costs a rewrite.
4. LZMA, or LZFSE?
   Recommended: LZMA: it saves 0.33 MB more, its encoder is in Python, and the decode is 4 ms.
5. If the probe fails, short ids or accept the size?
   Recommended: accept the size for now (raise the warning line to 32 MB) and revisit when the deployment targets reach 27 and Background Assets language packs apply; short ids cost 4,603 edits for a third of the saving.
6. Keep an empty `xx.lproj` folder per language, so the system's language lists stay?
   Recommended: yes.
7. Install the app on your own Mac with `ditto --hfsCompression`?
   Recommended: yes. It frees about 65% of the language bytes, and the signature still verifies; it is optional.
8. Should a 24th and 25th language wait for the pack?
   Recommended: yes for the Mac; with the pack, each language costs about 50 KB instead of 470 KB.
