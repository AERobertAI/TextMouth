import AVFoundation
import XCTest
@testable import TextMouth

/// What the Mac's host reads back of a file the own readers' import wrote,
/// with Apple's audio file reader. The iPhone's unit bundle shares
/// `OwnAudioImportTests` and names no audio framework, so these helpers live
/// in a file only the Mac's bundle compiles.
extension XCTestCase {
    /// Every sample of the .m4a at `url`, a file a conversion wrote, as
    /// 32-bit whole numbers with each sample at the top of its 32 bits.
    func samplesOfConvertedFile(at url: URL) throws -> [Int32] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt32, interleaved: true)
        let frames = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(frames, 1)))
        try file.read(into: buffer)
        let count = Int(buffer.frameLength) * Int(file.processingFormat.channelCount)
        let data = try XCTUnwrap(buffer.int32ChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }

    /// Whether the file at `url` holds Apple Lossless.
    func isAppleLossless(_ url: URL) throws -> Bool {
        // The format is held while its description is read: the pointer is into the format's own storage.
        let storedFormat = try AVAudioFile(forReading: url).fileFormat
        return storedFormat.streamDescription.pointee.mFormatID == kAudioFormatAppleLossless
    }
}
