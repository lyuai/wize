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
    var votes: [String: AnswerVote] = [:]
    var detailDelay: UInt64 = 0
    var anchorPage: Int?
    var answerRequests = 0
    init() {
        func item(_ id: String) -> ReadingItem {
            ReadingItem(id: id, kind: .answer, title: "问题", excerpt: "", author: id, questionID: "q", contentHTML: "<p>\(id)</p>")
        }
        first = item("first"); middle = item("middle"); last = item("last")
    }
    func feed(hot: Bool, next: URL?) async throws -> Page<ReadingItem> { Page(items: [], next: nil) }
    func currentUser() async throws -> (name: String, avatar: URL?, headline: String?) { ("读者", nil, "爱阅读") }
    func answers(questionID: String, sort: String, offset: Int) async throws -> Page<ReadingItem> {
        answerRequests += 1
        if let anchorPage {
            let item = offset == anchorPage ? middle : ReadingItem(id: "page-\(offset)", kind: .answer, title: "问题", excerpt: "", author: "", questionID: "q", contentHTML: "<p>回答</p>")
            return Page(items: [item], next: offset < anchorPage ? URL(string: "https://example.invalid/next") : nil)
        }
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
    func detail(_ item: ReadingItem, prefetch: Bool) async throws -> ReadingItem {
        var result = item
        result.vote = votes[item.id] ?? .neutral
        if detailDelay > 0 { try await Task.sleep(nanoseconds: detailDelay) }
        return result
    }
    func setVote(answerID: String, vote: AnswerVote) async throws -> AnswerVoteResult {
        votes[answerID] = vote
        return AnswerVoteResult(vote: vote, upCount: nil, downCount: nil)
    }
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
        let seekingSource = FixtureSource()
        seekingSource.anchorPage = 7
        let seekingModel = ReaderModel(source: seekingSource)
        seekingModel.selectAnswer(seekingSource.middle)
        await waitFor { seekingSource.answerRequests >= 5 && !seekingModel.streamLoading && seekingModel.streamHasMore }
        precondition(seekingModel.streamError == nil, "A normal search past the first batch must not display an error")
        await seekingModel.loadMoreStream()
        precondition(seekingModel.streamError == nil && seekingModel.streamItems.contains(where: { $0.id == "page-0" }), "A later batch must continue locating the answer")
        precondition(answerVote(from: ["voting": 1]) == .up)
        precondition(answerVote(from: ["relationship": ["voting": 1]]) == .up)
        precondition(answerVote(from: ["relationship": ["voting": 0]]) == .neutral)
        precondition(answerVote(from: ["voting": 99]) == nil)
        let voteSource = FixtureSource()
        voteSource.votes["middle"] = .up
        let voteModel = ReaderModel(source: voteSource)
        voteModel.question = ReadingItem(id: "q", kind: .question, title: "问题", excerpt: "", author: "", questionID: nil)
        await voteModel.loadAnswers()
        voteModel.selectAnswer(voteSource.middle)
        await waitFor { voteModel.streamItems.count == 3 && voteModel.selected?.vote == .up }
        await voteModel.toggleVote(.up)
        precondition(voteSource.votes["middle"] == .neutral && voteModel.selected?.vote == .neutral)
        precondition(voteModel.answers.first(where: { $0.id == "middle" })?.vote == .neutral)
        await voteModel.toggleVote(.up)
        precondition(voteModel.streamItems.first(where: { $0.id == "middle" })?.vote == .up)
        voteModel.leaveReading()
        voteModel.selectAnswer(voteSource.middle)
        await waitFor { voteModel.selected?.vote == .up }
        voteModel.setVisibleAnswer("first")
        voteSource.detailDelay = 100_000_000
        voteModel.setVisibleAnswer("middle")
        try? await Task.sleep(nanoseconds: 10_000_000)
        await voteModel.toggleVote(.up)
        try? await Task.sleep(nanoseconds: 150_000_000)
        precondition(voteModel.selected?.vote == .neutral, "An older detail response must not undo a confirmed vote")
        let source = FixtureSource()
        let model = ReaderModel(source: source)
        model.question = ReadingItem(id: "q", kind: .question, title: "问题", excerpt: "", author: "", questionID: nil)
        await model.loadAnswers()
        model.selectAnswer(source.middle)
        precondition(model.selected?.id == "middle", "selectAnswer must set selected synchronously")
        precondition(model.bodyHTML == "<p>middle</p>" && model.streamError == nil, "Selecting an answer with inline contentHTML must never flash bodyHTML = nil")
        precondition(model.streamItems.map(\.id) == ["first", "middle", "last"], "Selecting an answer from a loaded question must populate streamItems synchronously on the first frame")
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

        // Verify on-demand open-license fonts and ReadingFontManager lifecycle
        let downloadableOptions = ReadingFontOption.all.filter { !$0.isBuiltIn }
        precondition(downloadableOptions.count >= 4, "Should offer multiple downloadable fonts")
        precondition(downloadableOptions.contains(where: { $0.id == "lxgw-neo-zhisong" && $0.title.contains("宋") }), "Should offer LXGW Neo ZhiSong (宋体)")
        precondition(downloadableOptions.contains(where: { $0.id == "source-han-serif" && $0.title.contains("宋") }), "Should offer Source Han Serif (思源宋体)")
        for option in downloadableOptions {
            precondition(option.license == "SIL Open Font License 1.1", "All downloadable fonts must use a copyright-free open license")
            precondition(!option.urls.isEmpty && !option.fileName.isEmpty, "Downloadable font must specify source URLs and fileName")
        }

        let tempFontDir = FileManager.default.temporaryDirectory.appendingPathComponent("wize-font-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFontDir) }
        var validTTF = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00])
        validTTF.append(contentsOf: Array(repeating: UInt8(0x41), count: 64))
        var observedProgress: [Double] = []
        let targetFont = ReadingFontOption.option(for: "lxgw-neo-zhisong")
        let fontManager = ReadingFontManager(directory: tempFontDir) { _, reportProgress in
            reportProgress(0.35)
            reportProgress(0.85)
            try await Task.sleep(nanoseconds: 10_000_000)
            return validTTF
        }
        precondition(fontManager.state(for: ReadingFontOption.option(for: "system")) == .builtIn, "Built-in font must report .builtIn")
        precondition(fontManager.state(for: targetFont) == .notDownloaded, "Downloadable font must start as .notDownloaded")
        var selectedCallbackID: String?
        fontManager.download(targetFont) { id in selectedCallbackID = id }
        if case .downloading(let initialProgress) = fontManager.state(for: targetFont) {
            observedProgress.append(initialProgress)
        }
        await waitFor { fontManager.state(for: targetFont) == .downloaded }
        precondition(!observedProgress.isEmpty, "Font download must enter .downloading state immediately")
        precondition(selectedCallbackID == targetFont.id, "Completing download must invoke selection callback")
        precondition(FileManager.default.fileExists(atPath: fontManager.fontFileURL(for: targetFont).path), "Font file must be saved on disk")
        guard let css = fontManager.fontFaceCSS[targetFont.id] else {
            fatalError("Downloaded font must generate @font-face CSS")
        }
        precondition(css.contains("@font-face") && css.contains(targetFont.webFontFamilyName), "Generated CSS must define @font-face for the font's web family")

        // Re-initializing manager against same directory must restore downloaded state and cached CSS synchronously
        let restoredManager = ReadingFontManager(directory: tempFontDir)
        precondition(restoredManager.state(for: targetFont) == .downloaded, "Restored manager must detect downloaded font on disk")
        precondition(restoredManager.fontFaceCSS[targetFont.id] == css, "Restored manager must load cached @font-face CSS synchronously")

        // Removing font must delete files and reset state
        fontManager.removeFont(targetFont)
        precondition(fontManager.state(for: targetFont) == .notDownloaded, "Removed font must return to .notDownloaded")
        precondition(fontManager.fontFaceCSS[targetFont.id] == nil, "Removed font must clear cached CSS")
        precondition(!FileManager.default.fileExists(atPath: fontManager.fontFileURL(for: targetFont).path), "Removed font file must be deleted from disk")

        // Invalid font payload must fail cleanly
        let failingManager = ReadingFontManager(directory: tempFontDir) { _, _ in
            Data("<html>not a font</html>".utf8)
        }
        failingManager.download(targetFont)
        await waitFor {
            if case .failed = failingManager.state(for: targetFont) { return true }
            return false
        }
        precondition(!FileManager.default.fileExists(atPath: failingManager.fontFileURL(for: targetFont).path), "Invalid font data must not be persisted")

        print("PASS: sorting, current answer, comment ownership, stale responses and on-demand fonts")
    }
}
