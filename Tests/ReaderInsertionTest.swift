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
<html><style>body{margin:0}section{height:400px}header{height:80px}</style><body><header>title</header><section data-wize-answer="old">old</section><section data-wize-answer="old2">old2</section></body></html>
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
_ = evaluate("window.scrollTo(0, 180)")
let initial = (evaluate("document.querySelector('section[data-wize-answer]').getBoundingClientRect().top") as? NSNumber)?.doubleValue ?? .nan
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let marker = "let script = \"(() => { const first = document.querySelector('section[data-wize-answer]');"
let line = source.components(separatedBy: "\n").first { $0.contains(marker) }!
let extracted = String(line.trimmingCharacters(in: .whitespaces).dropFirst("let script = \"".count).dropLast())
let payload = "{\"before\":\"<section data-wize-answer='before'>before</section>\",\"after\":\"<section data-wize-answer='after'>after</section>\"}"
let actual = extracted.replacingOccurrences(of: "\\(encoded)", with: payload)
guard (evaluate(actual) as? Bool) == true else { fatalError("insertion failed") }
let after = (evaluate("document.querySelector(\"section[data-wize-answer='old']\").getBoundingClientRect().top") as? NSNumber)?.doubleValue ?? .nan
let order = evaluate("Array.from(document.querySelectorAll('section')).map(e => e.getAttribute('data-wize-answer')).join(',')") as? String
print("before=\(initial), after=\(after), order=\(order ?? "nil")")
if abs(initial-after) > 1 || order != "before,old,old2,after" { fatalError("scroll or order mismatch") }
_ = evaluate("document.querySelector(\"section[data-wize-answer=\'before\']\").style.height = \"600px\"")
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
let afterResize = (evaluate("document.querySelector(\"section[data-wize-answer=\'old\']\").getBoundingClientRect().top") as? NSNumber)?.doubleValue ?? .nan
print("after earlier media resize=\(afterResize)")
if abs(initial-afterResize) > 1 { fatalError("earlier media shifted the reading position") }
print("PASS")
