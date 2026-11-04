#if DEBUG
import Foundation

// Explicitly enabled only for development builds with WIZE_VISUAL_FIXTURE=1.
@MainActor
final class ReadingFixtureSource: ReadingSource {
    private let question = ReadingItem(id: "sample-question", kind: .question, title: "排版样本｜从一座城市里的旧书店，能读到什么？", excerpt: "", author: "", questionID: nil)
    private var samples: [ReadingItem] {
        let long = """
        <p>我喜欢旧书店，并不是因为每一本书都稀有。真正有意思的，是你永远不知道下一页会遇到什么。</p>
        <p>有人在扉页写下日期，有人留下车票，也有人用一条细细的线，标出他觉得重要的句子。这些痕迹让阅读多了一点偶遇的意味。</p>
        <blockquote>一本书被许多人读过，也就有了许多种生活。</blockquote>
        <p>在这样一个地方，时间似乎走得慢一些。你不必急着寻找答案，可以先把问题放在一边。</p>
        """
        let short = "<p>读到的也许不是答案，而是别人认真生活过的证据。</p>"
        let image = """
        <p>有时候，最值得停下来的不是文字，而是一幅偶然遇到的画面。</p>
        <figure><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 250" role="img" aria-label="书桌与窗外的风景" style="width:100%;height:auto;border-radius:5px"><rect width="600" height="250" fill="#dce3d6"/><rect x="55" y="30" width="250" height="150" rx="6" fill="#f8f5ea"/><path d="M55 145 Q130 70 205 135 T305 120 V180 H55Z" fill="#9dac95"/><rect x="325" y="145" width="170" height="26" rx="3" fill="#ad8f71"/><rect x="355" y="110" width="90" height="35" rx="3" fill="#536c5c"/></svg><figcaption>一处安静的阅读角落</figcaption></figure>
        <p>把注意力交给眼前的内容，也给思考留一点余地。</p>
        """
        func answer(_ id: String, _ author: String, _ html: String, _ excerpt: String, _ votes: Int, _ comments: Int) -> ReadingItem {
            ReadingItem(id: id, kind: .answer, title: question.title, excerpt: excerpt, author: author, questionID: question.id, contentHTML: html, upCount: votes, commentCount: comments)
        }
        return [answer("sample-long", "林间来信", long, "那些被读过的书，留下了许多人的生活痕迹。", 1286, 42),
                answer("sample-short", "未完成的旅人", short, "读到的是别人认真生活过的证据。", 286, 8),
                answer("sample-image", "晚风", image, "一幅画面，有时会让人想多停留一会儿。", 78, 3)]
    }
    func feed(hot: Bool, next: URL?) async throws -> Page<ReadingItem> {
        let longerQuestion = ReadingItem(id: "sample-question-long", kind: .question,
            title: "排版样本｜当一条热榜标题很长，在手机上换行时应该如何保持舒展和清晰？",
            excerpt: "不同长度的文字应当自然排列，让标题与摘要都保留充足的阅读空间。", author: "不应显示的作者", questionID: nil)
        let shortQuestion = ReadingItem(id: "sample-question-short", kind: .question,
            title: "排版样本｜你最近读到了什么？", excerpt: "关于阅读的一点闲谈。", author: "", questionID: nil)
        return Page(items: hot ? [question, longerQuestion, shortQuestion] : [samples[0], question], next: nil)
    }
    func currentUser() async throws -> (name: String, avatar: URL?) { ("阅读者", nil) }
    func answers(questionID: String, sort: String, offset: Int) async throws -> Page<ReadingItem> {
        let ordered = sort == "updated" ? Array(samples.reversed()) : samples
        // Split the time ordering so the last answer is outside its first page.
        // This exercises sort changes and incremental reading without network access.
        if sort == "updated" {
            let items = Array(ordered.dropFirst(offset).prefix(2))
            let next = offset + items.count < ordered.count ? URL(string: "https://example.invalid/next") : nil
            return Page(items: items, next: next)
        }
        return Page(items: offset == 0 ? ordered : [], next: nil)
    }
    func detail(_ item: ReadingItem, prefetch: Bool) async throws -> ReadingItem { samples.first(where: { $0.id == item.id }) ?? item }
    func setVote(answerID: String, vote: AnswerVote) async throws { }
    func comments(_ item: ReadingItem, next: URL?) async throws -> Page<ReadingComment> {
        var comment = ReadingComment(id: "sample-comment", author: "一位读者", html: "<p>很喜欢这段话，读完想再慢慢想一会儿。</p>", likes: 12)
        comment.replyCount = 2
        return Page(items: [comment], next: nil)
    }
    func replies(to comment: ReadingComment, next: URL?) async throws -> Page<ReadingComment> {
        var reply = ReadingComment(id: next == nil ? "sample-reply-1" : "sample-reply-2", author: next == nil ? "另一位读者" : "路过的人", html: "<p>我也这样觉得。</p>", likes: 1)
        reply.depth = 1; reply.replyTo = comment.author; reply.parentID = comment.id
        return Page(items: [reply], next: next == nil ? URL(string: "https://example.invalid/replies") : nil)
    }
}
#endif
