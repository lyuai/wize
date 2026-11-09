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
        let comments = parseReadingComments([["id": 1, "author": ["member": ["name": "甲"]], "content": "原评论", "child_comments": [
            ["id": 2, "author": ["member": ["name": "乙"]], "reply_to_author": ["member": ["name": "甲"]], "content": "回复"],
            ["id": 3, "author": ["member": ["name": "丙"]], "reply_to_author": ["member": ["name": "乙"]], "content": "二级回复"]
        ]]])
        precondition(comments.count == 3 && comments[1].replyTo == "甲" && comments[1].depth == 1, "Nested replies must retain their relationship")
        precondition(comments[1].parentID == "1", "Nested replies must retain their parent ID")
        precondition(comments[2].parentID == "2" && comments[2].depth == 2, "Replies to an earlier sibling by reply_to_author must nest under that sibling")
        precondition(commentTreeRows(comments, collapsed: []).map(\.depth) == [0, 1, 2], "Tree must indent nested replies")
        precondition(commentTreeRows(comments, collapsed: ["1"]).map(\.id) == ["1"], "Collapsed branches must hide descendants")
        precondition(commentTreeRows(comments, collapsed: ["2"]).map(\.id) == ["1", "2"], "A nested collapse must preserve its parent")
        var orphan = comments[1]; orphan.parentID = "missing"
        precondition(commentTreeRows([orphan], collapsed: []).map(\.id) == ["2"], "An unavailable parent must not hide a comment")
        precondition(htmlImageSources(#"<img src="//pic.zhimg.com/example.jpg">"#) == ["https://pic.zhimg.com/example.jpg"], "Protocol-relative images should use HTTPS")
        let linked = commentHTMLFragments(#"前<a class="comment_img" href="https://pic.zhimg.com/example.jpg">查看图片</a>后<a href="https://example.com">普通链接</a>"#)
        precondition(linked.count == 3, "Image links should preserve surrounding text and ordinary links")
        guard case .image(let linkedURL) = linked[1], linkedURL.host == "pic.zhimg.com",
              case .text(let trailing) = linked[2], trailing.contains("普通链接") else { fatalError("Comment image links must render as media") }
        let emoji = commentTextFragments("谢谢[感谢]，真的[捂脸][未知]。")
        precondition(emoji.count == 5, "Known emoji should be inline while unknown markers stay as text")
        guard case .text("谢谢") = emoji[0], case .emoji("[感谢]", _) = emoji[1],
              case .text("，真的") = emoji[2], case .emoji("[捂脸]", let facepalmURL) = emoji[3],
              case .text("[未知]。") = emoji[4] else { fatalError("Emoji and text must preserve their original order") }
        precondition(facepalmURL.host?.hasSuffix("zhimg.com") == true, "Primary emoji URLs should use Zhihu CDN for low-latency loading")
        precondition(CommentEmoji.fallbackURL(for: facepalmURL) != nil, "Emoji URLs should resolve to their fallback mirror when needed")
        let stickerImg = expandedImageHTML(#"<img class="sticker" src="https://pic1.zhimg.com/v2-sticker.png" alt="[惊喜]">"#)
        precondition(!stickerImg.contains("[惊喜]"), "Sticker images must not expose bracketed alt text while loading")

        let sizedImg = expandedImageHTML(#"<img src="https://pic.zhimg.com/thumb.jpg" data-original="https://pic.zhimg.com/raw.jpg" data-rawwidth="1200" data-rawheight="800">"#)
        precondition(sizedImg.contains(#"src="https://pic.zhimg.com/raw.jpg""#), "expandedImageHTML should promote data-original to src")
        precondition(sizedImg.contains(#"width="1200" height="800""#), "expandedImageHTML should preserve raw dimensions to prevent image load layout shifts")
        precondition(sizedImg.contains(#"loading="lazy" decoding="async""#), "expandedImageHTML should add lazy loading and async decoding")

        if let readerViewSource = try? String(contentsOfFile: "Wize/ReaderView.swift", encoding: .utf8),
           let commentStart = readerViewSource.range(of: "private var commentList: some View"),
           let commentEnd = readerViewSource.range(of: "private func retryRow", range: commentStart.lowerBound..<readerViewSource.endIndex) {
            let visibleCommentLines = readerViewSource[commentStart.lowerBound..<commentEnd.lowerBound]
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(".accessibilityLabel(") }
                .joined(separator: "\n")
            let forbiddenLabels = [
                #"Text("回复")"#,
                "展开讨论",
                "收起讨论",
                "条回复",
                "加载更多回复",
                "加载更多评论",
                "暂无评论",
                "这里还没有讨论",
                #"navigationTitle("评论"#
            ]
            for label in forbiddenLabels {
                precondition(!visibleCommentLines.contains(label), "Comment view must not contain visible UI text label: \(label)")
            }
            precondition(visibleCommentLines.contains(#"compactCount("bubble.right""#), "Comment view should use icon + number for comment and reply counts")
            precondition(visibleCommentLines.contains(#"Image(systemName: "arrowtriangle.right.fill")"#), "Reply target should use an icon instead of text label")
            precondition(!visibleCommentLines.contains("Circle().fill("), "Empty comment state should stay minimal without decorative circles")
            precondition(visibleCommentLines.contains("startsAtAvatar ? topPadding + 26 : 0"), "Parent comment thread line should start right beneath the replied-to avatar")
            precondition(visibleCommentLines.contains("LoadingSkeleton(kind: .comment"), "Initial comment loading should display comment skeletons")
            precondition(visibleCommentLines.contains("CommentAuthorBadge()"), "Comments by the answer author should display an author badge")
            precondition(!readerViewSource.contains("mappin.and.ellipse"), "RegionBadge should use clean inverted teardrop icon instead of pushpin SF Symbol")
            precondition(readerViewSource.contains("TeardropPinShape()"), "RegionBadge should render TeardropPinShape")
        }

        let withIP = parseReadingComments([[
            "id": 9,
            "author": ["name": "甲", "role": "author"],
            "content": "来自浙江的评论",
            "comment_tag": [["type": "ip_info", "text": "IP 属地浙江"], ["type": "author", "text": "作者"]]
        ]])
        precondition(withIP.first?.ipInfo == "浙江", "Comment IP location should strip 'IP 属地' prefix and keep only region name")
        precondition(withIP.first?.isAuthor == true, "Comment author role should be parsed from author/comment_tag")
        precondition(normalizedIPRegion("IP 属地浙江") == "浙江", "normalizedIPRegion should strip 'IP 属地'")
        precondition(normalizedIPRegion("IP属地：广东") == "广东", "normalizedIPRegion should strip 'IP属地：'")
        precondition(normalizedIPRegion("发布于 IP 属地上海") == "上海", "normalizedIPRegion should strip compound prefixes")
        precondition(normalizedIPRegion("IP 属地") == nil, "normalizedIPRegion should return nil when region is empty")
        precondition(normalizedIPRegion("IP 属地未知") == nil, "normalizedIPRegion should return nil when region is unknown")

        let inlineSegments = commentInlineSegments(#"参考 <a href="https://link.zhihu.com/?target=https%3A//example.com/doc">文档链接</a> 谢谢[感谢]"#)
        precondition(inlineSegments.count == 4, "Comment inline segments should split text, links, and emojis")
        guard case .text("参考 ") = inlineSegments[0],
              case .link("文档链接", let docURL) = inlineSegments[1],
              docURL.absoluteString == "https://example.com/doc",
              case .text(" 谢谢") = inlineSegments[2],
              case .emoji("[感谢]", _) = inlineSegments[3] else {
            fatalError("Comment inline segments must unwrap Zhihu redirect links and keep inline emojis")
        }

        print("PASS: comment text, original GIFs, repeated images, raw image dimensions and pure icon-based comment UI")
    }
}
