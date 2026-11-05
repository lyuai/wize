import SwiftUI

/// 构建信息：版本号、构建号、发布日期与反馈通道配置（来自 Info.plist）。
enum AppInfo {
    static var displayName: String { "无知" }

    private static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var version: String { string("CFBundleShortVersionString") }
    static var build: String { string("CFBundleVersion") }

    static var versionDisplay: String {
        guard !version.isEmpty else { return "—" }
        return build.isEmpty ? version : "\(version)（\(build)）"
    }

    static var releaseDate: String {
        let raw = string("WizeReleaseDate")
        return raw.isEmpty ? "—" : raw
    }

    static var githubRepository: String { string("WizeGitHubRepo") }
    static var githubToken: String { string("WizeGitHubToken") }

    /// 反馈通道是否已配置。未配置时 App 内提交会给出可恢复的失败提示。
    static var isFeedbackConfigured: Bool {
        !githubRepository.isEmpty && !githubToken.isEmpty && !githubToken.hasPrefix("$(")
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let sage = Color(red: 0.30, green: 0.41, blue: 0.36)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image("AboutLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                        .padding(.top, 28)
                        .accessibilityLabel("无知应用图标")

                    VStack(spacing: 4) {
                        Text(AppInfo.displayName)
                            .font(.title2.weight(.semibold))
                        Text("一个安静的阅读器")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        infoRow("版本", value: AppInfo.versionDisplay)
                        Divider().padding(.leading, 16)
                        infoRow("发布时间", value: AppInfo.releaseDate)
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    Text("代码以 MIT 许可发布；书法图标的来源与再使用限制见 Design/README.md。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .tint(sage)
        }
        .presentationDetents([.medium, .large])
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
