import Foundation

@main
struct CommentFragmentsTest {
    static func main() {
        let html = #"<p>前文<img src="https://example.com/pic.gif">中间<img data-original="https://example.com/pic.gif" src="https://example.com/thumb.jpg">后文</p>"#
        let fragments = commentHTMLFragments(html)
        precondition(fragments.count == 5, "Repeated media and surrounding text must be kept")
        guard case .text(let first) = fragments[0], first.contains("前文"),
              case .image(let firstURL) = fragments[1], firstURL.absoluteString == "https://example.com/pic.gif",
              case .text(let middle) = fragments[2], middle.contains("中间"),
              case .image(let secondURL) = fragments[3], secondURL == firstURL,
              case .text(let last) = fragments[4], last.contains("后文") else {
            fatalError("Comment text and images must stay in source order")
        }
        guard case .text(let plain) = commentHTMLFragments("只有文字").first, plain == "只有文字" else {
            fatalError("Plain comments must remain readable")
        }
        let comments = parseReadingComments([["id": 1, "author": ["member": ["name": "甲"]], "content": "原评论", "child_comments": [["id": 2, "author": ["member": ["name": "乙"]], "reply_to_author": ["member": ["name": "甲"]], "content": "回复"]]]])
        precondition(comments.count == 2 && comments[1].replyTo == "甲" && comments[1].depth == 1, "Nested replies must retain their relationship")
        precondition(comments[1].parentID == "1", "Nested replies must retain their parent ID")
        precondition(commentTreeRows(comments, collapsed: []).map(\.depth) == [0, 1], "Tree must indent replies")
        precondition(commentTreeRows(comments, collapsed: ["1"]).map(\.id) == ["1"], "Collapsed branches must hide descendants")
        var orphan = comments[1]; orphan.parentID = "missing"
        precondition(commentTreeRows([orphan], collapsed: []).map(\.id) == ["2"], "An unavailable parent must not hide a comment")
        precondition(htmlImageSources(#"<img src="//pic.zhimg.com/example.jpg">"#) == ["https://pic.zhimg.com/example.jpg"], "Protocol-relative images should use HTTPS")
        let linked = commentHTMLFragments(#"前<a class="comment_img" href="https://pic.zhimg.com/example.jpg">查看图片</a>后<a href="https://example.com">普通链接</a>"#)
        precondition(linked.count == 3, "Image links should preserve surrounding text and ordinary links")
        guard case .image(let linkedURL) = linked[1], linkedURL.host == "pic.zhimg.com",
              case .text(let trailing) = linked[2], trailing.contains("普通链接") else { fatalError("Comment image links must render as media") }
        print("PASS: comment text, original GIFs and repeated images preserve their order")
    }
}
