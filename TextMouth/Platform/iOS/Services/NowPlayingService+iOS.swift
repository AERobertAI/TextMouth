// Phase 0 stand-in: on the Mac, NowPlayingService watches Core Audio's default
// output device and its device list, so that it notices AirPods leaving (placed
// in their case, a drained battery) and pauses before the system's spurious
// play/pause toggle can restart a paused book. iOS has no Core Audio device
// API, so here the service watches nothing: its device queries answer "no
// device" and its listeners are never installed. Phase 1 will take the same
// signal from the audio session's route-change notification.
//
// The two names below are Core Audio's own on the Mac (macOS-only types), and
// NowPlayingService names them in the properties and the initializer that tests
// and shared code use. Declaring them here, for iOS only, keeps those lines of
// the shared file exactly as the Mac compiles them.

import Foundation

/// The identifier Core Audio gives an output device: a 32-bit unsigned number
/// on the Mac, and the same number here so the shared declarations keep their
/// types. Nothing on iOS produces one yet.
typealias AudioDeviceID = UInt32

/// Stands in for Core Audio's block that reports a property change. iOS
/// installs no such listener, so the block is only ever held as nil.
typealias AudioObjectPropertyListenerBlock = () -> Void
