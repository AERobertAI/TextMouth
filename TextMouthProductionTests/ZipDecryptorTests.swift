#if os(macOS)
import XCTest
import ZIPFoundation
@testable import TextMouth

/// A password-protected ZIP is made plain in memory (FR41, phase 1). The
/// fixtures come from the tools macOS ships, which are independent of
/// TextMouth's own reading: `zip -P` writes ZipCrypto, and `bsdtar` writes
/// WinZip AES in 128 and 256 bits. Each test makes its archives in its own
/// folder, and a missing tool skips the test.
final class ZipDecryptorTests: XCTestCase {

    /// The folder this test's files are made in.
    private var folder: URL!

    /// Text long enough that `zip` deflates it.
    private let longText = String(repeating: "lorem ipsum dolor sit amet ", count: 9000) + "END"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZipDecryptorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src/d"), withIntermediateDirectories: true)
        try "short words".write(to: folder.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try longText.write(to: folder.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        try "inner words".write(to: folder.appendingPathComponent("src/d/c.txt"), atomically: true, encoding: .utf8)
    }

    /// Runs `tool` with `arguments` in the sources folder; skips the test when it cannot run.
    private func run(_ tool: String, _ arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("\(tool) is not here") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder.appendingPathComponent("src")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("\(tool) could not make the fixture") }
    }

    /// A ZipCrypto archive of the sources, written by `zip`.
    private func zipCryptoArchive(password: String) throws -> URL {
        let url = folder.appendingPathComponent("crypto.zip")
        try run("/usr/bin/zip", ["-q", "-r", "-P", password, url.path, "a.txt", "b.txt", "d"])
        return url
    }

    /// A WinZip AES archive of the sources, written by `bsdtar`.
    private func aesArchive(password: String, strength: String) throws -> URL {
        let url = folder.appendingPathComponent("aes-\(strength).zip")
        try run("/usr/bin/bsdtar", ["-a", "-cf", url.path, "--options", "zip:encryption=\(strength)", "--passphrase", password, "a.txt", "b.txt", "d"])
        return url
    }

    /// The files of the plain archive `data`, by path, with their bytes.
    private func files(of data: Data) throws -> [String: String] {
        let archive = try Archive(data: data, accessMode: .read)
        var found: [String: String] = [:]
        for entry in archive where entry.type == .file {
            var bytes = Data()
            // Checked against the checksum the plain archive records.
            _ = try archive.extract(entry, skipCRC32: false) { bytes.append($0) }
            found[entry.path] = String(decoding: bytes, as: UTF8.self)
        }
        return found
    }

    /// The files every fixture holds.
    private var expectedFiles: [String: String] {
        ["a.txt": "short words", "b.txt": longText, "d/c.txt": "inner words"]
    }

    // MARK: - The Schemes

    /// ZipCrypto: every file comes out plain, stored and deflated alike.
    func testZipCryptoIsMadePlain() throws {
        let url = try zipCryptoArchive(password: "secret")
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: url).sorted(), ["a.txt", "b.txt", "d/c.txt"])
        let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret("secret"))
        XCTAssertEqual(try files(of: plain), expectedFiles)
    }

    /// WinZip AES at 128 and 256 bits, whose checksums are made again.
    func testWinZipAESIsMadePlain() throws {
        for strength in ["aes128", "aes256"] {
            let url = try aesArchive(password: "secret", strength: strength)
            let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret("secret"))
            XCTAssertEqual(try files(of: plain), expectedFiles, strength)
        }
    }

    /// The plain archive holds no encrypted entry, so every reader takes it as it is.
    func testThePlainArchiveHoldsNothingEncrypted() throws {
        let url = try aesArchive(password: "secret", strength: "aes256")
        let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret("secret"))
        let copy = folder.appendingPathComponent("plain.zip")
        try plain.write(to: copy)
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: copy), [])
        XCTAssertEqual(ZipCentralDirectory.records(ofFileAt: copy)?.map(\.name).sorted(), ["a.txt", "b.txt", "d/", "d/c.txt"])
    }

    // MARK: - The Wrong Password

    /// A wrong password is named as such, for each scheme.
    func testAWrongPasswordIsRefused() throws {
        let crypto = try zipCryptoArchive(password: "secret")
        let aes = try aesArchive(password: "secret", strength: "aes256")
        for url in [crypto, aes] {
            XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: url, password: Secret("Secret"))) {
                XCTAssertEqual($0 as? ZipDecryptor.Failure, .wrongPassword, url.lastPathComponent)
            }
            XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: url, password: Secret(""))) {
                XCTAssertEqual($0 as? ZipDecryptor.Failure, .wrongPassword, url.lastPathComponent)
            }
        }
    }

    /// An accent typed decomposed opens a file whose writer composed it, and the reverse.
    func testAnAccentedPasswordOpensInEitherForm() throws {
        let composed = "p\u{E4}ssw\u{F6}rd"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        for url in [try zipCryptoArchive(password: composed), try aesArchive(password: composed, strength: "aes256")] {
            let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret(decomposed))
            XCTAssertEqual(try files(of: plain), expectedFiles, url.lastPathComponent)
        }
    }

    // MARK: - Damage

    /// A flipped byte in AES data fails its authentication: damage, never wrong text.
    func testAFlippedByteInAESDataIsRefused() throws {
        let url = try aesArchive(password: "secret", strength: "aes256")
        var bytes = [UInt8](try Data(contentsOf: url))
        // The first entry's data starts after its 30-byte header, name, and extra field.
        let dataStart = 30 + Int(bytes.u16(26)) + Int(bytes.u16(28))
        bytes[dataStart + 12] ^= 0xFF
        let damaged = folder.appendingPathComponent("damaged.zip")
        try Data(bytes).write(to: damaged)
        XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: damaged, password: Secret("secret")))
    }

    /// A plain archive passes through unchanged in content.
    func testAnArchiveWithoutEncryptionIsCopiedAsItIs() throws {
        let made = try makeTemporaryZip(prefix: "plain", entries: ["a.txt": Data("short words".utf8)], compressionMethod: .deflate)
        defer { try? FileManager.default.removeItem(at: made) }
        let plain = try ZipDecryptor.decrypt(archiveAt: made, password: Secret("anything"))
        XCTAssertEqual(try files(of: plain), ["a.txt": "short words"])
    }

    /// A file that is no archive is damage.
    func testANonArchiveIsDamage() throws {
        let url = folder.appendingPathComponent("not.zip")
        try Data("plain words".utf8).write(to: url)
        XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: url, password: Secret("x"))) {
            XCTAssertEqual($0 as? ZipDecryptor.Failure, .damaged)
        }
    }

    /// Strong encryption (flag bit 6) is refused in its own words, not as a wrong password.
    func testStrongEncryptionIsUnsupported() throws {
        let url = try zipCryptoArchive(password: "secret")
        let strong = folder.appendingPathComponent("strong.zip")
        var bytes = [UInt8](try Data(contentsOf: url))
        // Set bit 6 in the first central header's flags.
        let central = try XCTUnwrap(ZipCentralDirectoryTestLookup.firstCentralHeader(in: bytes))
        bytes[central + 8] |= 0x40
        try Data(bytes).write(to: strong)
        XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: strong, password: Secret("secret"))) {
            XCTAssertEqual($0 as? ZipDecryptor.Failure, .unsupported)
        }
    }
}

/// Finds a central directory header in test bytes, without TextMouth's own reader.
enum ZipCentralDirectoryTestLookup {
    /// The offset of the first "PK\1\2" header in `bytes`, or nil.
    static func firstCentralHeader(in bytes: [UInt8]) -> Int? {
        (0..<max(0, bytes.count - 4)).first { bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x01 && bytes[$0 + 3] == 0x02 }
    }
}
#endif
