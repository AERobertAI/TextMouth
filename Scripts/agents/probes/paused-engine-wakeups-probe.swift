import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// Probe of how often a paused speech engine wakes, and of two ways to make
// it wake less without stopping it (perf/playback-idle, audit C12, November
// 15, 2026). A text book paused in rendered audio keeps its `AVAudioEngine`
// running with the player node paused (`AudioEngineService.pause()`), so the
// output's I/O thread goes on being called for silence. This builds the same
// graph (player node, time-pitch unit, main mixer), pauses the node, and
// counts the output unit's render cycles a second, their size in frames, and
// the process's idle wake-ups as `top` reports them, in four states:
//
//   1. as the app is today;
//   2. with the process's power hint set to Favor Saving Power
//      (`kAudioHardwarePropertyPowerHint`, TN2321), set back with a play
//      started at once, and changed both ways while a play runs;
//   3. with this process's I/O buffer raised through the output unit
//      (`kAudioDevicePropertyBufferFrameSize` on the AUHAL, TN2321 listing 3);
//   4. set back, with a play started at once, to see that it plays from its
//      first frame and that no render cycle is missed.
//
// Nothing is heard: the main mixer's volume is 0 throughout, and the one
// buffer played is a ramp a ten-thousandth of full scale. It never changes
// the default output device, its sample rate, or its volume. The power hint
// is the process's own by its definition ("allows a process to indicate",
// AudioHardware.h), and the I/O buffer size is each client process's own
// (TN2321: "An application has complete control over the size of the I/O
// buffer it uses"; Apple's engineers on coreaudio-api, March 2013, the same).
// A second copy of the probe, run as `--read`, reads the device's buffer size
// from another process while this one has raised it, to show exactly that.
//
//     python3 -I Scripts/agents/run_locked.py NAME swiftc -O \
//         Scripts/agents/probes/paused-engine-wakeups-probe.swift -o SCRATCH/wakeups
//     python3 -I Scripts/agents/run_locked.py NAME SCRATCH/wakeups [--buffer]
//
// State 3 runs only when asked for with `--buffer`: without it the probe
// writes no property of the output device at all. The result recorded on
// November 15, 2026 is at the end of this file.

// MARK: - Counting render cycles

/// What the render thread counts: cycles, frames, and the host time and
/// size of each of the last cycles, in a ring the main thread reads. Plain
/// memory written by one thread and read by another without a lock, which a
/// probe's counts can bear.
struct CycleLog {
    static let capacity = 4_096
    var cycles = 0
    var frames = 0
    var hostTimes = [UInt64](repeating: 0, count: CycleLog.capacity)
    var sizes = [UInt32](repeating: 0, count: CycleLog.capacity)
}

let cycleLog = UnsafeMutablePointer<CycleLog>.allocate(capacity: 1)
cycleLog.initialize(to: CycleLog())

/// Called by the output unit before and after each render cycle; counts the
/// cycle once, before it renders.
let renderNotify: AURenderCallback = { _, flags, timeStamp, _, frameCount, _ in
    guard flags.pointee.contains(.unitRenderAction_PreRender) else { return noErr }
    let slot = cycleLog.pointee.cycles % CycleLog.capacity
    cycleLog.pointee.hostTimes[slot] = timeStamp.pointee.mHostTime
    cycleLog.pointee.sizes[slot] = frameCount
    cycleLog.pointee.cycles += 1
    cycleLog.pointee.frames += Int(frameCount)
    return noErr
}

// MARK: - Reading the device (never writing it)

/// The default output device, read only.
func defaultOutputDevice() -> AudioObjectID {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
}

/// One property of `device`, read as a `T`, or nil when it cannot be read.
func read<T>(_ selector: AudioObjectPropertySelector, of device: AudioObjectID, as initial: T) -> T? {
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

/// The device's I/O buffer size as this process sees it, in frames.
func deviceBufferFrames(_ device: AudioObjectID) -> UInt32 {
    read(kAudioDevicePropertyBufferFrameSize, of: device, as: UInt32(0)) ?? 0
}

// A second copy, run as `--read`, prints what another process sees, and ends.
if CommandLine.arguments.contains("--read") {
    print(deviceBufferFrames(defaultOutputDevice()))
    exit(0)
}

/// The output of running `path` with `arguments`, trimmed.
func output(of path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return "could not run: \(error.localizedDescription)" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// This process's idle wake-ups over one second, from `top`'s second sample.
func idleWakeUpsPerSecond() -> String {
    let pid = String(ProcessInfo.processInfo.processIdentifier)
    let text = output(of: "/usr/bin/top", ["-l", "2", "-pid", pid, "-stats", "pid,idlew"])
    // The last line is the second sample's row: the pid, then the count.
    return text.split(separator: "\n").last?.split(separator: " ").last.map(String.init) ?? "?"
}

/// This process's CPU use over one second, from `top`'s second sample.
func cpuPercent() -> String {
    let pid = String(ProcessInfo.processInfo.processIdentifier)
    let text = output(of: "/usr/bin/top", ["-l", "2", "-pid", pid, "-stats", "pid,cpu"])
    return text.split(separator: "\n").last?.split(separator: " ").last.map(String.init) ?? "?"
}

// MARK: - The power hint and the process's buffer size

/// Set this process's power hint (`kAudioHardwarePropertyPowerHint`).
func setPowerHint(_ hint: AudioHardwarePowerHint) -> OSStatus {
    var value = hint.rawValue
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyPowerHint,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    return AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
    )
}

/// This process's I/O buffer size, through the output unit.
func bufferFrames(of unit: AudioUnit) -> UInt32 {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &value, &size)
    return value
}

/// The range the output unit allows for this process's I/O buffer size.
func bufferFrameRange(of unit: AudioUnit) -> AudioValueRange {
    var value = AudioValueRange()
    var size = UInt32(MemoryLayout<AudioValueRange>.size)
    AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSizeRange, kAudioUnitScope_Global, 0, &value, &size)
    return value
}

/// Ask for this process's I/O buffer to be `frames` long, through the
/// output unit.
func setBufferFrames(_ frames: UInt32, of unit: AudioUnit) -> OSStatus {
    var value = frames
    return AudioUnitSetProperty(
        unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &value, UInt32(MemoryLayout<UInt32>.size)
    )
}

// MARK: - The probe

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let timePitch = AVAudioUnitTimePitch()
let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
engine.attach(player)
engine.attach(timePitch)
engine.connect(player, to: timePitch, format: format)
engine.connect(timePitch, to: engine.mainMixerNode, format: format)
// Silent from the first cycle to the last.
engine.mainMixerNode.outputVolume = 0

var configurationChanges = 0
let observer = NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
) { _ in configurationChanges += 1 }

guard let outputUnit = engine.outputNode.audioUnit else {
    print("no output unit")
    exit(1)
}
AudioUnitAddRenderNotify(outputUnit, renderNotify, nil)

let device = defaultOutputDevice()
let sampleRate = read(kAudioDevicePropertyNominalSampleRate, of: device, as: Float64(0)) ?? 0
let transport = read(kAudioDevicePropertyTransportType, of: device, as: UInt32(0)) ?? 0
let range = bufferFrameRange(of: outputUnit)
let fourCC = String(bytes: (0..<4).map { UInt8((transport >> (24 - 8 * $0)) & 0xFF) }, encoding: .ascii) ?? "?"
print("output device: transport '\(fourCC)', \(Int(sampleRate)) Hz, buffer range \(Int(range.mMinimum))-\(Int(range.mMaximum)) frames")

do { try engine.start() } catch {
    print("engine did not start: \(error.localizedDescription)")
    exit(1)
}
// Paused as a paused book's node is: played, then paused.
player.play()
player.pause()

/// Measure one state for `seconds`: the cycles a second, their size, the
/// buffer size this process and another process read, and idle wake-ups.
func measure(_ label: String, seconds: Double = 4) {
    let cyclesBefore = cycleLog.pointee.cycles
    let framesBefore = cycleLog.pointee.frames
    let began = Date()
    let wakeUps = idleWakeUpsPerSecond() + ", CPU % " + cpuPercent()
    let rest = seconds - Date().timeIntervalSince(began)
    if rest > 0 { Thread.sleep(forTimeInterval: rest) }
    let elapsed = Date().timeIntervalSince(began)
    let cycles = cycleLog.pointee.cycles - cyclesBefore
    let frames = cycleLog.pointee.frames - framesBefore
    let elsewhere = output(of: CommandLine.arguments[0], ["--read"])
    print(String(
        format: "%@: %.1f cycles/s, %d frames a cycle, buffer here %d, in another process %@, "
            + "idle wake-ups/s %@, engine running %@, configuration changes %d",
        label, Double(cycles) / elapsed, cycles > 0 ? frames / cycles : 0,
        Int(bufferFrames(of: outputUnit)), elsewhere, wakeUps,
        engine.isRunning ? "yes" : "no", configurationChanges
    ))
}

/// Play a faint ramp from the paused node, at mixer volume 0, and report how
/// soon its first frame was rendered and whether any cycle or frame was
/// missed. A tap on the player node records what the node rendered.
/// `duringPlay`, if given, runs half a second into the play, to show what a
/// change made while audio plays does to it.
func playAndCheck(_ label: String, duringPlay: (() -> Void)? = nil) {
    let frameCount = AVAudioFrameCount(44_100)
    guard let ramp = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let samples = ramp.floatChannelData?[0] else { return }
    ramp.frameLength = frameCount
    // Each frame holds its own index, scaled far below hearing.
    for frame in 0..<Int(frameCount) { samples[frame] = Float(frame + 1) * 1e-9 }

    final class Heard: @unchecked Sendable {
        var first: Date?
        var values: [Float] = []
        let lock = NSLock()
    }
    let heard = Heard()
    player.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
        guard let data = buffer.floatChannelData?[0] else { return }
        heard.lock.lock()
        for frame in 0..<Int(buffer.frameLength) where data[frame] != 0 {
            if heard.first == nil { heard.first = Date() }
            heard.values.append(data[frame])
        }
        heard.lock.unlock()
    }
    let cyclesBefore = cycleLog.pointee.cycles
    player.stop()
    // The node's own report that the buffer played back, apart from the tap.
    let playedBack = DispatchSemaphore(value: 0)
    player.scheduleBuffer(ramp, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
        playedBack.signal()
    }
    let asked = Date()
    player.play()
    Thread.sleep(forTimeInterval: 0.5)
    duringPlay?()
    Thread.sleep(forTimeInterval: 2.5)
    // How far the node itself says it played, in its own frames.
    let nodeFrames = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? -1
    let reportedPlayedBack = playedBack.wait(timeout: .now()) == .success
    player.pause()
    player.removeTap(onBus: 0)

    heard.lock.lock()
    let values = heard.values
    let first = heard.first
    heard.lock.unlock()
    // The ramp is whole when the frames heard are 1, 2, 3, ... with no gap.
    var gaps = 0
    for (index, value) in values.enumerated() where Int((value / 1e-9).rounded()) != index + 1 { gaps += 1 }
    // A missed cycle shows as a host-time step well over a cycle's length.
    var longestStep = 0.0
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let cyclesNow = cycleLog.pointee.cycles
    let count = min(cyclesNow - cyclesBefore, CycleLog.capacity - 1)
    if count > 1 {
        for cycle in (cyclesNow - count + 1)..<cyclesNow {
            let now = cycleLog.pointee.hostTimes[cycle % CycleLog.capacity]
            let before = cycleLog.pointee.hostTimes[(cycle - 1) % CycleLog.capacity]
            let step = Double(now &- before) * Double(info.numer) / Double(info.denom) / 1e9
            longestStep = max(longestStep, step)
        }
    }
    print(String(
        format: "%@: first frame rendered %.0f ms after play(), %d of %d frames seen, %d out of place, "
            + "node time %lld frames, played back reported %@, "
            + "longest step between cycles %.1f ms over %d cycles, engine running %@, configuration changes %d",
        label, (first?.timeIntervalSince(asked) ?? -1) * 1_000, values.count, Int(frameCount), gaps,
        Int64(nodeFrames), reportedPlayedBack ? "yes" : "no",
        longestStep * 1_000, count, engine.isRunning ? "yes" : "no", configurationChanges
    ))
}

DispatchQueue.global(qos: .userInitiated).async {
    let original = bufferFrames(of: outputUnit)
    measure("1 today, node paused")
    playAndCheck("1 today, play")

    // The power hint, set while the engine runs.
    var status = setPowerHint(.favorSavingPower)
    print("power hint Favor Saving Power: status \(status)")
    measure("2 power hint")
    status = setPowerHint(.none)
    print("power hint None: status \(status)")
    playAndCheck("2 power hint set back, play at once")
    measure("2 power hint set back")
    // The hint changed both ways while audio plays: what a second window
    // playing would hear when another window's long pause begins or ends.
    playAndCheck("2 power hint raised during a play") { _ = setPowerHint(.favorSavingPower) }
    playAndCheck("2 power hint set back during a play") { _ = setPowerHint(.none) }

    if CommandLine.arguments.contains("--buffer") {
        // This process's own I/O buffer, raised to 4,096 frames or the top
        // of the range if that is lower.
        let raised = UInt32(min(4_096, range.mMaximum))
        var began = Date()
        status = setBufferFrames(raised, of: outputUnit)
        print(String(format: "buffer %d frames: status %d, took %.1f ms", Int(raised), Int(status), Date().timeIntervalSince(began) * 1_000))
        measure("3 buffer raised")
        began = Date()
        status = setBufferFrames(original, of: outputUnit)
        print(String(format: "buffer %d frames: status %d, took %.1f ms", Int(original), Int(status), Date().timeIntervalSince(began) * 1_000))
        playAndCheck("4 set back, play at once")
        measure("4 set back, node paused")
    }

    engine.stop()
    NotificationCenter.default.removeObserver(observer)
    exit(0)
}
RunLoop.main.run()

// Result, November 15, 2026 (macOS 26.3, output on AirPods; run without
// state 3, so no device property was written):
//
//     output device: transport 'blue', 48000 Hz, buffer range 15-960 frames
//     1 today, node paused: 93.8 cycles/s, 512 frames a cycle, buffer here 512, in another process 512, idle wake-ups/s 0, CPU % 0.3
//     1 today, play: first frame rendered 181 ms after play(), 44100 of 44100 frames seen, 0 out of place, played back reported yes
//     2 power hint: 50.2 cycles/s, 957 frames a cycle, buffer here 960, in another process 512, idle wake-ups/s 0, CPU % 0.1
//     2 power hint set back, play at once: first frame rendered 213 ms after play(), 44100 of 44100 frames seen, 0 out of place, played back reported yes
//     2 power hint set back: 93.8 cycles/s, 512 frames a cycle, buffer here 512, in another process 512, CPU % 0.3
//     2 power hint raised during a play: 7484 of 44100 frames seen, node time 10856 frames, played back reported no
//     2 power hint set back during a play: 0 of 44100 frames seen, node time -1 frames, played back reported no
//     (engine running yes and configuration changes 0 on every line)
//
// What it shows:
// - A paused engine is called 93.8 times a second for silence, at 0.3% of a
//   core. `top` counts none of these as idle wake-ups.
// - The power hint works while the engine runs, with no configuration change:
//   50.2 cycles a second on AirPods, whose largest buffer is 960 frames, and
//   0.1% of a core. The other process went on reading 512 frames, so the
//   size is this process's alone.
// - Set back while the node is paused, a play started at once is whole: every
//   frame in order, no cycle missed.
// - Changed while a play runs, the hint stalls the player node: it stopped a
//   quarter of a second in, never reported its buffer played back, and the
//   next play, begun with the hint still raised, rendered nothing at all.
//   The hint is the whole process's, and TextMouth has other audio that may
//   be running when one book's pause grows long: another window's speech or
//   audiobook, Where Am I?, a recording, the audio editor. So the throttle
//   was not built (the report of November 15 has the rest).
