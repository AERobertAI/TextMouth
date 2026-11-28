import Foundation

/// The iPhone's watch on the memory a conversion by one of TextMouth's own
/// readers (`OwnAudioConverter`) takes, which no helper process holds apart
/// from the app: a header may ask for a Monkey's Audio frame of 24 million
/// samples, about 200 MB with the copy made of it, and four conversions of
/// one ZIP run at once. iOS ends the app past its memory limit, which the
/// listener would meet as a crash, so the conversion asks the floor that
/// FFmpeg's in-app run keeps (`SessionMemoryFloor`, `RunMemory`) before each
/// block, and ends with the same sentence as FFmpeg's does
/// ("Converting a.ape was stopped because the app's memory grew by more
/// than 700 MB while it ran."). The Mac has no such watch: its own readers
/// run in the app as here, but a Mac has swap and no memory limit that ends
/// an app, and its behavior is unchanged.
struct OwnAudioMemoryWatch: Sendable {
    /// The name of the file converted, which the sentence names.
    let fileName: String
    /// What the conversion keeps of the memory the app had left as it began.
    let memory: RunMemory

    /// A watch on the conversion of `fileName`, beginning now; `floor` is the
    /// app's, unless a test scripts its own.
    init(fileName: String, floor: SessionMemoryFloor = .app) {
        self.fileName = fileName
        memory = floor.run(beganWith: floor.left)
    }

    /// Asks whether the app still has memory to spare, before a block is
    /// decoded: nothing when it has (or the system sets it no limit).
    /// - Throws: `ImportAudioConverter.Failure.killed`, as an FFmpeg run
    ///   stopped for memory is told, when the app has less left than the
    ///   floor, or none.
    func check() throws {
        guard let left = memory.leftWhenCrossed() else { return }
        throw ImportAudioConverter.Failure.killed(fileName: fileName, reason: memory.stopReason(whenLeft: left).words)
    }
}
