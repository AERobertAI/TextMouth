import Foundation

func runTimeFormattingTests() {
print("\n--- Time Formatting Tests ---")

test("Time formatting to the second") {
    func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
    try assertEqual(formatTime(0), "0:00")
    try assertEqual(formatTime(30), "0:30")
    try assertEqual(formatTime(65), "1:05")
    try assertEqual(formatTime(120), "2:00")
    try assertEqual(formatTime(3600), "1:00:00")
    try assertEqual(formatTime(3661), "1:01:01")
    try assertEqual(formatTime(5400), "1:30:00")
    try assertEqual(formatTime(7200), "2:00:00")
    print("    All time formats correct (to the second)")
}

test("Spoken time formatting for VoiceOver") {
    func spokenTime(_ seconds: Double) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) \(secs == 1 ? "second" : "seconds")") }
        return parts.joined(separator: ", ")
    }

    // Zero
    try assertEqual(spokenTime(0), "0 seconds")

    // Seconds only
    try assertEqual(spokenTime(45), "45 seconds")
    try assertEqual(spokenTime(1), "1 second")

    // Minutes only (no seconds if 0)
    try assertEqual(spokenTime(120), "2 minutes")
    try assertEqual(spokenTime(60), "1 minute")

    // Minutes and seconds
    try assertEqual(spokenTime(90), "1 minute, 30 seconds")
    try assertEqual(spokenTime(3275), "54 minutes, 35 seconds")

    // Hours only
    try assertEqual(spokenTime(3600), "1 hour")
    try assertEqual(spokenTime(7200), "2 hours")

    // Hours and minutes
    try assertEqual(spokenTime(5400), "1 hour, 30 minutes")

    // Hours, minutes, seconds
    try assertEqual(spokenTime(3725), "1 hour, 2 minutes, 5 seconds")

    // Key regression: 54:35 must NOT be read as "54 hours"
    // spokenTime(3275) = "54 minutes, 35 seconds" (not "54 hours, 35 minutes")
    let result = spokenTime(3275)
    try assertTrue(!result.contains("hour"), "54:35 should not contain 'hour'")
    try assertTrue(result.contains("54 minutes"), "54:35 should say '54 minutes'")
}

} // end runTimeFormattingTests
