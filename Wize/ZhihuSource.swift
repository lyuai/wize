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

struct ReadingComment: Identifiable {
    let id: String
    let author: String
    let html: String
    let likes: Int
    var avatarURL: URL? = nil
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
    case response(Int), malformed, unsupported, voteUnconfirmed
    var errorDescription: String? {
        switch self {
        case .response(401), .response(403): return "知乎要求登录或安全验证，请先登录后重试。"
        case .response(let code): return "知乎返回错误（\(code)），请稍后重试。"
        case .malformed: return "无法读取知乎返回的数据。"
        case .unsupported: return "暂不支持此类型的内容。"
        case .voteUnconfirmed: return "无法确认知乎的赞同状态，请稍后重试。"
        }
    }
}

// The reader depends on this small interface so additional sources can supply the same capabilities.
@MainActor
protocol ReadingSource {
    func feed(hot: Bool, next: URL?) async throws -> Page<ReadingItem>
    func currentUser() async throws -> (name: String, avatar: URL?, headline: String?)
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

    func currentUser() async throws -> (name: String, avatar: URL?, headline: String?) {
        let json = try await request(url("/api/v4/me", [.init(name: "include", value: "avatar_url,name,headline")]))
        guard let name = json["name"] as? String, !name.isEmpty else { throw SourceError.malformed }
        return (name, mediaURL(json["avatar_url"]), json["headline"] as? String)
    }

    func answers(questionID: String, sort: String, offset: Int) async throws -> Page<ReadingItem> {
        let json = try await request(url("/api/v4/questions/\(questionID)/answers", [
            .init(name: "include", value: "data[*].content,voteup_count,votedown_count,comment_count,voting,relationship.voting,author,question"),
            .init(name: "sort_by", value: sort), .init(name: "offset", value: String(offset)), .init(name: "limit", value: "20")
        ]))
        return Page(items: objects(json).compactMap { parseObject($0, fallbackQuestionID: questionID) }, next: nextURL(json))
    }

    func detail(_ item: ReadingItem, prefetch: Bool = false) async throws -> ReadingItem {
        let path = item.kind == .article ? "/api/v4/articles/\(item.id)" : "/api/v4/answers/\(item.id)"
        let json = try await request(url(path, [.init(name: "include", value: "content,author,question,voteup_count,votedown_count,comment_count,voting,relationship.voting")]), prefetch: prefetch)
        guard let content = json["content"] as? String, !content.isEmpty else { throw SourceError.malformed }
        var updated = item
        updated.contentHTML = content
        if let author = json["author"] as? [String: Any] {
            updated.avatarURL = mediaURL(author["avatar_url"]) ?? item.avatarURL
            updated.authorHeadline = author["headline"] as? String ?? item.authorHeadline
            updated.authorToken = author["url_token"] as? String ?? item.authorToken
        }
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
    "感谢": "https://pic1.zhimg.com/v2-e39d5eebfef8b0ac6065ad156cb05e66.png",
    "捂脸": "https://pic1.zhimg.com/v2-b62e608e405aeb33cd52830218f561ea.png",
    "谢邀": "https://pic2.zhimg.com/v2-6fe2283baa639ae1d7c024487f1d68c7.png",
    "赞同": "https://pic2.zhimg.com/v2-419a1a3ed02b7cfadc20af558aabc897.png",
    "微笑": "https://pic1.zhimg.com/v2-3700cc07f14a49c6db94a82e989d4548.png",
    "大笑": "https://pic1.zhimg.com/v2-3ac403672728e5e91f5b2d3c095e415a.png",
    "笑哭": "https://pic4.zhimg.com/v2-ca0015e8ed8462cfce839fba518df585.png",
    "思考": "https://pic4.zhimg.com/v2-bffb2bf11422c5ef7d8949788114c2ab.png",
    "吃瓜": "https://pic4.zhimg.com/v2-74ecc4b114fce67b6b42b7f602c3b1d6.png",
    "好奇": "https://pic2.zhimg.com/v2-72b9696632f66e05faaca12f1f1e614b.png",
    "流泪": "https://pic4.zhimg.com/v2-dd613c7c81599bcc3085fc855c752950.png",
    "抱抱": "https://pic2.zhimg.com/v2-b2e3fa9e0b6f431bd18d4a9d5d3c6596.png"
]

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

func expandedImageHTML(_ html: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"(?i)<img\b[^>]*>"#) else { return html }
    var result = html
    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let tag = String(result[range])
        guard let url = htmlImageSources(tag).first else { continue }
        let escaped = url.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        let newTag = tag.replacingOccurrences(of: #"(?i)(?:^|\s)src\s*=\s*["'][^"']*["']"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(?:^|\s)loading\s*=\s*["'][^"']*["']"#, with: "", options: .regularExpression)
        result.replaceSubrange(range, with: newTag.replacingOccurrences(of: "<img", with: "<img loading=\"lazy\" src=\"\(escaped)\"", options: .caseInsensitive))
    }
    return result
}
