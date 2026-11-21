import Foundation
import SwiftSoup

// Proof of the guard's big stack, run as a child process with limits.
// usage: proof MODE SHAPE N DIALECT   (compiled with MarkupGuard.swift, MarkupScanner.swift and MarkupNesting.swift by Scripts/test/markup-stack-proof.py)
//   MODE    guard (MarkupGuard with its first layer's depth limit lifted, called from a 512 KiB thread),
//           raw   (SwiftSoup alone, from a 512 KiB thread: shows the shape overflows without the big stack),
//           ok    (MarkupGuard with the standard limits on a shallow document, to show a tree that passes is returned)
//   SHAPE   div, divclose, list, listclose, quote, quoteclose, spanclose
//   DIALECT html or xml

let args = CommandLine.arguments
let mode = args[1]
let shape = args[2]
let n = Int(args[3]) ?? 0
let xml = args.count > 4 && args[4] == "xml"

/// The start and end tags a shape repeats.
func tags(of shape: String) -> (String, String) {
    switch shape {
    case "div": return ("<div>", "")
    case "divclose": return ("<div>", "</div>")
    case "list": return ("<ul><li>", "")
    case "listclose": return ("<ul><li>", "</li></ul>")
    case "quote": return ("<blockquote>", "")
    case "quoteclose": return ("<blockquote>", "</blockquote>")
    case "spanclose": return ("<span>", "</span>")
    default: return ("<div>", "")
    }
}

/// The document of n repeats of the shape.
func document() -> String {
    let (open, close) = tags(of: shape)
    let body = String(repeating: open, count: n) + "words" + String(repeating: close, count: n)
    return xml ? "<?xml version=\"1.0\"?><r>" + body + "</r>" : "<html><body>" + body + "</body></html>"
}

/// Runs the proof on a thread with a 512 KiB stack, as an import's worker has, and prints what happened.
func proof() {
    let markup = document()
    let start = Date()
    var outcome = ""
    switch mode {
    case "raw":
        // SwiftSoup alone: expected to overflow the 512 KiB stack in the deepest shapes.
        let tree = try? (xml ? SwiftSoup.parse(markup, "", Parser.xmlParser()) : SwiftSoup.parseHTML(markup, ""))
        outcome = tree == nil ? "parse threw" : "parsed"
    case "ok":
        do { let tree = try MarkupGuard.parse(markup); outcome = "parsed, returned a tree of \(tree.getChildNodes().count) top nodes" } catch { outcome = "threw \(error)" }
    default:
        // The guard with its first layer's depth limit lifted, as the existing tests lift it; every other limit stands.
        var limits = MarkupGuard.Limits.standard
        limits.deepestNesting = .max
        limits.deepestTree = 128
        do {
            let tree = try MarkupGuard.$limits.withValue(limits) { xml ? try MarkupGuard.parseXML(markup) : try MarkupGuard.parse(markup) }
            outcome = "NOT refused: returned a tree of \(tree.getChildNodes().count) top nodes"
        } catch let refusal as MarkupRefusal {
            outcome = refusal == .nestedTooDeeply(limit: 128) ? "refused by the second layer: nestedTooDeeply(128)" : "refused otherwise: \(refusal)"
        } catch {
            outcome = "error \(error)"
        }
    }
    let seconds = Date().timeIntervalSince(start)
    print("\(mode) \(shape) \(xml ? "xml" : "html") N=\(n): \(outcome) in \(String(format: "%.2f", seconds)) s")
}

/// What the thread runs, held in a class so that its address can pass through the C interface of pthread_create.
final class Job { let run: () -> Void; init(_ run: @escaping () -> Void) { self.run = run } }
let job = Job(proof)
var attributes = pthread_attr_t()
pthread_attr_init(&attributes)
pthread_attr_setstacksize(&attributes, 512 * 1024)
var thread: pthread_t?
let made = pthread_create(&thread, &attributes, { context in
    Unmanaged<Job>.fromOpaque(context).takeUnretainedValue().run()
    return nil
}, Unmanaged.passUnretained(job).toOpaque())
if made == 0, let thread { pthread_join(thread, nil) } else { print("no thread \(made)") }
