# PROGRESS-brfguess

Branch `feature/braille-code-guess`. Items of the brief:

1. Stricter detector rule: done (BrailleCodeDetector.Count.isClearlyEBAE; thresholds checked with liblouis forward, scratchpad g/).
2. Origin field `brailleTableOrigin` (BrailleTableOrigin.guessed): row, record, marker, summary, choice clears it: done.
3. Import guess (FileImportService.brailleReading(ofImported:)), BraillePreferences.guessesTable: done in code.
4. Book Information wording ", guessed", Braille tab switch: done in code.
5. Tests: BrailleTableGuessTests.swift, BrailleGuessFixtures.swift; OnDiskContract, BrailleSettingsView tests updated.

Left: make generate, typecheck-tests, train, report.
