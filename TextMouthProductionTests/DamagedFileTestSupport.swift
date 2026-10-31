import Foundation
import os
import XCTest

/// Helpers for tests that hand parsers damaged copies of good files.
extension XCTestCase {
    /// The stack size of a GCD worker thread, which imports (the import
    /// queue) and feed refreshes (`OffMainWork`) run on: 512 KiB, a
    /// sixteenth of the main thread's.
    static let workerThreadStackSize = 512 * 1024

    /// Runs `body` on a thread with a worker thread's stack
    /// (`workerThreadStackSize`) and returns what it returns, or nil, after
    /// recording a failure, when it has not finished within `timeout`
    /// seconds. A parser that recurses once for every level of nesting
    /// overflows such a stack long before the main thread's, so a test of
    /// deeply nested input runs its parse here, as the app would. It never
    /// traps itself: a body that overflows the stack still ends the test
    /// host, which is why such a test runs only with its fix in place.
    func onWorkerSizedStack<Value: Sendable>(
        timeout: TimeInterval = 60,
        _ body: @escaping @Sendable () -> Value
    ) -> Value? {
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let value = body()
            result.withLock { $0 = value }
            finished.signal()
        }
        thread.stackSize = Self.workerThreadStackSize
        // The test waits for it, so it runs at the waiting thread's
        // priority, which the thread performance checker asks of a wait.
        thread.qualityOfService = .userInteractive
        thread.start()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            XCTFail("The work on a \(Self.workerThreadStackSize / 1024) KiB stack did not finish within \(Int(timeout)) seconds")
            return nil
        }
        return result.withLock { $0 }
    }

    /// `text` up to, not including, the first `marker`: a copy cut off
    /// partway, as an interrupted download or extraction leaves it.
    static func truncated(_ text: String, before marker: String) -> String {
        guard let range = text.range(of: marker) else {
            preconditionFailure("Fixture marker \(marker) not found")
        }
        return String(text[..<range.lowerBound])
    }

    /// `text` as UTF-8 with the byte 0xE9 inserted before the first `marker`.
    /// That byte is "é" in ISO Latin 1 but can never stand alone in UTF-8, as
    /// in a file a tool wrote in Latin 1 while declaring UTF-8.
    static func misencoded(_ text: String, before marker: String) -> Data {
        guard let range = text.range(of: marker) else {
            preconditionFailure("Fixture marker \(marker) not found")
        }
        var data = Data(text[..<range.lowerBound].utf8)
        data.append(0xE9)
        data.append(contentsOf: text[range.lowerBound...].utf8)
        return data
    }
}
