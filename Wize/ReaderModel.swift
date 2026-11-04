import Foundation
import Combine

@MainActor
final class ReaderModel: ObservableObject {
    enum Channel: String, CaseIterable { case recommend = "推荐", hot = "热榜" }
    @Published var channel: Channel = .recommend
    @Published var feeds: [Channel: [ReadingItem]] = [:]
    @Published var feedError: String?
    @Published var loadingFeed = false
    @Published var refreshingFeed = false
    @Published var question: ReadingItem?
    @Published var answers: [ReadingItem] = []
    @Published var answerSort = "default"
    @Published var answerError: String?
    @Published var loadingAnswers = false
    @Published var hasMoreAnswers = false
    @Published var selected: ReadingItem?
    @Published var bodyHTML: String?
    struct ScrollRequest: Equatable { let id: String; let token = UUID() }
    @Published var streamAnchor: ReadingItem?
    @Published var scrollRequest: ScrollRequest?
    @Published var streamItems: [ReadingItem] = []
    @Published var streamLoading = false
    @Published var streamHasMore = false
    @Published var streamError: String?
    private var streamOffset = 0
    private var streamGeneration = 0
    private var streamSeekingAnchor = false
    private var streamLeadingItems: [ReadingItem] = []
    @Published private(set) var streamSearchExhausted = false
    @Published var bodyError: String?
    @Published var voting = false
    @Published var voteError: String?
    @Published var comments: [ReadingComment] = []
    @Published var commentReplies: [String: [ReadingComment]] = [:]
    @Published var replyErrors: [String: String] = [:]
    @Published var loadingReplies: Set<String> = []
    @Published var replyNext: [String: URL] = [:]
    @Published private(set) var commentTarget: ReadingItem?
    @Published var commentError: String?
    @Published var loadingComments = false
    @Published var showsComments = false
    @Published var showsLogin = false
    @Published var accountName: String?
    @Published var accountAvatarURL: URL?
    private let source: any ReadingSource
    init() { self.source = ZhihuSource() }
    init(source: any ReadingSource) { self.source = source }
    private var feedNext: [Channel: URL] = [:]
    private var commentsNext: URL?
    private var feedGeneration = 0
    private var bodyGeneration = 0
    private var answerGeneration = 0
    private var commentsGeneration = 0
    private struct CachedDetail {
        let item: ReadingItem
        let date: Date
    }
    private var detailCache: [String: CachedDetail] = [:]
    private var detailTasks: [String: (id: UUID, task: Task<ReadingItem, Error>)] = [:]
    private var prefetchingKeys: Set<String> = []
    private var detailCacheGeneration = 0
    private struct CachedComments { let page: Page<ReadingComment>; let date: Date }
    private var commentCache: [String: CachedComments] = [:]
    private var commentTasks: [String: (id: UUID, task: Task<Page<ReadingComment>, Error>)] = [:]

    // Keep speculative work small and short-lived; explicit reads share an in-flight request.
    func prefetchDetail(_ item: ReadingItem) async {
        guard item.kind != .question, cachedDetail(for: item.key) == nil,
              detailTasks[item.key] == nil, prefetchingKeys.count < 2 else { return }
        let generation = detailCacheGeneration
        prefetchingKeys.insert(item.key)
        defer { if generation == detailCacheGeneration { prefetchingKeys.remove(item.key) } }
        _ = try? await detail(for: item, prefetch: true)
    }

    private func cachedDetail(for key: String) -> ReadingItem? {
        guard let cached = detailCache[key] else { return nil }
        guard Date().timeIntervalSince(cached.date) < 120 else {
            detailCache.removeValue(forKey: key)
            return nil
        }
        return cached.item
    }

    private func detail(for item: ReadingItem, prefetch: Bool = false) async throws -> ReadingItem {
        if let cached = cachedDetail(for: item.key) { return cached }
        if let pending = detailTasks[item.key] {
            do { return try await pending.task.value }
            catch {
                // A speculative request may be disallowed on constrained networks.
                // A user's explicit selection still deserves a normal attempt.
                if prefetch { throw error }
            }
        }
        let generation = detailCacheGeneration
        let taskID = UUID()
        let task = Task { try await source.detail(item, prefetch: prefetch) }
        detailTasks[item.key] = (taskID, task)
        do {
            let result = try await task.value
            if generation == detailCacheGeneration {
                if detailTasks[item.key]?.id == taskID { detailTasks[item.key] = nil }
                if (result.contentHTML?.utf8.count ?? 0) <= 1_000_000 {
                    detailCache[item.key] = CachedDetail(item: result, date: Date())
                    if detailCache.count > 8, let oldest = detailCache.min(by: { $0.value.date < $1.value.date })?.key {
                        detailCache.removeValue(forKey: oldest)
                    }
                }
            }
            return result
        } catch {
            if generation == detailCacheGeneration, detailTasks[item.key]?.id == taskID { detailTasks[item.key] = nil }
            throw error
        }
    }

    private func clearDetailCache() {
        detailCacheGeneration += 1
        detailTasks.values.forEach { $0.task.cancel() }
        detailTasks.removeAll()
        detailCache.removeAll()
        prefetchingKeys.removeAll()
        commentTasks.values.forEach { $0.task.cancel() }
        commentTasks.removeAll()
        commentCache.removeAll()
    }

    func prefetchComments(_ item: ReadingItem) async {
        guard item.commentCount != 0, commentTasks.count < 2 else { return }
        _ = try? await firstComments(for: item)
    }

    private func firstComments(for item: ReadingItem) async throws -> Page<ReadingComment> {
        if let cached = commentCache[item.key], Date().timeIntervalSince(cached.date) < 60 { return cached.page }
        if let pending = commentTasks[item.key] { return try await pending.task.value }
        let generation = detailCacheGeneration
        let id = UUID()
        let task = Task { try await source.comments(item, next: nil) }
        commentTasks[item.key] = (id, task)
        do {
            let page = try await task.value
            if generation == detailCacheGeneration {
                if commentTasks[item.key]?.id == id { commentTasks[item.key] = nil }
                commentCache[item.key] = CachedComments(page: page, date: Date())
                if commentCache.count > 4, let oldest = commentCache.min(by: { $0.value.date < $1.value.date })?.key { commentCache.removeValue(forKey: oldest) }
            }
            return page
        } catch {
            if commentTasks[item.key]?.id == id { commentTasks[item.key] = nil }
            throw error
        }
    }

    func loadFeed(reset: Bool = false) async {
        guard !loadingFeed || reset else { return }
        let current = channel
        let next = reset ? nil : feedNext[current]
        if !reset && feeds[current] != nil && next == nil { return }
        feedGeneration += 1
        let generation = feedGeneration
        loadingFeed = true; refreshingFeed = reset; feedError = nil
        defer { if generation == feedGeneration { loadingFeed = false; refreshingFeed = false } }
        do {
            let page = try await source.feed(hot: current == .hot, next: next)
            guard generation == feedGeneration else { return }
            let existing = reset ? [] : feeds[current, default: []]
            let keys = Set(existing.map(\.key))
            feeds[current] = existing + page.items.filter { !keys.contains($0.key) }
            feedNext[current] = page.next
        } catch {
            if generation == feedGeneration { feedError = error.localizedDescription }
        }
    }

    func changeChannel(_ value: Channel) {
        guard value != channel else { return }
        feedGeneration += 1; loadingFeed = false; refreshingFeed = false; feedError = nil
        channel = value; question = nil; leaveReading()
    }

    func leaveReading() {
        bodyGeneration += 1
        resetStreamState()
        streamAnchor = nil; streamItems = []; scrollRequest = nil
        selected = nil; bodyHTML = nil; bodyError = nil; showsComments = false
    }

    func open(_ item: ReadingItem) {
        showsComments = false
        if item.kind == .question {
            leaveReading()
            answerGeneration += 1; loadingAnswers = false
            question = item; answers = []; answerSort = "default"
            Task { await loadAnswers() }
        } else {
            question = nil
            selectAnswer(item)
        }
    }

    func selectAnswer(_ item: ReadingItem) {
        if let questionID = item.questionID, streamAnchor?.questionID == questionID,
           streamItems.contains(where: { $0.key == item.key }), bodyHTML != nil {
            showsComments = false
            setVisibleAnswer(item.id)
            scrollRequest = ScrollRequest(id: item.id)
            return
        }
        scrollRequest = nil
        selected = item; streamAnchor = item; streamItems = []; streamOffset = 0
        resetStreamState()
        bodyHTML = nil; bodyError = nil; showsComments = false
        voteError = nil; voting = false
        bodyGeneration += 1
        let generation = bodyGeneration
        Task {
            do {
                let detail = try await detail(for: item)
                if generation == bodyGeneration {
                    selected = detail
                    streamItems = [detail]
                    bodyHTML = detail.contentHTML
                    if item.kind == .answer, let questionID = item.questionID {
                        let existing = question?.id == questionID ? answers.filter { !($0.contentHTML ?? "").isEmpty } : []
                        if existing.contains(where: { $0.key == item.key }) {
                            streamItems = existing.map { $0.key == item.key ? detail : $0 }
                            streamOffset = answers.count
                            streamHasMore = hasMoreAnswers
                        } else {
                            streamSeekingAnchor = true
                            streamHasMore = true
                            await loadMoreStream()
                        }
                    }
                }
            } catch {
                if generation == bodyGeneration { bodyError = error.localizedDescription }
            }
        }
    }

    private func resetStreamState() {
        streamHasMore = false; streamLoading = false; streamError = nil
        streamSeekingAnchor = false; streamSearchExhausted = false; streamLeadingItems = []
        streamGeneration += 1
    }

    func loadMoreStream() async {
        guard let anchor = streamAnchor, anchor.kind == .answer,
              let questionID = anchor.questionID, streamHasMore, !streamLoading else { return }
        let generation = streamGeneration
        streamLoading = true
        defer { if generation == streamGeneration { streamLoading = false } }
        do {
            let sort = question?.id == questionID ? answerSort : "default"
            var pagesSearched = 0
            repeat {
                let pageOffset = streamOffset
                let page = try await source.answers(questionID: questionID, sort: sort, offset: streamOffset)
                guard generation == streamGeneration else { return }
                streamOffset += page.items.count
                streamHasMore = page.next != nil && !page.items.isEmpty
                // Keep the question directory in step when the reader fetches its
                // next page first. A separately loaded directory may already be ahead.
                if question?.id == questionID, answerSort == sort, answers.count == pageOffset {
                    let keys = Set(answers.map(\.key))
                    answers += page.items.filter { !keys.contains($0.key) }
                    hasMoreAnswers = streamHasMore
                }
                let readable = page.items.filter { !($0.contentHTML ?? "").isEmpty }
                if streamSeekingAnchor {
                    if readable.contains(where: { $0.key == anchor.key }), let first = streamItems.first {
                        let prior = streamLeadingItems
                        streamLeadingItems = []
                        streamItems = prior + readable.map { $0.key == anchor.key ? first : $0 }
                        streamSeekingAnchor = false
                    } else {
                        streamLeadingItems += readable
                    }
                    pagesSearched += 1
                } else {
                    let seen = Set(streamItems.map(\.key))
                    streamItems += readable.filter { !seen.contains($0.key) }
                }
            } while streamSeekingAnchor && streamHasMore && pagesSearched < 5
            streamError = streamSeekingAnchor ? (streamHasMore ? "暂未找到当前回答的位置" : "无法在当前排序中找到此回答") : nil
            streamSearchExhausted = streamSeekingAnchor && !streamHasMore
            if streamSearchExhausted { streamLeadingItems = [] }
            if streamSeekingAnchor { streamHasMore = false }
        } catch {
            if generation == streamGeneration { streamHasMore = false; streamError = error.localizedDescription }
        }
    }

    func retryStream() {
        streamError = nil
        streamHasMore = true
        Task { await loadMoreStream() }
    }

    func setVisibleAnswer(_ id: String) {
        guard let item = streamItems.first(where: { $0.id == id }), item.key != selected?.key else { return }
        selected = item; voting = false; voteError = nil
        let key = item.key
        Task {
            if let detail = try? await source.detail(item, prefetch: false), selected?.key == key, !voting { selected = detail }
        }
    }

    func toggleVote(_ direction: AnswerVote) async {
        guard let item = selected, item.kind == .answer, !voting else { return }
        let target: AnswerVote = item.vote == direction ? .neutral : direction
        voting = true
        defer { if selected?.key == item.key { voting = false } }
        do {
            try await source.setVote(answerID: item.id, vote: target)
            detailCache.removeValue(forKey: item.key)
            if selected?.key == item.key {
                var updated = item
                if let count = updated.upCount { updated.upCount = max(0, count + (target == .up ? 1 : 0) - (item.vote == .up ? 1 : 0)) }
                if let count = updated.downCount { updated.downCount = max(0, count + (target == .down ? 1 : 0) - (item.vote == .down ? 1 : 0)) }
                updated.vote = target
                selected = updated
            }
        } catch {
            if selected?.key == item.key { voteError = error.localizedDescription }
        }
    }

    func loadAnswers(more: Bool = false) async {
        guard let question, !more || (!loadingAnswers && hasMoreAnswers) else { return }
        let offset = more ? answers.count : 0
        // A changed ordering cannot reuse the old stream's offset or an in-flight page.
        if !more, streamAnchor?.questionID == question.id { resetStreamState() }
        // Do not present the previous ordering under the newly selected sort while loading or after an error.
        if !more { answers = []; hasMoreAnswers = false }
        answerGeneration += 1
        let generation = answerGeneration
        loadingAnswers = true; answerError = nil
        defer { if generation == answerGeneration { loadingAnswers = false } }
        do {
            let page = try await source.answers(questionID: question.id, sort: answerSort, offset: offset)
            guard generation == answerGeneration else { return }
            let existing = more ? answers : []
            let keys = Set(existing.map(\.key))
            answers = existing + page.items.filter { !keys.contains($0.key) }
            hasMoreAnswers = page.next != nil && !page.items.isEmpty
            if !more, let current = selected, current.questionID == question.id,
               streamAnchor?.questionID == question.id {
                // Keep the current answer when it is in the first page. Otherwise start
                // the new ordering at its beginning instead of searching an unbounded
                // number of pages and leaving the reader stranded on one answer.
                let start = answers.first(where: { $0.key == current.key }) ?? answers.first
                streamAnchor = nil
                if let start { selectAnswer(start) }
            }
        } catch { if generation == answerGeneration { answerError = error.localizedDescription } }
    }

    func showComments() {
        guard let selected else { return }
        commentTarget = selected
        showsComments = true; comments = []; commentsNext = nil; commentError = nil; loadingComments = false
        commentReplies = [:]; replyErrors = [:]; loadingReplies = []; replyNext = [:]
        commentsGeneration += 1
        Task { await loadComments(reset: true) }
    }

    func loadComments(reset: Bool = false) async {
        guard let target = commentTarget, !loadingComments else { return }
        if !reset && commentsNext == nil { return }
        let generation = commentsGeneration
        loadingComments = true; commentError = nil
        defer { if generation == commentsGeneration { loadingComments = false } }
        do {
            let page = try await (reset ? firstComments(for: target) : source.comments(target, next: commentsNext))
            guard generation == commentsGeneration, target.key == commentTarget?.key else { return }
            comments = reset ? page.items : comments + page.items
            commentsNext = page.next
        } catch { if generation == commentsGeneration { commentError = error.localizedDescription } }
    }
    var canLoadMoreComments: Bool { commentsNext != nil }

    func loadReplies(to comment: ReadingComment) async {
        guard !loadingReplies.contains(comment.id) else { return }
        let generation = commentsGeneration
        loadingReplies.insert(comment.id); replyErrors[comment.id] = nil
        defer { if generation == commentsGeneration { loadingReplies.remove(comment.id) } }
        do {
            let page = try await source.replies(to: comment, next: replyNext[comment.id])
            guard generation == commentsGeneration else { return }
            let existing = commentReplies[comment.id] ?? []
            var known = Set((comments + existing).map(\.id))
            commentReplies[comment.id] = existing + page.items.filter { known.insert($0.id).inserted }
            replyNext[comment.id] = page.next
        } catch {
            if generation == commentsGeneration { replyErrors[comment.id] = error.localizedDescription }
        }
    }
    func loadAccount() async {
        do {
            let account = try await source.currentUser()
            accountName = account.name
            accountAvatarURL = account.avatar
        } catch {
            accountName = nil
            accountAvatarURL = nil
        }
    }

    func resetAfterLogin() {
        clearDetailCache()
        Task {
            await loadAccount()
            if feedError != nil || feeds[channel] == nil { await loadFeed(reset: feeds[channel] == nil) }
            if bodyError != nil, let item = selected { selectAnswer(item) }
            else if streamError != nil && !streamSearchExhausted { retryStream() }
            if answerError != nil { await loadAnswers(more: !answers.isEmpty && hasMoreAnswers) }
            if showsComments && commentError != nil { await loadComments(reset: true) }
        }
    }
}
