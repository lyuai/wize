import Foundation

@main
struct VideoHTMLTest {
    static func main() {
        let html = """
        <p>前文</p>
        <a class="video-box" href="https://link.zhihu.com/?target=https%3A//www.zhihu.com/video/1965789251959526374" target="_blank" data-video-id="" data-video-playable="" data-name="" data-poster="https://picx.zhimg.com/v2-f08ce62b9adca0db656dc08963d71541_720w.jpg?source=ccfced1a" data-lens-id="1965789251959526374"><img class="thumbnail" src="https://picx.zhimg.com/v2-f08ce62b9adca0db656dc08963d71541_720w.jpg?source=ccfced1a"/><span class="content"><span class="title"></span><span class="url">https://www.zhihu.com/video/1965789251959526374</span></span></a>
        <p>后文 <a href="https://www.zhihu.com/question/1">普通链接</a></p>
        """

        let output = expandedVideoHTML(html)
        precondition(output.contains("class=\"wize-video\""), "video anchors should become cards")
        precondition(output.contains("data-wize-video=\"1965789251959526374\""), "lens id should be preserved")
        precondition(output.contains("data-wize-video-kind=\"lens\""), "video kind should be preserved")
        precondition(output.contains("data-wize-poster=\"https://picx.zhimg.com/v2-f08ce62b9adca0db656dc08963d71541_720w.jpg?source=ccfced1a\""),
                     "poster should be preserved")
        precondition(!output.contains("video-box"), "the original video link should be removed")
        precondition(output.contains("href=\"https://www.zhihu.com/question/1\""), "ordinary links should stay untouched")

        let direct = videoReference(fromHTMLTag: #"<a href="https://www.zhihu.com/zvideo/123">z</a>"#)
        precondition(direct == VideoReference(id: "123", kind: .zvideo), "zvideo links should resolve")
        let lens = videoReference(fromHTMLTag: #"<a href="https://lens.zhihu.com/api/v4/videos/456">l</a>"#)
        precondition(lens == VideoReference(id: "456", kind: .lens), "lens links should resolve")
        let redirected = videoReference(fromHTMLTag: #"<a href="https://link.zhihu.com/?target=https%3A//www.zhihu.com/video/789">v</a>"#)
        precondition(redirected == VideoReference(id: "789", kind: .lens), "redirected video links should resolve")

        let withImages = expandedImageHTML(output)
        precondition(withImages.contains("wize-video-poster"), "the poster should survive image normalization")
        precondition(withImages.contains("wize-video"), "the video card should survive image normalization")

        print("PASS: embedded video cards and references")
    }
}
