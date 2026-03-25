import Foundation

/// Append a timestamped message to the debug log file for VoiceOver focus debugging.
/// Uses the same log file as ReaderViewModel.debugLog().
func voiceOverFocusLog(_ msg: String) {
    let logPath = TextMouthPaths.debugLogFile.path
    let line = "\(Date()) [VoiceOverFocus]: \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath),
           let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}
