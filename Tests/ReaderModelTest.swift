import Foundation

@MainActor
final class FixtureSource: ReadingSource {
    let first: ReadingItem
    let middle: ReadingItem
    let last: ReadingItem
    var delays: [String: UInt64] = [:]
    var failingSort: String?
    var omitFirst = false
    var paged = false
    var commentRequests = 0
    var commentDelay: UInt64 = 0
    init() {
        func item(_ id: String) -> ReadingItem {
            ReadingItem(id: id, kind: .answer, title: "问题", excerpt: "", author: id, questionID: "q", contentHTML: "<p>\(id)</p>")
        }
        first = item("first"); middle = item("middle"); last = item("last")
    }
    func feed(hot: Bool, next: URL?) async throws -> Page<ReadingItem> { Page(items: [], next: nil) }
    func currentUser() async throws -> (name: String, avatar: URL?) { ("读者", nil) }
    func answers(questionID: String, sort: String, offset: Int) async throws -> Page<ReadingItem> {
        if let delay = delays[sort] { try await Task.sleep(nanoseconds: delay) }
        if failingSort == sort { throw SourceError.response(503) }
        let ordered = sort == "updated" ? [last, middle, first] : [first, middle, last]
        let available = omitFirst ? ordered.filter { $0.id != first.id } : ordered
        if paged {
            let items = Array(available.dropFirst(offset).prefix(2))
            return Page(items: items, next: offset + items.count < available.count ? URL(string: "https://example.invalid/next") : nil)
        }
        return Page(items: available, next: nil)
    }
    func detail(_ item: ReadingItem, prefetch: Bool) async throws -> ReadingItem { item }
    func setVote(answerID: String, vote: AnswerVote) async throws { }
    func comments(_ item: ReadingItem, next: URL?) async throws -> Page<ReadingComment> {
        commentRequests += 1
        if commentDelay > 0 { try await Task.sleep(nanoseconds: commentDelay) }
        return Page(items: [ReadingComment(id: "comment", author: item.id, html: "内容", likes: 0)], next: nil)
    }
    func replies(to comment: ReadingComment, next: URL?) async throws -> Page<ReadingComment> {
        var reply = ReadingComment(id: next == nil ? "reply1" : "reply2", author: "读者", html: "回复", likes: 0)
        reply.replyTo = comment.author; reply.depth = 1
        return Page(items: [reply], next: next == nil ? URL(string: "https://example.invalid/replies2") : nil)
    }
}

@main
struct ReaderModelTest {
    @MainActor static func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("Timed out waiting for reader state")
    }
    @MainActor static func main() async {
        let source = FixtureSource()
        let model = ReaderModel(source: source)
        model.question = ReadingItem(id: "q", kind: .question, title: "问题", excerpt: "", author: "", questionID: nil)
        await model.loadAnswers()
        model.selectAnswer(source.middle)
        await waitFor { model.streamItems.count == 3 && model.selected?.id == "middle" }
        precondition(model.streamItems.map(\.id) == ["first", "middle", "last"])

        model.answerSort = "updated"
        await model.loadAnswers()
        await waitFor { model.streamItems.map(\.id) == ["last", "middle", "first"] }
        precondition(model.selected?.id == "middle", "Changing sort should keep the selected answer")

        source.commentDelay = 40_000_000
        let prefetch = Task { await model.prefetchComments(source.middle) }
        try? await Task.sleep(nanoseconds: 5_000_000)
        model.showComments()
        model.setVisibleAnswer("first")
        await prefetch.value
        await waitFor { !model.loadingComments && !model.comments.isEmpty }
        precondition(model.commentTarget?.id == "middle" && model.comments.first?.author == "middle", "Comments must remain attached to the answer that opened them")
        precondition(source.commentRequests == 1, "Opening comments must reuse an in-flight prefetch")
        let comment = model.comments[0]
        await model.loadReplies(to: comment)
        await model.loadReplies(to: comment)
        precondition(model.commentReplies[comment.id]?.map(\.id) == ["reply1", "reply2"] && model.replyNext[comment.id] == nil, "Reply pages must preserve order and finish pagination")

        source.delays = ["default": 150_000_000, "updated": 10_000_000]
        model.answerSort = "default"
        let stale = Task { await model.loadAnswers() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        model.answerSort = "updated"
        let latest = Task { await model.loadAnswers() }
        await stale.value; await latest.value
        await waitFor { model.streamItems.map(\.id) == ["last", "middle", "first"] }
        precondition(model.answers.map(\.id) == ["last", "middle", "first"], "An older response must not replace the latest sort")
        source.delays = [:]
        source.failingSort = "default"
        model.answerSort = "default"
        await model.loadAnswers()
        precondition(model.answers.isEmpty && model.answerError != nil, "A failed sort must not show the previous ordering under the new selection")
        precondition(model.selected?.id == "first", "A failed sort must keep the current answer readable")
        source.failingSort = nil
        model.resetAfterLogin()
        await waitFor { model.streamItems.map(\.id) == ["first", "middle", "last"] }
        precondition(model.answers.map(\.id) == ["first", "middle", "last"], "Retry should restore the requested order")
        model.setVisibleAnswer("first")
        source.omitFirst = true
        model.answerSort = "updated"
        await model.loadAnswers()
        await waitFor { model.selected?.id == "last" && model.streamItems.map(\.id) == ["last", "middle"] }
        precondition(model.streamError == nil, "A current answer outside the first page must not strand the new ordering")
        let pagedSource = FixtureSource()
        pagedSource.paged = true
        let pagedModel = ReaderModel(source: pagedSource)
        pagedModel.question = model.question
        await pagedModel.loadAnswers()
        pagedModel.selectAnswer(pagedSource.first)
        await waitFor { pagedModel.streamItems.count == 2 }
        await pagedModel.loadMoreStream()
        precondition(pagedModel.answers.map(\.id) == ["first", "middle", "last"], "Reader pagination must update the answer directory")
        precondition(pagedModel.streamItems.map(\.id) == ["first", "middle", "last"] && !pagedModel.hasMoreAnswers, "Both views must finish on the same page")
        let concurrentSource = FixtureSource()
        concurrentSource.paged = true
        let concurrentModel = ReaderModel(source: concurrentSource)
        concurrentModel.question = model.question
        await concurrentModel.loadAnswers()
        concurrentModel.selectAnswer(concurrentSource.first)
        await waitFor { concurrentModel.streamItems.count == 2 }
        concurrentSource.delays = ["default": 30_000_000]
        async let directoryPage: Void = concurrentModel.loadAnswers(more: true)
        async let readerPage: Void = concurrentModel.loadMoreStream()
        _ = await (directoryPage, readerPage)
        precondition(concurrentModel.answers.map(\.id) == ["first", "middle", "last"], "Concurrent pagination must not duplicate directory entries")
        precondition(concurrentModel.streamItems.map(\.id) == ["first", "middle", "last"], "Concurrent pagination must not duplicate reader entries")
        print("PASS: sorting, current answer, comment ownership and stale responses")
    }
}
