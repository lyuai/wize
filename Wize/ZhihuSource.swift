import Foundation
import WebKit

struct ReadingItem: Identifiable, Hashable {
    enum Kind: String { case question, answer, article }
    let id: String
    let kind: Kind
    let title: String
    let excerpt: String
    let author: String
    let questionID: String?
    var avatarURL: URL? = nil
    var authorHeadline: String? = nil
    var authorToken: String? = nil
    var ipInfo: String? = nil
    var imageURL: URL? = nil
    var contentHTML: String? = nil
    var upCount: Int? = nil
    var downCount: Int? = nil
    var commentCount: Int? = nil
    var vote: AnswerVote? = nil
    var key: String { "\(kind.rawValue):\(id)" }
}

enum AnswerVote: String { case up, down, neutral }

struct AnswerVoteResult {
    let vote: AnswerVote
    let upCount: Int?
    let downCount: Int?
}

enum VideoKind: String, Hashable { case lens, zvideo }

struct VideoReference: Hashable {
    let id: String
    let kind: VideoKind
}

struct VideoPlayback {
    let url: URL
    let title: String?
    let poster: URL?
}

struct ReadingComment: Identifiable {
    let id: String
    let author: String
    let html: String
    let likes: Int
    var avatarURL: URL? = nil
    var ipInfo: String? = nil
    var replyTo: String? = nil
    var depth: Int = 0
    var replyCount: Int = 0
    var parentID: String? = nil
}

struct Page<T> {
    let items: [T]
    let next: URL?
}

struct ReadingCollection: Identifiable {
    let id: String
    let title: String
    var isFavorited: Bool
}

enum SourceError: LocalizedError {
    case response(Int), malformed, unsupported, voteUnconfirmed, videoUnavailable
    var errorDescription: String? {
        switch self {
        case .response(401), .response(403): return "知乎要求登录或安全验证，请先登录后重试。"
        case .response(let code): return "知乎返回错误（\(code)），请稍后重试。"
        case .malformed: return "无法读取知乎返回的数据。"
        case .unsupported: return "暂不支持此类型的内容。"
        case .voteUnconfirmed: return "无法确认知乎的赞同状态，请稍后重试。"
        case .videoUnavailable: return "视频暂时无法播放，请稍后重试。"
        }
    }
}

// The reader depends on this small interface so additional sources can supply the same capabilities.
@MainActor
protocol ReadingSource {
    func feed(hot: Bool, next: URL?) async throws -> Page<ReadingItem>
    func currentUser() async throws -> (name: String, avatar: URL?, headline: String?, token: String?)
    func answers(questionID: String, sort: String, offset: Int) async throws -> Page<ReadingItem>
    func detail(_ item: ReadingItem, prefetch: Bool) async throws -> ReadingItem
    func setVote(answerID: String, vote: AnswerVote) async throws -> AnswerVoteResult
    func comments(_ item: ReadingItem, next: URL?) async throws -> Page<ReadingComment>
    func replies(to comment: ReadingComment, next: URL?) async throws -> Page<ReadingComment>
}

extension ReadingSource {
    func replies(to comment: ReadingComment, next: URL?) async throws -> Page<ReadingComment> { throw SourceError.unsupported }
}

// The source is intentionally isolated from reader state and presentation.
@MainActor
final class ZhihuSource: ReadingSource {
    private let base = "https://www.zhihu.com"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
    private let prefetchSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private func request(_ url: URL, method: String = "GET", body: [String: String]? = nil, form: [String: String]? = nil, prefetch: Bool = false) async throws -> [String: Any] {
        guard url.scheme == "https", let host = url.host,
              host == "zhihu.com" || host.hasSuffix(".zhihu.com") else { throw SourceError.malformed }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
        let matching = cookies.filter { $0.domain == host || (host.hasSuffix($0.domain.hasPrefix(".") ? $0.domain : "." + $0.domain)) }
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let xsrf = matching.first(where: { $0.name == "_xsrf" })?.value {
                request.setValue(xsrf, forHTTPHeaderField: "x-xsrftoken")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if let xsrf = matching.first(where: { $0.name == "_xsrf" })?.value { request.setValue(xsrf, forHTTPHeaderField: "x-xsrftoken") }
            var encoded = URLComponents(); encoded.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = encoded.percentEncodedQuery?.data(using: .utf8)
        }
        request.setValue(matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let (data, response) = try await (prefetch ? prefetchSession : session).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.malformed }
        // API responses can refresh the session. Keep WebKit's persistent cookie
        // store authoritative so the next request and the login view see updates.
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard domain == "zhihu.com" || domain.hasSuffix(".zhihu.com"),
                  host == domain || host.hasSuffix("." + domain) else { continue }
            if let expiry = cookie.expiresDate, expiry <= Date() {
                await WKWebsiteDataStore.default().httpCookieStore.deleteCookie(cookie)
            } else {
                await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            }
        }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.response(http.statusCode) }
        if data.isEmpty { return [:] }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SourceError.malformed }
        return result
    }

    private func url(_ path: String, _ params: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: base + path)!
        components.queryItems = params.isEmpty ? nil : params
        return components.url!
    }

    func feed(hot: Bool, next: URL? = nil) async throws -> Page<ReadingItem> {
        let initial = hot
            ? url("/api/v3/feed/topstory/hot-lists/total", [.init(name: "limit", value: "30")])
            : url("/api/v3/feed/topstory/recommend", [.init(name: "limit", value: "20"), .init(name: "action", value: "down"), .init(name: "page_number", value: "1")])
        let json = try await request(next ?? initial)
        return Page(items: objects(json).compactMap { parseFeed($0) }, next: nextURL(json))
    }

    func currentUser() async throws -> (name: String, avatar: URL?, headline: String?, token: String?) {
        let json = try await request(url("/api/v4/me", [.init(name: "include", value: "avatar_url,name,headline,url_token")]))
        guard let name = json["name"] as? String, !name.isEmpty else { throw SourceError.malformed }
        return (name, mediaURL(json["avatar_url"]), json["headline"] as? String, json["url_token"] as? String)
    }

    func answers(questionID: String, sort: String, offset: Int) async throws -> Page<ReadingItem> {
        let json = try await request(url("/api/v4/questions/\(questionID)/answers", [
            .init(name: "include", value: "data[*].content,voteup_count,votedown_count,comment_count,voting,relationship.voting,author,question,ip_info"),
            .init(name: "sort_by", value: sort), .init(name: "offset", value: String(offset)), .init(name: "limit", value: "20")
        ]))
        return Page(items: objects(json).compactMap { parseObject($0, fallbackQuestionID: questionID) }, next: nextURL(json))
    }

    func detail(_ item: ReadingItem, prefetch: Bool = false) async throws -> ReadingItem {
        let path = item.kind == .article ? "/api/v4/articles/\(item.id)" : "/api/v4/answers/\(item.id)"
        let json = try await request(url(path, [.init(name: "include", value: "content,author,question,voteup_count,votedown_count,comment_count,voting,relationship.voting,ip_info")]), prefetch: prefetch)
        guard let content = json["content"] as? String, !content.isEmpty else { throw SourceError.malformed }
        var updated = item
        updated.contentHTML = content
        if let author = json["author"] as? [String: Any] {
            updated.avatarURL = mediaURL(author["avatar_url"]) ?? item.avatarURL
            updated.authorHeadline = author["headline"] as? String ?? item.authorHeadline
            updated.authorToken = author["url_token"] as? String ?? item.authorToken
        }
        updated.ipInfo = (json["ip_info"] as? String) ?? item.ipInfo
        updated.upCount = json["voteup_count"] as? Int ?? item.upCount
        updated.downCount = json["votedown_count"] as? Int ?? item.downCount
        updated.commentCount = json["comment_count"] as? Int ?? item.commentCount
        updated.vote = answerVote(from: json)
        if updated.vote == nil, item.kind == .answer {
            updated.vote = try? await answerRelationshipVote(answerID: item.id, prefetch: prefetch)
        }
        return updated
    }

    private func answerRelationshipVote(answerID: String, prefetch: Bool = false) async throws -> AnswerVote {
        let json = try await request(url("/api/v4/answers/\(answerID)/relationship", [.init(name: "desktop", value: "true")]), prefetch: prefetch)
        guard let vote = answerVote(from: json) else { throw SourceError.voteUnconfirmed }
        return vote
    }

    func setVote(answerID: String, vote: AnswerVote) async throws -> AnswerVoteResult {
        let json = try await request(url("/api/v4/answers/\(answerID)/voters"), method: "POST", body: ["type": vote.rawValue])
        let confirmed: AnswerVote
        if let value = answerVote(from: json) { confirmed = value }
        else { confirmed = try await answerRelationshipVote(answerID: answerID) }
        return AnswerVoteResult(vote: confirmed, upCount: json["voteup_count"] as? Int, downCount: json["votedown_count"] as? Int)
    }

    func videoPlayback(_ reference: VideoReference) async throws -> VideoPlayback {
        switch reference.kind {
        case .lens:
            return try await lensVideoPlayback(id: reference.id)
        case .zvideo:
            let json = try await request(url("/api/v4/zvideos/\(reference.id)", [
                .init(name: "include", value: "video")
            ]))
            let video = json["video"] as? [String: Any] ?? json
            if let lensID = identifier(video["video_id"]) ?? identifier(video["id"]),
               video["playlist"] == nil, video["playlist_v2"] == nil {
                return try await lensVideoPlayback(id: lensID)
            }
            return try playback(from: video, fallbackTitle: json["title"] as? String, poster: nil)
        }
    }

    private func lensVideoPlayback(id: String) async throws -> VideoPlayback {
        guard let url = URL(string: "https://lens.zhihu.com/api/v4/videos/\(id)") else {
            throw SourceError.malformed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.malformed }
        guard (200..<300).contains(http.statusCode) else { throw SourceError.response(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.malformed
        }
        return try playback(from: json, fallbackTitle: nil, poster: nil)
    }

    private func playback(from json: [String: Any], fallbackTitle: String?, poster: URL?) throws -> VideoPlayback {
        let title = (json["title"] as? String) ?? fallbackTitle
        let cover = poster
            ?? mediaURL(json["cover_url"])
            ?? mediaURL(json["thumbnail"])
            ?? mediaURL(json["image_url"])
        let ranks = ["FHD": 0, "HD": 1, "SD": 2, "LD": 3]
        var best: (rank: Int, url: URL)?
        for key in ["playlist", "playlist_v2"] {
            guard let playlist = json[key] as? [String: Any] else { continue }
            for (quality, value) in playlist {
                guard let entry = value as? [String: Any],
                      let raw = (entry["play_url"] as? String) ?? (entry["url"] as? String),
                      let url = URL(string: raw) else { continue }
                let rank = ranks[quality.uppercased()] ?? 4
                if best == nil || rank < best!.rank { best = (rank, url) }
            }
        }
        if let best { return VideoPlayback(url: best.url, title: title, poster: cover) }
        throw SourceError.videoUnavailable
    }

    func collections(for item: ReadingItem) async throws -> [ReadingCollection] {
        let url = URL(string: "https://api.zhihu.com/collections/contents/\(item.kind.rawValue)/\(item.id)?limit=50")!
        let json = try await request(url)
        return objects(json).compactMap { object in
            guard let id = identifier(object["id"]), let title = object["title"] as? String else { return nil }
            return ReadingCollection(id: id, title: title, isFavorited: object["is_favorited"] as? Bool ?? false)
        }
    }

    func setCollection(_ collection: ReadingCollection, for item: ReadingItem, add: Bool) async throws {
        let url = URL(string: "https://api.zhihu.com/collections/contents/\(item.kind.rawValue)/\(item.id)")!
        _ = try await request(url, method: "PUT", form: [add ? "add_collections" : "remove_collections": collection.id])
    }

    func comments(_ item: ReadingItem, next: URL? = nil) async throws -> Page<ReadingComment> {
        let category = item.kind == .article ? "articles" : "answers"
        let json = try await request(next ?? url("/api/v4/\(category)/\(item.id)/root_comments", [
            .init(name: "limit", value: "20"), .init(name: "order", value: "normal"), .init(name: "status", value: "open")
        ]))
        let entries = parseReadingComments(objects(json))
        return Page(items: entries, next: nextURL(json))
    }

    func replies(to comment: ReadingComment, next: URL?) async throws -> Page<ReadingComment> {
        let json = try await request(next ?? url("/api/v4/comment_v5/comment/\(comment.id)/child_comment", [
            .init(name: "limit", value: "20"), .init(name: "order", value: "normal")
        ]))
        return Page(items: parseReadingComments(objects(json), depth: comment.depth + 1, parentAuthor: comment.author, parentID: comment.id), next: nextURL(json))
    }

    private func objects(_ json: [String: Any]) -> [[String: Any]] { json["data"] as? [[String: Any]] ?? [] }
    private func nextURL(_ json: [String: Any]) -> URL? {
        let paging = json["paging"] as? [String: Any] ?? [:]
        guard !(paging["is_end"] as? Bool ?? true), let next = paging["next"] as? String else { return nil }
        return URL(string: next)
    }
    private func identifier(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private func parseFeed(_ entry: [String: Any]) -> ReadingItem? {
        let target = entry["target"] as? [String: Any] ?? entry
        return parseObject(target, fallbackQuestionID: nil)
    }
    private func parseObject(_ object: [String: Any], fallbackQuestionID: String?) -> ReadingItem? {
        guard let id = identifier(object["id"]) else { return nil }
        let question = object["question"] as? [String: Any] ?? [:]
        let author = object["author"] as? [String: Any] ?? [:]
        let rawType = object["type"] as? String ?? (object["answer_count"] != nil ? "question" : "")
        guard let kind = ReadingItem.Kind(rawValue: rawType) else { return nil }
        let title = object["title"] as? String ?? question["title"] as? String ?? "回答"
        let excerpt = object["excerpt"] as? String ?? object["excerpt_new"] as? String ?? object["content"] as? String ?? ""
        var item = ReadingItem(id: id, kind: kind, title: title, excerpt: excerpt, author: author["name"] as? String ?? "", questionID: identifier(question["id"]) ?? fallbackQuestionID)
        item.avatarURL = mediaURL(author["avatar_url"])
        item.authorHeadline = author["headline"] as? String
        item.authorToken = author["url_token"] as? String
        item.ipInfo = object["ip_info"] as? String
        item.contentHTML = object["content"] as? String
        item.upCount = object["voteup_count"] as? Int
        item.downCount = object["votedown_count"] as? Int
        item.commentCount = object["comment_count"] as? Int
        item.vote = answerVote(from: object)
        item.imageURL = mediaURL(object["thumbnail"]) ?? mediaURL(object["image_url"]) ?? firstHTMLImage(object["content"] as? String ?? "")
        return item
    }
}

func parseReadingComments(_ entries: [[String: Any]], depth: Int = 0, parentAuthor: String? = nil, parentID: String? = nil) -> [ReadingComment] {
    entries.flatMap { entry -> [ReadingComment] in
        guard let rawID = entry["id"], let id = (rawID as? String) ?? (rawID as? NSNumber)?.stringValue else { return [] }
        func member(_ value: Any?) -> [String: Any] {
            let object = value as? [String: Any] ?? [:]
            return object["member"] as? [String: Any] ?? object
        }
        let author = member(entry["author"])
        let name = author["name"] as? String ?? "知乎用户"
        let reply = member(entry["reply_to_author"] ?? entry["reply_to"])
        var comment = ReadingComment(id: id, author: name, html: entry["content"] as? String ?? "", likes: entry["vote_count"] as? Int ?? 0)
        comment.avatarURL = mediaURL(author["avatar_url"])
        comment.replyTo = (reply["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parentAuthor
        comment.depth = depth
        let rawParent = entry["reply_to_comment_id"] ?? entry["parent_comment_id"] ?? entry["in_reply_to_comment_id"]
        let explicitParent = (rawParent as? String) ?? (rawParent as? NSNumber)?.stringValue
        comment.parentID = explicitParent.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } ?? parentID
        if let tags = entry["comment_tag"] as? [[String: Any]],
           let ip = tags.first(where: { $0["type"] as? String == "ip_info" })?["text"] as? String,
           !ip.isEmpty {
            comment.ipInfo = ip
        }
        let children = entry["child_comments"] as? [[String: Any]] ?? []
        comment.replyCount = entry["child_comment_count"] as? Int ?? entry["reply_count"] as? Int ?? children.count
        return [comment] + parseReadingComments(children, depth: depth + 1, parentAuthor: name, parentID: id)
    }
}

struct CommentTreeRow: Identifiable {
    let comment: ReadingComment
    let depth: Int
    let hasChildren: Bool
    var id: String { comment.id }
}

// Only link comments when the source supplies a parent ID; unresolved parents stay visible.
func commentTreeRows(_ comments: [ReadingComment], collapsed: Set<String>) -> [CommentTreeRow] {
    var unique: [ReadingComment] = []
    var seen = Set<String>()
    for comment in comments where seen.insert(comment.id).inserted { unique.append(comment) }
    let ids = Set(unique.map(\.id))
    var children: [String: [ReadingComment]] = [:]
    var roots: [ReadingComment] = []
    for comment in unique {
        if let parent = comment.parentID, parent != comment.id, ids.contains(parent) {
            children[parent, default: []].append(comment)
        } else { roots.append(comment) }
    }
    var result: [CommentTreeRow] = []
    var visited = Set<String>()
    func append(_ comment: ReadingComment, depth: Int) {
        guard visited.insert(comment.id).inserted else { return }
        let descendants = children[comment.id] ?? []
        result.append(CommentTreeRow(comment: comment, depth: depth, hasChildren: !descendants.isEmpty))
        if !collapsed.contains(comment.id) { for child in descendants { append(child, depth: depth + 1) } }
    }
    for root in roots { append(root, depth: 0) }
    // Cyclic or malformed parent references must never make comments disappear.
    for comment in unique where !visited.contains(comment.id) && !collapsed.contains(comment.parentID ?? "") {
        var ancestor = comment.parentID
        var chain = Set<String>()
        while let id = ancestor, chain.insert(id).inserted {
            if collapsed.contains(id) { break }
            ancestor = unique.first(where: { $0.id == id })?.parentID
        }
        if ancestor == nil || (ancestor != nil && !collapsed.contains(ancestor!)) { append(comment, depth: 0) }
    }
    return result
}

func answerVote(from object: [String: Any]) -> AnswerVote? {
    parseVote(object["voting"]) ?? parseVote((object["relationship"] as? [String: Any])?["voting"])
}

private func parseVote(_ value: Any?) -> AnswerVote? {
    if let number = value as? Int {
        switch number { case 1: return .up; case -1: return .down; case 0: return .neutral; default: return nil }
    }
    if let string = value as? String {
        switch string { case "up", "1": return .up; case "down", "-1": return .down; case "neutral", "0": return .neutral; default: return nil }
    }
    return nil
}

private func mediaURL(_ value: Any?) -> URL? {
    guard let value = value as? String, let url = URL(string: value), url.scheme == "https" else { return nil }
    return url
}

// Zhihu often puts the original image (including GIFs) in a lazy-load attribute.
func htmlImageSources(_ html: String) -> [String] {
    let tags = try? NSRegularExpression(pattern: #"(?i)<img\b[^>]*>"#)
    let range = NSRange(html.startIndex..., in: html)
    return (tags?.matches(in: html, range: range) ?? []).compactMap { match in
        guard let tagRange = Range(match.range, in: html) else { return nil }
        let tag = String(html[tagRange])
        for name in ["data-actualsrc", "data-original", "src"] {
            let pattern = #"(?i)(?:^|\s)"# + name + #"\s*=\s*["']([^"']+)["']"#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let found = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let valueRange = Range(found.range(at: 1), in: tag) else { continue }
            var value = String(tag[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
            if value.hasPrefix("//") { value = "https:" + value }
            if mediaURL(value) != nil { return value }
        }
        return nil
    }
}
func firstHTMLImage(_ html: String) -> URL? { htmlImageSources(html).first.flatMap { URL(string: $0) } }

enum CommentHTMLFragment {
    case text(String)
    case image(URL)
}

enum CommentTextFragment {
    case text(String)
    case emoji(label: String, url: URL)
}

// Common Zhihu emoticons are returned as literal placeholders in comment text.
// Load their images from Zhihu rather than bundling the artwork in the app.
private let commentEmojiURLs: [String: String] = [
    "感谢": "https://pic1.zhimg.com/v2-694cac2ec9f3c63f774e723f77d8c840.png",
    "哇": "https://picx.zhimg.com/v2-6a766571a6d6d3a4d8d16f433e5b284c.png",
    "打招呼": "https://picx.zhimg.com/v2-95c560d0c9c0491f6ef404cc010878fc.png",
    "握手": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_42.png",
    "知乎益蜂": "https://pica.zhimg.com/v2-11d9b8b6edaae71e992f95007c777446.png",
    "百分百赞": "https://picx.zhimg.com/v2-27521d5ba23dfc1ea58fd9ebb220e304.png",
    "为爱发乎": "https://pic1.zhimg.com/v2-609b1f168acfa22d59fa09d3cb0846ee.png",
    "脑爆": "https://pica.zhimg.com/v2-b6f53e9726998343e7713f564a422575.png",
    "暗中学习": "https://pica.zhimg.com/v2-5dc88b4f8cbc58d7597e2134a384e392.png",
    "匿了": "https://pic1.zhimg.com/v2-c1e799b8357888525ec45793e8270306.png",
    "谢邀": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_1.png",
    "赞同": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_2.png",
    "蹲": "https://pic4.zhimg.com/v2-66e5de3da039ac969d3b9d4dc5ef3536.png",
    "爱": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_3.png",
    "耶": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_13.png",
    "惊喜": "https://pic1.zhimg.com/v2-5c9b7521eb16507c9d2f747f3a32a813.png",
    "思考": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_6.png",
    "酷": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_7.png",
    "大笑": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_8.png",
    "微笑": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_9.png",
    "捂脸": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_10.png",
    "捂嘴": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_11.png",
    "飙泪笑": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_12.png",
    "害羞": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_4.png",
    "可怜": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_14.png",
    "好奇": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_5.png",
    "流泪": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_16.png",
    "大哭": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_17.png",
    "生气": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_18.png",
    "惊讶": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_19.png",
    "调皮": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_20.png",
    "衰": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_21.png",
    "发呆": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_22.png",
    "机智": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_23.png",
    "嘘": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_24.png",
    "尴尬": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_25.png",
    "小情绪": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_26.png",
    "为难": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_27.png",
    "吃瓜": "https://pic4.zhimg.com/v2-74ecc4b114fce67b6b42b7f602c3b1d6.png",
    "语塞": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_29.png",
    "看看你": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_30.png",
    "撇嘴": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_31.png",
    "魔性笑": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_32.png",
    "潜水": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_33.png",
    "口罩": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_34.png",
    "开心": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_35.png",
    "滑稽": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_36.png",
    "笑哭": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_37.png",
    "白眼": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_38.png",
    "红心": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_39.png",
    "柠檬": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_40.png",
    "拜托": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_41.png",
    "赞": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_43.png",
    "发火": "https://pic1.zhimg.com/v2-d5c0ed511a09bf5ceb633387178e0d30.png",
    "不抬杠": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_45.png",
    "种草": "https://cdn.jsdelivr.net/gh/Dao1023/zhihu-emoji@main/zhihu/emoji_46.png",
    "抱抱": "https://pic2.zhimg.com/v2-b2e3fa9e0b6f431bd18d4a9d5d3c6596.png",
    "doge": "https://pic4.zhimg.com/v2-501ff2e1fb7cf3f9326ec5348dc8d84f.png",
]

/// 表情图主地址不可用时使用的知乎 CDN 备用地址。
private let commentEmojiFallbackURLs: [String: String] = [
    "握手": "https://pic2.zhimg.com/v2-f5aa165e86b5c9ed3b7bee821da59365.png",
    "谢邀": "https://pic2.zhimg.com/v2-6fe2283baa639ae1d7c024487f1d68c7.png",
    "赞同": "https://pic2.zhimg.com/v2-419a1a3ed02b7cfadc20af558aabc897.png",
    "爱": "https://pic1.zhimg.com/v2-0942128ebfe78f000e84339fbb745611.png",
    "耶": "https://pic2.zhimg.com/v2-f3b3b8756af8b42bd3cb534cbfdbe741.png",
    "思考": "https://pic4.zhimg.com/v2-bffb2bf11422c5ef7d8949788114c2ab.png",
    "酷": "https://pic4.zhimg.com/v2-c96dd18b15beb196b2daba95d26d9b1c.png",
    "大笑": "https://pic1.zhimg.com/v2-3ac403672728e5e91f5b2d3c095e415a.png",
    "微笑": "https://pic1.zhimg.com/v2-3700cc07f14a49c6db94a82e989d4548.png",
    "捂脸": "https://pic1.zhimg.com/v2-b62e608e405aeb33cd52830218f561ea.png",
    "捂嘴": "https://pic4.zhimg.com/v2-0e26b4bbbd86a0b74543d7898fab9f6a.png",
    "飙泪笑": "https://pic4.zhimg.com/v2-3bb879be3497db9051c1953cdf98def6.png",
    "害羞": "https://pic4.zhimg.com/v2-52f8c87376792e927b6cf0896b726f06.png",
    "可怜": "https://pic1.zhimg.com/v2-aa15ce4a2bfe1ca54c8bb6cc3ea6627b.png",
    "好奇": "https://pic2.zhimg.com/v2-72b9696632f66e05faaca12f1f1e614b.png",
    "流泪": "https://pic4.zhimg.com/v2-dd613c7c81599bcc3085fc855c752950.png",
    "大哭": "https://pic1.zhimg.com/v2-41f74f3795489083630fa29fde6c1c4d.png",
    "生气": "https://pic4.zhimg.com/v2-6a976b21fd50b9535ab3e5b17c17adc7.png",
    "惊讶": "https://pic4.zhimg.com/v2-0d9811a7961c96d84ee6946692a37469.png",
    "调皮": "https://pic1.zhimg.com/v2-76c864a7fd5ddc110965657078812811.png",
    "衰": "https://pic1.zhimg.com/v2-d6d4d1689c2ce59e710aa40ab81c8f10.png",
    "发呆": "https://pic2.zhimg.com/v2-7f09d05d34f03eab99e820014c393070.png",
    "机智": "https://pic1.zhimg.com/v2-4e025a75f219cf79f6d1fda7726e297f.png",
    "嘘": "https://pic4.zhimg.com/v2-f80e1dc872d68d4f0b9ac76e8525d402.png",
    "尴尬": "https://pic3.zhimg.com/v2-b779f7eb3eac05cce39cc33e12774890.png",
    "小情绪": "https://pic1.zhimg.com/v2-c65aaaa25730c59f5097aca04e606d88.png",
    "为难": "https://pic1.zhimg.com/v2-132ab52908934f6c3cd9166e51b99f47.png",
    "语塞": "https://pic2.zhimg.com/v2-58e3ec448b58054fde642914ebb850f9.png",
    "看看你": "https://pic3.zhimg.com/v2-4e4870fc6e57bb76e7e5924375cb20b6.png",
    "撇嘴": "https://pic2.zhimg.com/v2-1043b00a7b5776e2e6e1b0af2ab7445d.png",
    "魔性笑": "https://pic2.zhimg.com/v2-e6270881e74c90fc01994e8cd072bd3a.png",
    "潜水": "https://pic1.zhimg.com/v2-99bb6a605b136b95e442f5b69efa2ccc.png",
    "口罩": "https://pic4.zhimg.com/v2-6551348276afd1eaf836551b93a94636.png",
    "开心": "https://pic2.zhimg.com/v2-c99cdc3629ff004f83ff44a952e5b716.png",
    "滑稽": "https://pic4.zhimg.com/v2-8a8f1403a93ddd0a458bed730bebe19b.png",
    "笑哭": "https://pic4.zhimg.com/v2-ca0015e8ed8462cfce839fba518df585.png",
    "白眼": "https://pic2.zhimg.com/v2-d4f78d92922632516769d3f2ce055324.png",
    "红心": "https://pic2.zhimg.com/v2-9ab384e3947547851cb45765e6fc1ea8.png",
    "柠檬": "https://pic4.zhimg.com/v2-a8f46a21217d58d2b4cdabc4568fde15.png",
    "拜托": "https://pic2.zhimg.com/v2-3e36d546a9454c8964fbc218f0db1ff8.png",
    "赞": "https://pic1.zhimg.com/v2-c71427010ca7866f9b08c37ec20672e0.png",
    "不抬杠": "https://pic4.zhimg.com/v2-395d272d5635143119b1dbc0b51e05e4.png",
    "种草": "https://pic2.zhimg.com/v2-cb191a92f1296e33308b2aa16f61bfb9.png",
]

enum CommentEmoji {
    static func url(for name: String) -> URL? {
        commentEmojiURLs[name].flatMap(URL.init(string:))
    }

    static func fallbackURL(for url: URL) -> URL? {
        commentEmojiFallbackURLs.first { $0.value == url.absoluteString }
            .flatMap { URL(string: $0.value) }
    }
}

func commentTextFragments(_ text: String) -> [CommentTextFragment] {
    guard let expression = try? NSRegularExpression(pattern: #"\[([^\[\]\n]{1,12})\]"#) else { return [.text(text)] }
    var result: [CommentTextFragment] = []
    var position = text.startIndex
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text),
              let value = commentEmojiURLs[String(text[nameRange])], let url = URL(string: value) else { continue }
        if position < range.lowerBound { result.append(.text(String(text[position..<range.lowerBound]))) }
        result.append(.emoji(label: String(text[range]), url: url))
        position = range.upperBound
    }
    if position < text.endIndex { result.append(.text(String(text[position...]))) }
    return result
}

// Preserve the source order and repeated images instead of collecting every image at the end.
func commentHTMLFragments(_ html: String) -> [CommentHTMLFragment] {
    guard let expression = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*>|<a\b[^>]*>.*?</a\s*>"#) else { return [.text(html)] }
    let matches = expression.matches(in: html, range: NSRange(html.startIndex..., in: html))
    var fragments: [CommentHTMLFragment] = []
    var position = html.startIndex
    for match in matches {
        guard let range = Range(match.range, in: html) else { continue }
        let tag = String(html[range])
        var imageURL = htmlImageSources(tag).first.flatMap(URL.init(string:))
        if imageURL == nil, tag.lowercased().hasPrefix("<a"),
           let href = try? NSRegularExpression(pattern: #"(?i)\bhref\s*=\s*["']([^"']+)["']"#),
           let match = href.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
           let valueRange = Range(match.range(at: 1), in: tag) {
            var value = String(tag[valueRange]).replacingOccurrences(of: "&amp;", with: "&")
            if value.hasPrefix("//") { value = "https:" + value }
            if let url = mediaURL(value), let host = url.host?.lowercased(),
               host == "zhimg.com" || host.hasSuffix(".zhimg.com"),
               tag.contains("图片") || tag.contains("动图") || tag.lowercased().contains("comment_img") || tag.lowercased().contains("comment_sticker") {
                imageURL = url
            }
        }
        guard let imageURL else { continue }
        if position < range.lowerBound { fragments.append(.text(String(html[position..<range.lowerBound]))) }
        fragments.append(.image(imageURL))
        position = range.upperBound
    }
    if position < html.endIndex { fragments.append(.text(String(html[position...]))) }
    return fragments
}

private func htmlTagAttribute(_ name: String, in tag: String) -> String? {
    let pattern = #"(?i)(?:^|\s)"# + name + #"\s*=\s*["']([^"']+)["']"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let found = expression.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
          let valueRange = Range(found.range(at: 1), in: tag) else { return nil }
    return String(tag[valueRange])
}

func expandedVideoHTML(_ html: String) -> String {
    guard let anchor = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*>.*?</a\s*>"#) else { return html }
    var result = html
    let matches = anchor.matches(in: result, range: NSRange(result.startIndex..., in: result))
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let tag = String(result[range])
        guard let reference = videoReference(fromHTMLTag: tag) else { continue }
        let poster = normalizedMediaURL(htmlTagAttribute("data-poster", in: tag))
            ?? normalizedMediaURL(htmlImageSources(tag).first)
        let title = (htmlTagAttribute("data-name", in: tag) ?? htmlTagAttribute("data-video-title", in: tag))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let posterHTML = poster.map {
            "<img class=\"wize-video-poster\" loading=\"lazy\" decoding=\"async\" src=\"\(htmlEscapeAttribute($0.absoluteString))\" alt=\"\">"
        } ?? ""
        let titleHTML: String
        if let title, !title.isEmpty {
            let escaped = htmlEscapeAttribute(title)
            titleHTML = "<span class=\"wize-video-title\">\(escaped)</span>"
        } else {
            titleHTML = ""
        }
        let card = """
        <div class="wize-video" role="button" aria-label="播放视频" data-wize-video="\(htmlEscapeAttribute(reference.id))" data-wize-video-kind="\(reference.kind.rawValue)" data-wize-poster="\(htmlEscapeAttribute(poster?.absoluteString ?? ""))">\(posterHTML)<span class="wize-video-play"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6.4v11.2l9-5.6z"/></svg></span>\(titleHTML)</div>
        """
        result.replaceSubrange(range, with: card)
    }
    return result
}

func videoReference(fromHTMLTag tag: String) -> VideoReference? {
    if let raw = htmlTagAttribute("data-lens-id", in: tag), let id = videoDigits(raw) {
        return VideoReference(id: id, kind: .lens)
    }
    if let raw = htmlTagAttribute("data-zvideo-id", in: tag), let id = videoDigits(raw) {
        return VideoReference(id: id, kind: .zvideo)
    }
    if let raw = htmlTagAttribute("data-video-id", in: tag), let id = videoDigits(raw) {
        let isZVideo = tag.lowercased().contains("zvideo")
        return VideoReference(id: id, kind: isZVideo ? .zvideo : .lens)
    }
    guard let raw = htmlTagAttribute("href", in: tag) else { return nil }
    var value = raw.replacingOccurrences(of: "&amp;", with: "&")
    if let components = URLComponents(string: value),
       let target = components.queryItems?.first(where: { $0.name == "target" })?.value {
        value = target
    }
    if value.hasPrefix("//") { value = "https:" + value }
    guard let url = URL(string: value) else { return nil }
    let path = url.path.lowercased()
    let patterns = [
        ("lens", #"/videos?/(\d+)"#),
        ("zvideo", #"/zvideos?/(\d+)"#)
    ]
    for (kind, pattern) in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let idRange = Range(match.range(at: 1), in: path) else { continue }
        let id = String(path[idRange])
        return VideoReference(id: id, kind: kind == "zvideo" ? .zvideo : .lens)
    }
    if url.host?.lowercased() == "lens.zhihu.com" {
        let components = path.split(separator: "/")
        if let id = components.last, id.allSatisfy(\.isNumber), !id.isEmpty {
            return VideoReference(id: String(id), kind: .lens)
        }
    }
    return nil
}

private func videoDigits(_ value: String) -> String? {
    let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !digits.isEmpty && digits.allSatisfy(\.isNumber) ? digits : nil
}

private func normalizedMediaURL(_ value: String?) -> URL? {
    guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    value = value.replacingOccurrences(of: "&amp;", with: "&")
    if value.hasPrefix("//") { value = "https:" + value }
    return mediaURL(value)
}

private func htmlEscapeAttribute(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func expandedImageHTML(_ html: String) -> String {
    // Zhihu often wraps images in links to the full-size asset. The reader has
    // its own tap-to-preview gesture, so unwrap those links first to avoid the
    // web view also navigating while the preview opens.
    var result = unwrapImageLinks(html)
    guard let regex = try? NSRegularExpression(pattern: #"(?i)<img\b[^>]*>"#) else { return result }
    let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let tag = String(result[range])
        guard let url = htmlImageSources(tag).first else { continue }
        let escaped = url.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let newTag = tag.replacingOccurrences(of: #"(?i)(?:^|\s)src\s*=\s*["'][^"']*["']"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(?:^|\s)loading\s*=\s*["'][^"']*["']"#, with: "", options: .regularExpression)
        var attributes = "loading=\"lazy\" decoding=\"async\" src=\"\(escaped)\""
        if htmlTagAttribute("width", in: newTag) == nil, htmlTagAttribute("height", in: newTag) == nil,
           let rawWidth = htmlTagAttribute("data-rawwidth", in: tag).flatMap(Int.init), rawWidth > 0,
           let rawHeight = htmlTagAttribute("data-rawheight", in: tag).flatMap(Int.init), rawHeight > 0 {
            attributes += " width=\"\(rawWidth)\" height=\"\(rawHeight)\""
        }
        result.replaceSubrange(range, with: newTag.replacingOccurrences(of: "<img", with: "<img \(attributes)", options: .caseInsensitive))
    }
    return result
}

private func unwrapImageLinks(_ html: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"(?is)<a\b[^>]*>(.*?)</a\s*>"#) else { return html }
    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
    var result = html
    for match in matches.reversed() {
        guard let whole = Range(match.range, in: result),
              let innerRange = Range(match.range(at: 1), in: html) else { continue }
        let inner = String(html[innerRange])
        guard inner.range(of: "<img", options: .caseInsensitive) != nil else { continue }
        result.replaceSubrange(whole, with: inner)
    }
    return result
}
