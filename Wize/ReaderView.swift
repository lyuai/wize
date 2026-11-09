import SwiftUI
import WebKit
import SafariServices
import LinkPresentation
import Social

/// The answer at the reading focus. It is deliberately separate from
/// `ReaderModel.selected`: scrolling across answer boundaries should refresh the
/// floating actions, not rebuild the whole reading screen.
@MainActor
final class ReadingFocus: ObservableObject {
    @Published var item: ReadingItem?
}

/// Whether the reading chrome (reading settings / account) is showing. Kept in its
/// own store so hiding it while scrolling never rebuilds the reading screen.
@MainActor
final class ReadingChrome: ObservableObject {
    @Published var showsControls = true
    /// Single-line question title, shown only after the large title has left the page.
    @Published var showsCompactTitle = false
}

struct ReaderView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var phonePath: [PhonePage] = []
    @State private var availableWidth: CGFloat = ReaderWindowMetrics.width
    @State private var chrome = ReadingChrome()
    @State private var showsReadingSettings = false
    @State private var showsAccountMenu = false
    @State private var showsAbout = false
    @State private var showsFeedback = false
    @State private var feedbackSubmitted = false
    @State private var showsFeedbackThanks = false
    @State private var accountDestination: AccountDestination?
    @State private var profileItem: ReadingItem?
    @State private var collectionItem: ReadingItem?
    @State private var webLink: ReaderWebLink?
    @State private var imageMenu: ReaderImageMenuTarget?
    @State private var imageNotice: String?
    @State private var collectedKeys: Set<String> = []
    @State private var readKeys: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "reading.readKeys") ?? [])
    @State private var readingOffset: CGFloat = 0
    @State private var readingOffsetAnchor = ""
    // A reference type kept in @State on purpose: `@StateObject` would make this
    // screen observe every reading-focus change and bring the per-switch rebuild
    // back. Only the floating actions observe the store.
    @State private var focus = ReadingFocus()
    @State private var collapsedComments: Set<String> = []
    private let collectionSource = ZhihuSource()
    @AppStorage("reading.theme") private var readingTheme = "system"
    enum PhonePage: Hashable { case question, answer }
    private enum AccountDestination { case settings, login, about, feedback }

    private var usesWideLayout: Bool {
        // 744pt is iPad mini portrait, a normal full-screen width, so it stays
        // two columns. Only a genuinely narrow window falls back to one column.
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular && availableWidth >= 700
    }

    private func markRead(_ item: ReadingItem?) {
        guard let key = item?.key, !key.isEmpty else { return }
        guard readKeys.insert(key).inserted else { return }
        var stored = UserDefaults.standard.stringArray(forKey: "reading.readKeys") ?? []
        stored.removeAll { $0 == key }
        stored.append(key)
        if stored.count > 300 { stored.removeFirst(stored.count - 300) }
        UserDefaults.standard.set(stored, forKey: "reading.readKeys")
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if usesWideLayout { wideLayout } else { phoneLayout }
            }
            .onAppear { availableWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { availableWidth = $0 }
        }
        .tint(ReaderPalette.accent)
        .sheet(isPresented: $model.showsLogin, onDismiss: model.resetAfterLogin) {
            LoginView(model: model, onOpenProfile: { item in
                model.showsLogin = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    profileItem = item
                }
            })
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showsReadingSettings) { ReadingSettingsView() }
        .sheet(isPresented: $showsAbout) { AboutView() }
        .sheet(isPresented: $showsFeedback, onDismiss: {
            if feedbackSubmitted {
                feedbackSubmitted = false
                showsFeedbackThanks = true
            }
        }) {
            FeedbackView(context: feedbackContext, onSubmitted: { feedbackSubmitted = true })
        }
        .fullScreenCover(isPresented: $showsFeedbackThanks) {
            FeedbackThanksView(name: model.accountName) { showsFeedbackThanks = false }
        }
        .sheet(item: $profileItem) { AuthorProfileView(item: $0) }
        .sheet(item: $webLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .sheet(item: $collectionItem) { item in
            CollectionPickerView(item: item) { saved in
                if saved { collectedKeys.insert(item.key) } else { collectedKeys.remove(item.key) }
            }
        }
        .task { async let account: Void = model.loadAccount(); await model.loadFeed(); selectInitialContentIfNeeded(); await account }
        .task { await CommentEmojiLoader.shared.preloadAll() }
        .task(id: model.selected?.key) {
            guard let item = model.selected else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled, model.selected?.key == item.key else { return }
            await model.prefetchComments(item)
        }
        .task(id: model.selected?.key) {
            #if DEBUG
            if ProcessInfo.processInfo.environment["WIZE_VISUAL_FIXTURE"] == "1" { return }
            #endif
            guard let item = model.selected, item.kind == .answer || item.kind == .article else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let folders = try await collectionSource.collections(for: item)
                guard !Task.isCancelled, model.selected?.key == item.key else { return }
                if folders.contains(where: \.isFavorited) { collectedKeys.insert(item.key) }
                else { collectedKeys.remove(item.key) }
            } catch { /* Keep the last known state until the collection picker is opened. */ }
        }
        .onChange(of: model.channel) { _ in selectInitialContentIfNeeded() }
        .onChange(of: model.showsComments) { if $0 { collapsedComments = [] } }
        .onChange(of: model.answerSort) { _ in Task { await model.loadAnswers() } }
        .onChange(of: model.selected?.key) { _ in
            focus.item = model.selected
            markRead(model.selected)
        }
        .onChange(of: model.streamAnchor?.key) { _ in
            chrome.showsCompactTitle = false
            readingOffset = 0
            readingOffsetAnchor = ""
        }
        .onChange(of: model.question?.key) { _ in
            markRead(model.question)
        }
        .onChange(of: model.feeds[model.channel]) { _ in selectInitialContentIfNeeded() }
        .onChange(of: model.answers) { answers in
            if usesWideLayout, model.question != nil, model.selected == nil, let first = answers.first {
                model.selectAnswer(first)
            }
        }
        .onChange(of: usesWideLayout) { isWide in
            if isWide {
                phonePath = []
                selectInitialContentIfNeeded()
            } else {
                var path: [PhonePage] = []
                if model.question != nil { path.append(.question) }
                if model.selected != nil { path.append(.answer) }
                phonePath = path
            }
        }
        .overlay {
            if let target = imageMenu {
                ReaderImageContextMenuOverlay(
                    target: target,
                    onZoom: {
                        withAnimation(.easeOut(duration: 0.14)) { imageMenu = nil }
                        ImagePreviewPresenter.shared.present(url: target.url, sourceFrame: target.frame)
                    },
                    onSave: {
                        withAnimation(.easeOut(duration: 0.14)) { imageMenu = nil }
                        Task { await saveImage(target.url) }
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.14)) { imageMenu = nil }
                    }
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let imageNotice {
                Text(imageNotice)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.72), in: Capsule())
                    .padding(.bottom, 28)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func saveImage(_ url: URL) async {
        let result = await PhotoImageSaver.save(url: url)
        let message: String
        switch result {
        case .success: message = "已存储到照片"
        case .denied: message = "没有照片写入权限"
        case .failed: message = "图片存储失败"
        }
        withAnimation(.easeOut(duration: 0.18)) { imageNotice = message }
        try? await Task.sleep(for: .seconds(2))
        withAnimation(.easeIn(duration: 0.2)) { imageNotice = nil }
    }

    private func selectInitialContentIfNeeded() {
        guard usesWideLayout, model.selected == nil, model.question == nil,
              let first = model.feeds[model.channel]?.first else { return }
        model.open(first)
    }

    private func openWebLink(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            webLink = ReaderWebLink(url: url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    /// Present the login sheet even when the comment sheet is currently up.
    private func openLogin(dismissComments: Bool = false) {
        guard dismissComments else { model.showsLogin = true; return }
        model.showsComments = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            model.showsLogin = true
        }
    }

    private var wideLayout: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ipadChannelSwitcher
                        ZStack {
                            NavigationStack { feedList(for: model.channel) }
                                .opacity(model.question == nil || model.channel == .hot ? 1 : 0)
                                .allowsHitTesting(model.question == nil || model.channel == .hot)
                            if model.question != nil && model.channel != .hot { NavigationStack { answerList } }
                        }
                    }
                    .background(ReaderPalette.directory)
                    .frame(width: geometry.size.width * 0.36)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .topTrailing) {
                            ReaderChromeCapsule(chrome: chrome) {
                                HStack(spacing: 0) {
                                    if model.channel == .hot && model.question != nil {
                                        Picker("回答排序", selection: $model.answerSort) {
                                            Text("热度").tag("default")
                                            Text("时间").tag("updated")
                                        }
                                        .pickerStyle(.menu)
                                        .frame(height: 44)
                                    }
                                    readingSettingsButton
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                    accountMenu
                                }
                            }
                            .padding(.top, 6)
                            .padding(.trailing, 12)
                        }
                        .background(readingBackground.ignoresSafeArea())
                }
                // The directory rail sits above the reading page, so its shadow
                // falls onto the page's leading edge instead of its own. Drawn
                // as a full-bleed layer so it runs the whole screen height,
                // including both safe areas.
                HStack(spacing: 0) {
                    Color.clear.frame(width: geometry.size.width * 0.36)
                    directoryEdgeShadow.frame(width: 20)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .ignoresSafeArea(edges: .vertical)
                .allowsHitTesting(false)
                if model.showsComments {
                    Color(uiColor: UIColor { traits in
                        traits.userInterfaceStyle == .dark
                            ? UIColor.black.withAlphaComponent(0.46)
                            : UIColor.black.withAlphaComponent(0.18)
                    })
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { model.showsComments = false }
                        .transition(.opacity)
                        .accessibilityLabel("关闭评论")
                        .accessibilityAddTraits(.isButton)
                    NavigationStack { commentList }
                        .environment(\.openURL, OpenURLAction { url in openWebLink(url); return .handled })
                        .background(CommentSwipeDismiss { model.showsComments = false })
                        .frame(width: min(max(geometry.size.width * 0.38, 360), 480))
                        .frame(maxHeight: .infinity)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.22), radius: 16, x: -5)
                        .padding(.vertical, 8)
                        .padding(.trailing, 8)
                        .accessibilityAction(.escape) { model.showsComments = false }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: model.showsComments)
        }
    }

    /// A gradient stand-in for the shadow the directory rail casts onto the
    /// reading page. It replaces the hard `Divider` so the two columns share
    /// the paper cards' softened, floating edge language. Kept as a scrim
    /// instead of `.shadow` so the page's WKWebView is never rasterized into
    /// an offscreen shadow layer while scrolling.
    private var directoryEdgeShadow: some View {
        LinearGradient(
            stops: [
                .init(color: ReaderPalette.edgeShadow, location: 0),
                .init(color: ReaderPalette.edgeShadow.opacity(0.58), location: 0.24),
                .init(color: ReaderPalette.edgeShadow.opacity(0.24), location: 0.55),
                .init(color: ReaderPalette.edgeShadow.opacity(0.06), location: 0.82),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 20)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var channelPicker: some View {
        Picker("栏目", selection: Binding(
            get: { model.channel },
            set: { channel in model.changeChannel(channel); Task { await model.loadFeed() } }
        )) {
            Text("推荐").tag(ReaderModel.Channel.recommend)
            Text("热榜").tag(ReaderModel.Channel.hot)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var ipadChannelSwitcher: some View {
        channelPicker
            .padding(5)
            .readerGlassCapsule()
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
    }

    private var accountMenu: some View {
        Button { showsAccountMenu = true } label: {
            AvatarView(url: model.accountAvatarURL, size: 32)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("账号与阅读设置")
        .popover(isPresented: $showsAccountMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(url: model.accountAvatarURL, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.accountName ?? "知乎账号").font(.headline).lineLimit(2)
                        if let headline = model.accountHeadline, !headline.isEmpty {
                            Text(headline).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                        } else if model.accountName == nil {
                            Text("查看或登录知乎账号").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(16)
                Divider().padding(.horizontal, 16)
                accountMenuRow("阅读设置", systemImage: "textformat.size", destination: .settings)
                accountMenuRow("知乎账号", systemImage: "person.crop.circle", destination: .login)
                Divider().padding(.horizontal, 16)
                accountMenuRow("问题反馈与建议", systemImage: "envelope", destination: .feedback)
                accountMenuRow("关于", systemImage: "info.circle", destination: .about)
            }
            .frame(width: 290)
            .buttonStyle(.plain)
            .presentationCompactAdaptation(.popover)
            .onDisappear {
                switch accountDestination {
                case .settings: showsReadingSettings = true
                case .login: model.showsLogin = true
                case .about: showsAbout = true
                case .feedback: showsFeedback = true
                case nil: break
                }
                accountDestination = nil
            }
        }
    }

    /// 整行可点的菜单项：命中区域覆盖整行宽度，而不是只有图标和文字。
    private func accountMenuRow(_ title: String, systemImage: String, destination: AccountDestination) -> some View {
        Button {
            accountDestination = destination
            showsAccountMenu = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 22, alignment: .center)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var phoneLayout: some View {
        NavigationStack(path: $phonePath) {
            phoneFeedTabs
                .navigationDestination(for: PhonePage.self) { page in
                    switch page { case .question: answerList; case .answer: detail }
                }
        }
        .sheet(isPresented: $model.showsComments) {
            NavigationStack { commentList }
                .environment(\.openURL, OpenURLAction { url in openWebLink(url); return .handled })
                .background(CommentSwipeDismiss { model.showsComments = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: phonePath) { path in
            guard !usesWideLayout else { return }
            if path.isEmpty {
                model.question = nil
                model.leaveReading()
            } else if path.last == .question {
                model.leaveReading()
            }
        }
    }

    private var phoneFeedTabs: some View {
        TabView(selection: Binding(
            get: { model.channel },
            set: { channel in model.changeChannel(channel); Task { await model.loadFeed() } }
        )) {
            feedList(for: .recommend).tag(ReaderModel.Channel.recommend)
            feedList(for: .hot).tag(ReaderModel.Channel.hot)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 14) {
                channelPicker.frame(width: 176)
                Spacer(minLength: 0)
                accountMenu.frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
            .background(ReaderPalette.directory)
        }
        .background(ReaderPalette.directory.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func feedList(for channel: ReaderModel.Channel) -> some View {
        List {
            ForEach(Array((model.feeds[channel] ?? []).enumerated()), id: \.element.key) { index, item in
                Button {
                    markRead(item)
                    model.open(item)
                    if !usesWideLayout { phonePath.append(item.kind == .question ? .question : .answer) }
                } label: {
                    ItemRow(
                        item: item,
                        isHot: channel == .hot,
                        hotRank: channel == .hot ? index + 1 : nil,
                        isRead: readKeys.contains(item.key)
                    )
                }
                .buttonStyle(DirectoryRowButtonStyle())
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                .listRowBackground(directoryRowBackground(
                    selected: usesWideLayout && (model.selected?.key == item.key || model.question?.key == item.key)
                ))
                .task {
                    guard channel == model.channel else { return }
                    let upcoming = Array((model.feeds[channel] ?? []).dropFirst(index).prefix(6))
                    async let avatars: Void = AvatarCache.shared.prefetch(upcoming.compactMap(\.avatarURL) + upcoming.compactMap(\.imageURL))
                    async let detail: Void = model.prefetchDetail(item)
                    if index >= max((model.feeds[channel]?.count ?? 0) - 4, 0) { await model.loadFeed() }
                    await detail
                    await avatars
                }
            }
            if channel == model.channel, let error = model.feedError { retryRow(error) { await model.loadFeed() }.listRowBackground(Color.clear) }
            else if channel == model.channel, model.loadingFeed, (model.feeds[channel] ?? []).isEmpty {
                ForEach(0..<5, id: \.self) { _ in LoadingSkeleton(kind: .feed, label: "正在加载内容").listRowSeparator(.hidden).listRowBackground(Color.clear) }
            }
            else if channel == model.channel, model.loadingFeed, !model.refreshingFeed {
                LoadingSkeleton(kind: .feed, label: "正在加载更多")
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            else if channel == model.channel, !model.loadingFeed, model.feeds[channel]?.isEmpty == true {
                ContentUnavailableView("暂无内容", systemImage: "text.book.closed", description: Text("下拉刷新，看看有没有新的内容。"))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(ReaderPalette.directory.ignoresSafeArea(edges: .bottom))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(usesWideLayout ? .hidden : .automatic, for: .navigationBar)
        .refreshable { if channel == model.channel { await model.loadFeed(reset: true) } }
    }

    private var answerList: some View {
        List {
            if let question = model.question {
                Text(question.title).font(.headline.weight(.semibold)).padding(.vertical, 8).listRowSeparator(.hidden)
            }
            Picker("回答排序", selection: $model.answerSort) {
                Text("热度").tag("default"); Text("时间").tag("updated")
            }.pickerStyle(.segmented).listRowSeparator(.hidden)
            ForEach(Array(model.answers.enumerated()), id: \.element.key) { index, item in
                Button {
                    markRead(item)
                    model.selectAnswer(item)
                    if !usesWideLayout { phonePath.append(.answer) }
                } label: {
                    ItemRow(item: item, showsTitle: false, isRead: readKeys.contains(item.key))
                }
                    .buttonStyle(DirectoryRowButtonStyle())
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                    .listRowBackground(directoryRowBackground(selected: usesWideLayout && model.selected?.key == item.key))
                    .task {
                        async let avatars: Void = AvatarCache.shared.prefetch(Array(model.answers.dropFirst(index).prefix(6)).compactMap(\.avatarURL))
                        async let detail: Void = model.prefetchDetail(item)
                        if index >= max(model.answers.count - 4, 0), model.hasMoreAnswers { await model.loadAnswers(more: true) }
                        await detail
                        await avatars
                    }
            }
            if let error = model.answerError { retryRow(error) { await model.loadAnswers(more: !model.answers.isEmpty && model.hasMoreAnswers) }.listRowBackground(Color.clear) }
            else if model.loadingAnswers {
                ForEach(0..<(model.answers.isEmpty ? 4 : 1), id: \.self) { _ in
                    LoadingSkeleton(kind: .answer, label: model.answers.isEmpty ? "正在加载回答" : "正在加载更多")
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }
            else if model.answers.isEmpty {
                ContentUnavailableView("暂无回答", systemImage: "text.bubble", description: Text("这个问题还没有可显示的回答。"))
                    .listRowBackground(Color.clear)
            }
        }.listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(ReaderPalette.directory.ignoresSafeArea(edges: .bottom))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if usesWideLayout { ToolbarItem(placement: .navigationBarLeading) {
                Button("返回列表") { model.question = nil }
            } } }
    }

    private var readingBackground: Color {
        switch readingTheme {
        case "paper": return Color(red: 0.961, green: 0.941, blue: 0.902)
        case "light": return .white
        case "dark": return Color(red: 0.114, green: 0.125, blue: 0.137)
        default: return ReaderPalette.page
        }
    }

    /// 反馈表单可附带的信息（用户可在表单里关闭）。
    private var feedbackContext: FeedbackContext {
        let defaults = UserDefaults.standard
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        return FeedbackContext(
            accountName: model.accountName,
            accountHeadline: model.accountHeadline,
            accountToken: model.accountToken,
            readingFontSize: defaults.object(forKey: "reading.fontSize") as? Int ?? (isPad ? 18 : 17),
            readingLineHeight: defaults.object(forKey: "reading.lineHeight") as? Double ?? 1.8,
            readingWidth: defaults.object(forKey: "reading.width") as? Int ?? (isPad ? 800 : 680),
            readingFont: defaults.string(forKey: "reading.font") ?? "system",
            readingTheme: defaults.string(forKey: "reading.theme") ?? "system"
        )
    }

    /// 阅读界面里的直接入口：一键打开阅读设置（iPhone 单列与 iPad 宽栏都有）。
    private var readingSettingsButton: some View {
        Button { showsReadingSettings = true } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel("阅读设置")
        .accessibilityHint("调整字号、行距、字体与阅读配色")
    }

    @ViewBuilder private var detail: some View {
        if let item = model.selected {
            VStack(alignment: .leading, spacing: 0) {
                if let html = model.bodyHTML {
                    HTMLReader(
                        html: html,
                        item: model.streamAnchor ?? item,
                        stream: model.streamItems,
                        paperCards: usesWideLayout,
                        onChromeVisibility: { chrome.showsControls = $0 },
                        scrollRequest: model.scrollRequest,
                        onVisibleAnswer: { id in
                            guard let answer = model.streamItems.first(where: { $0.id == id }) else { return }
                            if focus.item?.key != answer.key { focus.item = answer }
                            markRead(answer)
                            // Only the edge action avatar is drawn by SwiftUI; the
                            // stream's own avatars are loaded by the web view.
                            if let url = answer.avatarURL {
                                Task { await AvatarCache.shared.prefetch([url]) }
                            }
                        },
                        onNearEnd: { Task { await model.loadMoreStream() } },
                        onOpenLink: openWebLink,
                        onOpenImage: { url, frame, touchPoint in
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                                imageMenu = ReaderImageMenuTarget(url: url, frame: frame, touchPoint: touchPoint)
                            }
                        },
                        onCompactTitle: { chrome.showsCompactTitle = $0 },
                        restoreOffset: readingOffsetAnchor == (model.streamAnchor?.id ?? item.id) ? readingOffset : 0,
                        onReadingOffset: { offset in
                            readingOffset = offset
                            readingOffsetAnchor = model.streamAnchor?.id ?? item.id
                        }
                    )
                    .id(model.streamAnchor?.key ?? item.key)
                    .ignoresSafeArea(.container, edges: usesWideLayout ? [] : .bottom)
                }
                else if let error = model.bodyError {
                    ReaderStatusCard(
                        message: error,
                        isLoginRequired: requiresLogin(error),
                        onRetry: { model.selectAnswer(item) },
                        onLogin: { openLogin() }
                    )
                    .frame(maxWidth: 460)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { LoadingSkeleton(kind: .body, label: "正在加载正文").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
                if let error = model.streamError {
                    let needsLogin = requiresLogin(error)
                    ReaderStatusCard(
                        message: error,
                        isLoginRequired: needsLogin,
                        retryTitle: "重试",
                        onRetry: model.streamSearchExhausted ? nil : { model.retryStream() },
                        onLogin: { openLogin() }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .padding(.bottom, usesWideLayout ? 0 : 56)
                }
            }
            .task(id: model.streamAnchor?.key) {
                await AvatarCache.shared.prefetch(Array(model.streamItems.prefix(6)).compactMap(\.avatarURL))
            }
            .background(readingBackground.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .topLeading) {
                if usesWideLayout, model.bodyHTML != nil {
                    ReaderCompactTitle(chrome: chrome, title: item.title, floating: true)
                        .padding(.leading, 18)
                        .padding(.top, 10)
                        .padding(.trailing, 168)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .overlay(alignment: .trailing) {
                if usesWideLayout, !model.showsComments, model.bodyHTML != nil {
                    ReaderChromeVisibility(chrome: chrome) {
                        ReaderActionOverlay(focus: focus, model: model, layout: .trailing,
                                            collectedKeys: collectedKeys,
                                            onProfile: { profileItem = $0 },
                                            onCollect: { collectionItem = $0 })
                            .readerGlassCapsule()
                            .padding(.trailing, 12)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !usesWideLayout, model.bodyHTML != nil {
                    ReaderBottomChromeCapsule(chrome: chrome) {
                        ReaderActionOverlay(focus: focus, model: model, layout: .bottom,
                                            collectedKeys: collectedKeys,
                                            onProfile: { profileItem = $0 },
                                            onCollect: { collectionItem = $0 })
                            .frame(maxWidth: 260)
                            .readerGlassCapsule()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .alert("操作未完成", isPresented: Binding(get: { model.voteError != nil }, set: { if !$0 { model.voteError = nil } })) {
                Button("好", role: .cancel) { model.voteError = nil }
            } message: { Text(model.voteError ?? "") }
            .toolbar {
                if !usesWideLayout {
                    ToolbarItem(placement: .principal) {
                        ReaderCompactTitle(chrome: chrome, title: item.title, floating: false)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        readingSettingsButton
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text(model.question == nil ? "选择一篇内容开始阅读" : "选择一个回答开始阅读").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 横向滑动关闭评论栏。识别器只有在滑动明显偏横向时才开始，
    /// 竖向的列表滚动和 iPhone 抽屉档位拖动不会被抢走。
    private struct CommentSwipeDismiss: UIViewRepresentable {
        var onDismiss: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

        func makeUIView(context: Context) -> InstallerView {
            let view = InstallerView()
            view.isUserInteractionEnabled = false
            view.coordinator = context.coordinator
            return view
        }

        func updateUIView(_ uiView: InstallerView, context: Context) {
            context.coordinator.onDismiss = onDismiss
            uiView.coordinator = context.coordinator
            uiView.installIfNeeded()
        }

        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var onDismiss: () -> Void
            let pan = UIPanGestureRecognizer()

            init(onDismiss: @escaping () -> Void) {
                self.onDismiss = onDismiss
                super.init()
                pan.addTarget(self, action: #selector(handle))
                pan.delegate = self
                pan.cancelsTouchesInView = false
                pan.maximumNumberOfTouches = 1
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                let velocity = pan.velocity(in: pan.view)
                return abs(velocity.x) > max(abs(velocity.y) * 1.5, 80)
            }

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
                other.view is UIScrollView
            }

            @objc private func handle(_ gesture: UIPanGestureRecognizer) {
                guard gesture.state == .ended else { return }
                let translation = gesture.translation(in: gesture.view)
                let velocity = gesture.velocity(in: gesture.view)
                let crossed = abs(translation.x) > 56 && abs(translation.x) > abs(translation.y) * 1.2
                let flicked = abs(velocity.x) > 900 && abs(velocity.x) > abs(velocity.y) * 1.4
                guard crossed || flicked else { return }
                onDismiss()
            }
        }

        final class InstallerView: UIView {
            weak var coordinator: Coordinator?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                installIfNeeded()
            }

            func installIfNeeded() {
                guard let coordinator else { return }
                guard window != nil, let host = panelView() else {
                    coordinator.pan.view?.removeGestureRecognizer(coordinator.pan)
                    return
                }
                guard coordinator.pan.view !== host else { return }
                coordinator.pan.view?.removeGestureRecognizer(coordinator.pan)
                host.addGestureRecognizer(coordinator.pan)
            }

            /// 挂到评论栏自己的导航视图上，这样列表和标题栏都能左滑关闭，
            /// 又不会接到背后的正文或整页抽屉容器。
            private func panelView() -> UIView? {
                var responder: UIResponder? = self
                var nearest: UIView?
                while let next = responder?.next {
                    if let navigation = next as? UINavigationController {
                        return navigation.view
                    }
                    if let controller = next as? UIViewController, nearest == nil {
                        nearest = controller.view
                    }
                    responder = next
                }
                return nearest
            }

            deinit {
                if let coordinator {
                    coordinator.pan.view?.removeGestureRecognizer(coordinator.pan)
                }
            }
        }
    }

    private var commentList: some View {
        let rows = commentTreeRows(model.comments.flatMap { [$0] + (model.commentReplies[$0.id] ?? []) }, collapsed: collapsedComments)
        return List {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let comment = row.comment
                let depth = min(row.depth, 3)
                let nextDepth = index + 1 < rows.count ? min(rows[index + 1].depth, 3) : 0
                let topPadding: CGFloat = row.depth == 0 ? (index == 0 ? 4 : 12) : 6
                VStack(alignment: .leading, spacing: 7) {
                    commentRow(comment)
                }
                .padding(.leading, CGFloat(depth) * 24)
                .padding(.top, topPadding)
                .padding(.bottom, row.depth == 0 ? 4 : 6)
                .overlay(alignment: .leading) {
                    if max(depth, nextDepth) > 0 {
                        commentThreadLines(depth: depth, topPadding: topPadding, index: index, rows: rows)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .task {
                    let slice = Array(rows.dropFirst(index).prefix(6))
                    CommentEmojiLoader.shared.preload(slice.flatMap { CommentEmoji.urls(in: $0.comment.html) })
                    for item in slice {
                        for fragment in commentHTMLFragments(item.comment.html) {
                            if case .image(let imageURL) = fragment {
                                Task { _ = await RemoteImageLoader.shared.image(for: imageURL) }
                            }
                        }
                    }
                    await AvatarCache.shared.prefetch(slice.compactMap { $0.comment.avatarURL })
                }
                .task {
                    if index == rows.count - 1, model.canLoadMoreComments {
                        await model.loadComments()
                    }
                }
            }
            if let error = model.commentError {
                ReaderStatusCard(
                    message: error,
                    isLoginRequired: requiresLogin(error),
                    onRetry: { Task { await model.loadComments(reset: true) } },
                    onLogin: { openLogin(dismissComments: true) }
                )
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else if model.loadingComments {
                ForEach(0..<(rows.isEmpty ? 5 : 1), id: \.self) { _ in
                    LoadingSkeleton(kind: .comment, label: "正在加载")
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                }
            } else if model.canLoadMoreComments {
                Button { Task { await model.loadComments() } } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .accessibilityLabel("加载更多评论")
            }
        }.listStyle(.plain)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if model.comments.isEmpty && !model.loadingComments && model.commentError == nil {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("暂无评论")
                        .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    commentPanelTitle
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { model.showsComments = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭评论")
                }
            }
    }

    /// Replies are joined by quiet vertical rules aligned under the parent comment's
    /// avatar. Each parent row starts the rule directly below its 24pt avatar, and a
    /// reply at depth d draws the rule of every ancestor level so the thread connects
    /// continuously from the replied-to avatar down through nested replies.
    private func commentThreadLines(depth: Int, topPadding: CGFloat, index: Int, rows: [CommentTreeRow]) -> some View {
        let nextDepth = index + 1 < rows.count ? min(rows[index + 1].depth, 3) : 0
        let maxLevel = max(depth, min(nextDepth, depth + 1))
        return ZStack(alignment: .leading) {
            ForEach(1...maxLevel, id: \.self) { level in
                let startsAtAvatar = level > depth
                let starts = startsAtAvatar || index == 0
                let ends = nextDepth < level
                UnevenRoundedRectangle(
                    topLeadingRadius: starts ? 0.75 : 0,
                    bottomLeadingRadius: ends ? 0.75 : 0,
                    bottomTrailingRadius: ends ? 0.75 : 0,
                    topTrailingRadius: starts ? 0.75 : 0
                )
                .fill(ReaderPalette.accent.opacity(0.32))
                .frame(width: 1.5)
                .padding(.top, startsAtAvatar ? topPadding + 26 : 0)
                .padding(.leading, 11.25 + CGFloat(level - 1) * 24)
            }
        }
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func commentMetadata(_ comment: ReadingComment) -> some View {
        HStack(spacing: 12) {
            if let ip = normalizedIPRegion(comment.ipInfo) {
                RegionBadge(ip: ip)
            }
            if comment.likes > 0 {
                MetadataCount(symbol: "hand.thumbsup", count: comment.likes,
                              accessibilityLabel: "\(displayCount(comment.likes)) 次赞同")
            }
            if comment.replyCount > 0 {
                replyCountBadge(comment)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 回复数放在与赞同同一行；点按加载/展开/收起（加载更多翻页也由此触发）。
    @ViewBuilder
    private func replyCountBadge(_ comment: ReadingComment) -> some View {
        if model.loadingReplies.contains(comment.id) {
            ProgressView()
                .controlSize(.mini)
        } else {
            let loaded = model.commentReplies[comment.id] != nil
            let collapsed = collapsedComments.contains(comment.id)
            let hasMore = loaded && !collapsed && model.replyNext[comment.id] != nil
            let failed = model.replyErrors[comment.id] != nil
            let indicator: String = failed ? "exclamationmark.circle" : ((!loaded || collapsed) ? "chevron.down" : (hasMore ? "ellipsis" : "chevron.up"))
            Button {
                toggleReplies(comment)
            } label: {
                HStack(spacing: 3) {
                    compactCount("bubble.right", count: comment.replyCount)
                    Image(systemName: indicator)
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(failed ? "回复没有载入，点按再试一次" : (!loaded ? "查看 \(comment.replyCount) 条回复" : collapsed ? "展开 \(comment.replyCount) 条回复" : hasMore ? "加载更多回复" : "收起 \(comment.replyCount) 条回复"))
        }
    }

    private func toggleReplies(_ comment: ReadingComment) {
        let loaded = model.commentReplies[comment.id] != nil
        let collapsed = collapsedComments.contains(comment.id)
        if !loaded {
            collapsedComments.remove(comment.id)
            Task { await model.loadReplies(to: comment) }
        } else if collapsed {
            collapsedComments.remove(comment.id)
            if model.replyNext[comment.id] != nil {
                Task { await model.loadReplies(to: comment) }
            }
        } else if model.replyNext[comment.id] != nil {
            Task { await model.loadReplies(to: comment) }
        } else {
            collapsedComments.insert(comment.id)
        }
    }

    private func commentRow(_ comment: ReadingComment) -> some View {
        let isAuthor = comment.isAuthor || (!comment.author.isEmpty && comment.author == model.commentTarget?.author)
        return HStack(alignment: .top, spacing: 8) {
            AvatarView(url: comment.avatarURL, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(comment.author).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if isAuthor {
                            CommentAuthorBadge()
                        }
                        if let replyTo = comment.replyTo {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(replyTo).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        commentMetadata(comment)
                    }.frame(minHeight: 24)
                    ForEach(Array(commentHTMLFragments(comment.html).enumerated()), id: \.offset) { _, fragment in
                        switch fragment {
                        case .text(let html):
                            let segments = commentInlineSegments(html)
                            if !segments.isEmpty {
                                CommentInlineText(segments: segments, plainLabel: htmlText(html))
                            }
                        case .image(let url):
                            CommentImageView(url: url)
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 2)
    }

    /// 评论浮层锁定打开时的那条回答：头像和作者一直留在标题上，不跟着后面的滚动换人。
    private var commentPanelTitle: some View {
        let count = model.commentTarget?.commentCount ?? model.comments.count
        let author = model.commentTarget?.author.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = author.isEmpty ? "匿名用户" : author
        return HStack(spacing: 8) {
            if let target = model.commentTarget {
                AvatarView(url: target.avatarURL, size: 22)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            compactCount("bubble.right", count: count)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.commentTarget == nil ? "\(displayCount(count)) 条评论" : "\(name)，\(displayCount(count)) 条评论")
    }

    private func directoryRowBackground(selected: Bool) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            if selected {
                ReaderPalette.selection
                Capsule()
                    .fill(ReaderPalette.accent)
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 7)
            }
        }
    }

    private func retryRow(_ message: String, action: @escaping () async -> Void) -> some View {
        ReaderStatusCard(
            message: message,
            isLoginRequired: requiresLogin(message),
            retryTitle: "重试",
            onRetry: { Task { await action() } },
            onLogin: { openLogin() }
        )
        .padding(.vertical, 8)
    }

    private func requiresLogin(_ message: String) -> Bool {
        message.contains("登录") || message.contains("安全验证")
    }

}


/// Shared recovery card for loading errors. Authentication failures get a
/// direct login action instead of a dead-end retry.
private struct ReaderStatusCard: View {
    let message: String
    let isLoginRequired: Bool
    var retryTitle: String = "重试"
    var onRetry: (() -> Void)? = nil
    var onLogin: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isLoginRequired ? "person.crop.circle" : "wifi.exclamationmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ReaderPalette.accent)
                    .frame(width: 30, height: 30)
                    .background(ReaderPalette.accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(isLoginRequired ? "需要登录知乎" : "暂时无法加载")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                if isLoginRequired, let onLogin {
                    Button("登录知乎") { onLogin() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if let onRetry {
                    if isLoginRequired {
                        Button(retryTitle) { onRetry() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button(retryTitle) { onRetry() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .background(ReaderPalette.directory, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// Floating reading chrome (reading settings / account). It fades out while the
/// reader scrolls down so the page reads edge-to-edge, and comes back on scroll up
/// or when the page is at the top. Only this capsule observes the visibility store.
private enum ReaderWindowMetrics {
    static var width: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let width = scene?.keyWindow?.bounds.width, width > 1 { return width }
        if let width = scene?.screen.bounds.width, width > 1 { return width }
        return 390
    }
}

private struct DirectoryRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.055) : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The large title stays in the article. This single line takes over only after that
/// title has scrolled away, so the question is never shown twice at the top.
private struct ReaderCompactTitle: View {
    @ObservedObject var chrome: ReadingChrome
    let title: String
    var floating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = Text(title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
        return Group {
            if floating {
                if chrome.showsCompactTitle {
                    label
                        .frame(maxWidth: 320, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .readerGlassCapsule()
                        .transition(.opacity)
                }
            } else {
                label.opacity(chrome.showsCompactTitle ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(!chrome.showsCompactTitle)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: chrome.showsCompactTitle)
    }
}

private struct ReaderChromeVisibility<Content: View>: View {
    @ObservedObject var chrome: ReadingChrome
    let content: Content

    init(chrome: ReadingChrome, @ViewBuilder content: () -> Content) {
        self.chrome = chrome
        self.content = content()
    }

    var body: some View {
        content
            .opacity(chrome.showsControls ? 1 : 0)
            .allowsHitTesting(chrome.showsControls)
            .accessibilityHidden(!chrome.showsControls)
            .animation(.easeInOut(duration: 0.18), value: chrome.showsControls)
    }
}

private struct ReaderChromeCapsule<Content: View>: View {
    @ObservedObject var chrome: ReadingChrome
    let content: Content

    init(chrome: ReadingChrome, @ViewBuilder content: () -> Content) {
        self.chrome = chrome
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 2)
            .readerGlassCapsule()
            .opacity(chrome.showsControls ? 1 : 0)
            .allowsHitTesting(chrome.showsControls)
            .accessibilityHidden(!chrome.showsControls)
            .animation(.easeInOut(duration: 0.18), value: chrome.showsControls)
    }
}

/// iPhone bottom action bar wrapper: gently tucks down and fades out while scrolling
/// down through an answer/article, and springs back on upward scroll or at top/bottom.
private struct ReaderBottomChromeCapsule<Content: View>: View {
    @ObservedObject var chrome: ReadingChrome
    let content: Content

    init(chrome: ReadingChrome, @ViewBuilder content: () -> Content) {
        self.chrome = chrome
        self.content = content()
    }

    var body: some View {
        content
            .opacity(chrome.showsControls ? 1 : 0)
            .offset(y: chrome.showsControls ? 0 : 28)
            .allowsHitTesting(chrome.showsControls)
            .accessibilityHidden(!chrome.showsControls)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: chrome.showsControls)
    }
}

/// Floating reading actions for the answer at the reading focus. It observes the
/// lightweight `ReadingFocus` store so scrolling across answer boundaries only
/// refreshes this bar.
private struct ReaderActionOverlay: View {
    enum Layout { case trailing, bottom }

    @ObservedObject var focus: ReadingFocus
    @ObservedObject var model: ReaderModel
    let layout: Layout
    let collectedKeys: Set<String>
    var onProfile: (ReadingItem) -> Void
    var onCollect: (ReadingItem) -> Void

    private var item: ReadingItem? {
        // Prefer the newest copy of the focused answer so vote counts and vote
        // state reflect changes without rebuilding the reading screen.
        if let key = focus.item?.key, let latest = model.streamItems.first(where: { $0.key == key }) {
            return latest
        }
        return focus.item ?? model.selected
    }

    var body: some View {
        if let item {
            Group {
                if layout == .trailing {
                    VStack(spacing: 2) { actions(for: item) }
                } else {
                    HStack(spacing: 0) { actions(for: item) }
                }
            }
            .task(id: item.key) {
                ReaderSharePresenter.shared.prefetch(for: item)
            }
        }
    }

    @ViewBuilder
    private func actions(for item: ReadingItem) -> some View {
        if item.kind == .answer {
            Button { onProfile(item) } label: {
                AvatarView(url: item.avatarURL, size: 36)
                    .frame(width: layout == .trailing ? 56 : 52, height: 52)
            }
            .accessibilityLabel("查看作者：\(item.author.isEmpty ? "匿名用户" : item.author)")
            VoteActionButton(
                isOn: item.vote == .up,
                count: item.upCount,
                vertical: layout == .trailing
            ) {
                Task { await model.toggleVote(.up, for: item) }
            }
            .disabled(model.voting)
            .accessibilityLabel(item.vote == .up ? "取消赞同" : "赞同")
        }
        Button { model.showComments(for: item) } label: {
            actionLabel("bubble.right", item.commentCount)
        }
        .accessibilityLabel("查看评论")
        let canCollect = item.kind == .answer || item.kind == .article
        let shareURL = zhihuWebURL(for: item)
        if canCollect || shareURL != nil {
            Menu {
                if canCollect {
                    let isCollected = collectedKeys.contains(item.key)
                    Button {
                        onCollect(item)
                    } label: {
                        Label(isCollected ? "已收藏" : "收藏", systemImage: isCollected ? "star.fill" : "star")
                    }
                }
                if let shareURL {
                    Button {
                        ReaderSharePresenter.shared.present(item: item, url: shareURL)
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: layout == .trailing ? 56 : 52, height: 52)
                    .foregroundStyle(ReaderPalette.accent)
                    .contentShape(Rectangle())
            }
            .tint(ReaderPalette.accent)
            .accessibilityLabel("更多操作")
        }
    }

    @ViewBuilder
    private func actionLabel(_ icon: String, _ count: Int?) -> some View {
        if layout == .trailing {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(displayCount(count)).font(.system(size: 10, weight: .medium)).monospacedDigit()
            }.frame(width: 56, height: 52)
                .foregroundStyle(ReaderPalette.accent)
        } else {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(displayCount(count)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }.fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(ReaderPalette.accent)
        }
    }
}

/// Presents `UIActivityViewController` directly on the active window's top-most
/// view controller with zero async wait on tap. Pre-warms thumbnail icons and
/// `ShareSheet` extension machinery while reading so the share sheet slides up
/// once at full width without stutter or panel replacement.
@MainActor
private final class ReaderSharePresenter {
    static let shared = ReaderSharePresenter()
    private var activeSources: [Any] = []
    private var didWarmUp = false
    private var warmUpController: UIActivityViewController?

    private static let defaultPreviewIcon: UIImage = renderPreviewIcon(from: nil)

    func prefetch(for item: ReadingItem) {
        warmUpIfNeeded()
        guard let imageURL = item.imageURL ?? item.avatarURL else { return }
        if AvatarCache.shared.cachedImage(for: imageURL) != nil
            || RemoteImageLoader.shared.cachedImage(for: imageURL) != nil {
            return
        }
        Task {
            _ = await AvatarCache.shared.image(for: imageURL)
        }
    }

    private func warmUpIfNeeded() {
        guard !didWarmUp else { return }
        didWarmUp = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, let url = NSURL(string: "https://www.zhihu.com") else { return }
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.loadViewIfNeeded()
            self.warmUpController = controller
            try? await Task.sleep(for: .seconds(2))
            self.warmUpController = nil
        }
    }

    func present(item: ReadingItem, url: URL) {
        let title = zhihuShareTitle(for: item)
        let imageURL = item.imageURL ?? item.avatarURL
        let rawIcon = Self.cachedShareIcon(url: imageURL)
        let thumbnail = rawIcon.map { Self.renderPreviewIcon(from: $0) } ?? Self.defaultPreviewIcon
        guard let host = Self.topViewController() else { return }

        let urlSource = ReaderShareItemSource(url: url, title: title, thumbnail: thumbnail)
        let sources: [Any] = [urlSource]
        let activities: [UIActivity] = [
            ReaderWeChatActivity(kind: .session, title: title, url: url, thumbnail: thumbnail),
            ReaderWeChatActivity(kind: .timeline, title: title, url: url, thumbnail: thumbnail)
        ]
        self.activeSources = sources

        let controller = UIActivityViewController(activityItems: sources, applicationActivities: activities)
        controller.excludedActivityTypes = [.saveToCameraRoll, .assignToContact, .print]
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.activeSources = []
        }
        if UIDevice.current.userInterfaceIdiom == .phone,
           let pc = controller.presentationController,
           pc.responds(to: Selector(("setLayoutMargins:"))) {
            pc.setValue(UIEdgeInsets.zero, forKey: "layoutMargins")
        }
        if UIDevice.current.userInterfaceIdiom == .pad,
           let popover = controller.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(
                x: host.view.bounds.midX,
                y: host.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        host.present(controller, animated: true)
    }

    private static func cachedShareIcon(url: URL?) -> UIImage? {
        guard let url else { return nil }
        if let cached = AvatarCache.shared.cachedImage(for: url) {
            return cached
        }
        if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
            return cached
        }
        return nil
    }

    private static func renderPreviewIcon(from image: UIImage?) -> UIImage {
        let size = CGSize(width: 120, height: 120)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.322, green: 0.471, blue: 0.388, alpha: 1.0).setFill()
            ctx.fill(rect)
            if let image {
                let srcSize = image.size
                if srcSize.width > 0 && srcSize.height > 0 {
                    let scale = max(size.width / srcSize.width, size.height / srcSize.height)
                    let drawWidth = srcSize.width * scale
                    let drawHeight = srcSize.height * scale
                    let drawRect = CGRect(
                        x: (size.width - drawWidth) * 0.5,
                        y: (size.height - drawHeight) * 0.5,
                        width: drawWidth,
                        height: drawHeight
                    )
                    image.draw(in: drawRect)
                    return
                }
            }
            let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)
            if let symbol = UIImage(systemName: "text.book.closed.fill", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let symSize = symbol.size
                let symRect = CGRect(
                    x: (size.width - symSize.width) * 0.5,
                    y: (size.height - symSize.height) * 0.5,
                    width: symSize.width,
                    height: symSize.height
                )
                symbol.draw(in: symRect)
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first { !$0.isHidden }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}

private final class ReaderShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String
    private let thumbnail: UIImage
    private let metadata: LPLinkMetadata

    init(url: URL, title: String, thumbnail: UIImage) {
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        metadata.title = title
        metadata.iconProvider = NSItemProvider(object: thumbnail)
        self.metadata = metadata
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url as NSURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url as NSURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                thumbnailImageForActivityType activityType: UIActivity.ActivityType?,
                                suggestedSize size: CGSize) -> UIImage? {
        thumbnail
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        metadata
    }
}

/// 分享面板中缺省显示的「微信」与「朋友圈」操作项：
/// 优先调起系统微信分享扩展（com.tencent.xin.sharetimeline，支持发送给朋友与分享到朋友圈），
/// 若设备未启用扩展或未安装微信则自动复制标题与链接并尝试打开微信。
private final class ReaderWeChatActivity: UIActivity {
    enum Kind {
        case session
        case timeline
    }

    private static let sessionIcon: UIImage = makeIcon(for: .session)
    private static let timelineIcon: UIImage = makeIcon(for: .timeline)

    private let kind: Kind
    private let shareTitle: String
    private let shareURL: URL
    private let thumbnail: UIImage
    private var preparedComposeController: UIViewController?

    init(kind: Kind, title: String, url: URL, thumbnail: UIImage) {
        self.kind = kind
        self.shareTitle = title
        self.shareURL = url
        self.thumbnail = thumbnail
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .share }

    override var activityType: UIActivity.ActivityType? {
        switch kind {
        case .session:
            return UIActivity.ActivityType("com.lyuai.wize.share.wechat.session")
        case .timeline:
            return UIActivity.ActivityType("com.lyuai.wize.share.wechat.timeline")
        }
    }

    override var activityTitle: String? {
        switch kind {
        case .session: return "微信"
        case .timeline: return "朋友圈"
        }
    }

    override var activityImage: UIImage? {
        switch kind {
        case .session: return Self.sessionIcon
        case .timeline: return Self.timelineIcon
        }
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        true
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        if let compose = SLComposeViewController(forServiceType: "com.tencent.xin.sharetimeline") {
            compose.setInitialText(shareTitle)
            compose.add(thumbnail)
            compose.add(shareURL)
            compose.completionHandler = { [weak self] _ in
                self?.activityDidFinish(true)
            }
            preparedComposeController = compose
        } else {
            preparedComposeController = nil
        }
    }

    override var activityViewController: UIViewController? {
        preparedComposeController
    }

    override func perform() {
        UIPasteboard.general.string = "\(shareTitle)\n\(shareURL.absoluteString)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let wechatURL = URL(string: "weixin://") {
            UIApplication.shared.open(wechatURL, options: [:], completionHandler: nil)
        }
        activityDidFinish(true)
    }

    private static func makeIcon(for kind: Kind) -> UIImage {
        let size = CGSize(width: 60, height: 60)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 14)
            switch kind {
            case .session:
                UIColor(red: 0.027, green: 0.757, blue: 0.376, alpha: 1.0).setFill()
            case .timeline:
                UIColor(red: 0.145, green: 0.655, blue: 0.435, alpha: 1.0).setFill()
            }
            path.fill()
            let symbolName = kind == .session ? "bubble.left.and.bubble.right.fill" : "camera.aperture"
            let config = UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
            if let symbol = UIImage(systemName: symbolName, withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let symSize = symbol.size
                let symRect = CGRect(
                    x: (size.width - symSize.width) * 0.5,
                    y: (size.height - symSize.height) * 0.5,
                    width: symSize.width,
                    height: symSize.height
                )
                symbol.draw(in: symRect)
            }
        }
        return rendered.withRenderingMode(.alwaysOriginal)
    }
}

private struct VoteActionButton: View {
    let isOn: Bool
    let count: Int?
    let vertical: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst = 0
    @State private var showsBurst = false

    var body: some View {
        Button {
            showsBurst = !isOn && !reduceMotion
            burst += 1
            action()
        } label: {
            if vertical {
                VStack(spacing: 4) {
                    icon.frame(height: 22)
                    countText.font(.system(size: 10, weight: .medium))
                }
                .frame(width: 56, height: 52)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 4) {
                    icon
                    countText.font(.system(size: 12, weight: .medium))
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(VotePressStyle())
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: burst)
    }

    private var icon: some View {
        ZStack {
            if isOn {
                Circle()
                    .fill(ReaderPalette.accent.opacity(0.16))
                    .frame(width: 30, height: 30)
                Circle()
                    .strokeBorder(ReaderPalette.accent.opacity(0.26), lineWidth: 0.75)
                    .frame(width: 30, height: 30)
            }
            if showsBurst {
                LikeBurst().id(burst)
            }
            Image(systemName: isOn ? "hand.thumbsup.fill" : "hand.thumbsup")
                .font(.system(size: 17, weight: isOn ? .semibold : .medium))
                .foregroundStyle(ReaderPalette.accent)
                .symbolEffect(.bounce, options: .speed(1.15), value: reduceMotion ? -1 : burst)
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.18), value: isOn)
        }
        .frame(width: 26, height: 22)
    }

    private var countText: some View {
        Text(displayCount(count))
            .monospacedDigit()
            .fontWeight(isOn ? .semibold : .medium)
            .foregroundStyle(ReaderPalette.accent)
            .contentTransition(.numericText(value: Double(count ?? 0)))
            .animation(.snappy(duration: 0.28), value: count)
            .animation(.easeInOut(duration: 0.18), value: isOn)
    }
}

private struct VotePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

private struct LikeBurst: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(ReaderPalette.accent.opacity(0.5), lineWidth: 1)
                .frame(width: 18, height: 18)
                .scaleEffect(expanded ? 2.05 : 0.55)
                .opacity(expanded ? 0 : 0.85)
            ForEach(0..<7, id: \.self) { index in
                let angle = Double(index) / 7 * .pi * 2 - .pi / 2
                Circle()
                    .fill(ReaderPalette.accent.opacity(index.isMultiple(of: 2) ? 0.9 : 0.55))
                    .frame(width: index.isMultiple(of: 2) ? 3.5 : 2.2,
                           height: index.isMultiple(of: 2) ? 3.5 : 2.2)
                    .offset(x: expanded ? cos(angle) * 16 : 0,
                            y: expanded ? sin(angle) * 16 : 0)
                    .scaleEffect(expanded ? 0.2 : 1)
                    .opacity(expanded ? 0 : 1)
            }
            Image(systemName: "sparkle")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(ReaderPalette.accent)
                .offset(x: 11, y: -13)
                .scaleEffect(expanded ? 0.2 : 1)
                .opacity(expanded ? 0 : 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.58)) { expanded = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LoadingSkeleton: View {
    enum Kind { case feed, answer, comment, body, collection }
    let kind: Kind
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private func line(_ trailing: CGFloat = 0, height: CGFloat = 10) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: height / 2).fill(Color.primary.opacity(0.10)).frame(height: height)
            if trailing > 0 { Spacer(minLength: trailing).frame(width: trailing) }
        }
    }

    private var avatar: some View { Circle().fill(Color.primary.opacity(0.10)).frame(width: 24, height: 24) }

    var body: some View {
        Group {
            switch kind {
            case .feed, .answer:
                VStack(alignment: .leading, spacing: 11) {
                    if kind == .feed { line(45, height: 14); line(110, height: 14) }
                    HStack(spacing: 8) { avatar; line(130, height: 9) }
                    line(20); line(80)
                }.padding(.vertical, 14)
            case .comment:
                HStack(alignment: .top, spacing: 8) {
                    avatar
                    VStack(alignment: .leading, spacing: 9) { line(150); line(28); line(100) }
                }.padding(.vertical, 8)
            case .body:
                VStack(alignment: .leading, spacing: 13) {
                    line(40, height: 18); line(110, height: 18)
                    HStack(spacing: 9) { avatar; line(150) }.padding(.vertical, 10)
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(spacing: 12) { line(); line(10); line(65) }.padding(.bottom, 16)
                    }
                }.frame(maxWidth: 680).padding(.horizontal, 24).padding(.top, 28)
            case .collection:
                line(100, height: 13).padding(.vertical, 12)
            }
        }
        .opacity(dimmed && !reduceMotion ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dimmed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}


private extension View {
    func readerGlassCapsule() -> some View {
        glassEffect(.regular.interactive(), in: Capsule())
    }
}

private enum ReaderPalette {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.68, green: 0.77, blue: 0.72, alpha: 1)
            : UIColor(red: 0.30, green: 0.41, blue: 0.36, alpha: 1)
    })
    static let directory = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.116, blue: 0.111, alpha: 1)
            : UIColor(red: 0.953, green: 0.953, blue: 0.933, alpha: 1)
    })
    static let page = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.098, green: 0.110, blue: 0.106, alpha: 1)
            : UIColor(red: 0.984, green: 0.980, blue: 0.969, alpha: 1)
    })
    static let selection = accent.opacity(0.18)
    /// The reading sheet rests on the directory, so its leading edge casts a
    /// soft shadow onto the directory's trailing edge. Dark mode needs extra
    /// weight: a black-on-black shadow all but disappears without it.
    static let edgeShadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.40)
            : UIColor.black.withAlphaComponent(0.10)
    })
}

private enum ReadingDefaults {
    static var fontSize: Double { UIDevice.current.userInterfaceIdiom == .phone ? 17 : 18 }
    static var width: Int { UIDevice.current.userInterfaceIdiom == .pad ? 800 : 680 }
}

/// The reader's chosen size stays the base. System text size scales it, and a
/// cap keeps accessibility sizes from blowing the column apart.
private enum ReaderTypography {
    static func appliedSize(base: Double, dynamicType: DynamicTypeSize) -> Double {
        min(40, max(15, base * scale(for: dynamicType)))
    }

    static func scale(for dynamicType: DynamicTypeSize) -> Double {
        switch dynamicType {
        case .xSmall: return 0.82
        case .small: return 0.88
        case .medium: return 0.94
        case .large: return 1
        case .xLarge: return 1.12
        case .xxLarge: return 1.23
        case .xxxLarge: return 1.35
        case .accessibility1: return 1.64
        case .accessibility2: return 1.94
        case .accessibility3: return 2.35
        case .accessibility4: return 2.76
        case .accessibility5: return 3.12
        @unknown default: return 1
        }
    }
}

private struct AuthorProfileView: View {
    let item: ReadingItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                AvatarView(url: item.avatarURL, size: 68)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                VStack(spacing: 5) {
                    Text(item.author.isEmpty ? "匿名用户" : item.author)
                        .font(.title3.weight(.semibold))
                    if let region = normalizedIPRegion(item.ipInfo) {
                        RegionBadge(ip: region)
                    }
                }
                if let headline = item.authorHeadline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let token = item.authorToken, !token.isEmpty {
                    Link(destination: URL(string: "https://www.zhihu.com/people")!.appendingPathComponent(token)) {
                        Label("在知乎查看主页", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(ReaderPalette.accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ReaderPalette.accent)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("作者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
            } }
        }
        .tint(ReaderPalette.accent)
        .presentationDetents([.height(270)])
        .presentationDragIndicator(.visible)
    }
}

private struct CollectionPickerView: View {
    let item: ReadingItem
    let onChange: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var collections: [ReadingCollection] = []
    @State private var loading = true
    @State private var savingID: String?
    @State private var error: String?
    private let source = ZhihuSource()

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    ForEach(0..<4, id: \.self) { _ in LoadingSkeleton(kind: .collection, label: "正在加载收藏夹").listRowSeparator(.hidden) }
                }
                else if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                    }
                } else if collections.isEmpty {
                    Text("没有可用的收藏夹，请先在知乎创建。").foregroundStyle(.secondary)
                } else {
                    ForEach(collections) { collection in
                        Button {
                            Task { await toggle(collection) }
                        } label: {
                            HStack {
                                Text(collection.title).foregroundStyle(.primary)
                                Spacer()
                                if savingID == collection.id { Text("正在保存").font(.caption).foregroundStyle(.secondary) }
                                else if collection.isFavorited { Image(systemName: "checkmark").foregroundStyle(ReaderPalette.accent) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(savingID != nil)
                    }
                }
            }
            .navigationTitle("收藏到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
            } }
        }
        .tint(ReaderPalette.accent)
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do {
            collections = try await source.collections(for: item)
            onChange(collections.contains(where: \.isFavorited))
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func toggle(_ collection: ReadingCollection) async {
        savingID = collection.id
        defer { savingID = nil }
        do {
            try await source.setCollection(collection, for: item, add: !collection.isFavorited)
            if let index = collections.firstIndex(where: { $0.id == collection.id }) {
                collections[index].isFavorited.toggle()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onChange(collections.contains(where: \.isFavorited))
        } catch { self.error = error.localizedDescription }
    }
}

private func displayCount(_ count: Int?) -> String {
    guard let count else { return "—" }
    if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000) }
    return String(count)
}

private func compactCount(_ symbol: String, count: Int) -> some View {
    HStack(spacing: 4) {
        Image(systemName: symbol)
        Text(displayCount(count)).monospacedDigit()
    }.fixedSize(horizontal: true, vertical: false)
}

/// 评论者为当前回答/文章作者时的克制胶囊标识。
private struct CommentAuthorBadge: View {
    var body: some View {
        Text("作者")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ReaderPalette.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(ReaderPalette.accent.opacity(0.14), in: Capsule())
            .fixedSize()
            .accessibilityLabel("回答作者")
    }
}

/// 倒水滴定位图标：与阅读正文 HTML 内的 SVG 路径保持同一几何造型，替代 SF Symbols 的图钉图标。
private struct TeardropPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24.0
        let ox = rect.midX - 12.0 * scale
        let oy = rect.midY - 12.0 * scale
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: ox + x * scale, y: oy + y * scale)
        }
        var path = Path()
        path.move(to: pt(12.0, 21.2))
        path.addCurve(
            to: pt(18.6, 10.1),
            control1: pt(16.3, 16.8),
            control2: pt(18.6, 13.3)
        )
        path.addArc(
            center: pt(12.0, 10.1),
            radius: 6.6 * scale,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: true
        )
        path.addCurve(
            to: pt(12.0, 21.2),
            control1: pt(5.4, 13.3),
            control2: pt(7.7, 16.8)
        )
        path.closeSubpath()
        let r = 2.2 * scale
        let c = pt(12.0, 9.9)
        path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        return path
    }
}

/// 列表中与评论区内统一的统计徽标：地区、赞同、回复。
private struct RegionBadge: View {
    let ip: String
    var body: some View {
        HStack(spacing: 3) {
            TeardropPinShape()
                .stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)
            Text(ip).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("地区：\(ip)")
    }
}

private struct MetadataCount: View {
    let symbol: String
    let count: Int
    let accessibilityLabel: String
    var body: some View {
        compactCount(symbol, count: count)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct ItemRow: View {
    let item: ReadingItem
    var isHot = false
    var hotRank: Int? = nil
    var showsTitle: Bool = true
    var isRead: Bool = false
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var excerptSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var rankSize: CGFloat = 15

    /// Counts and the author's region sit on the author line, right-aligned,
    /// matching the reading header. The thumbnail shares the whole text block.
    private var showsInlineCounts: Bool {
        item.kind == .answer && (item.upCount != nil || item.commentCount != nil)
    }

    var body: some View {
        // 缩略图与整块文字（标题/作者/摘要）同高区域并排，而不是只把标题撑到
        // 图片高度；短标题不会在左下方留下空洞，长标题也能占满可用宽度。
        HStack(alignment: .top, spacing: 10) {
            if let hotRank {
                Text(String(format: "%02d", hotRank))
                    .font(.system(size: rankSize, weight: hotRank <= 3 ? .bold : .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(hotRank <= 3 ? ReaderPalette.accent : Color.secondary)
                    .frame(minWidth: 24, alignment: .leading)
                    .padding(.top, 2)
                    .accessibilityLabel("热榜第 \(hotRank) 名")
            }
            VStack(alignment: .leading, spacing: 8) {
                if showsTitle {
                    Text(item.title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .foregroundStyle(isRead ? Color.primary.opacity(0.72) : Color.primary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !isHot, (!item.author.isEmpty || showsInlineCounts) {
                    HStack(spacing: 7) {
                        if !item.author.isEmpty {
                            AvatarView(url: item.avatarURL, size: showsTitle ? 22 : 28)
                            Text(item.author).font(showsTitle ? .caption.weight(.medium) : .headline)
                                .foregroundStyle(showsTitle ? Color.secondary : (isRead ? Color.primary.opacity(0.62) : Color.primary))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if showsInlineCounts {
                            Spacer(minLength: 8)
                            metadataRow
                        }
                    }
                } else if isHot, showsInlineCounts {
                    HStack {
                        Spacer(minLength: 0)
                        metadataRow
                    }
                }
                if !item.excerpt.isEmpty {
                    Text(htmlText(item.excerpt))
                        .font(.system(size: excerptSize))
                        .foregroundStyle(isRead ? Color.secondary.opacity(0.72) : Color.secondary)
                        .lineSpacing(3)
                        .lineLimit(2)
                }
                if !showsInlineCounts, item.kind == .answer, item.upCount != nil || item.commentCount != nil {
                    metadataRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsTitle, let url = item.imageURL {
                FeedThumbnailView(url: url, height: item.excerpt.isEmpty ? 56 : 82)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 10) }
    }

    /// 列表作者行、评论作者行共用：地区 + 赞同 + 评论，统一 12pt 间隔。
    private var metadataRow: some View {
        HStack(spacing: 12) {
            if let region = normalizedIPRegion(item.ipInfo) {
                RegionBadge(ip: region)
            }
            if let count = item.upCount {
                MetadataCount(symbol: "hand.thumbsup", count: count,
                              accessibilityLabel: "\(displayCount(count)) 次赞同")
            }
            if let count = item.commentCount {
                MetadataCount(symbol: "bubble.right", count: count,
                              accessibilityLabel: "\(displayCount(count)) 条评论")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}


@MainActor
final class CommentEmojiLoader {
    static let shared = CommentEmojiLoader()
    static let placeholderImage: UIImage = {
        let size = CGSize(width: 21, height: 21)
        return UIGraphicsImageRenderer(size: size).image { _ in }
    }()

    private var images: [URL: UIImage] = [:]
    private var tasks: [URL: Task<UIImage?, Never>] = [:]
    private var preloadTask: Task<Void, Never>?
    private let diskDirectory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("wize-comment-emojis", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        for url in CommentEmoji.allURLs {
            if let diskImage = loadFromDisk(url) {
                images[url] = diskImage
            }
        }
    }

    func cachedImage(_ url: URL) -> UIImage? {
        if let image = images[url] { return image }
        if let diskImage = loadFromDisk(url) {
            images[url] = diskImage
            return diskImage
        }
        return nil
    }

    func image(for url: URL) async -> UIImage? {
        if let image = cachedImage(url) { return image }
        if let task = tasks[url] { return await task.value }
        let diskDir = diskDirectory
        let task = Task { await Self.fetch(url, diskDirectory: diskDir) }
        tasks[url] = task
        let image = await task.value
        tasks[url] = nil
        if let image { images[url] = image }
        return image
    }

    /// 启动后预载全部表情图，评论区首帧就能直接画图而不是先显示 [xxx] 再替换。
    func preloadAll() async {
        if let preloadTask {
            await preloadTask.value
            return
        }
        let urls = CommentEmoji.allURLs.filter { cachedImage($0) == nil }
        guard !urls.isEmpty else { return }
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                var iterator = urls.makeIterator()
                for _ in 0..<16 {
                    guard let url = iterator.next() else { break }
                    group.addTask { _ = await self.image(for: url) }
                }
                while await group.next() != nil {
                    guard let url = iterator.next() else { continue }
                    group.addTask { _ = await self.image(for: url) }
                }
            }
        }
        preloadTask = task
        await task.value
    }

    func preload(_ urls: [URL]) {
        let pending = Set(urls).filter { cachedImage($0) == nil }
        guard !pending.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for url in pending {
                    group.addTask { _ = await self.image(for: url) }
                }
            }
        }
    }

    private func loadFromDisk(_ url: URL) -> UIImage? {
        guard let fileURL = Self.cacheFileURL(for: url, in: diskDirectory),
              let data = try? Data(contentsOf: fileURL),
              let decoded = UIImage(data: data) else { return nil }
        let size = CGSize(width: 21, height: 21)
        return UIGraphicsImageRenderer(size: size).image { _ in
            decoded.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private nonisolated static func cacheFileURL(for url: URL, in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let name = url.lastPathComponent.isEmpty ? String(abs(url.absoluteString.hashValue)) : url.lastPathComponent
        return directory.appendingPathComponent(name)
    }

    private nonisolated static func fetch(_ url: URL, diskDirectory: URL?, allowFallback: Bool = true) async -> UIImage? {
        var request = URLRequest(url: url)
        request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let source = UIImage(data: data) else {
            if allowFallback, let fallback = await MainActor.run(body: { CommentEmoji.fallbackURL(for: url) }) {
                if let fallbackImage = await fetch(fallback, diskDirectory: diskDirectory, allowFallback: false) {
                    if let fileURL = cacheFileURL(for: url, in: diskDirectory),
                       let png = fallbackImage.pngData() {
                        try? png.write(to: fileURL, options: .atomic)
                    }
                    return fallbackImage
                }
            }
            return nil
        }
        let size = CGSize(width: 21, height: 21)
        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        if let fileURL = cacheFileURL(for: url, in: diskDirectory),
           let png = rendered.pngData() {
            try? png.write(to: fileURL, options: .atomic)
        }
        return rendered
    }
}

@MainActor
private final class AvatarCache {
    static let shared = AvatarCache()
    private let images = NSCache<NSURL, UIImage>()
    private var pending: [URL: Task<UIImage?, Never>] = [:]

    private init() { images.countLimit = 200; images.totalCostLimit = 20 * 1024 * 1024 }

    func cachedImage(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        if let task = pending[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url)
            request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return UIImage(data: data)
        }
        pending[url] = task
        let image = await task.value
        pending[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        return image
    }

    func prefetch(_ urls: [URL]) async {
        await withTaskGroup(of: Void.self) { group in
            for url in Set(urls) { group.addTask { _ = await self.image(for: url) } }
        }
    }
}

private struct AvatarView: View {
    let url: URL?
    let size: CGFloat
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image = image ?? url.flatMap({ AvatarCache.shared.cachedImage(for: $0) }) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = AvatarCache.shared.cachedImage(for: url) {
                image = cached
                return
            }
            image = nil
            let loaded = await AvatarCache.shared.image(for: url)
            if !Task.isCancelled { image = loaded }
        }
    }
}

private struct FeedThumbnailView: View {
    let url: URL
    let height: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let resolved = image ?? AvatarCache.shared.cachedImage(for: url) {
                Image(uiImage: resolved)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: 72, height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
        .task(id: url) {
            if let cached = AvatarCache.shared.cachedImage(for: url) {
                image = cached
                return
            }
            image = nil
            if let loaded = await AvatarCache.shared.image(for: url), !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.16)) {
                    image = loaded
                }
            }
        }
    }
}

private func htmlText(_ html: String) -> String {
    // NSAttributedString's HTML importer can spin the main run loop while
    // SwiftUI is rendering a List, causing an AttributeGraph reentrancy abort.
    // List previews only need plain text; full answers use the web reader.
    var text = html.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li)\\s*>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
    for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct CommentInlineText: View {
    let segments: [CommentInlineSegment]
    let plainLabel: String
    @State private var images: [URL: UIImage] = [:]

    private var rendered: Text {
        segments.reduce(Text("")) { result, segment in
            switch segment {
            case .text(let value):
                return result + Text(value)
            case .emoji(_, let url):
                let image = images[url] ?? CommentEmojiLoader.shared.cachedImage(url) ?? CommentEmojiLoader.placeholderImage
                // 行内表情图默认与文字基线底部对齐，视觉上会偏高，向下微调；
                // 未就绪时使用同尺寸透明占位图，彻底消除「[xxx] 文字变图片」和行宽跳动。
                return result + Text(Image(uiImage: image)).baselineOffset(-3)
            case .link(let label, let url):
                var attributed = AttributedString(label)
                attributed.link = url
                attributed.foregroundColor = ReaderPalette.accent
                attributed.underlineStyle = .single
                return result + Text(attributed)
            }
        }
    }
    var body: some View {
        rendered.font(.body).textSelection(.enabled)
            .accessibilityLabel(plainLabel)
            .task(id: plainLabel) { await loadEmojis() }
    }
    private func loadEmojis() async {
        let urls = Set(segments.compactMap { segment -> URL? in
            if case .emoji(_, let url) = segment { return url }
            return nil
        })
        for url in urls where images[url] == nil && CommentEmojiLoader.shared.cachedImage(url) == nil {
            if let image = await CommentEmojiLoader.shared.image(for: url), !Task.isCancelled {
                images[url] = image
            }
        }
    }
}

private struct CommentImageView: View {
    let url: URL
    @State private var frame: CGRect = .zero
    @State private var image: UIImage?

    private var resolvedImage: UIImage? {
        image ?? RemoteImageLoader.shared.cachedImage(for: url)
    }

    private var aspectRatio: CGFloat {
        guard let img = resolvedImage, img.size.width > 0, img.size.height > 0 else {
            return 4.0 / 3.0
        }
        return min(max(img.size.width / img.size.height, 0.55), 2.2)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            if let resolvedImage {
                NativeCommentImage(image: resolvedImage)
                    .transition(.opacity)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: 260, maxHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { frame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, newValue in frame = newValue }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            ImagePreviewPresenter.shared.present(url: url, sourceFrame: frame == .zero ? nil : frame)
        }
        .task(id: url) {
            if let cached = RemoteImageLoader.shared.cachedImage(for: url) {
                image = cached
                return
            }
            if let loaded = await RemoteImageLoader.shared.image(for: url), !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.16)) {
                    image = loaded
                }
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("查看评论图片")
    }
}

/// 原生 UIImageView 承载评论区静态图与 GIF 动图（无需为每张图创建 WKWebView）。
private struct NativeCommentImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image {
            view.image = image
        }
    }
}

private func htmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private struct ReaderWebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ReaderImageMenuTarget: Identifiable {
    let url: URL
    let frame: CGRect
    let touchPoint: CGPoint
    var id: String { "\(url.absoluteString)|\(Int(touchPoint.x))|\(Int(touchPoint.y))" }
}

/// 长按正文图片时在手指按下瞬间立即在手指附近弹出的浮动菜单（无须松开手指）。
private struct ReaderImageContextMenuOverlay: View {
    let target: ReaderImageMenuTarget
    let onZoom: () -> Void
    let onSave: () -> Void
    let onDismiss: () -> Void

    private let menuWidth: CGFloat = 168
    private let menuHeight: CGFloat = 92

    var body: some View {
        GeometryReader { proxy in
            let globalOrigin = proxy.frame(in: .global).origin
            let localTouch = CGPoint(
                x: target.touchPoint.x - globalOrigin.x,
                y: target.touchPoint.y - globalOrigin.y
            )
            let clampedX = min(
                max(localTouch.x, menuWidth * 0.5 + 16),
                max(proxy.size.width - menuWidth * 0.5 - 16, menuWidth * 0.5 + 16)
            )
            // 默认显示在手指正上方，避免手指遮挡菜单；若靠近顶部则显示在手指正下方。
            let prefersAbove = localTouch.y - 70 - menuHeight * 0.5 >= 56
            let rawY = prefersAbove ? (localTouch.y - 68) : (localTouch.y + 68)
            let clampedY = min(
                max(rawY, menuHeight * 0.5 + 56),
                max(proxy.size.height - menuHeight * 0.5 - 40, menuHeight * 0.5 + 56)
            )

            ZStack {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                VStack(spacing: 0) {
                    Button(action: onZoom) {
                        HStack {
                            Text("放大查看")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 45)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()

                    Button(action: onSave) {
                        HStack {
                            Text("存储到照片")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 45)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.primary)
                .frame(width: menuWidth)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                .position(x: clampedX, y: clampedY)
            }
        }
        .ignoresSafeArea()
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

private struct HTMLReader: UIViewRepresentable {
    let html: String
    let item: ReadingItem
    var stream: [ReadingItem] = []
    var paperCards = false
    var isPreview = false
    var onChromeVisibility: (Bool) -> Void = { _ in }
    var scrollRequest: ReaderModel.ScrollRequest? = nil
    var onVisibleAnswer: (String) -> Void = { _ in }
    var onNearEnd: () -> Void = {}
    var onOpenLink: (URL) -> Void = { _ in }
    var onOpenImage: (URL, CGRect, CGPoint) -> Void = { _, _, _ in }
    var onCompactTitle: (Bool) -> Void = { _ in }
    var restoreOffset: CGFloat = 0
    var onReadingOffset: (CGFloat) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var fontManager = ReadingFontManager.shared
    @AppStorage("reading.fontSize") private var fontSize = ReadingDefaults.fontSize
    @AppStorage("reading.lineHeight") private var lineHeight = 1.8
    @AppStorage("reading.width") private var readingWidth = ReadingDefaults.width
    @AppStorage("reading.paragraphSpacing") private var paragraphSpacing = 1.0
    @AppStorage("reading.font") private var font = "system"
    @AppStorage("reading.theme") private var theme = "system"
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let initialPositionScript = WKUserScript(
            source: """
            (() => {
                const body = document.body;
                if (!body) return;
                const id = body.getAttribute('data-wize-anchor');
                const sections = Array.from(document.querySelectorAll('section[data-wize-answer]'));
                let target = null;
                if (id && sections.length > 1 && sections[0].getAttribute('data-wize-answer') !== id) {
                    const el = sections.find(e => e.getAttribute('data-wize-answer') === id);
                    if (el) {
                        window.scrollTo(0, Math.max(0, el.getBoundingClientRect().top + window.scrollY));
                        target = el;
                    }
                }
                const active = target || sections.find(e => e.getAttribute('data-wize-answer') === id) || sections[0];
                sections.forEach(section => section.classList.remove('current'));
                if (active) active.classList.add('current');
                const index = sections.indexOf(active);
                if (index >= 0) {
                    sections.slice(index, index + 2).forEach(s => s.querySelectorAll('img[loading=lazy]').forEach(img => img.loading = 'eager'));
                }
                body.removeAttribute('data-wize-pending');
            })()
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(initialPositionScript)
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.alwaysBounceHorizontal = false
        view.scrollView.isDirectionalLockEnabled = true
        // 阅读区只允许纵向滚动：禁用横向拖动与缩放导致的面板平移。
        view.scrollView.showsHorizontalScrollIndicator = false
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.scrollView.delegate = context.coordinator
        // 单击不再打开查看器：阅读时点击图片不应打断滚动；长按按下瞬间即在手指附近弹出菜单。
        let imageLongPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(HTMLReader.Coordinator.handleImageLongPress(_:)))
        imageLongPress.minimumPressDuration = 0.35
        imageLongPress.allowableMovement = 14
        imageLongPress.cancelsTouchesInView = false
        imageLongPress.delegate = context.coordinator
        view.addGestureRecognizer(imageLongPress)
        // 视频卡片保持单击播放；只有点中视频才响应，图片仍然走长按菜单。
        let videoTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(HTMLReader.Coordinator.handleVideoTap(_:)))
        videoTap.cancelsTouchesInView = false
        videoTap.delegate = context.coordinator
        view.addGestureRecognizer(videoTap)
        context.coordinator.attach(view)
        context.coordinator.contentSizeObservation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak coordinator = context.coordinator, weak view] _, _ in
            DispatchQueue.main.async {
                guard let coordinator, let view else { return }
                coordinator.inspectAfterLayout(view)
            }
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let colors: (String, String, String)
        switch theme {
        case "paper": colors = ("#f5f0e6", "#302b25", "light")
        case "light": colors = ("#ffffff", "#222222", "light")
        case "dark": colors = ("#1d2023", "#e5e5e3", "dark")
        default: colors = ("light-dark(#fbfaf7, #191c1b)", "light-dark(#282b28, #e4e7e3)", "light dark")
        }
        let selectedFont = ReadingFontOption.option(for: font)
        let fontFamily = selectedFont.cssFamily
        let fontFaceCSS = fontManager.fontFaceCSS[selectedFont.id] ?? ""
        let fontFaceKey = "\(selectedFont.id):\(fontFaceCSS.count)"
        let appliedFontSize = ReaderTypography.appliedSize(base: fontSize, dynamicType: dynamicTypeSize)
        let paperColor: String
        switch theme {
        case "paper": paperColor = "#fbf7ef"
        case "light": paperColor = "#ffffff"
        case "dark": paperColor = "#272b2e"
        default: paperColor = "light-dark(#ffffff, #252a27)"
        }
        let cardCSS = paperCards ? """
        body { padding-left: 16px; padding-right: 16px; }
        .answer { background: \(paperColor); border: 1px solid rgba(128,128,128,.12); border-radius: 12px; padding: 26px 72px 28px 22px; box-shadow: 0 5px 18px rgba(0,0,0,.08); }
        .answer + .answer { border-top: 1px dotted rgba(128,128,128,.28); margin-top: 18px; padding-top: 26px; }
        """ : ""
        let phoneGapColor: String
        switch theme {
        case "paper": phoneGapColor = "#e9e1d4"
        case "light": phoneGapColor = "#eeefec"
        case "dark": phoneGapColor = "#141719"
        default: phoneGapColor = "light-dark(#e9ece7, #111513)"
        }
        let phoneAnswerCSS = paperCards || isPreview ? "" : """
        body { margin: 0 auto; padding: 0 0 100px; background: \(colors.0); }
        header { background: \(colors.0); padding: 36px clamp(20px, 5vw, 28px) 0; }
        header h1 { margin-bottom: 0; }
        .answer { background: \(colors.0); padding: 26px clamp(20px, 5vw, 28px) 32px; box-shadow: 0 3px 6px -4px rgba(0,0,0,.22); }
        .answer + .answer { border: 0; border-top: 12px solid \(phoneGapColor); margin-top: 0; padding-top: 26px; background-clip: padding-box; }
        .byline { margin-bottom: 20px; }
        .author-name { font-size: 15px; font-weight: 600; }
        """
        // The settings preview uses the same document and typography as a real answer.
        let previewCSS = isPreview ? """
        body { margin: 0 auto; padding-top: 0; padding-bottom: 0; }
        header, .byline { display: none; }
        .answer { box-shadow: none; }
        """ : ""
        let title = htmlEscape(item.title)
        let parts = stream.isEmpty ? [item] : stream
        let presentationKey = "\(colors.0)|\(colors.1)|\(colors.2)|\(fontFamily)|\(appliedFontSize)|\(lineHeight)|\(readingWidth)|\(paragraphSpacing)|\(title)|\(cardCSS)|\(previewCSS)"
        context.coordinator.onVisibleAnswer = onVisibleAnswer
        context.coordinator.onNearEnd = onNearEnd
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onOpenImage = onOpenImage
        context.coordinator.onChromeVisibility = onChromeVisibility
        context.coordinator.onCompactTitle = onCompactTitle
        context.coordinator.restoreOffset = restoreOffset
        context.coordinator.onReadingOffset = onReadingOffset
        context.coordinator.streamEnabled = !stream.isEmpty
        // Scrolling only changes the active answer, never the stream contents. Skip the
        // expensive document build (every answer's HTML is scanned for images) unless
        // what the document is made of actually changed.
        let documentKey = documentFingerprint(parts: parts, presentationKey: presentationKey,
                                              fallbackHTML: html)
        if !context.coordinator.lastHTML.isEmpty, documentKey == context.coordinator.lastDocumentKey {
            if context.coordinator.fontFaceKey != fontFaceKey {
                context.coordinator.updateFontFace(fontFaceCSS, key: fontFaceKey, in: view)
            }
            if let request = scrollRequest, context.coordinator.lastScrollToken != request.token {
                context.coordinator.lastScrollToken = request.token
                context.coordinator.scrollToAnswer(request.id, in: view)
            }
            return
        }
        let sectionList = parts.enumerated().map { index, answer in
            let author = htmlEscape(answer.author.isEmpty ? "匿名用户" : answer.author)
            let avatar = answer.avatarURL.map { "<img class=\"avatar\" loading=\"lazy\" decoding=\"async\" src=\"\(htmlEscape($0.absoluteString))\" alt=\"\">" } ?? ""
            let content = expandedVideoHTML(answer.contentHTML ?? (index == 0 ? html : ""))
            let ip = normalizedIPRegion(answer.ipInfo) ?? ""
            let ipSpan = ip.isEmpty ? "" : "<span class=\"ip\"><svg viewBox=\"0 0 24 24\" aria-label=\"地区\"><path d=\"M12 21.2c4.3-4.4 6.6-7.9 6.6-11.1a6.6 6.6 0 1 0-13.2 0c0 3.2 2.3 6.7 6.6 11.1z\"/><circle cx=\"12\" cy=\"9.9\" r=\"2.2\"/></svg>\(htmlEscape(ip))</span>"
            let counts = """
            <div class="counts">\(ipSpan)<span><svg viewBox="0 0 24 24" aria-label="赞同"><path d="M7 10v10H4V10h3zm2 10V10l4-7c.4-.8 1.6-.5 1.6.4V8H19c1.3 0 2.2 1.2 1.9 2.4l-1.6 7.5A2.5 2.5 0 0 1 16.8 20H9z"/></svg><b data-count="up">\(displayCount(answer.upCount))</b></span><span><svg viewBox="0 0 24 24" aria-label="评论"><path d="M4 5.5h16v11H11l-4.5 3v-3H4z"/></svg><b data-count="comments">\(displayCount(answer.commentCount))</b></span></div>
            """
            let byline = "<div class=\"byline\">\(avatar)<span class=\"author-name\">\(author)</span>\(counts)</div>"
            return "<section class=\"answer\" data-wize-answer=\"\(htmlEscape(answer.id))\">\(byline)<main>\(expandedImageHTML(content))</main></section>"
        }
        let sections = sectionList.joined()
        let headingFontFamily = selectedFont.isBuiltIn ? "'Songti SC', 'STSong', Georgia, serif" : fontFamily
        let style = """
        :root { --wize-link: light-dark(#527863, #a7c4b1); overflow-x: hidden; color-scheme: \(colors.2); background: \(colors.0); color: \(colors.1); } body[data-wize-pending] { opacity: 0; animation: wize-reveal .01s linear .7s forwards; } @keyframes wize-reveal { to { opacity: 1; } } body { box-sizing: border-box; font: \(appliedFontSize)px \(fontFamily); line-height: \(lineHeight); max-width: \(readingWidth)px; margin: 36px auto \(paperCards ? 0 : 36)px; padding: 0 clamp(20px, 5vw, 28px) \(paperCards ? 0 : 12)px; overflow-wrap: anywhere; } h1 { font-family: \(headingFontFamily); font-size: clamp(1.28em, 3.2vw, 1.5em); font-weight: 600; line-height: 1.45; letter-spacing: .02em; margin: 0 0 30px; } .byline { display:flex; align-items:center; gap:10px; opacity:.78; font: 500 14px -apple-system, sans-serif; margin: 0 -8px 26px; padding: 6px 8px; border-left: 2px solid transparent; border-radius: 3px; } .avatar { width:32px; height:32px; border-radius:50%; object-fit:cover; } .counts { display:flex; gap:22px; font: 12px -apple-system, sans-serif; opacity:.58; margin-top:24px; } .counts b { font-weight:500; } .counts .ip { max-width:9em; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; } .answer + .answer { border-top: 1px dotted rgba(128,128,128,.32); margin-top: 32px; padding-top: 28px; } p { margin: 0 0 \(paragraphSpacing * 0.7)em; } main p:empty, main p:has(> br:only-child) { display:none; } img, video { max-width: 100%; height: auto; -webkit-touch-callout: none; } main img { border-radius: 5px; } .avatar { height:32px; } a { color: var(--wize-link); text-decoration-line: underline; text-decoration-color: color-mix(in srgb, currentColor 34%, transparent); text-decoration-thickness: .06em; text-underline-offset: .18em; text-decoration-skip-ink: auto; font-weight: 500; -webkit-tap-highlight-color: transparent; } a:visited { color: var(--wize-link); } a:active { opacity: .58; } main a { overflow-wrap: anywhere; } pre { white-space: pre-wrap; }
        .byline { opacity: 1; margin-bottom: 20px; transition: border-color .18s ease; } .author-name { min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; } .answer.current .byline { border-left-color: var(--wize-link); } .counts { margin:0 0 0 auto; flex-shrink:0; gap:12px; opacity:.68; } .counts span { display:inline-flex; align-items:center; gap:6px; } .counts .ip { max-width:9em; } .counts svg { width:15px; height:15px; fill:none; stroke:currentColor; stroke-width:1.5; stroke-linejoin:round; stroke-linecap:round; } @media (prefers-reduced-motion: reduce) { .byline { transition: none; } }
        .wize-video { position:relative; display:block; margin:1.1em 0; border-radius:8px; overflow:hidden; background:#111; }
        .wize-video-poster { display:block; width:100%; height:auto; margin:0; border-radius:0; }
        .wize-video:not(:has(.wize-video-poster)) { aspect-ratio:16/9; background:linear-gradient(135deg,#2d3833,#111); }
        .wize-video-play { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; background:linear-gradient(180deg,rgba(0,0,0,.02),rgba(0,0,0,.28)); }
        .wize-video-play svg { width:54px; height:54px; padding:11px; border-radius:50%; background:rgba(255,255,255,.94); fill:#1b1f1d; box-shadow:0 6px 20px rgba(0,0,0,.24); }
        .wize-video-title { position:absolute; left:14px; right:14px; bottom:12px; color:#fff; font:500 13px -apple-system,sans-serif; line-height:1.35; text-shadow:0 1px 4px rgba(0,0,0,.55); }
        .wize-video video { display:block; width:100%; height:auto; background:#000; }
        .wize-video.is-playing { aspect-ratio:auto; }
        .wize-video-toggle { position:absolute; left:50%; top:50%; width:54px; height:54px; margin:-27px 0 0 -27px; display:none; align-items:center; justify-content:center; border-radius:50%; background:rgba(255,255,255,.94); box-shadow:0 6px 20px rgba(0,0,0,.24); pointer-events:none; }
        .wize-video-toggle svg { width:22px; height:22px; fill:#1b1f1d; }
        .wize-video.is-paused .wize-video-toggle { display:flex; }
        video::-webkit-media-controls-overlay-enclosure, video::-webkit-media-controls-start-playback-button { display:none !important; -webkit-appearance:none; }
        .wize-video[data-loading="1"] .wize-video-play svg { animation: wize-video-pulse 1s ease-in-out infinite; }
        @keyframes wize-video-pulse { 50% { transform:scale(.86); opacity:.55; } }
        .wize-video-error { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; padding:16px; color:#fff; font:500 13px -apple-system,sans-serif; text-align:center; background:rgba(0,0,0,.6); }
        main blockquote { margin: 1.2em 0; padding: .15em 0 .15em 1.05em; border-left: 2.5px solid color-mix(in srgb, var(--wize-link) 55%, transparent); color: inherit; opacity: .84; }
        main img.emojione, main img.ztext-emoji { display: inline-block; width: 1.25em; height: 1.25em; vertical-align: -0.18em; margin: 0 .06em; border-radius: 0; }
        main hr { border: 0; height: 0; border-top: 1.5px dotted color-mix(in srgb, currentColor 36%, transparent); margin: 2em 0; }
        main p:last-child { margin-bottom: 0; }
        main figure { margin: .8em 0; }
        main figcaption { margin-top: .4em; font-size: .8em; line-height: 1.5; text-align: center; opacity: .68; }
        main ul, main ol { padding-left: 1.5em; }
        main li + li { margin-top: .2em; }
        main code { font: .88em ui-monospace, 'SF Mono', Menlo, monospace; padding: .16em .38em; border-radius: 5px; background: color-mix(in srgb, currentColor 6.5%, transparent); }
        main pre { margin: 1.15em 0; padding: 14px 16px; border-radius: 9px; background: color-mix(in srgb, currentColor 5.5%, transparent); border: 1px solid color-mix(in srgb, currentColor 10%, transparent); font: .86em ui-monospace, 'SF Mono', Menlo, monospace; line-height: 1.6; overflow-x: auto; overflow-wrap: normal; }
        main pre code { font-size: inherit; padding: 0; border-radius: 0; background: transparent; }
        main table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; margin: 1.15em 0; font-size: .92em; line-height: 1.55; }
        main th, main td { padding: 8px 12px; border: 1px solid color-mix(in srgb, currentColor 14%, transparent); text-align: left; vertical-align: top; }
        main th { background: color-mix(in srgb, currentColor 5.5%, transparent); font-weight: 600; }
        \(cardCSS)
        \(phoneAnswerCSS)
        \(previewCSS)
        """
        let document = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"><style>\(style)</style><style id="wize-font-face"></style></head><body data-wize-anchor="\(htmlEscape(item.id))" data-wize-pending="1"><header><h1>\(title)</h1></header>\(sections)</body></html>
        """
        if context.coordinator.lastHTML != document {
            let coordinator = context.coordinator
            if !coordinator.lastHTML.isEmpty, coordinator.sections == sectionList,
               coordinator.documentTitle == title, coordinator.presentationKey != presentationKey {
                coordinator.presentationKey = presentationKey
                coordinator.lastHTML = document
                coordinator.lastDocumentKey = documentKey
                coordinator.updateFontFace(fontFaceCSS, key: fontFaceKey, in: view)
                coordinator.updateStyle(style, in: view, preservePosition: !isPreview)
                return
            }
            if coordinator.presentationKey == presentationKey,
               !coordinator.sections.isEmpty,
               sectionList.count > coordinator.sections.count,
               let start = (0...(sectionList.count - coordinator.sections.count)).first(where: {
                   Array(sectionList[$0..<($0 + coordinator.sections.count)]) == coordinator.sections
               }) {
                let before = sectionList.prefix(start).joined()
                let after = sectionList.dropFirst(start + coordinator.sections.count).joined()
                coordinator.sections = sectionList
                coordinator.lastHTML = document
                coordinator.lastDocumentKey = documentKey
                coordinator.previousCount = parts.count
                coordinator.previousFirstID = parts.first?.id
                coordinator.enqueueSurrounding(before: before, after: after, in: view)
                return
            }
            coordinator.presentationKey = presentationKey
            coordinator.documentTitle = title
            coordinator.sections = sectionList
            coordinator.cancelPendingAppends()
            coordinator.userHasScrolled = false
            coordinator.noteCompactTitle(false)
            if context.coordinator.lastHTML.isEmpty, parts.first?.id != item.id,
               parts.contains(where: { $0.id == item.id }) {
                context.coordinator.pendingAnchorID = item.id
                context.coordinator.pendingOffset = 0
            }
            if !context.coordinator.lastHTML.isEmpty {
                let extent = max(view.scrollView.contentSize.height - view.scrollView.bounds.height, 1)
                if context.coordinator.previousCount == 1, context.coordinator.previousFirstID != parts.first?.id,
                   parts.contains(where: { $0.id == item.id }) {
                    context.coordinator.pendingAnchorID = item.id
                    context.coordinator.pendingOffset = max(0, view.scrollView.contentOffset.y)
                } else if context.coordinator.previousCount != parts.count {
                    context.coordinator.pendingOffset = max(0, view.scrollView.contentOffset.y)
                } else {
                    context.coordinator.pendingScrollFraction = max(0, view.scrollView.contentOffset.y / extent)
                }
            }
            context.coordinator.previousCount = parts.count
            context.coordinator.previousFirstID = parts.first?.id
            context.coordinator.lastHTML = document
            context.coordinator.lastDocumentKey = documentKey
            coordinator.fontFaceKey = fontFaceKey
            coordinator.loadingDocument = true
            coordinator.didRestoreOffset = false
            coordinator.lastRestoreExtent = -1
            let initialHTML = fontFaceCSS.isEmpty
                ? document
                : document.replacingOccurrences(of: "<style id=\"wize-font-face\"></style>", with: "<style id=\"wize-font-face\">\(fontFaceCSS)</style>")
            view.loadHTMLString(initialHTML, baseURL: URL(string: "https://www.zhihu.com"))
        } else {
            if context.coordinator.fontFaceKey != fontFaceKey {
                context.coordinator.updateFontFace(fontFaceCSS, key: fontFaceKey, in: view)
            }
            if let request = scrollRequest, context.coordinator.lastScrollToken != request.token {
                context.coordinator.lastScrollToken = request.token
                context.coordinator.scrollToAnswer(request.id, in: view)
            }
        }
    }
    /// A cheap fingerprint of the document's inputs. Stream items only ever append,
    /// and an item's content is replaced only together with its counts, so the id,
    /// the metadata and the content length identify a rendered section exactly.
    private func documentFingerprint(parts: [ReadingItem], presentationKey: String, fallbackHTML: String) -> Int {
        var hasher = Hasher()
        hasher.combine(presentationKey)
        hasher.combine(item.id)
        hasher.combine(parts.count)
        hasher.combine(fallbackHTML.utf8.count)
        for part in parts {
            hasher.combine(part.id)
            hasher.combine(part.author)
            hasher.combine(part.avatarURL?.absoluteString)
            hasher.combine(part.upCount ?? -1)
            hasher.combine(part.downCount ?? -1)
            hasher.combine(part.commentCount ?? -1)
            hasher.combine(part.contentHTML?.utf8.count ?? -1)
        }
        return hasher.finalize()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var lastHTML = ""
        var lastDocumentKey: Int?
        var previousCount = 0
        var lastScrollToken: UUID?
        var previousFirstID: String?
        var pendingAnchorID: String?
        var restoringAnchor = false
        var pendingScrollFraction: CGFloat?
        var pendingOffset: CGFloat?
        var onVisibleAnswer: (String) -> Void = { _ in }
        var onNearEnd: () -> Void = {}
        var onChromeVisibility: (Bool) -> Void = { _ in }
        var streamEnabled = false
        var contentSizeObservation: NSKeyValueObservation?
        var presentationKey = ""
        var documentTitle = ""
        var sections: [String] = []
        var loadingDocument = false
        var userHasScrolled = false
        var fontFaceKey = ""
        private var pendingFontFaceCSS: String?
        private var pendingStyle: String?
        private var preserveStylePosition = true
        private var applyingStyle = false
        private struct Insertion: Encodable { let before: String; let after: String }
        private var pendingAppends: [Insertion] = []
        private var appending = false
        private var documentGeneration = 0
        private var lastInspection = Date.distantPast
        private var lastNearEnd = Date.distantPast
        private var chromeVisible = true
        private var chromeRevealWorkItem: DispatchWorkItem?
        private var lastScrollOffsetY: CGFloat = 0
        private var scrollAccum: CGFloat = 0
        private weak var webView: WKWebView?
        var onOpenLink: (URL) -> Void = { _ in }
        var onOpenImage: (URL, CGRect, CGPoint) -> Void = { _, _, _ in }
        var onCompactTitle: (Bool) -> Void = { _ in }
        var restoreOffset: CGFloat = 0
        var onReadingOffset: (CGFloat) -> Void = { _ in }
        var didRestoreOffset = false
        var lastRestoreExtent: CGFloat = -1
        private var compactTitleVisible = false
        private var lastOffsetSave = Date.distantPast
        private var lastTitleCheck = Date.distantPast

        func attach(_ webView: WKWebView) { self.webView = webView }

        private var inlineVideoTask: Task<Void, Never>?
        private var lastVideoPauseCheck = Date.distantPast

        private func playInlineVideo(_ reference: VideoReference, poster: URL?, in webView: WKWebView) {
            inlineVideoTask?.cancel()
            let id = reference.id
            let loading = """
            (() => {
                const card = document.querySelector('[data-wize-video="\(id)"]');
                if (!card) return false;
                card.removeAttribute('data-error');
                const error = card.querySelector('.wize-video-error');
                if (error) error.remove();
                card.setAttribute('data-loading', '1');
                return true;
            })()
            """
            webView.evaluateJavaScript(loading)
            inlineVideoTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let playback = try await ZhihuSource().videoPlayback(reference)
                    guard !Task.isCancelled else { return }
                    self.injectInlineVideo(playback, poster: poster ?? playback.poster, reference: reference, in: webView)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.showInlineVideoError(in: webView, id: id)
                }
            }
        }

        private func injectInlineVideo(_ playback: VideoPlayback, poster: URL?, reference: VideoReference, in webView: WKWebView) {
            guard let urlData = try? JSONEncoder().encode(playback.url.absoluteString),
                  let urlJSON = String(data: urlData, encoding: .utf8) else { return }
            let posterJSON: String
            if let poster,
               let data = try? JSONEncoder().encode(poster.absoluteString),
               let value = String(data: data, encoding: .utf8) {
                posterJSON = value
            } else {
                posterJSON = "\"\""
            }
            let script = """
            (() => {
                const card = document.querySelector('[data-wize-video="\(reference.id)"]');
                if (!card) return false;
                document.querySelectorAll('.wize-video video').forEach(v => v.pause());
                card.classList.add('is-playing');
                card.removeAttribute('data-loading');
                card.removeAttribute('data-error');
                card.innerHTML = '';
                const video = document.createElement('video');
                video.src = \(urlJSON);
                video.controls = false;
                video.playsInline = true;
                video.setAttribute('playsinline', '');
                video.setAttribute('webkit-playsinline', '');
                video.preload = 'auto';
                const poster = \(posterJSON);
                if (poster) video.setAttribute('poster', poster);
                const toggle = document.createElement('span');
                toggle.className = 'wize-video-toggle';
                toggle.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6.4v11.2l9-5.6z"/></svg>';
                card.appendChild(video);
                card.appendChild(toggle);
                const sync = () => {
                    const paused = video.paused || video.ended;
                    card.classList.toggle('is-paused', paused);
                    card.setAttribute('aria-label', paused ? '播放视频' : '暂停视频');
                };
                video.addEventListener('play', sync);
                video.addEventListener('pause', sync);
                video.addEventListener('ended', sync);
                const start = () => {
                    const attempt = video.play();
                    if (attempt && attempt.catch) attempt.catch(() => sync());
                };
                video.addEventListener('loadedmetadata', start, { once: true });
                if (video.readyState >= 1) start();
                return true;
            })()
            """
            webView.evaluateJavaScript(script)
        }

        /// 播放中的视频不再铺系统控制遮罩。点一下只在暂停和继续之间切换，暂停时只留一枚播放钮。
        private func toggleInlineVideo(id: String, in webView: WKWebView) {
            let script = """
            (() => {
                const card = document.querySelector('[data-wize-video="\(id)"]');
                const video = card && card.querySelector('video');
                if (!video) return false;
                if (video.paused || video.ended) {
                    document.querySelectorAll('.wize-video video').forEach(v => { if (v !== video) v.pause(); });
                    const attempt = video.play();
                    if (attempt && attempt.catch) attempt.catch(() => {});
                } else {
                    video.pause();
                }
                return true;
            })()
            """
            webView.evaluateJavaScript(script)
        }

        private func showInlineVideoError(in webView: WKWebView, id: String) {
            let script = """
            (() => {
                const card = document.querySelector('[data-wize-video="\(id)"]');
                if (!card) return false;
                card.removeAttribute('data-loading');
                card.setAttribute('data-error', '1');
                let error = card.querySelector('.wize-video-error');
                if (!error) {
                    error = document.createElement('span');
                    error.className = 'wize-video-error';
                    card.appendChild(error);
                }
                error.textContent = '视频加载失败，点按重试';
                return true;
            })()
            """
            webView.evaluateJavaScript(script)
        }

        private func pauseOffscreenVideos(in webView: WKWebView) {
            let script = """
            (() => {
                document.querySelectorAll('.wize-video video').forEach(v => {
                    const r = v.getBoundingClientRect();
                    if (r.bottom < 24 || r.top > innerHeight - 24) v.pause();
                });
            })()
            """
            webView.evaluateJavaScript(script)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// 阅读区长按图片时在手指按下瞬间立即在手指附近弹出「放大查看 / 存储到照片」菜单；头像、行内表情与小图标不触发。
        @objc func handleImageLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let webView else { return }
            let point = gesture.location(in: webView)
            let touchPoint = gesture.location(in: nil)
            let script = """
            (() => {
                const el = document.elementFromPoint(\(point.x), \(point.y));
                const video = el && el.closest ? el.closest('[data-wize-video]') : null;
                if (video) {
                    if (video.querySelector('video') || video.getAttribute('data-loading') === '1') return null;
                    const rect = video.getBoundingClientRect();
                    return { video: video.getAttribute('data-wize-video') || '', kind: video.getAttribute('data-wize-video-kind') || 'lens', poster: video.getAttribute('data-wize-poster') || '', width: rect.width, height: rect.height, x: rect.left, y: rect.top };
                }
                const img = el && el.closest ? el.closest('img') : null;
                if (!img) return null;
                const rect = img.getBoundingClientRect();
                return { src: img.currentSrc || img.src || '', width: rect.width, height: rect.height, x: rect.left, y: rect.top, cls: String(img.className || '') };
            })()
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let info = result as? [String: Any] else { return }
                let width = info["width"] as? Double ?? 0
                let rect = CGRect(x: info["x"] as? Double ?? 0,
                                  y: info["y"] as? Double ?? 0,
                                  width: width,
                                  height: info["height"] as? Double ?? width)
                let frame = webView.convert(rect, to: nil)
                if let id = info["video"] as? String, !id.isEmpty {
                    let kind = VideoKind(rawValue: info["kind"] as? String ?? "") ?? .lens
                    let poster = (info["poster"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                    self.playInlineVideo(VideoReference(id: id, kind: kind), poster: poster, in: webView)
                    return
                }
                guard let src = info["src"] as? String,
                      let url = URL(string: src),
                      let className = info["cls"] as? String else { return }
                // 跳过头像、行内表情和其他小图；只放大正文里的图片。
                guard width >= 60, !className.contains("avatar") else { return }
                DispatchQueue.main.async {
                    // 取消 scrollView 当前手势追踪，确保手指无需松开即可立即显示浮动菜单且不带动页面滚动。
                    webView.scrollView.panGestureRecognizer.isEnabled = false
                    webView.scrollView.panGestureRecognizer.isEnabled = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    self.onOpenImage(url, frame, touchPoint)
                }
            }
        }
        /// 未播放的视频卡片点按后开始播放；已经在播的视频点按只暂停或继续，不唤起系统控制层。
        @objc func handleVideoTap(_ gesture: UITapGestureRecognizer) {
            guard let webView else { return }
            let point = gesture.location(in: webView)
            let script = """
            (() => {
                const el = document.elementFromPoint(\(point.x), \(point.y));
                const card = el && el.closest ? el.closest('[data-wize-video]') : null;
                if (!card || card.getAttribute('data-loading') === '1') return null;
                if (card.querySelector('video')) {
                    return { action: 'toggle', id: card.getAttribute('data-wize-video') || '' };
                }
                const rect = card.getBoundingClientRect();
                return { action: 'start', id: card.getAttribute('data-wize-video') || '', kind: card.getAttribute('data-wize-video-kind') || 'lens', poster: card.getAttribute('data-wize-poster') || '', width: rect.width, height: rect.height, x: rect.left, y: rect.top };
            })()
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let info = result as? [String: Any],
                      let id = info["id"] as? String, !id.isEmpty else { return }
                if info["action"] as? String == "toggle" {
                    self.toggleInlineVideo(id: id, in: webView)
                    return
                }
                let kind = VideoKind(rawValue: info["kind"] as? String ?? "") ?? .lens
                let poster = (info["poster"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                self.playInlineVideo(VideoReference(id: id, kind: kind), poster: poster, in: webView)
            }
        }

        func cancelPendingAppends() {
            inlineVideoTask?.cancel()
            documentGeneration += 1
            pendingAppends.removeAll()
            appending = false
            pendingStyle = nil
            applyingStyle = false
            pendingFontFaceCSS = nil
        }
        func updateFontFace(_ css: String, key: String, in webView: WKWebView) {
            fontFaceKey = key
            pendingFontFaceCSS = css
            flushFontFace(in: webView)
        }
        private func flushFontFace(in webView: WKWebView) {
            guard !loadingDocument, let css = pendingFontFaceCSS,
                  let data = try? JSONEncoder().encode(css),
                  let encoded = String(data: data, encoding: .utf8) else { return }
            pendingFontFaceCSS = nil
            let script = "(() => { const el = document.getElementById('wize-font-face'); if (!el) return false; el.textContent = \(encoded); return true; })()"
            webView.evaluateJavaScript(script)
        }
        func updateStyle(_ style: String, in webView: WKWebView, preservePosition: Bool) {
            pendingStyle = style
            preserveStylePosition = preservePosition
            flushStyle(in: webView)
        }
        private func flushStyle(in webView: WKWebView) {
            guard !loadingDocument, !applyingStyle, let style = pendingStyle,
                  let data = try? JSONEncoder().encode(style),
                  let encoded = String(data: data, encoding: .utf8) else { return }
            applyingStyle = true
            let generation = documentGeneration
            // Keep the text at a point in the viewport in place while it reflows.
            let script = "(() => { const style = document.querySelector('style'); if (!style) return false; const x = innerWidth * .5, y = Math.min(innerHeight * .35, 140); const range = document.caretRangeFromPoint(x, y); const element = document.elementFromPoint(x, y); const rect = range?.getBoundingClientRect(); const useRange = rect && rect.height > 0; const top = useRange ? rect.top : element?.getBoundingClientRect().top; style.textContent = \(encoded); if (!\(preserveStylePosition)) { window.scrollTo(0, 0); } else if (top != null) { const next = useRange ? range.getBoundingClientRect().top : element?.getBoundingClientRect().top; if (next != null) window.scrollBy(0, next - top); } return true; })()"
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView, self.documentGeneration == generation else { return }
                self.applyingStyle = false
                if result as? Bool == true, self.pendingStyle == style { self.pendingStyle = nil }
                if self.pendingStyle != nil, result as? Bool == true { self.flushStyle(in: webView) }
                self.inspect(webView)
            }
        }
        func enqueueSurrounding(before: String, after: String, in webView: WKWebView) {
            pendingAppends.append(Insertion(before: before, after: after))
            flushAppends(in: webView)
        }
        private func flushAppends(in webView: WKWebView) {
            guard !loadingDocument, !appending, let html = pendingAppends.first,
                  let data = try? JSONEncoder().encode(html),
                  let encoded = String(data: data, encoding: .utf8) else { return }
            appending = true
            let generation = documentGeneration
            // Preserve the first existing answer's screen position when earlier answers arrive.
            // This also avoids briefly showing a different answer while the document reloads.
            let script = "(() => { const first = document.querySelector('section[data-wize-answer]'); if (!document.body || !first) return false; const insertion = \(encoded); const top = first.getBoundingClientRect().top; if (insertion.before) first.insertAdjacentHTML('beforebegin', insertion.before); if (insertion.after) document.body.insertAdjacentHTML('beforeend', insertion.after); if (insertion.before) window.scrollBy(0, first.getBoundingClientRect().top - top); return true; })()"
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView, self.documentGeneration == generation else { return }
                self.appending = false
                if result as? Bool == true {
                    self.pendingAppends.removeFirst()
                    self.flushAppends(in: webView)
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                if url.fragment != nil, let current = webView.url,
                   current.host == url.host, current.path == url.path {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                if !isImageURL(url) { onOpenLink(url) }
                return
            }
            decisionHandler(.cancel)
            if scheme == "mailto" || scheme == "tel" { onOpenLink(url) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               (url.scheme == "http" || url.scheme == "https"),
               !isImageURL(url) {
                onOpenLink(url)
            }
            return nil
        }

        private func isImageURL(_ url: URL) -> Bool {
            let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"]
            if extensions.contains(url.pathExtension.lowercased()) { return true }
            guard let host = url.host?.lowercased() else { return false }
            return host == "zhimg.com" || host.hasSuffix(".zhimg.com")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            loadingDocument = false
            chromeVisible = true
            noteCompactTitle(false)
            chromeRevealWorkItem?.cancel()
            lastScrollOffsetY = 0
            scrollAccum = 0
            onChromeVisibility(true)
            flushFontFace(in: webView)
            flushStyle(in: webView)
            flushAppends(in: webView)
            let extent = max(webView.scrollView.contentSize.height - webView.scrollView.bounds.height, 0)
            if let id = pendingAnchorID, let offset = pendingOffset,
               let encoded = try? String(data: JSONEncoder().encode(id), encoding: .utf8) {
                pendingAnchorID = nil; pendingOffset = nil
                restoringAnchor = true
                let script = "(() => { const id = \(encoded); const el = Array.from(document.querySelectorAll('section[data-wize-answer]')).find(e => e.getAttribute('data-wize-answer') === id); if (el && (\(offset) > 0 || window.scrollY < 1)) window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY + \(offset)); })()"
                webView.evaluateJavaScript(script) { [weak self, weak webView] _, _ in
                    guard let self, let webView else { return }
                    self.restoringAnchor = false
                    self.restoreReadingOffset(in: webView)
                    self.inspect(webView)
                    self.updateCompactTitle(in: webView, force: true)
                }
                return
            } else if let offset = pendingOffset {
                pendingOffset = nil
                webView.scrollView.setContentOffset(CGPoint(x: 0, y: min(offset, extent)), animated: false)
            } else if let fraction = pendingScrollFraction {
                pendingScrollFraction = nil
                webView.scrollView.setContentOffset(CGPoint(x: 0, y: min(fraction, 1) * extent), animated: false)
            }
            inspect(webView)
            restoreReadingOffset(in: webView)
            updateCompactTitle(in: webView, force: true)
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userHasScrolled = true
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.x != 0 {
                scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y), animated: false)
            }
            if let webView, Date().timeIntervalSince(lastVideoPauseCheck) > 0.2 {
                lastVideoPauseCheck = Date()
                pauseOffscreenVideos(in: webView)
            }
            guard !loadingDocument, pendingAnchorID == nil, !restoringAnchor,
                  scrollView.contentSize.height > 0, let webView else { return }
            let remaining = scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y
            if userHasScrolled {
                let y = scrollView.contentOffset.y
                let delta = y - lastScrollOffsetY
                lastScrollOffsetY = y
                if y <= 16 || remaining <= 24 {
                    chromeRevealWorkItem?.cancel()
                    if !chromeVisible {
                        chromeVisible = true
                        onChromeVisibility(true)
                    }
                    scrollAccum = 0
                } else {
                    scrollAccum += delta
                    if scrollAccum > 48, chromeVisible {
                        chromeVisible = false
                        scrollAccum = 0
                        onChromeVisibility(false)
                        scheduleChromeReveal()
                    } else if scrollAccum < -40, !chromeVisible {
                        chromeRevealWorkItem?.cancel()
                        chromeVisible = true
                        scrollAccum = 0
                        onChromeVisibility(true)
                    } else if abs(scrollAccum) > 160 {
                        scrollAccum = 0
                    }
                    if !chromeVisible { scheduleChromeReveal() }
                }
            } else {
                // Keep the baseline in step with programmatic scrolling (anchor restore).
                lastScrollOffsetY = scrollView.contentOffset.y
            }
            if userHasScrolled {
                updateCompactTitle(in: webView)
                saveReadingOffset(of: scrollView)
            }
            guard streamEnabled else { return }
            if remaining < scrollView.bounds.height * 1.3,
               Date().timeIntervalSince(lastNearEnd) > 0.6 {
                lastNearEnd = Date()
                onNearEnd()
            }
            if userHasScrolled, Date().timeIntervalSince(lastInspection) > 0.2 { inspect(webView) }
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                if let webView, streamEnabled { inspect(webView) }
                scheduleChromeReveal(after: 0.3)
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let webView, streamEnabled { inspect(webView) }
            scheduleChromeReveal(after: 0.3)
        }

        private func saveReadingOffset(of scrollView: UIScrollView) {
            let now = Date()
            guard now.timeIntervalSince(lastOffsetSave) > 0.25 else { return }
            lastOffsetSave = now
            onReadingOffset(max(0, scrollView.contentOffset.y))
        }

        private func restoreReadingOffset(in webView: WKWebView) {
            guard !didRestoreOffset, !loadingDocument, restoreOffset > 1 else { return }
            let scrollView = webView.scrollView
            let extent = scrollView.contentSize.height - scrollView.bounds.height
            guard extent > 1 else { return }
            // Wait until the page is tall enough for the saved place. Images still
            // decoding would otherwise clamp us to a short document and stick there.
            let settled = abs(extent - lastRestoreExtent) < 1
            lastRestoreExtent = extent
            guard restoreOffset <= extent + 8 || settled else { return }
            didRestoreOffset = true
            let y = min(restoreOffset, max(0, extent))
            guard abs(scrollView.contentOffset.y - y) > 1 else { return }
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }

        func noteCompactTitle(_ visible: Bool) {
            guard visible != compactTitleVisible else { return }
            compactTitleVisible = visible
            onCompactTitle(visible)
        }

        private func updateCompactTitle(in webView: WKWebView, force: Bool = false) {
            guard !loadingDocument else { return }
            let now = Date()
            if !force, now.timeIntervalSince(lastTitleCheck) < 0.12 { return }
            lastTitleCheck = now
            let showing = compactTitleVisible ? "true" : "false"
            let script = "(() => { const header = document.querySelector('header h1'); if (!header) return false; const bottom = header.getBoundingClientRect().bottom; const showing = \(showing); return showing ? bottom < 36 : bottom < 2; })()"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                self.noteCompactTitle((result as? Bool) ?? false)
            }
        }

        private func scheduleChromeReveal(after delay: TimeInterval = 0.55) {
            guard !chromeVisible else { return }
            chromeRevealWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.chromeVisible else { return }
                self.chromeVisible = true
                self.onChromeVisibility(true)
            }
            chromeRevealWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
        func inspectAfterLayout(_ webView: WKWebView) {
            restoreReadingOffset(in: webView)
            guard streamEnabled, !loadingDocument else { return }
            flushAppends(in: webView)
            // Content size also changes while lazy images decode; do not round-trip to
            // the web process for every one of those changes.
            guard Date().timeIntervalSince(lastInspection) > 0.12 else { return }
            inspect(webView)
        }
        func scrollToAnswer(_ id: String, in webView: WKWebView) {
            userHasScrolled = false
            guard let encoded = try? String(data: JSONEncoder().encode(id), encoding: .utf8) else { return }
            let script = "(() => { const id = \(encoded); const el = Array.from(document.querySelectorAll('section[data-wize-answer]')).find(e => e.getAttribute('data-wize-answer') === id); if (el) el.scrollIntoView({block:'start'}); })()"
            webView.evaluateJavaScript(script)
        }
        private func inspect(_ webView: WKWebView) {
            guard streamEnabled, !loadingDocument, pendingAnchorID == nil, !restoringAnchor else { return }
            lastInspection = Date()
            // Tie edge actions to the answer at the reading focus, not a sliver at the top.
            let script = "(() => { const answers = Array.from(document.querySelectorAll('section[data-wize-answer]')); const focus = Math.min(innerHeight * .35, innerHeight - 1); const answer = answers.find(e => e.getBoundingClientRect().bottom > focus) || answers.find(e => e.getBoundingClientRect().bottom > 0); const index = answers.indexOf(answer); if (index >= 0) answers.slice(index, index + 2).forEach(section => section.querySelectorAll('img[loading=lazy]').forEach(img => img.loading = 'eager')); answers.forEach(section => section.classList.toggle('current', section === answer)); return { id: answer?.getAttribute('data-wize-answer') || null }; })()"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let result = result as? [String: Any] else { return }
                if self.userHasScrolled, let id = result["id"] as? String { self.onVisibleAnswer(id) }
            }
        }
    }
}

private struct ReadingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var fontManager = ReadingFontManager.shared
    @AppStorage("reading.fontSize") private var fontSize = ReadingDefaults.fontSize
    @AppStorage("reading.lineHeight") private var lineHeight = 1.8
    @AppStorage("reading.width") private var readingWidth = ReadingDefaults.width
    @AppStorage("reading.paragraphSpacing") private var paragraphSpacing = 1.0
    @AppStorage("reading.font") private var font = "system"
    @AppStorage("reading.theme") private var theme = "system"

    private let previewHTML = """
    <p>阅读让我们暂时放慢脚步，也让熟悉的世界重新变得清晰。</p>
    <p>在不同的观点之间，留下思考的空间，<strong>找到自己的答案</strong>。</p>
    <blockquote>好好阅读，慢慢思考。</blockquote>
    """

    var body: some View {
        NavigationStack {
            Form {
                Section("预览") {
                    let sample = ReadingItem(id: "reading-preview", kind: .article, title: "", excerpt: "", author: "", questionID: nil, contentHTML: previewHTML)
                    HTMLReader(html: previewHTML, item: sample,
                               paperCards: UIDevice.current.userInterfaceIdiom == .pad, isPreview: true)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                }
                Section("正文") {
                    HStack {
                        Text("字号")
                        Slider(value: $fontSize, in: 15...25, step: 1)
                        Text("\(Int(fontSize))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("行距")
                        Slider(value: $lineHeight, in: 1.5...2.1, step: 0.1)
                        Text(lineHeight, format: .number.precision(.fractionLength(1))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(fontManager.options) { option in
                        fontRow(option)
                    }
                } header: {
                    Text("字体")
                } footer: {
                    Text("可下载字体均采用 SIL Open Font License 1.1 开源许可，无版权限制，按需下载并保存在本机。")
                }
                Section("版面") {
                    Picker("行宽", selection: $readingWidth) {
                        Text("紧凑").tag(560)
                        Text("标准").tag(680)
                        Text("宽松").tag(800)
                    }.pickerStyle(.segmented)
                    Text("行宽在阅读区域足够宽时生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text("段间距")
                        Slider(value: $paragraphSpacing, in: 0.5...1.8, step: 0.1)
                        Text(paragraphSpacing, format: .number.precision(.fractionLength(1))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Section("阅读配色") {
                    Picker("背景", selection: $theme) {
                        Text("跟随系统").tag("system")
                        Text("明亮").tag("light")
                        Text("纸色").tag("paper")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button("恢复默认设置") {
                        fontSize = ReadingDefaults.fontSize; lineHeight = 1.8; font = "system"; theme = "system"
                        readingWidth = ReadingDefaults.width; paragraphSpacing = 1.0
                    }
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { fontManager.prepareFontIfNeeded(id: font) }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func fontRow(_ option: ReadingFontOption) -> some View {
        let state = fontManager.state(for: option)
        let isSelected = font == option.id
        Button {
            switch state {
            case .builtIn, .downloaded:
                fontManager.prepareFontIfNeeded(id: option.id)
                font = option.id
            case .notDownloaded, .failed:
                fontManager.download(option) { selectedID in
                    font = selectedID
                }
            case .downloading:
                fontManager.cancelDownload(option)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(titleFont(for: option))
                        .foregroundStyle(.primary)
                    if case .failed(let message) = state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(option.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                switch state {
                case .builtIn:
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ReaderPalette.accent)
                    }
                case .downloaded:
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ReaderPalette.accent)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.body)
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                case .notDownloaded:
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(ReaderPalette.accent)
                case .failed:
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.title3)
                        .foregroundStyle(ReaderPalette.accent)
                case .downloading(let progress):
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !option.isBuiltIn, state == .downloaded {
                Button(role: .destructive) {
                    if font == option.id { font = "system" }
                    fontManager.removeFont(option)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel("\(option.title)，\(accessibilityStateDescription(for: state, isSelected: isSelected))")
    }

    private func titleFont(for option: ReadingFontOption) -> Font {
        if let registered = fontManager.registeredFontNames[option.id] {
            return .custom(registered, size: 17)
        }
        if option.id == "serif" {
            return .custom("Songti SC", size: 17)
        }
        return .body
    }

    private func accessibilityStateDescription(for state: ReadingFontManager.State, isSelected: Bool) -> String {
        switch state {
        case .builtIn: return isSelected ? "已选中" : "内置字体"
        case .downloaded: return isSelected ? "已下载并选中" : "已下载"
        case .notDownloaded: return "未下载，点击按需下载"
        case .downloading(let p): return "正在下载 \(Int(p * 100))%"
        case .failed(let message): return "下载失败：\(message)"
        }
    }
}

private struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ReaderModel
    var onOpenProfile: ((ReadingItem) -> Void)? = nil
    @StateObject private var session = ZhihuLoginSession()
    @FocusState private var focusedField: Field?

    private enum Field {
        case username, smsCode, password
    }

    private var activeAccountName: String? {
        if session.switchingAccount || session.didLogout { return session.loggedInName }
        return session.loggedInName ?? model.accountName
    }

    private var activeAccountAvatar: URL? {
        if session.switchingAccount || session.didLogout { return session.loggedInAvatar }
        return session.loggedInAvatar ?? model.accountAvatarURL
    }

    private var activeAccountHeadline: String? {
        if session.switchingAccount || session.didLogout { return session.loggedInHeadline }
        return session.loggedInHeadline ?? model.accountHeadline
    }

    private var activeAccountToken: String? {
        if session.switchingAccount || session.didLogout { return session.loggedInToken }
        return session.loggedInToken ?? model.accountToken
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ReaderPalette.directory.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        if let name = activeAccountName, !session.switchingAccount {
                            accountProfileContent(
                                name: name,
                                avatar: activeAccountAvatar,
                                headline: activeAccountHeadline,
                                token: activeAccountToken
                            )
                        } else {
                            nativeLoginFormContent
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(activeAccountName != nil && !session.switchingAccount ? "知乎账号" : "登录知乎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if activeAccountName != nil && !session.switchingAccount {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(session.switchingAccount && model.accountName != nil ? "返回" : "取消") {
                            if session.switchingAccount && model.accountName != nil {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    session.cancelSwitchAccount()
                                }
                            } else {
                                dismiss()
                            }
                        }
                    }
                }
            }
            .onChange(of: session.verified) { verified in
                if verified {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                }
            }
            .onDisappear { session.stopObserving() }
        }
    }

    @ViewBuilder
    private func accountProfileContent(
        name: String,
        avatar: URL?,
        headline: String?,
        token: String?
    ) -> some View {
        VStack(spacing: 14) {
            AvatarView(url: avatar, size: 72)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3)

            VStack(spacing: 6) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let headline, !headline.isEmpty {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                Text("已连接知乎账号")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(ReaderPalette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(ReaderPalette.accent.opacity(0.12), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(alignment: .leading, spacing: 14) {
            accountFeatureRow(icon: "sparkles", title: "个性化推荐与热榜", subtitle: "根据你的知乎关注与阅读偏好同步推荐内容")
            Divider()
            accountFeatureRow(icon: "hand.thumbsup", title: "互动与评论", subtitle: "支持赞同回答、查看全部评论与楼中楼回复")
            Divider()
            accountFeatureRow(icon: "star", title: "收藏夹同步", subtitle: "可将回答或专栏文章直接存入你的知乎收藏夹")
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(spacing: 10) {
            if let token, !token.isEmpty, let onOpenProfile {
                Button {
                    let profile = ReadingItem(
                        id: token,
                        kind: .answer,
                        title: name,
                        excerpt: "",
                        author: name,
                        questionID: nil,
                        avatarURL: avatar,
                        authorHeadline: headline,
                        authorToken: token
                    )
                    onOpenProfile(profile)
                } label: {
                    HStack {
                        Label("查看我的知乎主页", systemImage: "person.text.rectangle")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .frame(height: 52)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    session.beginSwitchAccount()
                }
            } label: {
                HStack {
                    Label("切换其他知乎账号", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                Task {
                    await session.logout(model: model)
                }
            } label: {
                HStack {
                    Label("退出当前账号", systemImage: "rectangle.portrait.and.arrow.right")
                    Spacer()
                }
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func accountFeatureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ReaderPalette.accent)
                .frame(width: 28, height: 28)
                .background(ReaderPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var nativeLoginFormContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ReaderPalette.accent)
                    .frame(width: 36, height: 36)
                    .background(ReaderPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接你的知乎账号")
                        .font(.headline)
                    Text("开启个性化推荐、赞同互动与收藏同步")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)

        VStack(alignment: .leading, spacing: 12) {
            if session.needsCaptchaInteraction {
                HStack {
                    Label("请完成安全验证", systemImage: "shield.lefthalf.filled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ReaderPalette.accent)
                    Spacer()
                    Button {
                        session.reload()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)

                Text("请按下方提示依次点击图案或拖动滑块，验证通过后将自动继续。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            ZStack {
                ZhihuLoginWebView(session: session)
                    .frame(width: 354, height: 304)
                    .opacity(session.needsCaptchaInteraction ? 1 : 0.001)
                    .allowsHitTesting(session.needsCaptchaInteraction)
                    .accessibilityHidden(!session.needsCaptchaInteraction)

                if session.needsCaptchaInteraction && !session.captchaReady {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(ReaderPalette.accent)
                        Text("正在加载安全验证组件…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 354, height: 304)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: session.needsCaptchaInteraction ? 304 : 0)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.vertical, session.needsCaptchaInteraction ? 14 : 0)
        .padding(.horizontal, session.needsCaptchaInteraction ? 4 : 0)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground)
                .opacity(session.needsCaptchaInteraction ? 1 : 0),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )

        if !session.needsCaptchaInteraction {
            Picker("登录方式", selection: Binding(
                get: { session.mode },
                set: { newMode in
                    focusedField = nil
                    session.setMode(newMode)
                }
            )) {
                Text("短信验证码").tag(ZhihuLoginSession.Mode.sms)
                Text("密码登录").tag(ZhihuLoginSession.Mode.password)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: session.mode == .sms ? "iphone" : "person")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    TextField(session.mode == .sms ? "输入手机号" : "输入手机号或邮箱", text: $session.username)
                        .keyboardType(session.mode == .sms ? .phonePad : .emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                    if !session.username.isEmpty {
                        Button {
                            session.username = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 54)

                Divider().padding(.leading, 50)

                if session.mode == .sms {
                    HStack(spacing: 12) {
                        Image(systemName: "number")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        TextField("输入 6 位验证码", text: $session.smsCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focusedField, equals: .smsCode)
                        Button {
                            focusedField = .smsCode
                            session.sendSMSCode()
                        } label: {
                            if session.sendingCode {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.horizontal, 10)
                            } else {
                                Text(session.countdownText ?? "获取验证码")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(session.canSendSMS ? ReaderPalette.accent : .secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(
                                        (session.canSendSMS ? ReaderPalette.accent.opacity(0.12) : Color.primary.opacity(0.05)),
                                        in: Capsule()
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!session.canSendSMS)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "lock")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        SecureField("输入登录密码", text: $session.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let error = session.verificationError ?? session.pageError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
            } else if let status = session.statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ReaderPalette.accent)
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
            }

            Button {
                focusedField = nil
                session.submitLogin()
            } label: {
                HStack(spacing: 8) {
                    if session.submitting || session.checking {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    }
                    Text(session.submitting || session.checking ? "正在验证登录…" : "登录")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    session.canSubmit ? ReaderPalette.accent : ReaderPalette.accent.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(!session.canSubmit)

            Text("账号验证与加密传输直接与知乎服务器通信，Wize 不会存储你的明文密码，登录状态仅保存在本设备中。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 4)
        }
    }
}

@MainActor
private final class ZhihuLoginSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver, WKScriptMessageHandler {
    enum Mode: String {
        case sms
        case password
    }

    @Published var mode: Mode = .sms
    @Published var username = ""
    @Published var smsCode = ""
    @Published var password = ""
    @Published var loading = true
    @Published var sendingCode = false
    @Published var submitting = false
    @Published var checking = false
    @Published var verified = false
    @Published var needsCaptchaInteraction = false
    @Published var captchaReady = false
    @Published var countdownText: String?
    @Published var statusMessage: String?
    @Published var pageError: String?
    @Published var verificationError: String?

    @Published var loggedInName: String?
    @Published var loggedInAvatar: URL?
    @Published var loggedInHeadline: String?
    @Published var loggedInToken: String?
    @Published var switchingAccount = false
    @Published var didLogout = false

    let webView: WKWebView
    private let source = ZhihuSource()
    private let loginURL = URL(string: "https://www.zhihu.com/signin")!
    private var authCookie: String?
    private var observingCookies = false
    private var stopped = false
    private var pendingAutoVerification = false
    private var sawNewAuthCookie = false
    private var sawUnhumanPage = false
    private var pendingActionAfterCaptcha: (() -> Void)?

    var canSendSMS: Bool {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !sendingCode && countdownText == nil
    }

    var canSubmit: Bool {
        guard !submitting && !checking else { return false }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { return false }
        switch mode {
        case .sms:
            return !smsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password:
            return !password.isEmpty
        }
    }

    private static let cleanCaptchaCSS = """
    .WechatShareImage,
    .Unhuman-head,
    .Unhuman-title,
    .Unhuman-top,
    .Unhuman-tip,
    .Unhuman-footer,
    .SignFlowHeader,
    .Login-footer,
    .Login-tip,
    .OpenInAppButton,
    .AppHeader,
    .CornerButtons,
    .yidun_popup__mask {
        display: none !important;
    }
    html, body, #root, .App, .App-main, .Unhuman {
        background: transparent !important;
        margin: 0 !important;
        padding: 0 !important;
        min-height: 0 !important;
    }
    .Unhuman-verificationCode {
        width: 100% !important;
        max-width: 320px !important;
        margin: 0 auto !important;
        padding: 12px 8px !important;
        display: flex !important;
        flex-direction: column !important;
        align-items: center !important;
        justify-content: center !important;
        box-sizing: border-box !important;
    }
    button.Unhuman-confirm {
        width: 100% !important;
        max-width: 320px !important;
        margin: 12px auto !important;
        border-radius: 10px !important;
        background: #527863 !important;
    }
    .yidun_modal {
        top: 0px !important;
        box-shadow: none !important;
        border: none !important;
    }
    """

    private static let bridgeScript = """
    (() => {
        if (window.__wizeLoginBridgeInstalled) return;
        window.__wizeLoginBridgeInstalled = true;

        const style = document.createElement('style');
        style.textContent = \(ZhihuLoginSession.jsStringLiteral(cleanCaptchaCSS));
        (document.head || document.documentElement).appendChild(style);

        let autoClickedUnhuman = false;
        function inspect() {
            const path = location.pathname || '';
            const isUnhuman = path.includes('/account/unhuman');
            if (isUnhuman && !autoClickedUnhuman) {
                const hasCore = performance.getEntriesByType('resource').some(r => r.name.includes('core-optimi'));
                const confirmBtn = document.querySelector('button.Unhuman-confirm');
                if (hasCore && confirmBtn) {
                    autoClickedUnhuman = true;
                    setTimeout(() => confirmBtn.click(), 450);
                }
            }
            const bgImg = document.querySelector('.yidun_bgimg');
            const bgReady = !!(bgImg && bgImg.getBoundingClientRect().height > 50);
            const yidunPanel = document.querySelector('.yidun_panel, .yidun_modal, .Captcha, .geetest_panel');
            const yidunVisible = !!(yidunPanel && yidunPanel.offsetParent !== null && yidunPanel.getBoundingClientRect().height > 30);
            const hasCaptcha = isUnhuman || yidunVisible;

            const smsBtn = document.querySelector('button.CountingDownButton, .SignFlow-smsBindPhoneInputButton');
            const smsBtnText = smsBtn ? smsBtn.innerText.trim() : '';
            const isCountingDown = smsBtnText.includes('秒') || smsBtnText.includes('重发') && /\\d/.test(smsBtnText);

            const errMasks = Array.from(document.querySelectorAll('.SignFlowInput-errorMask:not(.SignFlowInput-errorMask--hidden), .Notification-text, .Toast'));
            const errText = errMasks.map(e => e.innerText.trim()).find(Boolean) || '';

            window.webkit?.messageHandlers?.wizeLogin?.postMessage({
                path,
                hasCaptcha,
                captchaReady: bgReady || (!isUnhuman && yidunVisible),
                countdownText: isCountingDown ? smsBtnText : '',
                errorText: errText
            });
        }
        setInterval(inspect, 300);
        window.addEventListener('DOMContentLoaded', inspect);
        inspect();
    })();
    """

    private static func jsStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\""
    }

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let controller = WKUserContentController()
        let userScript = WKUserScript(
            source: Self.bridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(userScript)
        configuration.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 354, height: 304), configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        super.init()
        controller.add(self, name: "wizeLogin")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task {
            if let current = try? await source.currentUser() {
                loggedInName = current.name
                loggedInAvatar = current.avatar
                loggedInHeadline = current.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
                loggedInToken = current.token
            }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            authCookie = Self.authCookieValue(await store.allCookies())
            guard !stopped else { return }
            store.add(self)
            observingCookies = true
            if loggedInName == nil {
                webView.load(URLRequest(url: loginURL))
            }
        }
    }

    func beginSwitchAccount() {
        switchingAccount = true
        verificationError = nil
        statusMessage = nil
        if webView.url == nil {
            webView.load(URLRequest(url: loginURL))
        }
    }

    func cancelSwitchAccount() {
        switchingAccount = false
        verificationError = nil
        statusMessage = nil
    }

    func logout(model: ReaderModel) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if (domain == "zhihu.com" || domain.hasSuffix(".zhihu.com")),
               ["z_c0", "q_c1", "unlock_ticket"].contains(cookie.name) {
                await store.deleteCookie(cookie)
            }
        }
        authCookie = nil
        loggedInName = nil
        loggedInAvatar = nil
        loggedInHeadline = nil
        loggedInToken = nil
        switchingAccount = false
        didLogout = true
        model.accountName = nil
        model.accountAvatarURL = nil
        model.accountHeadline = nil
        model.accountToken = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        webView.load(URLRequest(url: loginURL))
    }

    func setMode(_ newMode: Mode) {
        mode = newMode
        verificationError = nil
        statusMessage = nil
        let wantPassword = (newMode == .password)
        let js = """
        (() => {
            const hasPwd = !!document.querySelector('input[name="password"]');
            if (hasPwd !== \(wantPassword ? "true" : "false")) {
                const toggle = document.querySelector('.Login-signinButtons button');
                if (toggle) toggle.click();
            }
        })()
        """
        webView.evaluateJavaScript(js)
    }

    func sendSMSCode() {
        let phone = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else {
            verificationError = "请先输入手机号"
            return
        }
        verificationError = nil
        statusMessage = nil
        sendingCode = true
        let encodedPhone = Self.jsStringLiteral(phone)
        let js = """
        (() => {
            if (location.pathname.includes('/account/unhuman')) {
                const btn = document.querySelector('button.Unhuman-confirm');
                if (btn) btn.click();
                return 'unhuman';
            }
            const hasPwd = !!document.querySelector('input[name="password"]');
            if (hasPwd) {
                const toggle = document.querySelector('.Login-signinButtons button');
                if (toggle) toggle.click();
            }
            const input = document.querySelector('input[name="username"]');
            if (!input) return 'not_ready';
            input.focus();
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
            if (setter) setter.call(input, \(encodedPhone));
            else input.value = \(encodedPhone);
            input.dispatchEvent(new Event('input', { bubbles: true }));
            input.dispatchEvent(new Event('change', { bubbles: true }));
            const smsBtn = document.querySelector('button.CountingDownButton, .SignFlow-smsBindPhoneInputButton');
            if (!smsBtn) return 'no_button';
            smsBtn.click();
            return 'clicked';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let status = result as? String ?? ""
            if status == "unhuman" || status == "not_ready" {
                self.sendingCode = false
                if status == "unhuman" {
                    self.needsCaptchaInteraction = true
                    self.pendingActionAfterCaptcha = { [weak self] in self?.sendSMSCode() }
                } else {
                    self.reload()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self else { return }
                self.sendingCode = false
                if self.verificationError == nil && !self.needsCaptchaInteraction {
                    self.statusMessage = "验证码请求已发送，请留意短信或完成滑块验证"
                }
            }
        }
    }

    func submitLogin() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            verificationError = "请输入手机号或账号"
            return
        }
        verificationError = nil
        statusMessage = nil
        submitting = true
        let encodedUser = Self.jsStringLiteral(user)
        let isPassword = (mode == .password)
        let secret = isPassword ? password : smsCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedSecret = Self.jsStringLiteral(secret)
        let secretSelector = isPassword ? "input[name=\"password\"]" : "input[name=\"digits\"]"

        let js = """
        (() => {
            if (location.pathname.includes('/account/unhuman')) {
                const btn = document.querySelector('button.Unhuman-confirm');
                if (btn) btn.click();
                return 'unhuman';
            }
            const hasPwd = !!document.querySelector('input[name="password"]');
            if (hasPwd !== \(isPassword ? "true" : "false")) {
                const toggle = document.querySelector('.Login-signinButtons button');
                if (toggle) toggle.click();
            }
            function fill(sel, val) {
                const el = document.querySelector(sel);
                if (!el) return false;
                el.focus();
                const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set;
                if (setter) setter.call(el, val);
                else el.value = val;
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
            }
            if (!fill('input[name="username"]', \(encodedUser))) return 'not_ready';
            if (!fill('\(secretSelector)', \(encodedSecret))) return 'not_ready';
            const submitBtn = document.querySelector('button.Login-submitButton, form.Login-form button[type="submit"]');
            if (!submitBtn) return 'no_submit';
            submitBtn.click();
            return 'submitted';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let status = result as? String ?? ""
            if status == "unhuman" {
                self.submitting = false
                self.needsCaptchaInteraction = true
                self.pendingActionAfterCaptcha = { [weak self] in self?.submitLogin() }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self, self.submitting else { return }
                self.submitting = false
                if !self.verified {
                    self.verify(silent: false)
                }
            }
        }
    }

    func reload() {
        pageError = nil
        verificationError = nil
        captchaReady = false
        if webView.url == nil { webView.load(URLRequest(url: loginURL)) }
        else { webView.reload() }
    }

    func verify(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        if silent { pendingAutoVerification = false } else { verificationError = nil }
        Task {
            defer {
                checking = false
                submitting = false
                if pendingAutoVerification && !loading && !verified && !stopped { verify(silent: true) }
            }
            do {
                let account = try await source.currentUser()
                loggedInName = account.name
                loggedInAvatar = account.avatar
                loggedInHeadline = account.headline?.trimmingCharacters(in: .whitespacesAndNewlines)
                loggedInToken = account.token
                verified = true
            } catch {
                if !silent && !needsCaptchaInteraction {
                    verificationError = "登录尚未完成，请检查验证码或密码是否正确。"
                }
            }
        }
    }

    func stopObserving() {
        stopped = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wizeLogin")
        if observingCookies { webView.configuration.websiteDataStore.httpCookieStore.remove(self) }
        observingCookies = false
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let path = body["path"] as? String ?? ""
        let hasCaptcha = body["hasCaptcha"] as? Bool ?? false
        let isReady = body["captchaReady"] as? Bool ?? false
        let countdown = body["countdownText"] as? String ?? ""
        let errText = body["errorText"] as? String ?? ""

        if path.contains("/account/unhuman") {
            sawUnhumanPage = true
        }
        if captchaReady != isReady {
            withAnimation(.easeInOut(duration: 0.18)) {
                captchaReady = isReady
            }
        }
        let wasShowingCaptcha = needsCaptchaInteraction
        if needsCaptchaInteraction != hasCaptcha {
            withAnimation(.easeInOut(duration: 0.2)) {
                needsCaptchaInteraction = hasCaptcha
                if !hasCaptcha { captchaReady = false }
            }
        }
        if wasShowingCaptcha && !hasCaptcha && path.hasPrefix("/signin"),
           let action = pendingActionAfterCaptcha {
            pendingActionAfterCaptcha = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                action()
            }
        }
        countdownText = countdown.isEmpty ? nil : countdown
        if !errText.isEmpty && (sendingCode || submitting) {
            sendingCode = false
            submitting = false
            verificationError = errText
        }
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task {
            let newValue = Self.authCookieValue(await cookieStore.allCookies())
            guard observingCookies, newValue != authCookie else { return }
            authCookie = newValue
            if newValue != nil {
                sawNewAuthCookie = true
                pendingAutoVerification = true
                verify(silent: true)
            }
        }
    }

    private static func authCookieValue(_ cookies: [HTTPCookie]) -> String? {
        cookies.first {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return $0.name == "z_c0" && (domain == "zhihu.com" || domain.hasSuffix(".zhihu.com")) && !$0.value.isEmpty
        }?.value
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              let host = url.host?.lowercased(),
              host == "zhihu.com" || host.hasSuffix(".zhihu.com") else {
            decisionHandler(.allow)
            return
        }
        let path = url.path
        // Never allow the hidden WebView to render the Zhihu home feed (`/`).
        // Redirecting to `/` means login or security verification has succeeded.
        if path.isEmpty || path == "/" {
            decisionHandler(.cancel)
            loading = false
            needsCaptchaInteraction = false
            if sawUnhumanPage && authCookie == nil {
                verified = true
            } else {
                verify(silent: true)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        pageError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        if let path = webView.url?.path, path.contains("/account/unhuman") {
            sawUnhumanPage = true
            withAnimation(.easeInOut(duration: 0.2)) {
                needsCaptchaInteraction = true
            }
        } else if sawUnhumanPage, let path = webView.url?.path, path.hasPrefix("/signin") {
            withAnimation(.easeInOut(duration: 0.2)) {
                needsCaptchaInteraction = false
            }
            if let action = pendingActionAfterCaptcha {
                pendingActionAfterCaptcha = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    action()
                }
            }
        }
        if sawNewAuthCookie || pendingAutoVerification {
            verify(silent: true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        webView.reload()
    }
    private func fail(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false
        pageError = "网络连接异常，请检查网络后重试。"
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

private struct ZhihuLoginWebView: UIViewRepresentable {
    @ObservedObject var session: ZhihuLoginSession
    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
