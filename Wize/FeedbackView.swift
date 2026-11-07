import Darwin
import PhotosUI
import SwiftUI
import UIKit

/// 反馈提交时可选附带的上下文信息（表单里可以关闭）。
struct FeedbackContext: Equatable {
    var accountName: String?
    var accountHeadline: String?
    var accountToken: String?
    var readingFontSize: Int?
    var readingLineHeight: Double?
    var readingWidth: Int?
    var readingFont: String?
    var readingTheme: String?
}

/// 问题反馈与建议：文本 + 可选图片附件 + 可选邮箱，直接提交到项目仓库的 Issues。
struct FeedbackView: View {
    var context: FeedbackContext = FeedbackContext()
    var onSubmitted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var email = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var attachments: [UIImage] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var includesContext = true
    @FocusState private var focusedField: Field?

    private enum Field { case message, email }

    private let sage = Color(red: 0.30, green: 0.41, blue: 0.36)
    private let maxMessageLength = 4000

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedMessage.isEmpty && !isSubmitting }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if message.isEmpty {
                            Text("描述你遇到的问题，或想建议的改进……")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $message)
                            .focused($focusedField, equals: .message)
                            .frame(minHeight: 150)
                    }
                } header: {
                    Text("内容")
                } footer: {
                    if message.count > maxMessageLength {
                        Text("内容过长，请精简到 \(maxMessageLength) 字以内。")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("name@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                } header: {
                    Text("邮箱（可选）")
                } footer: {
                    Text("留一个邮箱，处理完成后我们会发邮件告知。")
                }

                Section {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 3, matching: .images) {
                        Label("添加图片", systemImage: "photo.badge.plus")
                    }
                    .onChange(of: pickerItems) { _, items in
                        Task { await loadAttachments(items) }
                    }
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Array(attachments.enumerated()), id: \.offset) { index, image in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 84, height: 84)
                                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        Button {
                                            removeAttachment(at: index)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 18))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.55))
                                        }
                                        .buttonStyle(.plain)
                                        .offset(x: 6, y: -6)
                                        .accessibilityLabel("移除附件 \(index + 1)")
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.trailing, 8)
                        }
                    }
                } header: {
                    Text("附件（可选）")
                } footer: {
                    Text("最多 3 张图片，例如截图。")
                }

                Section {
                    Toggle("附带账号与设备信息", isOn: $includesContext)
                } footer: {
                    Text(includesContext
                         ? "会附带当前登录的知乎账号、阅读设置、应用版本与设备信息；不包含密码、Cookie 或阅读记录。"
                         : "只提交你填写的内容与附件。")
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(isSubmitting ? "正在提交" : "提交")
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit || message.count > maxMessageLength)
                } footer: {
                    Text("提交时会附带应用版本与设备信息，可在上方关闭。")
                }
            }
            .navigationTitle("问题反馈与建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("提交失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .tint(sage)
        }
        .presentationDetents([.large])
    }

    @MainActor
    private func submit() async {
        focusedField = nil
        guard !trimmedMessage.isEmpty else { return }
        guard message.count <= maxMessageLength else {
            errorMessage = "内容过长，请精简后再试。"
            return
        }
        if !trimmedEmail.isEmpty, !Self.isValidEmail(trimmedEmail) {
            errorMessage = "邮箱格式看起来不正确，可以留空或检查一下。"
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await FeedbackSender.submit(
                message: trimmedMessage,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                attachments: attachments,
                context: includesContext ? context : nil
            )
            onSubmitted()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "提交失败，请稍后再试。"
        }
    }

    @MainActor
    private func loadAttachments(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                images.append(image)
            }
        }
        attachments = Array(images.prefix(3))
    }

    private func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
        if pickerItems.indices.contains(index) {
            pickerItems.remove(at: index)
        }
    }

    private static func isValidEmail(_ value: String) -> Bool {
        let pattern = #"^[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

struct FeedbackThanksView: View {
    var name: String? = nil
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var finished = false
    @State private var burst = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.21, green: 0.30, blue: 0.26),
                         Color(red: 0.36, green: 0.47, blue: 0.40)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 0.9 : 0)

            ThanksRings(appeared: appeared, reduceMotion: reduceMotion)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.95, blue: 0.90))
                        .frame(width: 132, height: 132)
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
                    Circle()
                        .strokeBorder(Color(red: 0.30, green: 0.41, blue: 0.36).opacity(0.22), lineWidth: 1)
                        .frame(width: 104, height: 104)
                    Image(systemName: "checkmark")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(Color(red: 0.25, green: 0.36, blue: 0.30))
                        .scaleEffect(appeared ? 1 : 0.5)
                        .opacity(appeared ? 1 : 0)
                        .animation(reduceMotion ? .easeOut(duration: 0.2)
                                                 : .spring(response: 0.5, dampingFraction: 0.62),
                                   value: appeared)
                }
                .scaleEffect(appeared ? 1 : 0.72)
                .animation(reduceMotion ? .easeOut(duration: 0.25)
                                         : .spring(response: 0.52, dampingFraction: 0.7),
                           value: appeared)

                VStack(spacing: 10) {
                    Text(thanksTitle)
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text("每一条建议，都会让这里更安静一点。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color(red: 0.98, green: 0.97, blue: 0.93))
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.easeOut(duration: 0.5).delay(0.12), value: appeared)
            }
            .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.21, green: 0.30, blue: 0.26).ignoresSafeArea())
        .statusBarHidden()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task {
            burst += 1
            withAnimation(reduceMotion ? .easeOut(duration: 0.25)
                                        : .spring(response: 0.55, dampingFraction: 0.74)) {
                appeared = true
            }
            try? await Task.sleep(for: .seconds(reduceMotion ? 1.4 : 2.6))
            guard !Task.isCancelled else { return }
            finish()
        }
        .sensoryFeedback(.success, trigger: burst)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(thanksTitle)
    }

    private var thanksTitle: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "谢谢你的反馈" : "谢谢你的反馈，\(trimmed)"
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}

private struct ThanksRings: View {
    let appeared: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: 150, height: 150)
                        .scaleEffect(appeared ? 1.5 + CGFloat(index) * 0.36 : 0.62)
                        .opacity(appeared ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.5).delay(Double(index) * 0.1), value: appeared)
                }
                ForEach(0..<9, id: \.self) { index in
                    let angle = Double(index) / 9 * .pi * 2 - .pi / 2
                    Circle()
                        .fill(Color(red: 0.96, green: 0.95, blue: 0.90).opacity(index.isMultiple(of: 2) ? 0.85 : 0.5))
                        .frame(width: index.isMultiple(of: 2) ? 5 : 3,
                               height: index.isMultiple(of: 2) ? 5 : 3)
                        .offset(x: appeared ? cos(angle) * 118 : 0,
                                y: appeared ? sin(angle) * 118 : 0)
                        .scaleEffect(appeared ? 0.2 : 1)
                        .opacity(appeared ? 0 : 1)
                        .animation(.easeOut(duration: 1.15).delay(0.05), value: appeared)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 把反馈直接提交到仓库 Issues。失败时给出可恢复的通用提示，不暴露仓库信息。
enum FeedbackSender {
    @MainActor
    static func submit(message: String, email: String?, attachments: [UIImage], context: FeedbackContext?) async throws {
        guard AppInfo.isFeedbackConfigured else { throw FeedbackError.notConfigured }

        var attachmentLinks: [String] = []
        for (index, image) in attachments.prefix(3).enumerated() {
            guard let data = compressedJPEG(image) else { continue }
            let fileName = "feedback-\(Self.fileTimestamp())-\(index + 1)-\(UUID().uuidString.prefix(6)).jpg"
            if let url = try await upload(data: data, fileName: String(fileName)) {
                attachmentLinks.append(url)
            }
        }

        let device = "\(deviceModelIdentifier()) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let body = issueBody(
            message: message,
            email: email,
            attachmentLinks: attachmentLinks,
            context: context,
            device: device
        )
        try await createIssue(title: issueTitle(for: message), body: body)
    }

    // MARK: - GitHub API

    private static func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.github.com/repos/\(AppInfo.githubRepository)/\(path)") else {
            throw FeedbackError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 40
        request.setValue("Bearer \(AppInfo.githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Wize/Feedback", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func upload(data: Data, fileName: String) async throws -> String? {
        var request = try makeRequest(path: "contents/feedback/\(fileName)", method: "PUT")
        let payload: [String: Any] = [
            "message": "Add feedback attachment",
            "content": data.base64EncodedString()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (responseData, response) = try await sessionData(for: request)
        try validate(responseData, response)
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let content = object["content"] as? [String: Any],
              let url = content["download_url"] as? String else {
            return nil
        }
        return url
    }

    private static func createIssue(title: String, body: String) async throws {
        var request = try makeRequest(path: "issues", method: "POST")
        let payload: [String: Any] = ["title": title, "body": body]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (responseData, response) = try await sessionData(for: request)
        try validate(responseData, response)
    }

    private static func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw FeedbackError.network
        }
    }

    private static func validate(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw FeedbackError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedbackError.server(http.statusCode)
        }
    }

    // MARK: - 内容组装

    private static func issueTitle(for message: String) -> String {
        let firstLine = message
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = firstLine.isEmpty ? "问题反馈与建议" : firstLine
        return "反馈：" + String(summary.prefix(48))
    }

    private static func issueBody(
        message: String,
        email: String?,
        attachmentLinks: [String],
        context: FeedbackContext?,
        device: String
    ) -> String {
        var sections: [String] = [message]
        var meta: [String] = []
        if let email, !email.isEmpty {
            meta.append("**联系邮箱**：\(email)")
        }
        if !attachmentLinks.isEmpty {
            let images = attachmentLinks.enumerated()
                .map { "![附件 \($0.offset + 1)](\($0.element))" }
                .joined(separator: "\n")
            meta.append("**附件**：\n\(images)")
        }
        if !meta.isEmpty {
            sections.append(meta.joined(separator: "\n\n"))
        }

        if let context {
            var lines: [String] = []
            if let name = context.accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                var account = "- 知乎账号：\(name)"
                if let token = context.accountToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                    account += "（https://www.zhihu.com/people/\(token)）"
                }
                lines.append(account)
                if let headline = context.accountHeadline?.trimmingCharacters(in: .whitespacesAndNewlines), !headline.isEmpty {
                    lines.append("- 账号简介：\(headline)")
                }
            } else {
                lines.append("- 知乎账号：未登录")
            }
            if let reading = readingSettingsSummary(context) {
                lines.append("- 阅读设置：\(reading)")
            }
            lines.append("- 设备：\(device)")
            lines.append("- 应用：无知 \(AppInfo.versionDisplay)（发布于 \(AppInfo.releaseDate)）")
            lines.append("- 语言/时区：\(Locale.current.identifier) / \(TimeZone.current.identifier)")
            lines.append("- 提交时间：\(displayTimestamp())")
            sections.append("**提交者信息**\n\n" + lines.joined(separator: "\n"))
        } else {
            sections.append("""
            <details><summary>环境信息</summary>

            - 无知 \(AppInfo.versionDisplay)
            - 提交时间：\(displayTimestamp())

            </details>
            """)
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    private static func readingSettingsSummary(_ context: FeedbackContext) -> String? {
        var parts: [String] = []
        if let size = context.readingFontSize { parts.append("字号 \(size)") }
        if let lineHeight = context.readingLineHeight { parts.append("行距 \(String(format: "%.1f", lineHeight))") }
        if let width = context.readingWidth { parts.append("行宽 \(width)") }
        if let font = context.readingFont {
            parts.append("字体 \(ReadingFontOption.option(for: font).title)")
        }
        if let theme = context.readingTheme {
            let names = ["system": "跟随系统", "light": "明亮", "paper": "纸色", "dark": "深色"]
            parts.append("配色 \(names[theme] ?? theme)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private static func deviceModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var identifier = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { continue }
            identifier.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    // MARK: - 图片与时间

    private static func compressedJPEG(_ image: UIImage, maxDimension: CGFloat = 1600) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func displayTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

enum FeedbackError: LocalizedError {
    case notConfigured
    case invalidResponse
    case server(Int)
    case network

    var errorDescription: String? {
        switch self {
        case .notConfigured, .invalidResponse, .server:
            return "提交失败，请稍后再试。"
        case .network:
            return "网络不太顺畅，请稍后再试。"
        }
    }
}
