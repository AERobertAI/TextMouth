"""retry_logs.py: logs of `xcodebuild test -retry-tests-on-failure -test-iterations 3`, as the tests read them.

The first two are trimmed from real runs on this Mac on November 15, 2026 (class and test names kept, paths and
timestamps shortened): a scratch branch, never merged, held tests that failed on their first try, on every
try, and by crashing the host. The three facts the readers rely on are in them: each try starts with
`(Iteration N of 3)`, a suite whose test needed a second try prints `failed` though the run SUCCEEDED, and
the Executed line counts every try (3 tests, 1 failure for two tests of which one failed once).
The third is put together from those forms, not run: no test may crash the host on this Mac again.
"""

# One test failed on its first try and passed on its second. xcodebuild exited 0.
PASSED_ON_TRY_TWO = """\
Test Suite 'Selected tests' started at 2026-11-15 20:52:59.660.
Test Suite 'TextMouthProductionTests.xctest' started at 2026-11-15 20:52:59.660.
Test Suite 'CountWordingTests' started at 2026-11-15 20:52:59.660.
Test Case '-[TextMouthProductionTests.CountWordingTests testBooks]' started (Iteration 1 of 3).
Test Case '-[TextMouthProductionTests.CountWordingTests testBooks]' passed (0.004 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' started (Iteration 1 of 3).
/r/TextMouthProductionTests/CountWordingTests.swift:123: error: -[TextMouthProductionTests.CountWordingTests testFlaky] : XCTAssertGreaterThanOrEqual failed: ("1") is less than ("2") - first try fails on purpose
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' failed (0.165 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' started (Iteration 2 of 3).
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' passed (0.001 seconds).
Test Suite 'CountWordingTests' failed at 2026-11-15 20:52:59.831.
\t Executed 3 tests, with 1 failure (0 unexpected) in 0.170 (0.171) seconds
Test Suite 'TextMouthProductionTests.xctest' failed at 2026-11-15 20:52:59.832.
\t Executed 3 tests, with 1 failure (0 unexpected) in 0.170 (0.172) seconds
Test Suite 'Selected tests' failed at 2026-11-15 20:52:59.832.
\t Executed 3 tests, with 1 failure (0 unexpected) in 0.170 (0.172) seconds

Test session results, code coverage, and logs:
\t/r/DD/Logs/Test/Test-TextMouth.xcresult

** TEST EXECUTE SUCCEEDED **
"""

# One test failed on all three tries, one passed on try two, and one crashed the host on its first try
# (it was not tried again: the host restarted and went on with the next test). xcodebuild said TEST FAILED.
FAILED_ALL_TRIES_AND_A_CRASH = """\
Test Suite 'Selected tests' started at 2026-11-15 20:51:26.532.
Test Suite 'CountWordingTests' started at 2026-11-15 20:51:26.533.
Test Case '-[TextMouthProductionTests.CountWordingTests testBooks]' started (Iteration 1 of 3).
Test Case '-[TextMouthProductionTests.CountWordingTests testBooks]' passed (0.001 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testCrashes]' started (Iteration 1 of 3).
CountWordingTests.swift:129: Fatal error: probe crash on the first try

Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

Test Suite 'Selected tests' started at 2026-11-15 20:51:51.687.
Test Suite 'CountWordingTests' started at 2026-11-15 20:51:51.688.
Test Case '-[TextMouthProductionTests.CountWordingTests testAlways]' started (Iteration 1 of 3).
/r/TextMouthProductionTests/CountWordingTests.swift:126: error: -[TextMouthProductionTests.CountWordingTests testAlways] : XCTAssertEqual failed: ("1") is not equal to ("-1") - fails on every try
Test Case '-[TextMouthProductionTests.CountWordingTests testAlways]' failed (6.021 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testAlways]' started (Iteration 2 of 3).
/r/TextMouthProductionTests/CountWordingTests.swift:126: error: -[TextMouthProductionTests.CountWordingTests testAlways] : XCTAssertEqual failed: ("2") is not equal to ("-1") - fails on every try
Test Case '-[TextMouthProductionTests.CountWordingTests testAlways]' failed (0.002 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testAlways]' started (Iteration 3 of 3).
/r/TextMouthProductionTests/CountWordingTests.swift:126: error: -[TextMouthProductionTests.CountWordingTests testAlways] : XCTAssertEqual failed: ("3") is not equal to ("-1") - fails on every try
Test Case '-[TextMouthProductionTests.CountWordingTests testAlways]' failed (0.001 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' started (Iteration 1 of 3).
/r/TextMouthProductionTests/CountWordingTests.swift:123: error: -[TextMouthProductionTests.CountWordingTests testFlaky] : XCTAssertGreaterThanOrEqual failed: ("1") is less than ("2") - first try fails on purpose
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' failed (0.001 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' started (Iteration 2 of 3).
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' passed (0.001 seconds).
Test Suite 'CountWordingTests' failed at 2026-11-15 20:51:57.808.
\t Executed 8 tests, with 4 failures (0 unexpected) in 6.030 (6.120) seconds
Test Suite 'Selected tests' failed at 2026-11-15 20:51:57.809.
\t Executed 8 tests, with 4 failures (0 unexpected) in 6.030 (6.122) seconds

** TEST FAILED **
"""

# The same run's end, if it had passed on try two and then a later test crashed the host on a retry: the
# crash's try started and never ended, and the host restarted.
CRASH_DURING_A_RETRY = """\
Test Suite 'Selected tests' started at 2026-11-15 21:00:00.000.
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' started (Iteration 1 of 3).
/r/TextMouthProductionTests/CountWordingTests.swift:123: error: -[TextMouthProductionTests.CountWordingTests testFlaky] : XCTAssertTrue failed
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' failed (0.100 seconds).
Test Case '-[TextMouthProductionTests.CountWordingTests testFlaky]' started (Iteration 2 of 3).
Fatal error: crashed on the retry

Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

Test Suite 'Selected tests' started at 2026-11-15 21:00:30.000.
Test Case '-[TextMouthProductionTests.CountWordingTests testBooks]' started (Iteration 1 of 3).
Test Case '-[TextMouthProductionTests.CountWordingTests testBooks]' passed (0.001 seconds).
Test Suite 'Selected tests' passed at 2026-11-15 21:00:31.000.
\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.002) seconds

** TEST FAILED **
"""
