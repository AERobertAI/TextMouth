// accessibility-client-probe.swift: can a process on this machine act as an accessibility client, and does that make a
// hosted AppKit window expose its controls?
//
// Usage: accessibility-client-probe
// Prints whether this process is trusted for accessibility (AXIsProcessTrusted), then opens a window with a slider and a
// stepper in a hosting view of its own, and prints how many accessibility children the hosting view returns and what the
// system-wide element answers, with and without this process having asked the accessibility server for its own windows.
// Nothing is clicked or typed. Compiled and run only by Scripts/agents/runner_ax_probe.py, which runs it under a time limit.
import AppKit
import ApplicationServices
import SwiftUI

/// The accessibility children of `view`, recursively, counted by role.
func roles(of element: Any, depth: Int = 0) -> [String] {
    guard depth < 12 else { return [] }
    var found: [String] = []
    if let node = element as? NSAccessibilityElementProtocol {
        _ = node
    }
    let object = element as AnyObject
    if let role = object.accessibilityRole?() { found.append(role.rawValue) }
    for child in (object.accessibilityChildren?() as? [Any]) ?? [] {
        found += roles(of: child, depth: depth + 1)
    }
    return found
}

// Unbuffered, so that what the program printed survives a stop by its time limit.
setvbuf(stdout, nil, _IONBF, 0)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")

struct Probe: View {
    @State var value = 0.5
    @State var number = 3
    var body: some View {
        VStack {
            Slider(value: $value)
            Stepper("Count", value: $number)
            Button("SwiftUI exposure probe") {}
        }.padding()
    }
}

let host = NSHostingView(rootView: Probe())
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = host
window.makeKeyAndOrderFront(nil)
RunLoop.current.run(until: Date().addingTimeInterval(1))

let before = roles(of: host)
print("hosting view's accessibility roles before any client request: \(before.count) \(Set(before).sorted())")

// Ask the accessibility server about this process's own windows, as a client would.
let own = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
var windows: CFTypeRef?
let status = AXUIElementCopyAttributeValue(own, kAXWindowsAttribute as CFString, &windows)
print("AXUIElementCopyAttributeValue(windows): status \(status.rawValue), \((windows as? [Any])?.count ?? -1) windows")
RunLoop.current.run(until: Date().addingTimeInterval(1))

let after = roles(of: host)
print("hosting view's accessibility roles after the request: \(after.count) \(Set(after).sorted())")
print("NSWorkspace.isVoiceOverEnabled: \(NSWorkspace.shared.isVoiceOverEnabled)")
