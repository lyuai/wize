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
let paragraphs = (0..<80).map { "<p>第\($0)段：阅读是缓慢的探索。不同的内容需要不同的空间和节奏。</p>" }.joined()
let html = "<html><style>body{font:17px -apple-system;line-height:1.8}p{margin:0 0 .7em}</style><body><section data-wize-answer='a'><main>\(paragraphs)</main></section></body></html>"
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
_ = evaluate("window.scrollTo(0, 800)")
_ = evaluate("window.testRange = document.caretRangeFromPoint(innerWidth * .5, Math.min(innerHeight * .35, 140)); window.testNode = document.querySelector('main'); true")
let initial = (evaluate("window.testRange.getBoundingClientRect().top") as? NSNumber)?.doubleValue ?? .nan
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let marker = "let script = \"(() => { const style = document.querySelector('style');"
let line = source.components(separatedBy: "\n").first { $0.contains(marker) }!
let extracted = String(line.trimmingCharacters(in: .whitespaces).dropFirst("let script = \"".count).dropLast())
let css = "body{font:23px -apple-system;line-height:1.65}p{margin:0 0 .5em}"
let encoded = String(data: try JSONEncoder().encode(css), encoding: .utf8)!
let actual = extracted.replacingOccurrences(of: "\\(encoded)", with: encoded).replacingOccurrences(of: "\\(preserveStylePosition)", with: "true")
guard (evaluate(actual) as? Bool) == true else { fatalError("style update failed") }
let after = (evaluate("window.testRange.getBoundingClientRect().top") as? NSNumber)?.doubleValue ?? .nan
let font = evaluate("getComputedStyle(document.body).fontSize") as? String
let retained = (evaluate("window.testNode === document.querySelector('main')") as? Bool) == true
print("before=\(initial), after=\(after), font=\(font ?? "nil"), same DOM=\(retained)")
if !initial.isFinite || !after.isFinite || abs(initial-after) > 2 || font != "23px" || !retained { fatalError("style change lost position or content") }
let preview = extracted.replacingOccurrences(of: "\\(encoded)", with: encoded).replacingOccurrences(of: "\\(preserveStylePosition)", with: "false")
guard (evaluate(preview) as? Bool) == true else { fatalError("preview style update failed") }
let previewOffset = (evaluate("window.scrollY") as? NSNumber)?.doubleValue ?? .nan
if previewOffset != 0 { fatalError("preview did not return to its opening text") }
print("PASS")
