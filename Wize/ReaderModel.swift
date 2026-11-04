import Foundation
import Combine
import CoreText

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
    @Published var accountHeadline: String?
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
    private var voteRevisions: [String: Int] = [:]
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
            if generation == detailCacheGeneration, detailTasks[item.key]?.id == taskID {
                detailTasks[item.key] = nil
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
        voteRevisions.removeAll()
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
        streamOffset = 0
        resetStreamState()
        bodyError = nil; showsComments = false
        voteError = nil; voting = false
        bodyGeneration += 1
        let generation = bodyGeneration
        let voteRevision = voteRevisions[item.key, default: 0]
        let matchedAnswer = item.questionID != nil && question?.id == item.questionID
            ? answers.first(where: { $0.key == item.key && !($0.contentHTML ?? "").isEmpty })
            : nil
        let immediate = cachedDetail(for: item.key)
            ?? (!(item.contentHTML ?? "").isEmpty ? item : matchedAnswer)
        if let immediate, let html = immediate.contentHTML, !html.isEmpty {
            selected = immediate
            streamAnchor = immediate
            bodyHTML = html
            if item.kind == .answer, let questionID = item.questionID {
                let existing = question?.id == questionID ? answers.filter { !($0.contentHTML ?? "").isEmpty } : []
                if existing.contains(where: { $0.key == item.key }) {
                    streamItems = existing.map { $0.key == item.key ? immediate : $0 }
                    streamOffset = answers.count
                    streamHasMore = hasMoreAnswers
                } else {
                    streamItems = [immediate]
                    streamSeekingAnchor = true
                    streamHasMore = true
                }
            } else {
                streamItems = [immediate]
            }
            let needsDetailRefresh = cachedDetail(for: item.key) == nil
            let needsStreamSearch = streamSeekingAnchor
            guard needsDetailRefresh || needsStreamSearch else { return }
            Task {
                if needsDetailRefresh, let refreshed = try? await detail(for: item),
                   generation == bodyGeneration, selected?.key == item.key, !voting {
                    selected = refreshed
                }
                if needsStreamSearch, generation == bodyGeneration {
                    await loadMoreStream()
                }
            }
            return
        }
        selected = item; streamAnchor = item; streamItems = []; bodyHTML = nil
        Task {
            do {
                var detail = try await detail(for: item)
                if generation == bodyGeneration {
                    if voteRevisions[item.key, default: 0] != voteRevision, let current = selected, current.key == item.key {
                        detail.vote = current.vote; detail.upCount = current.upCount; detail.downCount = current.downCount
                    }
                    selected = detail
                    streamItems = [detail]
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
                    if generation == bodyGeneration {
                        bodyHTML = detail.contentHTML
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
            streamError = nil
            streamSearchExhausted = streamSeekingAnchor && !streamHasMore
            if streamSearchExhausted { streamLeadingItems = [] }
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
        let revision = voteRevisions[key, default: 0]
        Task {
            if let detail = try? await source.detail(item, prefetch: false), selected?.key == key, !voting,
               voteRevisions[key, default: 0] == revision { selected = detail }
        }
    }

    func toggleVote(_ direction: AnswerVote) async {
        guard var item = selected, item.kind == .answer, !voting else { return }
        voting = true
        voteError = nil
        defer { if selected?.key == item.key { voting = false } }
        do {
            if item.vote == nil {
                item = try await source.detail(item, prefetch: false)
                guard selected?.key == item.key else { return }
                guard item.vote != nil else { throw SourceError.voteUnconfirmed }
                selected = item
            }
            let target: AnswerVote = item.vote == direction ? .neutral : direction
            let result = try await source.setVote(answerID: item.id, vote: target)
            voteRevisions[item.key, default: 0] += 1
            detailCache.removeValue(forKey: item.key)
            detailTasks.removeValue(forKey: item.key)?.task.cancel()
            func updated(_ original: ReadingItem) -> ReadingItem {
                guard original.key == item.key else { return original }
                var value = original
                let up = item.upCount.map { max(0, $0 + (result.vote == .up ? 1 : 0) - (item.vote == .up ? 1 : 0)) }
                let down = item.downCount.map { max(0, $0 + (result.vote == .down ? 1 : 0) - (item.vote == .down ? 1 : 0)) }
                value.upCount = result.upCount ?? up ?? original.upCount
                value.downCount = result.downCount ?? down ?? original.downCount
                value.vote = result.vote
                return value
            }
            streamItems = streamItems.map(updated)
            answers = answers.map(updated)
            for channel in Channel.allCases { if let items = feeds[channel] { feeds[channel] = items.map(updated) } }
            if let current = selected, current.key == item.key { selected = updated(current) }
            if result.vote != target, selected?.key == item.key { voteError = "知乎未确认该操作，请稍后重试。" }
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
            accountHeadline = account.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            accountName = nil
            accountAvatarURL = nil
            accountHeadline = nil
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

struct ReadingFontOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let license: String
    let cssFamily: String
    let postScriptName: String?
    let urls: [URL]
    let format: String
    let mimeType: String
    let fileName: String
    var isBuiltIn: Bool { urls.isEmpty }
    var webFontFamilyName: String { "WizeFont-\(id)" }

    static let all: [ReadingFontOption] = [
        ReadingFontOption(
            id: "system",
            title: "系统默认",
            subtitle: "苹方 · 系统无衬线",
            license: "System",
            cssFamily: "-apple-system, 'PingFang SC', sans-serif",
            postScriptName: nil,
            urls: [],
            format: "",
            mimeType: "",
            fileName: ""
        ),
        ReadingFontOption(
            id: "serif",
            title: "系统宋体",
            subtitle: "宋体 · 系统衬线",
            license: "System",
            cssFamily: "'Songti SC', 'STSong', 'Source Han Serif SC', 'Noto Serif CJK SC', Georgia, serif",
            postScriptName: "STSongti-SC-Regular",
            urls: [],
            format: "",
            mimeType: "",
            fileName: ""
        ),
        ReadingFontOption(
            id: "lxgw-neo-zhisong",
            title: "霞鹜新致宋",
            subtitle: "开源宋体 · SIL OFL 1.1 · 约 10 MB",
            license: "SIL Open Font License 1.1",
            cssFamily: "'WizeFont-lxgw-neo-zhisong', 'LXGW Neo ZhiSong', 'Songti SC', Georgia, serif",
            postScriptName: "LXGWNeoZhiSong",
            urls: [
                URL(string: "https://github.com/lxgw/LxgwNeoZhiSong/releases/download/v1.070/LXGWNeoZhiSong.ttf")!
            ],
            format: "truetype",
            mimeType: "font/ttf",
            fileName: "LXGWNeoZhiSong.ttf"
        ),
        ReadingFontOption(
            id: "source-han-serif",
            title: "思源宋体",
            subtitle: "Adobe & Google 开源宋体 · SIL OFL 1.1 · 约 24 MB",
            license: "SIL Open Font License 1.1",
            cssFamily: "'WizeFont-source-han-serif', 'Source Han Serif SC', 'Noto Serif CJK SC', 'Songti SC', Georgia, serif",
            postScriptName: "SourceHanSerifSC-Regular",
            urls: [
                URL(string: "https://raw.githubusercontent.com/adobe-fonts/source-han-serif/release/OTF/SimplifiedChinese/SourceHanSerifSC-Regular.otf")!,
                URL(string: "https://raw.githubusercontent.com/notofonts/noto-cjk/main/Serif/OTF/SimplifiedChinese/NotoSerifCJKsc-Regular.otf")!
            ],
            format: "opentype",
            mimeType: "font/otf",
            fileName: "SourceHanSerifSC-Regular.otf"
        ),
        ReadingFontOption(
            id: "lxgw-wenkai",
            title: "霞鹜文楷",
            subtitle: "开源楷体 · SIL OFL 1.1 · 约 14 MB",
            license: "SIL Open Font License 1.1",
            cssFamily: "'WizeFont-lxgw-wenkai', 'LXGW WenKai Lite', 'LXGW WenKai', 'Kaiti SC', serif",
            postScriptName: "LXGWWenKaiLite-Regular",
            urls: [
                URL(string: "https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.530/LXGWWenKaiLite-Regular.ttf")!,
                URL(string: "https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKai-Regular.ttf")!
            ],
            format: "truetype",
            mimeType: "font/ttf",
            fileName: "LXGWWenKaiLite-Regular.ttf"
        ),
        ReadingFontOption(
            id: "lxgw-neo-xihei",
            title: "霞鹜新晰黑",
            subtitle: "开源阅读黑体 · SIL OFL 1.1 · 约 7 MB",
            license: "SIL Open Font License 1.1",
            cssFamily: "'WizeFont-lxgw-neo-xihei', 'LXGW Neo XiHei', -apple-system, sans-serif",
            postScriptName: "LXGWNeoXiHei",
            urls: [
                URL(string: "https://github.com/lxgw/LxgwNeoXiHei/releases/download/v1.308/LXGWNeoXiHei.ttf")!
            ],
            format: "truetype",
            mimeType: "font/ttf",
            fileName: "LXGWNeoXiHei.ttf"
        ),
        ReadingFontOption(
            id: "source-han-sans",
            title: "思源黑体",
            subtitle: "Adobe & Google 开源黑体 · SIL OFL 1.1 · 约 16 MB",
            license: "SIL Open Font License 1.1",
            cssFamily: "'WizeFont-source-han-sans', 'Source Han Sans SC', 'Noto Sans CJK SC', -apple-system, sans-serif",
            postScriptName: "SourceHanSansSC-Regular",
            urls: [
                URL(string: "https://raw.githubusercontent.com/adobe-fonts/source-han-sans/release/OTF/SimplifiedChinese/SourceHanSansSC-Regular.otf")!,
                URL(string: "https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf")!
            ],
            format: "opentype",
            mimeType: "font/otf",
            fileName: "SourceHanSansSC-Regular.otf"
        )
    ]

    static func option(for id: String) -> ReadingFontOption {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

enum ReadingFontError: LocalizedError {
    case invalidFontData
    case downloadFailed
    var errorDescription: String? {
        switch self {
        case .invalidFontData: return "下载的字体文件无效，请重试。"
        case .downloadFailed: return "字体下载失败，请检查网络后重试。"
        }
    }
}

@MainActor
final class ReadingFontManager: ObservableObject {
    static let shared = ReadingFontManager()

    enum State: Equatable {
        case builtIn
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    typealias Fetcher = (ReadingFontOption, @escaping @Sendable (Double) -> Void) async throws -> Data

    let options: [ReadingFontOption]
    let directory: URL
    private let fetcher: Fetcher?
    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var fontFaceCSS: [String: String] = [:]
    @Published private(set) var registeredFontNames: [String: String] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(directory: URL? = nil, options: [ReadingFontOption] = ReadingFontOption.all, fetcher: Fetcher? = nil) {
        self.options = options
        self.fetcher = fetcher
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("ReadingFonts", isDirectory: true)
        }
        ensureDirectory()
        for option in options {
            if option.isBuiltIn {
                states[option.id] = .builtIn
            } else {
                let fileURL = fontFileURL(for: option)
                if FileManager.default.fileExists(atPath: fileURL.path),
                   let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
                   Self.isValidFontData(data) {
                    states[option.id] = .downloaded
                    registerFontFile(at: fileURL, for: option)
                    loadCachedFontFaceCSS(for: option, fontData: data)
                } else {
                    states[option.id] = .notDownloaded
                }
            }
        }
    }

    func state(for option: ReadingFontOption) -> State {
        states[option.id] ?? (option.isBuiltIn ? .builtIn : .notDownloaded)
    }

    func isAvailable(_ option: ReadingFontOption) -> Bool {
        option.isBuiltIn || state(for: option) == .downloaded
    }

    func fontFileURL(for option: ReadingFontOption) -> URL {
        directory.appendingPathComponent(option.fileName)
    }

    private func cssFileURL(for option: ReadingFontOption) -> URL {
        directory.appendingPathComponent("\(option.id).css")
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    nonisolated static func isValidFontData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let magic = [UInt8](data.prefix(4))
        let signatures: [[UInt8]] = [
            [0x00, 0x01, 0x00, 0x00], // TrueType
            [0x4F, 0x54, 0x54, 0x4F], // OpenType CFF ("OTTO")
            [0x74, 0x72, 0x75, 0x65], // Apple TrueType ("true")
            [0x74, 0x74, 0x63, 0x66], // TrueType Collection ("ttcf")
            [0x77, 0x4F, 0x46, 0x32]  // WOFF2 ("wOF2")
        ]
        return signatures.contains(magic)
    }

    nonisolated static func buildFontFaceCSS(for option: ReadingFontOption, data: Data) -> String {
        let base64 = data.base64EncodedString()
        return "@font-face { font-family: '\(option.webFontFamilyName)'; src: url('data:\(option.mimeType);base64,\(base64)') format('\(option.format)'); font-weight: normal; font-style: normal; font-display: block; }"
    }

    private func registerFontFile(at url: URL, for option: ReadingFontOption) {
        CTFontManagerRegisterFontURLs([url] as CFArray, .process, true, nil)
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
           let first = descriptors.first {
            if let psName = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String, !psName.isEmpty {
                registeredFontNames[option.id] = psName
            } else if let family = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String, !family.isEmpty {
                registeredFontNames[option.id] = family
            }
        }
    }

    private func loadCachedFontFaceCSS(for option: ReadingFontOption, fontData: Data? = nil) {
        if fontFaceCSS[option.id] != nil { return }
        let cssURL = cssFileURL(for: option)
        if let cached = try? String(contentsOf: cssURL, encoding: .utf8), !cached.isEmpty {
            fontFaceCSS[option.id] = cached
            return
        }
        let fileURL = fontFileURL(for: option)
        Task.detached(priority: .utility) {
            guard let data = fontData ?? (try? Data(contentsOf: fileURL, options: .mappedIfSafe)) else { return }
            let css = ReadingFontManager.buildFontFaceCSS(for: option, data: data)
            try? css.write(to: cssURL, atomically: true, encoding: .utf8)
            await MainActor.run {
                self.fontFaceCSS[option.id] = css
            }
        }
    }

    func prepareFontIfNeeded(id: String) {
        let option = options.first(where: { $0.id == id }) ?? ReadingFontOption.option(for: id)
        if option.id == "serif", let psName = option.postScriptName {
            requestSystemFontIfNeeded(postScriptName: psName)
        }
        guard !option.isBuiltIn, state(for: option) == .downloaded else { return }
        loadCachedFontFaceCSS(for: option)
    }

    private func requestSystemFontIfNeeded(postScriptName: String) {
        let attrs = [kCTFontNameAttribute as String: postScriptName] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { _, _ in true }
    }

    func download(_ option: ReadingFontOption, onSelect: ((String) -> Void)? = nil) {
        if option.isBuiltIn {
            if option.id == "serif", let psName = option.postScriptName {
                requestSystemFontIfNeeded(postScriptName: psName)
            }
            onSelect?(option.id)
            return
        }
        if state(for: option) == .downloaded {
            loadCachedFontFaceCSS(for: option)
            onSelect?(option.id)
            return
        }
        if case .downloading = state(for: option) { return }
        states[option.id] = .downloading(0.02)
        let customFetcher = fetcher
        let targetFileURL = fontFileURL(for: option)
        let targetCSSURL = cssFileURL(for: option)
        ensureDirectory()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let reportProgress: @Sendable (Double) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        guard let self, case .downloading = self.states[option.id] else { return }
                        self.states[option.id] = .downloading(min(max(progress, 0.02), 0.99))
                    }
                }
                let data: Data
                if let customFetcher {
                    data = try await customFetcher(option, reportProgress)
                } else {
                    data = try await Self.fetchFontData(for: option, onProgress: reportProgress)
                }
                try Task.checkCancellation()
                guard Self.isValidFontData(data) else { throw ReadingFontError.invalidFontData }
                let css = try await Task.detached(priority: .userInitiated) {
                    try data.write(to: targetFileURL, options: .atomic)
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    var mutableURL = targetFileURL
                    try? mutableURL.setResourceValues(values)
                    let generatedCSS = ReadingFontManager.buildFontFaceCSS(for: option, data: data)
                    try? generatedCSS.write(to: targetCSSURL, atomically: true, encoding: .utf8)
                    return generatedCSS
                }.value
                try Task.checkCancellation()
                self.registerFontFile(at: targetFileURL, for: option)
                self.fontFaceCSS[option.id] = css
                self.states[option.id] = .downloaded
                self.downloadTasks[option.id] = nil
                onSelect?(option.id)
            } catch is CancellationError {
                self.downloadTasks[option.id] = nil
                if self.states[option.id] != .downloaded {
                    self.states[option.id] = .notDownloaded
                }
            } catch {
                self.downloadTasks[option.id] = nil
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    self.states[option.id] = .notDownloaded
                } else {
                    self.states[option.id] = .failed((error as? LocalizedError)?.errorDescription ?? ReadingFontError.downloadFailed.localizedDescription)
                }
            }
        }
        downloadTasks[option.id] = task
    }

    func cancelDownload(_ option: ReadingFontOption) {
        downloadTasks[option.id]?.cancel()
        downloadTasks[option.id] = nil
        if state(for: option) != .downloaded {
            states[option.id] = .notDownloaded
        }
    }

    func removeFont(_ option: ReadingFontOption) {
        guard !option.isBuiltIn else { return }
        cancelDownload(option)
        let fileURL = fontFileURL(for: option)
        let cssURL = cssFileURL(for: option)
        CTFontManagerUnregisterFontURLs([fileURL] as CFArray, .process, nil)
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: cssURL)
        fontFaceCSS.removeValue(forKey: option.id)
        registeredFontNames.removeValue(forKey: option.id)
        states[option.id] = .notDownloaded
    }

    private static func fetchFontData(for option: ReadingFontOption, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WIZE_VISUAL_FIXTURE"] == "1"
            || ProcessInfo.processInfo.environment["WIZE_FONT_FIXTURE"] == "1" {
            for step in 1...4 {
                try await Task.sleep(nanoseconds: 40_000_000)
                onProgress(Double(step) * 0.24)
            }
            let candidates = [
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/System/Library/Fonts/Monaco.ttf",
                "/System/Library/Fonts/Core/Avenir.ttc"
            ]
            for path in candidates {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), isValidFontData(data) {
                    return data
                }
            }
            return Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }
        #endif
        var lastError: Error = ReadingFontError.downloadFailed
        for url in option.urls {
            do {
                let data = try await FontDownloadTaskRunner.download(from: url, onProgress: onProgress)
                if isValidFontData(data) { return data }
                lastError = ReadingFontError.invalidFontData
            } catch {
                let nsError = error as NSError
                if error is CancellationError || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                    throw CancellationError()
                }
                lastError = error
            }
        }
        throw lastError
    }
}

private final class FontDownloadTaskRunner: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    private var lastReported = Date.distantPast
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func download(from url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let runner = FontDownloadTaskRunner(onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                runner.start(url: url, continuation: continuation)
            }
        } onCancel: {
            runner.cancel()
        }
    }

    private func start(url: URL, continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Wize/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.task = task
        task.resume()
    }

    private func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReported) >= 0.05 else { return }
        lastReported = now
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        defer { session.finishTasksAndInvalidate() }
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation.resume(throwing: SourceError.response(http.statusCode))
            return
        }
        do {
            let data = try Data(contentsOf: location)
            continuation.resume(returning: data)
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        guard let error, let continuation = self.continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}
