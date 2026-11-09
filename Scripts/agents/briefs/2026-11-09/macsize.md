# The Mac app's size, with the iPhone's code in it (November 9, 2026)

You are `macsize`, a Sonnet worker, on branch `build/mac-size`. First read `common.md` beside this file and follow it exactly: it says how to start, check, and report.

The Mac app compiles `TextMouth/Phone/`, about 9,400 lines of the iPhone's models, policies, and wording, so that the Mac's fast tests can test them. The Mac never uses that code. The installed 0.4.2 is 22 MB, and its executable is 22.7 MB, against the user's target of 25 MB for the app. Nobody has measured what the iPhone's code adds to the Mac's Release build. That is your work, and the fix if it adds enough to matter.

## Read first

- `project.yml`: the Mac and iOS targets' sources, and how the iOS target leaves out `Platform/macOS`.
- `docs/developer/building.md`: the Release build, and the app size.
- `docs/architecture/platforms.md`: what `TextMouth/Phone/` holds and why the Mac compiles it.

## The work

1. **Measure.**
   - Build the Mac app in Release at e0ea3b9d through `run_locked.py`, with its own derived data in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/DerivedData-size.noindex`. Use `xcodebuild` directly, with the same settings as `make build`, and ask the linker for a map (`LD_GENERATE_MAP_FILE=YES` with `LD_MAP_FILE_PATH`, or `-Xlinker -map`).
   - From the map, give:
     - the executable's size;
     - what the `Phone/` objects add to it, with the five largest;
     - the 15 largest objects of the whole app, so the user can see where the 22 MB goes.
2. **Decide.**
   - If the `Phone/` objects add less than 100 KB, change nothing, and report the measurement.
   - If they add 100 KB or more, leave them out of the Mac's Release build only. Debug keeps them, so the Mac's tests still run them.
     - Read Apple's documentation for `EXCLUDED_SOURCE_FILE_NAMES` before using it, since how it matches paths decides what it leaves out.
     - Set it for the Mac target's Release configuration in `project.yml`, then run `python3 -I -B Scripts/agents/regenerate-project.py`.
     - If code the Mac uses refers to a type in `Phone/`, the build will say so. Report where, and leave that file in rather than restructuring anything.
3. **Prove it,** if you changed the build:
   - a Release build that succeeds, smaller by about what you measured;
   - the Debug build and the Mac tests unchanged: one train with `--areas phone,support`, and the classes that test `Phone/` code;
   - `make typecheck-mac` and `make typecheck-ios`;
   - the Release app's bundled resources and licences unchanged, compared with `copy_phases.py`.

## Checks

- Each Release build takes several minutes of CPU: at most three in all, each through `run_locked.py`.
- The derived data may take 2 GB or more. Report its size: the orchestrator clears it at the end.
- Edit no Markdown. Your report says what `docs/developer/building.md` needs.
