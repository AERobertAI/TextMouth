import XCTest

// Real media fixtures shared by the test classes that parse audio
// (`AudioDirectoryImportTests` and `ContentIndexValidationTests`), so the
// WAV writer exists once.

extension XCTestCase {
    /// Write a one-second mono PCM WAV, creating its folder as needed. Real
    /// media avoids relying on a parser's fallback behavior for corrupt
    /// dummy files.
    func writeSilence(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + 16_000), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(8_000), to: &data)
        appendLittleEndian(UInt32(16_000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(16_000), to: &data)
        data.append(Data(count: 16_000))
        try data.write(to: url)
    }
}

/// WAV header integers use little-endian byte order on every host.
private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var encoded = value.littleEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}
