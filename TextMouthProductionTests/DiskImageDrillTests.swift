import XCTest
@testable import TextMouth

/// The always-on tests of the storage drill's tools (`DiskImageDrill.swift`):
/// none of them runs `hdiutil` or touches a disk image. They pin the exact
/// commands the drill issues, the filter that decides which attached images
/// a sweep may detach, the folder snapshot that proves the user's files did
/// not change, and the command runner's timeout.
final class DiskImageDrillTests: XCTestCase {

    // MARK: - Commands

    /// The commands are exactly the ones the drill's safety rules name.
    func testTheCommandsHaveTheExactArguments() {
        let image = URL(fileURLWithPath: "/sandbox/TMDrill-ab12cd34-import.dmg")
        let mount = URL(fileURLWithPath: "/sandbox/mnt-import-ab12cd34")

        XCTAssertEqual(
            HDIUtil.createArguments(megabytes: 16, volumeName: "TMDrill-ab12cd34", image: image),
            ["create", "-size", "16m", "-fs", "HFS+", "-volname", "TMDrill-ab12cd34", "-ov",
             "/sandbox/TMDrill-ab12cd34-import.dmg"]
        )
        XCTAssertEqual(
            HDIUtil.attachArguments(image: image, mountPoint: mount),
            ["attach", "-nobrowse", "-noverify", "-noautofsck", "-mountpoint",
             "/sandbox/mnt-import-ab12cd34", "/sandbox/TMDrill-ab12cd34-import.dmg"]
        )
        XCTAssertEqual(
            HDIUtil.detachArguments(target: "/sandbox/mnt-import-ab12cd34"),
            ["detach", "-force", "/sandbox/mnt-import-ab12cd34"]
        )
    }

    /// An image's names put it in the folder given, with the volume name
    /// the sweeper looks for.
    func testAnImageIsNamedForTheSweeper() {
        let folder = URL(fileURLWithPath: "/sandbox/Scratch/x", isDirectory: true)
        let image = DiskImage(in: folder, name: "full", token: "0a1b2c3d")

        XCTAssertEqual(image.volumeName, "TMDrill-0a1b2c3d")
        XCTAssertEqual(image.imageURL.path, "/sandbox/Scratch/x/TMDrill-0a1b2c3d-full.dmg")
        XCTAssertEqual(image.mountPoint.path, "/sandbox/Scratch/x/mnt-full-0a1b2c3d")
    }

    // MARK: - The Fill Guards

    /// A volume is mounted only when the mount point's device is known and
    /// differs from its parent folder's.
    func testAVolumeIsMountedOnlyWhenItsDeviceDiffersFromTheParents() {
        XCTAssertEqual(FillGuards.volumeDevice(inside: 7, outside: 1), 7)
        XCTAssertNil(FillGuards.volumeDevice(inside: 1, outside: 1), "the same device means nothing is mounted")
        XCTAssertNil(FillGuards.volumeDevice(inside: nil, outside: 1))
        XCTAssertNil(FillGuards.volumeDevice(inside: 7, outside: nil))
        XCTAssertNil(FillGuards.volumeDevice(inside: nil, outside: nil))
    }

    /// No fill starts without a mounted volume and a known size; the reason
    /// names the missing one, the volume first.
    func testNoFillStartsWithoutAMountedVolumeAndAKnownSize() {
        let size: Int64 = 3 * 1024 * 1024

        XCTAssertNil(FillGuards.refusalBeforeFilling(volumeDevice: 7, capacityBytes: size))
        XCTAssertEqual(FillGuards.refusalBeforeFilling(volumeDevice: nil, capacityBytes: size), "the image is not attached")
        XCTAssertEqual(FillGuards.refusalBeforeFilling(volumeDevice: nil, capacityBytes: nil), "the image is not attached")
        XCTAssertEqual(FillGuards.refusalBeforeFilling(volumeDevice: 7, capacityBytes: nil), "the image's size is not known")
        XCTAssertEqual(FillGuards.refusalBeforeFilling(volumeDevice: 7, capacityBytes: 0), "the image's size is not known")
        XCTAssertEqual(FillGuards.refusalBeforeFilling(volumeDevice: 7, capacityBytes: -1), "the image's size is not known")
    }

    /// The ballast file's descriptor must be on the volume's device.
    func testTheBallastMustBeOnTheVolumesDevice() {
        XCTAssertNil(FillGuards.refusalForDescriptor(descriptorDevice: 7, volumeDevice: 7))
        XCTAssertEqual(
            FillGuards.refusalForDescriptor(descriptorDevice: 1, volumeDevice: 7),
            "the ballast file is not on the image's volume"
        )
    }

    /// The write cap is twice the image's size: exactly that is allowed, one
    /// byte more is not, and a 3 MB image can never take 6 MB and a byte.
    func testTheWriteCapIsTwiceTheImagesSizeWithExactBoundaries() {
        let size: Int64 = 3 * 1024 * 1024

        XCTAssertEqual(FillGuards.writeLimit(capacityBytes: size), 6 * 1024 * 1024)
        XCTAssertFalse(FillGuards.exceedsCap(written: 0, capacityBytes: size))
        XCTAssertFalse(FillGuards.exceedsCap(written: size, capacityBytes: size), "a full image is the normal case")
        XCTAssertFalse(FillGuards.exceedsCap(written: 2 * size, capacityBytes: size), "exactly twice is allowed")
        XCTAssertTrue(FillGuards.exceedsCap(written: 2 * size + 1, capacityBytes: size))
        XCTAssertTrue(FillGuards.exceedsCap(written: 10 * size, capacityBytes: size))
    }

    /// An image that was never made knows no size, so it cannot be filled.
    func testAnImageThatWasNeverMadeKnowsNoSize() {
        let image = DiskImage(in: URL(fileURLWithPath: "/sandbox/x", isDirectory: true), name: "fresh", token: "0a1b2c3d")

        XCTAssertNil(image.capacityBytes)
    }

    // MARK: - The Leftover Filter

    /// The sandbox prefixes name the folder holding every test sandbox,
    /// spelled as given and with links resolved.
    func testTheSandboxPrefixesCoverTheBaseNotOnlyThisProcess() {
        let home = URL(fileURLWithPath: "/private/tmp/base/TextMouthTests-4242", isDirectory: true)

        XCTAssertEqual(LeftoverImages.sandboxPrefixes(sandboxHome: home), ["/private/tmp/base/TextMouthTests-"])
    }

    /// Only a `TMDrill-` image under the sandbox base is picked, whichever
    /// way its path is spelled; every look-alike is left alone.
    func testOnlyTheDrillsOwnImagesAreFound() throws {
        let prefixes = ["/var/folders/zz/T/TextMouthTests-", "/private/var/folders/zz/T/TextMouthTests-"]
        let plist = Self.infoPlist(images: [
            // Ours: sandbox of a crashed earlier run, as hdiutil spells it.
            ("/private/var/folders/zz/T/TextMouthTests-777/Scratch/a/TMDrill-11111111-import.dmg",
             ["/dev/disk7", "/dev/disk7s1"]),
            // Ours, spelled with /var.
            ("/var/folders/zz/T/TextMouthTests-778/Scratch/b/TMDrill-22222222-full.dmg", ["/dev/disk8s1", "/dev/disk8"]),
            // A TMDrill- name outside the sandbox: not ours to detach.
            ("/Users/someone/Downloads/TMDrill-33333333.dmg", ["/dev/disk9"]),
            // Inside the sandbox but not a drill image.
            ("/var/folders/zz/T/TextMouthTests-779/Scratch/c/Backup.dmg", ["/dev/disk10"]),
            // The sandbox name without its dash, and a longer first component.
            ("/var/folders/zz/T/TextMouthTestsX/TMDrill-44444444.dmg", ["/dev/disk11"]),
            ("/var/folders/zz/T/NotTextMouthTests-1/TMDrill-55555555.dmg", ["/dev/disk12"]),
            // A name that only contains the prefix.
            ("/var/folders/zz/T/TextMouthTests-780/MyTMDrill-66666666.dmg", ["/dev/disk13"])
        ])

        let found = LeftoverImages.drillImages(inInfoPlist: plist, sandboxPrefixes: prefixes)

        XCTAssertEqual(found.map(\.imagePath), [
            "/private/var/folders/zz/T/TextMouthTests-777/Scratch/a/TMDrill-11111111-import.dmg",
            "/var/folders/zz/T/TextMouthTests-778/Scratch/b/TMDrill-22222222-full.dmg"
        ])
        // The whole disk is what is detached, whichever entry comes first.
        XCTAssertEqual(found.map(\.devices), [["/dev/disk7"], ["/dev/disk8"]])
    }

    /// Nothing attached, no images key, and text that is no property list
    /// all find nothing, and never throw.
    func testAnEmptyOrUnreadableListingFindsNothing() {
        let prefixes = ["/var/folders/zz/T/TextMouthTests-"]

        XCTAssertEqual(LeftoverImages.drillImages(inInfoPlist: Self.infoPlist(images: []), sandboxPrefixes: prefixes), [])
        XCTAssertEqual(LeftoverImages.drillImages(inInfoPlist: Data("not a plist".utf8), sandboxPrefixes: prefixes), [])
        XCTAssertEqual(LeftoverImages.drillImages(inInfoPlist: Data(), sandboxPrefixes: prefixes), [])
        // No prefix at all means no image may be touched.
        let any = Self.infoPlist(images: [("/var/folders/zz/T/TextMouthTests-1/TMDrill-1.dmg", ["/dev/disk3"])])
        XCTAssertEqual(LeftoverImages.drillImages(inInfoPlist: any, sandboxPrefixes: []), [])
    }

    /// A `hdiutil info -plist` listing of `images`, each an image path with
    /// its device entries, in the shape hdiutil prints.
    private static func infoPlist(images: [(path: String, devices: [String])]) -> Data {
        let listed: [[String: Any]] = images.map { image in
            [
                "image-path": image.path,
                "system-entities": image.devices.map { ["dev-entry": $0] }
            ]
        }
        let plist: [String: Any] = ["framework": "681.60.1", "images": listed]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    // MARK: - Folder Snapshots

    /// A snapshot of nothing changed differs in nothing.
    func testAnUnchangedFolderHasNoDifferences() throws {
        let folder = try makeFolder(["a.txt": "alpha", "sub/b.txt": "beta"])

        let before = try FolderSnapshot(of: folder)
        let after = try FolderSnapshot(of: folder)

        XCTAssertEqual(after.differences(from: before), [])
        XCTAssertEqual(before.entries["sub"], FolderSnapshot.folderMarker)
        XCTAssertEqual(before.entries["a.txt"]?.count, 64, "a SHA-256 is 64 hex digits")
    }

    /// A file whose bytes changed, a file that went, and a file that
    /// appeared are each named, with what happened to it.
    func testChangedMissingAndExtraFilesAreNamed() throws {
        let folder = try makeFolder(["keep.txt": "same", "edit.txt": "old", "gone.txt": "bye", "sub/deep.txt": "x"])
        let before = try FolderSnapshot(of: folder)

        try "new".write(to: folder.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("gone.txt"))
        try "hi".write(to: folder.appendingPathComponent("sub/fresh.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("emptydir"), withIntermediateDirectories: false)

        XCTAssertEqual(try FolderSnapshot(of: folder).differences(from: before), [
            "changed: edit.txt",
            "extra: emptydir",
            "extra: sub/fresh.txt",
            "missing: gone.txt"
        ])
    }

    /// The same bytes under another name count as a missing file and an
    /// extra one, not as no change.
    func testARenamedFileIsMissingAndExtra() throws {
        let folder = try makeFolder(["one.txt": "same bytes"])
        let before = try FolderSnapshot(of: folder)

        try FileManager.default.moveItem(at: folder.appendingPathComponent("one.txt"), to: folder.appendingPathComponent("two.txt"))

        XCTAssertEqual(try FolderSnapshot(of: folder).differences(from: before), ["extra: two.txt", "missing: one.txt"])
    }

    /// The folders a volume adds on its own are not part of a snapshot, but
    /// a hidden file of the app's (a staged import) is.
    func testSystemNamesAreIgnoredButOtherHiddenNamesAreNot() throws {
        let folder = try makeFolder(["book.txt": "text", ".Spotlight-V100/store.db": "index", ".fseventsd/log": "x"])
        let before = try FolderSnapshot(of: folder)
        XCTAssertEqual(Set(before.entries.keys), ["book.txt"])

        try makeFile(".import-leftover/part.txt", "half", in: folder)

        XCTAssertEqual(
            try FolderSnapshot(of: folder).differences(from: before),
            ["extra: .import-leftover", "extra: .import-leftover/part.txt"]
        )
    }

    /// Two files with the same text have the same digest, and the digest is
    /// the SHA-256 of the bytes (the well-known one for "abc").
    func testTheDigestIsASHA256() throws {
        let folder = try makeFolder(["abc.txt": "abc"])

        XCTAssertEqual(
            try FolderSnapshot.sha256(of: folder.appendingPathComponent("abc.txt")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// Makes a folder in the sandbox holding the files `contents` names
    /// (path to text), removed when the test ends.
    private func makeFolder(_ contents: [String: String]) throws -> URL {
        let folder = try makeSandboxDirectory("DiskImageDrillTests")
        for (path, text) in contents {
            try makeFile(path, text, in: folder)
        }
        return folder
    }

    /// Writes `text` at `path` inside `folder`, making the folders above it.
    private func makeFile(_ path: String, _ text: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - The Command Runner

    /// A command's output and status come back.
    func testARunReturnsItsOutputAndStatus() {
        let result = CommandRunner.run("/bin/echo", ["storage drill"])

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output, "storage drill\n")

        let failing = CommandRunner.run("/usr/bin/false", [])
        XCTAssertFalse(failing.succeeded)
        XCTAssertEqual(failing.status, 1)
    }

    /// A command that outruns its timeout is stopped and reported as timed
    /// out, long before it would have finished.
    func testARunThatOutrunsItsTimeoutIsStopped() {
        let started = Date()

        let result = CommandRunner.run("/bin/sleep", ["30"], timeout: 0.3)

        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A command that cannot start is reported, not thrown.
    func testACommandThatCannotStartIsReported() {
        let result = CommandRunner.run("/nonexistent/hdiutil", [])

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.output.contains("could not start"))
    }
}
