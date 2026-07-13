# TextMouth test compatibility runner

Run `swift run` in this directory to execute `TextMouthProductionTests`, the
hosted XCTest target that imports the real `TextMouth` module.

The historical files under `Sources/` are intentionally excluded from the
Swift package. They are retained temporarily as reference material for mining
additional test cases, but they are not compiled and cannot affect a pass or
failure. That harness duplicated production models and parsers, and many tests
exercised simulations rather than application code.

New and migrated regression tests belong in `TextMouthProductionTests/` and
must use `@testable import TextMouth`.

Migration progress is tracked in `../TODO-2026-07-12.md`. The historical
runner executed 1,184 logical scenarios (1,091 literal registrations plus
loop-generated cases). Two migration batches have moved 164 of those scenarios
to the hosted suite without compiling copied app implementations. The hosted
suite currently reports 124 XCTest methods and executes 231 logical cases when
named scenarios inside compatibility activities are counted.
