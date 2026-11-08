import Foundation
import SwiftSoup

// Measures how much stack SwiftSoup's parse of a deeply nested document touches, and then the release of the tree.
// usage: measure SHAPE N [xml]   SHAPE is one of the keys of `shapes` below, or recurse
// The run is on a thread with a 4 GiB stack (reserved, not touched); afterwards the pages of that stack that are resident are counted with mincore.

/// Bytes of the thread's stack that have been touched, counted as resident pages from the stack's low end up.
func touchedStack(top: UnsafeMutableRawPointer, size: Int) -> Int {
    let page = Int(getpagesize())
    let base = top - size
    let pages = size / page
    var vec = [CChar](repeating: 0, count: pages)
    guard mincore(base, size, &vec) == 0 else { return -1 }
    return vec.reduce(0) { $0 + (($1 & 1) != 0 ? 1 : 0) } * page
}

let args = CommandLine.arguments
let shape = args[1]
let n = Int(args[2])!
let xml = args.count > 3 && args[3] == "xml"
// Shape: the start tags, and the end tags that close them again at the end of the document.
let shapes: [String: (String, String)] = [
    "div": ("<div>", ""), "span": ("<span>", ""), "ul": ("<ul><li>", ""), "blockquote": ("<blockquote>", ""), "b": ("<b>", ""),
    "divclose": ("<div>", "</div>"), "spanclose": ("<span>", "</span>"), "attr": ("<div id=\"a\">", ""),
    "attrclose": ("<div id=\"a\">", "</div>"), "ol": ("<ol><li>", "</li></ol>"), "bq": ("<blockquote>", "</blockquote>"),
    "a": ("<a href=\"x\">", "</a>"), "table": ("<table><tr><td>", "</td></tr></table>"),
]
let (open, close) = shapes[shape] ?? ("<div>", "")
let stackSize = 4 << 30
/// A calibration: recursion with a frame of known size, to check that the pages counted are the stack used (`recurse N`).
@inline(never) func recurse(_ n: Int) -> Int { if n == 0 { return 0 }; var pad = (0, 0, 0, 0, 0, 0, 0, 0); withUnsafeMutablePointer(to: &pad) { $0.pointee.0 = n }; return recurse(n - 1) + pad.0 }

/// What the thread runs, held in a class so that its address can pass through the C interface of pthread_create.
final class Job { var run: () -> Void = {} }
let job = Job()
job.run = {
    let top = pthread_get_stackaddr_np(pthread_self())
    let before = touchedStack(top: top, size: stackSize)
    let html = (xml ? "<?xml version=\"1.0\"?><r>" : "<html><body>") + String(repeating: open, count: n) + "x" + String(repeating: close, count: n)
    if shape == "recurse" { let r = recurse(n); print("recursed", r, touchedStack(top: top, size: stackSize) - before); return }
    let t0 = Date()
    var doc: Document? = nil
    do { doc = try (xml ? SwiftSoup.parse(html, "", Parser.xmlParser()) : SwiftSoup.parse(html)) } catch { print("parse error \(error)") }
    let hadDoc = doc != nil
    var deepest = 0
    if let d = doc { var p: [(Node, Int)] = [(d, 0)]; while let (nd, k) = p.popLast() { deepest = max(deepest, k); for c in nd.getChildNodes() where c is Element { p.append((c, k + 1)) } } }
    let t1 = Date()
    let afterParse = touchedStack(top: top, size: stackSize)
    doc = nil
    let t2 = Date()
    let afterRelease = touchedStack(top: top, size: stackSize)
    let perLevelParse = Double(afterParse - before) / Double(n)
    let perLevelRelease = Double(max(0, afterRelease - afterParse)) / Double(n)
    print("\(shape)\(xml ? " xml" : "") N=\(n): parse touched \(afterParse - before) B (\(String(format: "%.0f", perLevelParse)) B/level, \(String(format: "%.2f", t1.timeIntervalSince(t0)))s); release added \(afterRelease - afterParse) B (\(String(format: "%.0f", perLevelRelease)) B/level, \(String(format: "%.2f", t2.timeIntervalSince(t1)))s); parsed=\(hadDoc) treeDepth=\(deepest)")
}

var attr = pthread_attr_t()
pthread_attr_init(&attr)
let setResult = pthread_attr_setstacksize(&attr, stackSize)
var thread: pthread_t? = nil
let made = pthread_create(&thread, &attr, { context in
    let job = Unmanaged<Job>.fromOpaque(context).takeUnretainedValue()
    job.run()
    return nil
}, Unmanaged.passUnretained(job).toOpaque())
print("setstacksize=\(setResult) create=\(made)")
if made == 0, let thread { pthread_join(thread, nil) }
