import Foundation

@main
struct ReaderLinkTest {
    static func main() throws {
        let source = """
        <p>前文 <a href="https://www.zhihu.com/question/1">一个普通链接</a> 后文</p>
        <p><a href="https://pic1.zhimg.com/v2-abc_1440w.jpg" target="_blank"><img src="//pic1.zhimg.com/v2-abc_720w.jpg" data-actualsrc="https://pic1.zhimg.com/v2-abc_1440w.jpg" data-rawwidth="800" data-rawheight="600"></a></p>
        <img src="https://pic2.zhimg.com/v2-def.png" data-rawwidth="400" data-rawheight="300">
        """

        let output = expandedImageHTML(source)

        precondition(!output.contains("target=\"_blank\""), "image taps should stay inside the reader")
        precondition(!output.contains("<a href=\"https://pic1.zhimg.com/v2-abc_1440w.jpg\"><img"),
                     "image links should be unwrapped so the preview gesture owns the tap")
        precondition(output.contains("src=\"https://pic1.zhimg.com/v2-abc_1440w.jpg\""),
                     "the original lazy-load source should replace the thumbnail")
        precondition(output.contains("width=\"800\" height=\"600\""),
                     "raw dimensions should avoid layout shifts")
        precondition(output.contains("<a href=\"https://www.zhihu.com/question/1\">"),
                     "ordinary text links should stay untouched")
        precondition(output.components(separatedBy: "<img").count == 3,
                     "both images should remain in place")

        if let readerPath = CommandLine.arguments.dropFirst().first {
            let reader = try String(contentsOfFile: readerPath, encoding: .utf8)
            precondition(reader.contains("--wize-link"), "links should use the reader accent")
            precondition(reader.contains("text-decoration-color: color-mix"),
                         "link underlines should be quiet and theme-aware")
            precondition(reader.contains("a:visited"), "visited links should keep the reading palette")
        }

        print("PASS: image links, original sources and reader link styling")
    }
}
