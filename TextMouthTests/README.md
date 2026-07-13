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
