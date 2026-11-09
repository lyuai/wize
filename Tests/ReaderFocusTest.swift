import AppKit
import WebKit
import Foundation
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
window.orderFront(nil)
final class LoadDelegate: NSObject, WKNavigationDelegate { var done = false; func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true } }
let delegate = LoadDelegate(); web.navigationDelegate = delegate
let html = """
<html><style>body{margin:0}section{height:400px}header{height:80px}</style><body><header>title</header><section data-wize-answer="old">old<img loading="lazy"></section><section data-wize-answer="old2">old2<img loading="lazy"></section><section data-wize-answer="old3">old3<img loading="lazy"></section></body></html>
"""
web.loadHTMLString(html, baseURL: nil)
let end = Date().addingTimeInterval(10)
while !delegate.done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
if !delegate.done { fatalError("load timeout") }
func evaluate(_ js: String) -> Any? {
 var done = false; var output: Any?; var failure: Error?
 web.evaluateJavaScript(js) { result, error in output = result; failure = error; done = true }
 let deadline = Date().addingTimeInterval(5)
 while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
 if let failure { fatalError("JS: \(failure)") }; if !done { fatalError("JS timeout") }; return output
}
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let marker = "let script = \"(() => { const answers = Array.from"
let line = source.components(separatedBy: "\n").first { $0.contains(marker) }!
let script = String(line.trimmingCharacters(in: .whitespaces).dropFirst("let script = \"".count).dropLast())
func current() -> String? { (evaluate(script) as? [String: Any])?["id"] as? String }
_ = evaluate("window.scrollTo(0, 100)")
precondition(current() == "old", "The first answer should own actions while the reading focus is within it")
precondition((evaluate("document.querySelector('section.current')?.getAttribute('data-wize-answer')") as? String) == "old", "The reading focus should mark the current answer")
let loading = evaluate("Array.from(document.querySelectorAll('img')).map(i => i.loading).join(',')") as? String
precondition(loading == "eager,eager,lazy", "Only the current and next answer should have their images prepared")
_ = evaluate("window.scrollTo(0, 440)")
precondition(current() == "old2", "A small remnant at the top should not own actions when the reading focus is in the next answer")
precondition((evaluate("document.querySelectorAll('section.current').length") as? NSNumber)?.intValue == 1, "Only one answer should be marked current")
precondition((evaluate("document.querySelector('section.current')?.getAttribute('data-wize-answer')") as? String) == "old2", "The current mark should follow the reading focus")
_ = evaluate("window.scrollTo(0, 320)")
precondition(current() == "old", "Scrolling back should restore the previous answer")

if let initStart = source.range(of: "let initialPositionScript = WKUserScript("),
   let firstTripleQuote = source.range(of: "\"\"\"\n", range: initStart.upperBound..<source.endIndex),
   let secondTripleQuote = source.range(of: "\n            \"\"\"", range: firstTripleQuote.upperBound..<source.endIndex) {
    let initScript = String(source[firstTripleQuote.upperBound..<secondTripleQuote.lowerBound])
    _ = evaluate("window.scrollTo(0, 0); document.body.setAttribute('data-wize-anchor', 'old2'); document.body.setAttribute('data-wize-pending', '1'); document.querySelectorAll('img').forEach(i => i.loading = 'lazy');")
    _ = evaluate(initScript)
    let pendingRemoved = evaluate("!document.body.hasAttribute('data-wize-pending')") as? Bool
    precondition(pendingRemoved == true, "Initial position script must clear data-wize-pending before first paint")
    precondition(current() == "old2", "Initial position script must scroll directly to the anchor answer before revealing body")
    let activeID = evaluate("document.querySelector('section.current')?.getAttribute('data-wize-answer')") as? String
    precondition(activeID == "old2", "Initial position script must mark the anchor answer as current")
} else {
    fatalError("Missing initialPositionScript in ReaderView.swift")
}

print("PASS: action target follows the reading focus across answer boundaries")
