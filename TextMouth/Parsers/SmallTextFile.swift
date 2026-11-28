import Foundation

/// A small text file that travels beside audio and says where its chapters
/// begin: a cue sheet (FMT24) or an Audacity label file (FMT06). The one way
/// both are read, so both are bounded and decoded alike.
enum SmallTextFile {
    /// The text of the file at `url`, decoded as a plain-text book's file is
    /// (`TextFileDecoder`): a byte-order mark names the encoding, valid UTF-8
    /// is UTF-8, and anything else is read as Windows-1252, which gives Latin
    /// 1's letters too; every line ends in a line feed. At most `byteLimit`
    /// plus one bytes are read, so a larger file is refused without being
    /// read whole.
    ///
    /// Only a regular file (or a link to one) is opened: opening a FIFO or a
    /// device for reading can wait forever.
    /// - Returns: nil when the file holds more than `byteLimit` bytes.
    /// - Throws: `CocoaError(.fileReadNoSuchFile)` for anything but a regular
    ///   file, or the error opening, reading, or decoding it.
    static func text(at url: URL, byteLimit: Int) throws -> String? {
        guard let data = try data(at: url, byteLimit: byteLimit) else { return nil }
        return try TextFileDecoder.decode(data, fileName: url.lastPathComponent, format: .txt).text
    }

    /// The bytes of the file at `url`, read as `text(at:byteLimit:)` reads them: only a regular file (or a link to one) is
    /// opened, and at most `byteLimit` plus one bytes are read.
    /// - Returns: nil when the file holds more than `byteLimit` bytes.
    /// - Throws: `CocoaError(.fileReadNoSuchFile)` for anything but a regular file, or the error opening or reading it.
    static func data(at url: URL, byteLimit: Int) throws -> Data? {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url]) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        return data.count <= byteLimit ? data : nil
    }
}
