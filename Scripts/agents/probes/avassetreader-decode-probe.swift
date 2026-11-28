// avassetreader-decode-probe.swift: does AVAssetReader decode an audio file on this machine, and how fast?
//
// Usage: avassetreader-decode-probe FILE [SECONDS]
// It reads FILE to its end as linear PCM through AVAssetReader (the call AudioMediaProbe.decodesSamples makes, which hangs
// on GitHub's macOS runners), on a background thread, and gives up after SECONDS (default 20) so that a hang is an answer
// and not a stuck job. Prints one line: "decoded N samples in S s" (exit 0), "hung after S s" (exit 3), or the reader's
// failure (exit 1). Compiled and run only by Scripts/agents/runner_audio_probe.py.
import AVFoundation
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: avassetreader-decode-probe FILE [SECONDS]")
    exit(2)
}
let limit = arguments.count > 2 ? (Double(arguments[2]) ?? 20) : 20
let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))
let finished = DispatchSemaphore(value: 0)
let started = Date()

// The read runs off the main thread, so the main thread can time it out.
DispatchQueue.global().async {
    guard let track = asset.tracks(withMediaType: .audio).first,
          let reader = try? AVAssetReader(asset: asset) else {
        print("failed: no audio track or no reader")
        exit(1)
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { print("failed: cannot add the output"); exit(1) }
    reader.add(output)
    guard reader.startReading() else { print("failed: startReading: \(String(describing: reader.error))"); exit(1) }
    var samples = 0
    while let buffer = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(buffer) }
    print(String(format: "decoded %d samples in %.2f s (status %d)", samples, Date().timeIntervalSince(started), reader.status.rawValue))
    finished.signal()
}

if finished.wait(timeout: .now() + limit) == .timedOut {
    print(String(format: "hung after %.0f s", limit))
    exit(3)
}
