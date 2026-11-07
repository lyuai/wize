import SwiftUI
import WebKit
import SafariServices

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
}

struct ReaderView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var phonePath: [PhonePage] = []
    @State private var availableWidth: CGFloat = 0
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
    @State private var videoPreview: VideoPreviewItem?
    @State private var collectedKeys: Set<String> = []
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
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular && availableWidth >= 760
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
            LoginView().presentationDetents([.large]).presentationDragIndicator(.visible)
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
        .fullScreenCover(item: $videoPreview) { item in
            VideoPlayerScreen(item: item)
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
        .onChange(of: model.selected?.key) { _ in focus.item = model.selected }
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
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { model.showsComments = false }
                    NavigationStack { commentList.simultaneousGesture(closeCommentsGesture) }
                        .simultaneousGesture(closeCommentsGesture)
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
            Label("推荐", systemImage: "sparkles").tag(ReaderModel.Channel.recommend)
            Label("热榜", systemImage: "flame").tag(ReaderModel.Channel.hot)
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
            NavigationStack { commentList.simultaneousGesture(closeCommentsGesture) }
                .simultaneousGesture(closeCommentsGesture)
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
                channelPicker.frame(width: 160)
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
            ForEach(Array((channel == model.channel && model.refreshingFeed ? [] : (model.feeds[channel] ?? [])).enumerated()), id: \.element.key) { index, item in
                Button {
                    model.open(item)
                    if !usesWideLayout { phonePath.append(item.kind == .question ? .question : .answer) }
                } label: { ItemRow(item: item, isHot: channel == .hot) }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                .listRowBackground(usesWideLayout && (model.selected?.key == item.key || model.question?.key == item.key) ? ReaderPalette.selection : Color.clear)
                .task {
                    guard channel == model.channel else { return }
                    async let avatars: Void = AvatarCache.shared.prefetch(Array((model.feeds[channel] ?? []).dropFirst(index).prefix(6)).compactMap(\.avatarURL))
                    async let detail: Void = model.prefetchDetail(item)
                    if index >= max((model.feeds[channel]?.count ?? 0) - 4, 0) { await model.loadFeed() }
                    await detail
                    await avatars
                }
            }
            if channel == model.channel, let error = model.feedError { retryRow(error) { await model.loadFeed() }.listRowBackground(Color.clear) }
            else if channel == model.channel, model.loadingFeed, !model.refreshingFeed,
                    !(model.feeds[channel] ?? []).isEmpty {
                LoadingSkeleton(kind: .feed, label: "正在加载更多")
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            else if channel == model.channel, model.loadingFeed, model.refreshingFeed || (model.feeds[channel] ?? []).isEmpty {
                ForEach(0..<5, id: \.self) { _ in LoadingSkeleton(kind: .feed, label: "正在加载内容").listRowSeparator(.hidden).listRowBackground(Color.clear) }
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
                Button { model.selectAnswer(item); if !usesWideLayout { phonePath.append(.answer) } } label: { ItemRow(item: item, showsTitle: false) }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                    .listRowBackground(usesWideLayout && model.selected?.key == item.key ? ReaderPalette.selection : Color.clear)
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
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                model.answerSort = value.translation.width < 0 ? "updated" : "default"
            })
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
                            // Only the edge action avatar is drawn by SwiftUI; the
                            // stream's own avatars are loaded by the web view.
                            if let url = answer.avatarURL {
                                Task { await AvatarCache.shared.prefetch([url]) }
                            }
                        },
                        onNearEnd: { Task { await model.loadMoreStream() } },
                        onOpenLink: openWebLink,
                        onOpenImage: { url, frame in ImagePreviewPresenter.shared.present(url: url, sourceFrame: frame) },
                        onOpenVideo: { reference, poster, _ in
                            videoPreview = VideoPreviewItem(reference: reference, poster: poster)
                        }
                    )
                    .id(model.streamAnchor?.key ?? item.key)
                    .ignoresSafeArea(.container, edges: usesWideLayout ? [] : .bottom)
                }
                else if let error = model.bodyError {
                    VStack(spacing: 12) { Text(error); Button("重试") { model.selectAnswer(item) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { LoadingSkeleton(kind: .body, label: "正在加载正文").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
                if let error = model.streamError {
                    HStack {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if !model.streamSearchExhausted {
                            Button("重试") { model.retryStream() }.font(.footnote)
                        }
                    }.padding(8)
                        .padding(.bottom, usesWideLayout ? 0 : 64)
                }
            }
            .task(id: model.streamAnchor?.key) {
                await AvatarCache.shared.prefetch(Array(model.streamItems.prefix(6)).compactMap(\.avatarURL))
            }
            .background(readingBackground.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .trailing) {
                if usesWideLayout, !model.showsComments, model.bodyHTML != nil {
                    ReaderActionOverlay(focus: focus, model: model, layout: .trailing,
                                        collectedKeys: collectedKeys,
                                        onProfile: { profileItem = $0 },
                                        onCollect: { collectionItem = $0 })
                        .readerGlassCapsule()
                        .padding(.trailing, 12)
                }
            }
            .overlay(alignment: .bottom) {
                if !usesWideLayout, model.bodyHTML != nil {
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
            .navigationBarTitleDisplayMode(.inline)
            .alert("操作未完成", isPresented: Binding(get: { model.voteError != nil }, set: { if !$0 { model.voteError = nil } })) {
                Button("好", role: .cancel) { model.voteError = nil }
            } message: { Text(model.voteError ?? "") }
            .toolbar {
                if !usesWideLayout {
                    ToolbarItem(placement: .principal) {
                        Text(item.title).font(.subheadline.weight(.medium))
                            .lineLimit(1).truncationMode(.tail)
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

    /// A horizontal swipe closes the comment panel on both iPhone and iPad,
    /// instead of requiring a scroll to the top before pulling the sheet down.
    private var closeCommentsGesture: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            let dx = value.translation.width
            guard abs(dx) > 56, abs(dx) > abs(value.translation.height) * 1.2 else { return }
            model.showsComments = false
        }
    }

    private var commentList: some View {
        let rows = commentTreeRows(model.comments.flatMap { [$0] + (model.commentReplies[$0.id] ?? []) }, collapsed: collapsedComments)
        return List {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let comment = row.comment
                let depth = min(row.depth, 3)
                let isEndOfBranch = index + 1 == rows.count || rows[index + 1].depth == 0
                let root = rows[...index].last(where: { $0.depth == 0 })?.comment
                VStack(alignment: .leading, spacing: 7) {
                    commentRow(comment)
                    if row.hasChildren {
                        let isCollapsed = collapsedComments.contains(comment.id)
                        let count = max(comment.replyCount, model.commentReplies[comment.id]?.count ?? 1)
                        Button {
                            if !collapsedComments.insert(comment.id).inserted { collapsedComments.remove(comment.id) }
                        } label: {
                            compactCount(isCollapsed ? "chevron.down" : "chevron.up", count: count)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ReaderPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 32)
                        .accessibilityLabel(isCollapsed ? "展开 \(count) 条回复" : "收起 \(count) 条回复")
                    }
                    if isEndOfBranch, let root, !collapsedComments.contains(root.id),
                       root.replyCount > 0 || model.replyNext[root.id] != nil {
                        replyPagination(for: root)
                            .padding(.leading, 32)
                    }
                }
                .padding(.leading, CGFloat(depth) * 24)
                .padding(.top, row.depth == 0 ? (index == 0 ? 4 : 12) : 6)
                .padding(.bottom, row.depth == 0 ? 4 : 6)
                .overlay(alignment: .leading) {
                    if depth > 0 {
                        commentThreadLines(depth: depth, index: index, rows: rows)
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .task { await AvatarCache.shared.prefetch(Array(rows.dropFirst(index).prefix(6)).compactMap { $0.comment.avatarURL }) }
                .task {
                    if index == rows.count - 1, model.canLoadMoreComments {
                        await model.loadComments()
                    }
                }
            }
            if model.commentError != nil {
                Button { Task { await model.loadComments(reset: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .accessibilityLabel("重试加载评论")
            } else if model.loadingComments {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
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
                    ZStack {
                        Circle().fill(ReaderPalette.accent.opacity(0.08)).frame(width: 100, height: 100)
                        Circle().stroke(ReaderPalette.accent.opacity(0.16), lineWidth: 1).frame(width: 72, height: 72)
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 29, weight: .light)).foregroundStyle(ReaderPalette.accent.opacity(0.8))
                        Circle().fill(ReaderPalette.accent.opacity(0.35)).frame(width: 5, height: 5).offset(x: 42, y: -29)
                        Circle().fill(ReaderPalette.accent.opacity(0.20)).frame(width: 4, height: 4).offset(x: -40, y: 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("暂无评论")
                    .allowsHitTesting(false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    let count = model.commentTarget?.commentCount ?? model.comments.count
                    compactCount("bubble.right", count: count)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(displayCount(count)) 条评论")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { model.showsComments = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭评论")
                }
            }
    }

    /// Replies are joined by quiet vertical rules aligned under the parent comment's
    /// avatar. A reply at depth d draws the rule of every ancestor level as well, so
    /// the thread stays continuous when replies are nested; the rules start and end
    /// with a soft cap instead of a cut-off stub.
    private func commentThreadLines(depth: Int, index: Int, rows: [CommentTreeRow]) -> some View {
        let previousDepth = index > 0 ? min(rows[index - 1].depth, 3) : -1
        let nextDepth = index + 1 < rows.count ? min(rows[index + 1].depth, 3) : -1
        return ZStack(alignment: .leading) {
            ForEach(1...depth, id: \.self) { level in
                let starts = previousDepth < level
                let ends = nextDepth < level
                UnevenRoundedRectangle(
                    topLeadingRadius: starts ? 0.75 : 0,
                    bottomLeadingRadius: ends ? 0.75 : 0,
                    bottomTrailingRadius: ends ? 0.75 : 0,
                    topTrailingRadius: starts ? 0.75 : 0
                )
                .fill(ReaderPalette.accent.opacity(0.32))
                .frame(width: 1.5)
                .padding(.leading, 11.25 + CGFloat(level - 1) * 24)
            }
        }
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func replyPagination(for root: ReadingComment) -> some View {
        if model.loadingReplies.contains(root.id) {
            ProgressView()
        } else if model.replyErrors[root.id] != nil {
            Button { Task { await model.loadReplies(to: root) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("重试加载回复")
        } else if model.commentReplies[root.id] == nil || model.replyNext[root.id] != nil {
            let loaded = model.commentReplies[root.id]?.count ?? 0
            let remaining = model.commentReplies[root.id] == nil ? max(root.replyCount, 1) : max(root.replyCount - loaded, 0)
            Button {
                Task { await model.loadReplies(to: root) }
            } label: {
                if remaining > 0 {
                    compactCount("bubble.right", count: remaining)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ReaderPalette.accent)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ReaderPalette.accent)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.commentReplies[root.id] == nil ? "查看 \(root.replyCount) 条回复" : "加载更多回复")
        }
    }

    private func commentRow(_ comment: ReadingComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(url: comment.avatarURL, size: 24)
            VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(comment.author).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let replyTo = comment.replyTo {
                            Image(systemName: "arrowtriangle.right.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(replyTo).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let ip = comment.ipInfo, !ip.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 10, weight: .medium))
                                Text(ip).lineLimit(1)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("地区：\(ip)")
                        }
                        if comment.likes > 0 {
                            compactCount("hand.thumbsup", count: comment.likes)
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("\(displayCount(comment.likes)) 次赞同")
                        }
                    }.frame(minHeight: 24)
                    ForEach(Array(commentHTMLFragments(comment.html).enumerated()), id: \.offset) { _, fragment in
                        switch fragment {
                        case .text(let html):
                            let text = htmlText(html)
                            if !text.isEmpty { CommentInlineText(text: text) }
                        case .image(let url):
                            CommentImageView(url: url)
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 2)
    }

    private func retryRow(_ message: String, action: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(message).foregroundStyle(.secondary); Button("重试") { Task { await action() } } }.padding(.vertical, 8)
    }

}


/// Floating reading chrome (reading settings / account). It fades out while the
/// reader scrolls down so the page reads edge-to-edge, and comes back on scroll up
/// or when the page is at the top. Only this capsule observes the visibility store.
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
            if layout == .trailing {
                VStack(spacing: 2) { actions(for: item) }
            } else {
                HStack(spacing: 0) { actions(for: item) }
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
        if item.kind == .answer || item.kind == .article {
            Button { onCollect(item) } label: {
                Image(systemName: collectedKeys.contains(item.key) ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel(collectedKeys.contains(item.key) ? "管理收藏，已收藏" : "收藏")
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
    static let selection = accent.opacity(0.13)
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

private struct AuthorProfileView: View {
    let item: ReadingItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                AvatarView(url: item.avatarURL, size: 76)
                Text(item.author.isEmpty ? "匿名用户" : item.author).font(.title3.weight(.semibold))
                if let headline = item.authorHeadline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(headline).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if let token = item.authorToken, !token.isEmpty {
                    Link(destination: URL(string: "https://www.zhihu.com/people")!.appendingPathComponent(token)) {
                        Label("在知乎查看主页", systemImage: "arrow.up.right")
                    }.buttonStyle(.bordered).padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28).padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("作者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
            } }
        }.tint(ReaderPalette.accent).presentationDetents([.medium, .large])
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
                    Text("没有可用的收藏夹，请先在知乎创建。 ").foregroundStyle(.secondary)
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

private struct ItemRow: View {
    let item: ReadingItem
    var isHot = false
    var showsTitle: Bool = true

    /// The answer list mirrors the reading header: author on the left, counts
    /// on the right of the same line. Feed rows keep their separate footer so
    /// thumbnails still have room.
    private var showsInlineCounts: Bool {
        !showsTitle && item.kind == .answer && (item.upCount != nil || item.commentCount != nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if showsTitle { Text(item.title).font(.system(size: 16, weight: .semibold)).lineSpacing(4).fixedSize(horizontal: false, vertical: true) }
                if !isHot, (!item.author.isEmpty || showsInlineCounts) {
                    HStack(spacing: 7) {
                        if !item.author.isEmpty {
                            AvatarView(url: item.avatarURL, size: showsTitle ? 22 : 28)
                            Text(item.author).font(showsTitle ? .caption.weight(.medium) : .headline)
                                .foregroundStyle(showsTitle ? Color.secondary : Color.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if showsInlineCounts {
                            Spacer(minLength: 8)
                            countsRow
                        }
                    }
                }
                if !item.excerpt.isEmpty { Text(htmlText(item.excerpt)).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(3).lineLimit(2) }
                if !showsInlineCounts, item.kind == .answer, item.upCount != nil || item.commentCount != nil {
                    countsRow
                }
            }.padding(.vertical, 14)
            if showsTitle, let url = item.imageURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                    .frame(width: 72, height: 82).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.vertical, 14)
            }
        }
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 10) }
    }

    private var countsRow: some View {
        HStack(spacing: 16) {
            if let count = item.upCount {
                compactCount("hand.thumbsup", count: count)
                    .accessibilityLabel("\(displayCount(count)) 次赞同")
            }
            if let count = item.commentCount {
                compactCount("bubble.right", count: count)
                    .accessibilityLabel("\(displayCount(count)) 条评论")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }
}

@MainActor
private final class AvatarCache {
    static let shared = AvatarCache()
    private let images = NSCache<NSURL, UIImage>()
    private var pending: [URL: Task<UIImage?, Never>] = [:]

    private init() { images.countLimit = 200; images.totalCostLimit = 20 * 1024 * 1024 }

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
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary.opacity(0.5)) }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await AvatarCache.shared.image(for: url)
            if !Task.isCancelled { image = loaded }
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
    let text: String
    @State private var images: [URL: UIImage] = [:]

    private var fragments: [CommentTextFragment] { commentTextFragments(text) }
    private var rendered: Text {
        fragments.reduce(Text("")) { result, fragment in
            switch fragment {
            case .text(let value): return result + Text(value)
            case .emoji(let label, let url):
                if let image = images[url] {
                    // 行内表情图默认与文字基线底部对齐，视觉上会偏高，向下微调。
                    return result + Text(Image(uiImage: image)).baselineOffset(-3)
                }
                return result + Text(label)
            }
        }
    }
    var body: some View {
        rendered.font(.body).textSelection(.enabled)
            .accessibilityLabel(text)
            .task(id: text) { await loadEmojis() }
    }
    private func loadEmojis() async {
        let urls = Set(fragments.compactMap { fragment -> URL? in
            if case .emoji(_, let url) = fragment { return url }
            return nil
        })
        for url in urls where images[url] == nil {
            var image = await Self.fetchEmoji(url)
            if image == nil, let fallback = CommentEmoji.fallbackURL(for: url) {
                image = await Self.fetchEmoji(fallback)
            }
            if let image, !Task.isCancelled { images[url] = image }
        }
    }

    private static func fetchEmoji(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.setValue("https://www.zhihu.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), let source = UIImage(data: data) else { return nil }
        let size = CGSize(width: 21, height: 21)
        return UIGraphicsImageRenderer(size: size).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

private struct CommentImageView: View {
    let url: URL
    @State private var frame: CGRect = .zero

    var body: some View {
        AnimatedCommentImage(url: url)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: 400, maxHeight: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("查看评论图片")
    }
}

private struct AnimatedCommentImage: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        // 图片本身不需要交互，让点击事件冒泡给 SwiftUI 的放大手势。
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        let escaped = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        view.loadHTMLString("<html><meta name=\"viewport\" content=\"width=device-width\"><style>html,body{margin:0;width:100%;height:100%}img{width:100%;height:100%;object-fit:contain}</style><img src=\"\(escaped)\"></html>", baseURL: URL(string: "https://www.zhihu.com/"))
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var url: URL? }
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
    var onOpenImage: (URL, CGRect) -> Void = { _, _ in }
    var onOpenVideo: (VideoReference, URL?, CGRect) -> Void = { _, _, _ in }
    @ObservedObject private var fontManager = ReadingFontManager.shared
    @AppStorage("reading.fontSize") private var fontSize = ReadingDefaults.fontSize
    @AppStorage("reading.lineHeight") private var lineHeight = 1.8
    @AppStorage("reading.width") private var readingWidth = ReadingDefaults.width
    @AppStorage("reading.paragraphSpacing") private var paragraphSpacing = 1.0
    @AppStorage("reading.font") private var font = "system"
    @AppStorage("reading.theme") private var theme = "system"
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false
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
        let imageTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(HTMLReader.Coordinator.handleImageTap(_:)))
        imageTap.cancelsTouchesInView = false
        imageTap.delegate = context.coordinator
        view.addGestureRecognizer(imageTap)
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
        let paperColor: String
        switch theme {
        case "paper": paperColor = "#fbf7ef"
        case "light": paperColor = "#ffffff"
        case "dark": paperColor = "#272b2e"
        default: paperColor = "light-dark(#ffffff, #252a27)"
        }
        let cardCSS = paperCards ? """
        body { padding-left: 16px; padding-right: 16px; }
        .answer { background: \(paperColor); border: 1px solid rgba(128,128,128,.12); border-radius: 12px; padding: 26px 22px 28px; box-shadow: 0 5px 18px rgba(0,0,0,.08); }
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
        let presentationKey = "\(colors.0)|\(colors.1)|\(colors.2)|\(fontFamily)|\(fontSize)|\(lineHeight)|\(readingWidth)|\(paragraphSpacing)|\(title)|\(cardCSS)|\(previewCSS)"
        context.coordinator.onVisibleAnswer = onVisibleAnswer
        context.coordinator.onNearEnd = onNearEnd
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onOpenImage = onOpenImage
        context.coordinator.onOpenVideo = onOpenVideo
        context.coordinator.onChromeVisibility = onChromeVisibility
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
            let ip = (answer.ipInfo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        :root { --wize-link: light-dark(#527863, #a7c4b1); overflow-x: hidden; color-scheme: \(colors.2); background: \(colors.0); color: \(colors.1); } body[data-wize-pending] { opacity: 0; } body { box-sizing: border-box; font: \(fontSize)px \(fontFamily); line-height: \(lineHeight); max-width: \(readingWidth)px; margin: 36px auto \(paperCards ? 0 : 36)px; padding: 0 clamp(20px, 5vw, 28px) \(paperCards ? 0 : 12)px; overflow-wrap: anywhere; } h1 { font-family: \(headingFontFamily); font-size: clamp(23px, 6vw, 27px); font-weight: 600; line-height: 1.45; letter-spacing: .02em; margin: 0 0 30px; } .byline { display:flex; align-items:center; gap:10px; opacity:.78; font: 500 14px -apple-system, sans-serif; margin: 0 -8px 26px; padding: 6px 8px; border-left: 2px solid transparent; border-radius: 3px; } .avatar { width:32px; height:32px; border-radius:50%; object-fit:cover; } .counts { display:flex; gap:22px; font: 12px -apple-system, sans-serif; opacity:.58; margin-top:24px; } .counts b { font-weight:500; } .counts .ip { max-width:9em; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; } .answer + .answer { border-top: 1px dotted rgba(128,128,128,.32); margin-top: 32px; padding-top: 28px; } p { margin: 0 0 \(paragraphSpacing * 0.7)em; } main p:empty, main p:has(> br:only-child) { display:none; } img, video { max-width: 100%; height: auto; } main img { border-radius: 5px; } .avatar { height:32px; } a { color: var(--wize-link); text-decoration-line: underline; text-decoration-color: color-mix(in srgb, currentColor 34%, transparent); text-decoration-thickness: .06em; text-underline-offset: .18em; text-decoration-skip-ink: auto; font-weight: 500; -webkit-tap-highlight-color: transparent; } a:visited { color: var(--wize-link); } a:active { opacity: .58; } main a { overflow-wrap: anywhere; } pre { white-space: pre-wrap; }
        .byline { opacity: 1; margin-bottom: 20px; } .author-name { min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; } .counts { margin:0 0 0 auto; flex-shrink:0; gap:14px; opacity:.68; } .counts span { display:inline-flex; align-items:center; gap:6px; } .counts .ip { max-width:9em; } .counts svg { width:15px; height:15px; fill:none; stroke:currentColor; stroke-width:1.5; stroke-linejoin:round; stroke-linecap:round; }
        .wize-video { position:relative; display:block; margin:1.1em 0; border-radius:8px; overflow:hidden; background:#111; }
        .wize-video-poster { display:block; width:100%; height:auto; margin:0; border-radius:0; }
        .wize-video:not(:has(.wize-video-poster)) { aspect-ratio:16/9; background:linear-gradient(135deg,#2d3833,#111); }
        .wize-video-play { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; background:linear-gradient(180deg,rgba(0,0,0,.02),rgba(0,0,0,.28)); }
        .wize-video-play svg { width:54px; height:54px; padding:11px; border-radius:50%; background:rgba(255,255,255,.94); fill:#1b1f1d; box-shadow:0 6px 20px rgba(0,0,0,.24); }
        .wize-video-title { position:absolute; left:14px; right:14px; bottom:12px; color:#fff; font:500 13px -apple-system,sans-serif; line-height:1.35; text-shadow:0 1px 4px rgba(0,0,0,.55); }
        main blockquote { margin: 1.2em 0; padding-left: 1em; border-left: 2px dotted rgba(128,128,128,.42); color: inherit; opacity: .82; }
        main img.emojione, main img.ztext-emoji { display: inline-block; vertical-align: -0.18em; margin: 0 .06em; border-radius: 0; }
        main hr { border: 0; height: 0; border-top: 1.5px dotted color-mix(in srgb, currentColor 36%, transparent); margin: 2em 0; }
        main p:last-child { margin-bottom: 0; }
        main figure { margin: .8em 0; }
        main figcaption { margin-top: .4em; font-size: .8em; line-height: 1.5; text-align: center; opacity: .68; }
        main ul, main ol { padding-left: 1.5em; }
        main li + li { margin-top: .2em; }
        main pre { overflow-x: auto; overflow-wrap: normal; } main table { display: block; max-width: 100%; overflow-x: auto; }
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
        private var lastScrollOffsetY: CGFloat = 0
        private var scrollAccum: CGFloat = 0
        private weak var webView: WKWebView?
        var onOpenLink: (URL) -> Void = { _ in }
        var onOpenImage: (URL, CGRect) -> Void = { _, _ in }
        var onOpenVideo: (VideoReference, URL?, CGRect) -> Void = { _, _, _ in }

        func attach(_ webView: WKWebView) { self.webView = webView }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// 阅读区里点到图片时打开全屏查看；头像、行内表情与小图标不触发。
        @objc func handleImageTap(_ gesture: UITapGestureRecognizer) {
            guard let webView else { return }
            let point = gesture.location(in: webView)
            let script = """
            (() => {
                const el = document.elementFromPoint(\(point.x), \(point.y));
                const video = el && el.closest ? el.closest('[data-wize-video]') : null;
                if (video) {
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
                    DispatchQueue.main.async { self.onOpenVideo(VideoReference(id: id, kind: kind), poster, frame) }
                    return
                }
                guard let src = info["src"] as? String,
                      let url = URL(string: src),
                      let className = info["cls"] as? String else { return }
                // 跳过头像、行内表情和其他小图；只放大正文里的图片。
                guard width >= 60, !className.contains("avatar") else { return }
                DispatchQueue.main.async { self.onOpenImage(url, frame) }
            }
        }
        func cancelPendingAppends() {
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
                    self.inspect(webView)
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
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userHasScrolled = true
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if scrollView.contentOffset.x != 0 {
                scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y), animated: false)
            }
            guard streamEnabled, !loadingDocument, pendingAnchorID == nil, !restoringAnchor,
                  scrollView.contentSize.height > 0, let webView else { return }
            if userHasScrolled {
                let y = scrollView.contentOffset.y
                let delta = y - lastScrollOffsetY
                lastScrollOffsetY = y
                if y <= 16 {
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
                    } else if scrollAccum < -40, !chromeVisible {
                        chromeVisible = true
                        scrollAccum = 0
                        onChromeVisibility(true)
                    } else if abs(scrollAccum) > 160 {
                        scrollAccum = 0
                    }
                }
            } else {
                // Keep the baseline in step with programmatic scrolling (anchor restore).
                lastScrollOffsetY = scrollView.contentOffset.y
            }
            let remaining = scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y
            if remaining < scrollView.bounds.height * 1.3,
               Date().timeIntervalSince(lastNearEnd) > 0.6 {
                lastNearEnd = Date()
                onNearEnd()
            }
            if userHasScrolled, Date().timeIntervalSince(lastInspection) > 0.2 { inspect(webView) }
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate, let webView, streamEnabled { inspect(webView) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let webView, streamEnabled { inspect(webView) }
        }
        func inspectAfterLayout(_ webView: WKWebView) {
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
            let script = "(() => { const answers = Array.from(document.querySelectorAll('section[data-wize-answer]')); const focus = Math.min(innerHeight * .35, innerHeight - 1); const answer = answers.find(e => e.getBoundingClientRect().bottom > focus) || answers.find(e => e.getBoundingClientRect().bottom > 0); const index = answers.indexOf(answer); if (index >= 0) answers.slice(index, index + 2).forEach(section => section.querySelectorAll('img[loading=lazy]').forEach(img => img.loading = 'eager')); return { id: answer?.getAttribute('data-wize-answer') || null }; })()"
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
    @StateObject private var session = ZhihuLoginSession()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("在知乎完成登录或安全验证").font(.subheadline.weight(.semibold))
                    Text("账号信息由知乎处理，登录状态保存在此设备。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(ReaderPalette.directory)

                if session.loading {
                    ProgressView().progressViewStyle(.linear).tint(ReaderPalette.accent)
                }
                ZStack {
                    ZhihuLoginWebView(session: session)
                    if let error = session.pageError {
                        ContentUnavailableView {
                            Label("无法打开知乎", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重新加载") { session.reload() }.buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemBackground))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = session.verificationError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("知乎账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { session.verify() } label: {
                        Text(session.checking ? "正在验证" : "完成登录")
                    }.disabled(session.checking || session.pageError != nil)
                }
                if session.canGoBack {
                    ToolbarItem(placement: .bottomBar) {
                        Button { session.goBack() } label: { Label("网页后退", systemImage: "chevron.left") }
                    }
                }
            }
            .onChange(of: session.verified) { verified in if verified { dismiss() } }
            .onDisappear { session.stopObserving() }
        }
    }
}

@MainActor
private final class ZhihuLoginSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    @Published var loading = true
    @Published var checking = false
    @Published var verified = false
    @Published var canGoBack = false
    @Published var pageError: String?
    @Published var verificationError: String?
    let webView: WKWebView
    private let source = ZhihuSource()
    private let loginURL = URL(string: "https://www.zhihu.com/signin")!
    private var authCookie: String?
    private var observingCookies = false
    private var stopped = false
    private var pendingAutoVerification = false
    private var sawNewAuthCookie = false
    private var sawSignInPage = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        Task {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            authCookie = Self.authCookieValue(await store.allCookies())
            guard !stopped else { return }
            store.add(self)
            observingCookies = true
            cookiesDidChange(in: store)
        }
        webView.load(URLRequest(url: loginURL))
    }

    func reload() {
        pageError = nil
        if webView.url == nil { webView.load(URLRequest(url: loginURL)) }
        else { webView.reload() }
    }
    func goBack() { webView.goBack() }
    func verify(silent: Bool = false) {
        guard !checking else { return }
        checking = true
        if silent { pendingAutoVerification = false } else { verificationError = nil }
        Task {
            defer {
                checking = false
                if pendingAutoVerification && !loading && !verified && !stopped { verify(silent: true) }
            }
            do {
                _ = try await source.currentUser()
                verified = true
            } catch {
                if !silent { verificationError = "暂时无法确认登录。请在知乎页面完成登录或验证后重试。" }
            }
        }
    }
    func stopObserving() {
        stopped = true
        if observingCookies { webView.configuration.websiteDataStore.httpCookieStore.remove(self) }
        observingCookies = false
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task {
            let newValue = Self.authCookieValue(await cookieStore.allCookies())
            guard observingCookies, newValue != authCookie else { return }
            authCookie = newValue
            if newValue != nil {
                sawNewAuthCookie = true
                pendingAutoVerification = true
                if !loading { verify(silent: true) }
            }
        }
    }
    private static func authCookieValue(_ cookies: [HTTPCookie]) -> String? {
        cookies.first {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return $0.name == "z_c0" && (domain == "zhihu.com" || domain.hasSuffix(".zhihu.com")) && !$0.value.isEmpty
        }?.value
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; pageError = nil; verificationError = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; canGoBack = webView.canGoBack
        if let url = webView.url, let host = url.host?.lowercased(),
           host == "zhihu.com" || host.hasSuffix(".zhihu.com") {
            if url.path.hasPrefix("/signin") { sawSignInPage = true }
            if sawSignInPage && (url.path.isEmpty || url.path == "/") { pendingAutoVerification = true }
        }
        if sawNewAuthCookie { pendingAutoVerification = true }
        if pendingAutoVerification { verify(silent: true) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false; pageError = "页面已停止运行，请重新加载。"
    }
    private func fail(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false; pageError = "请检查网络连接后重试。"
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
