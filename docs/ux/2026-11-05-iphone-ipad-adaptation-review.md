# 无知 / Wize：iPhone 与 iPad 适配审阅（2026-11-05）

- 审阅范围：iPhone / iPad 双端布局适配、方向与尺寸变化、安全区、Dynamic Type、深浅色、评论与设置面板、iPad 多任务基础、可访问性（对比度 / VoiceOver / Reduce Motion）、工程配置。
- 审阅方式：**模拟器实拍 + 真机（部分）+ 静态代码审计 + 单元测试**。设备与工具矩阵见附录 A。
- 结论口径：✅ 实测通过　⚠️ 可用但有明确问题　❌ 不达标或与 PLAN 冲突　◻ 未验证。
- 本报告为审阅记录，不代表任何修复已完成；仓库源码未被修改（审阅期间仅新增本报告与截图）。

---

## 0. 总体结论

**还没有做到"最好的 iPhone 和 iPad 适配"。** 目前处于**「信息架构已落地、平台化细节未收尾」**阶段：

- **主干是对的**：iPad 双栏（左目录 + 右纸页正文）、进入栏目自动打开首条、评论从右侧覆盖而不改变正文宽度、iPhone 单列导航、连续回答阅读、深浅色与 WebView 排版，这些 PLAN 里已确定的体验都在真机/模拟器上跑通了，视觉方向（纸页 + 轻玻璃）也符合设计基线。
- **但离"HIG 意义上的优秀适配"还差一轮系统精修**，最关键的 6 个问题：
  1. **Dynamic Type 只覆盖了一半**：系统最大无障碍字号下，左目录的作者名/计数放大到 2–3 倍，而标题仍是固定 16pt、摘要固定 14pt（层级倒置）；正文 WebView 完全不变（固定 18px）。
  2. **跨 760pt 布局切换会丢阅读位置**：iPad mini 横屏（双栏）→ 竖屏（单栏）→ 横屏后回到第一个回答顶部；转回横屏的截图与冷启动逐像素相同。
  3. **iPad 首帧按手机布局求值**：`availableWidth` 初值 0，iPad 第一帧渲染的是 iPhone 单列结构，第二帧才切双栏（代码确认，需录屏复核可见性）。
  4. **iPad mini 竖屏（744pt）被当成窄窗口**，整体回退 iPhone 单栏——与 PLAN「iPad 保持双栏」直接冲突（产品需拍板阈值）。
  5. **悬浮操作条盖住正文**：iPad mini 横屏、Pro 13 竖屏、iPhone 横屏都能看到玻璃操作条压在文字/计数上。
  6. **iPhone 竖屏阅读页可能空白**：审查管线两次独立启动、等待 20 秒后正文仍全白（工具栏/浮条正常），同管线横屏与评论场景正常；疑为导航转场中 WKWebView 首次绘制未触发，需人工点按复核（§2 P1-5）。

如果以"iPad 是阅读主设备、iPhone 是轻量阅读"的产品假设来衡量：**iPad 适配完成度约七成，iPhone 约六成**，剩余主要是 Dynamic Type、尺寸变化状态保持、悬浮层避让与可访问性打磨。

---

## 1. 分维度结论

| # | 维度 | 结论 | 关键证据 |
|---|---|---|---|
| 1 | iPad 双栏信息架构 | ✅ | [Pro 13 横屏双栏](../media/adaptation-review/ipadpro13-landscape-feed.png)、[Pro 13 竖屏双栏](../media/adaptation-review/ipadpro13-portrait-feed.png)：左 36% 目录 + 右 64% 纸页正文，进入自动打开首条 |
| 2 | iPad 窄窗口 / iPad mini | ❌ 需产品拍板 | [iPad mini 竖屏 744pt 回退单栏](../media/adaptation-review/ipadmini-portrait-feed-single-column.png)；横屏 1133pt 为双栏 |
| 3 | 跨阈值旋转 / 尺寸变化状态 | ❌ | mini 横→竖→横实验：阅读页保留但滚动位置丢失，转回横屏截图与冷启动 sha256 完全相同 |
| 4 | 首帧布局 | ❌（代码确认） | `ReaderView.swift:8,22-24,29-33`：`availableWidth` 初值 0 → 首帧 `phoneLayout` |
| 5 | iPhone 单列与横屏 | ⚠️ | iPhone 17 横屏 feed 正常（顶部栏横跨 80–788pt，左右安全区各 59pt）——**此前怀疑的"横屏半屏 bug"不成立**；但横屏 reader 底部浮条盖住正文 |
| 6 | 安全区（灵动岛 / Home indicator / 横屏刘海） | ⚠️ | 顶部栏走 `safeAreaInset`、评论 sheet 走系统 detent、横屏左右安全区正确；底部浮条保持沉浸式 overlay（**不做预留的不透明底栏**，用户已明确该方案不值得） |
| 7 | Dynamic Type / 无障碍字号 | ❌ | [AX XXXL 下左目录层级倒置、正文不缩放](../media/adaptation-review/ipadpro13-portrait-reader-axxxl.png)；CSS 固定 px（`:1153`）、列表标题/摘要固定 `.system(size:)`（`:863,871`） |
| 8 | 深浅色 / 纸色 | ✅ | Pro 13 横/竖、mini 横屏、iPhone 16 Pro 真机深色 feed 均正确反色；`light-dark()` + 动态 `UIColor` 生效 |
| 9 | 评论浮层 / sheet | ⚠️ | 宽度公式正确（420 / 371.5 / 407.9pt）；关闭与点空白可用；浅色下浮层与纸页近同色、无变暗遮罩、未显示"评论属于哪位作者" |
| 10 | 阅读设置 | ⚠️ | iPad 居中 form sheet 完整可读；iPhone 上 **设置预览区出现空白**（见 §2.5） |
| 11 | 可访问性（对比度 / VO / 动效） | ⚠️ | 正文对比度 12–16:1 优秀；链接色 3.0–3.5:1、12px 计数 3.7:1、选中态 1.19:1 不达标；评论浮层非 modal；Reduce Motion/Increase Contrast 未适配 |
| 12 | 键盘 / 指针（iPad 生产力） | ❌ | 全仓库无 `keyboardShortcut` / `hoverEffect` / `focusable` |
| 13 | iPad 多任务基础 | ⚠️ | 无 `UIRequiresFullScreen`、有 LaunchScreen、target=1,2；但无场景清单/多窗口声明，Split View/Stage Manager 未实测 |
| 14 | 场景状态恢复 | ❌ | 无 `@SceneStorage`、无 `NavigationPath` 持久化；冷启动回到 feed 顶部 |
| 15 | 工程配置 | ⚠️ | `project.yml` ↔ `pbxproj` 同步（xcodegen 重生成 diff=0）、图标/LaunchScreen 正常；缺共享 scheme、缺 `PrivacyInfo.xcprivacy`、iPhone 方向键未显式声明 |
| 16 | 单元测试 | ✅ | CONTRIBUTING 5 条命令 5/5 PASS（插入保位、样式保位、动作归属、评论片段、模型状态） |

---

## 2. 问题清单（按严重级）

> 说明：`file:line` 指向仓库源码；**代码确认** = 可直接从源码判定，**实测确认** = 本轮设备截图/像素测量可证实，**需复现** = 观察到但受环境限制未能稳定复现。

### P1-1　Dynamic Type 只覆盖一半：层级倒置 + 正文不缩放【实测确认】
- **现象**：`accessibility-extra-extra-extra-large` 下（[截图](../media/adaptation-review/ipadpro13-portrait-reader-axxxl.png)）：
  - 左目录作者名「林间来信」、计数「1286 / 42」放大 2–3 倍，**条目标题仍 16pt、摘要仍 14pt** → 次级信息大于主标题，阅读层级被破坏；
  - 右侧 WebView 正文与普通字号截图**逐像素相同**，完全不跟随系统字号；
  - 底部/右侧悬浮操作条图标与计数为固定 17/10/12pt，同样不缩放。
- **根因**：`ItemRow` 标题 `.font(.system(size: 16, weight: .semibold))`、摘要 `.font(.system(size: 14))`（`Wize/ReaderView.swift:863,871`）；正文 CSS `body { font: \(fontSize)px ... }`（`:1153`，默认 17/18 为固定常量 `:739-740`）；全仓库无 `@ScaledMetric` / `UIFontMetrics` / `preferredFont`。
- **建议**：① 列表标题/摘要改 `.headline`/`.subheadline`（或 `@ScaledMetric`）；② WebView 监听 `UIContentSizeCategory.didChangeNotification`，用 `UIFontMetrics(forTextStyle: .body).scaledValue(for: 17)` 计算 CSS 字号，用户自定义字号作为系数叠加；③ 悬浮条计数改 `.caption2` 并设置最大缩放上限。
- **验收**：AX XXXL 下左目录标题 ≥ 作者名、正文显著放大、布局不截断。

### P1-2　跨 760pt 布局切换丢阅读位置【实测确认】
- **现象**：iPad mini 横屏 1133pt（双栏）读到第 2 个回答 → 竖屏 744pt（单栏，阅读页与选中项保留）→ 转回横屏：右栏回到**第一个回答顶部**；`mini-landscape-after-rotate-back-light.png` 与全新启动的 `mini-landscape-feed-light.png` **sha256 完全相同**。
- **根因**：`ReaderView.swift:29` 的 `if usesWideLayout { wideLayout } else { phoneLayout }` 是两棵不同视图树，跨阈值时 `detail`/`HTMLReader` 被销毁重建，`WKWebView` 的滚动状态随旧 Coordinator 丢失；`onChange(of: usesWideLayout)`（`:75-87`）只重建 `phonePath`，未恢复滚动/锚点。
- **建议**：把 `HTMLReader` 提升到宽窄分支之外（共享同一 `UIViewRepresentable` 身份），或把 `(answerID, scrollY/fraction)` 持久化到 `ReaderModel`，重建后通过现有 `ScrollRequest`/注入脚本恢复；验收：横→竖→横仍停在原回答原段落。

### P1-3　iPad 首帧按手机布局求值【代码确认，需录屏复核】
- `usesWideLayout` 依赖 `availableWidth >= 760`，而 `availableWidth` 初值 0，只在 `.onAppear`/`.onChange` 赋值（`ReaderView.swift:8,22-24,29-33`）→ iPad 第一帧渲染 `phoneLayout`（`NavigationStack` + `TabView(.page)`），第二帧才切双栏，同时会触发一次 `onChange(of: usesWideLayout)` 状态迁移。
- **建议**：首帧把 `availableWidth == 0` 视为"未知"而非"窄"（`(availableWidth == 0 || availableWidth >= 760)`），或改用 `onGeometryChange(for:)` 预置宽度；验收：iPad 冷启动录屏无单列一闪。

### P1-4　iPad mini 竖屏 744pt 被误判为窄窗口，回退单栏【实测确认，需产品拍板】
- **现象**：[iPad mini (A17 Pro) 竖屏 744×1133pt 全屏启动为 phoneLayout 单栏](../media/adaptation-review/ipadmini-portrait-feed-single-column.png)：顶部推荐/热榜 + 全宽单列 + iPhone 式整页阅读 + 底部 sheet 评论，没有左目录/右正文双栏。
- **冲突**：`PLAN.md:9`「iPad 保持左侧内容列表、右侧正文的双栏」；`PLAN.md:13`「iPad 窄窗口同样使用单列」——744pt 是 mini 的**常规全屏宽度**，不是窄窗口。当前 16pt 之差让 mini 竖屏整体降级。
- **建议**：阈值降至约 700–720，或改为「idiom==pad && regular 即双栏，仅在窗口 < ~700pt 时单列」；若产品确认 mini 竖屏就该单列，请把该决策写回 PLAN 并显式化阈值，避免"实现与文档不一致"。

### P1-5　iPhone 竖屏阅读页可能出现空白 WebView【可复现于审查管线，需人工点按复核】
- **现象**：iPhone 17e 上 `portrait-reader` 场景正文区整片空白（工具栏标题与底部浮条正常显示，说明 `bodyHTML != nil`，见[空白截图](../media/adaptation-review/iphone17e-portrait-reader-blank.png)），**两次独立启动间隔 50 分钟、等待 20 秒后仍空白且截图 sha256 完全一致**（非渲染延迟）；同样管线的 `landscape-reader` 正常、`comments` 场景（打开评论引发一次视图更新后）正文可见。`settings` 的「预览」WKWebView 同样空白。
- **可能的机制**：`portrait-reader` 场景复刻的是真实用户路径——`model.open(item)` 后立即 `phonePath.append(.answer)` 推入详情页（`ReaderView.swift:269-272` 与审查注入 `:140-158` 同序）。详情页的 WKWebView 在导航转场期间创建，若首次 `loadHTMLString` 后未获得绘制机会，会停留为空白层，直到下一次 SwiftUI 更新（评论/设置等交互）才显示。`body[data-wize-pending]{opacity:0}`（`:1167`、`:1047-1074`）与 `allowsContentJavaScript=false`（`:1046`）也可能叠加。
- **判断**：审查注入只增加了"自动触发同一用户动作序列"的 `reviewAutoScene()`，布局代码未改；因此这很可能是**普通点按进入阅读页也会偶发**的真实缺陷，但本轮无 XCUITest，无法用真实点按 100% 复现定性。
- **建议**：① 人工复核：iPhone 竖屏连续点按 10 条内容进入阅读页，观察是否出现空白（可录屏）；② 给 `data-wize-pending` 加原生超时兜底；③ 详情页 WKWebView 在 `didFinish` 前强制 `setNeedsLayout`/占位动画，或等 `bodyHTML` 就绪后再 push 转场；④ 验收：冷启动/连续点按各 20 次无空白。

### P2-1　悬浮操作条压住正文 / 计数【实测确认】
- iPad mini 横屏（右栏 725pt）浮条直接盖住正文行尾；Pro 13 竖屏（右栏 660pt）盖住回答卡片的评论计数；**iPhone 横屏**浮条覆盖正文两行（[截图](../media/adaptation-review/iphone17e-landscape-reader.png)）。
- 根因：浮条为 `.overlay(alignment: .trailing/.bottom)`（`ReaderView.swift:408-424`），不参与布局；正文 CSS 右侧只有 `clamp(20px,5vw,28px)` padding（`:1153`）。
- 建议（2026-11-05 按用户反馈修订）：**不为底部预留独立的、不透明的"安全阅读区"**——那会在阅读页底部制造一条常驻的灰色色带，用户明确表示不接受、不值得。保持 PLAN 的沉浸式「悬浮操作直接覆盖阅读区边缘」：
  1. 手机端唯一需要的「避让」是让正文末尾能滚到悬浮条之上（现有 CSS `padding-bottom: 100px` 只是文末可滚动余量，背景与纸面同色，不产生色带），保持现状即可；
  2. 真正要修的是 **iPad 宽栏右侧浮条对正文的横向遮挡**：给 WebView `padding-right` 增加约 72px（浮条宽 + 间距），与底部无关；
  3. 若后续仍希望减少遮挡，可做**滚动时淡出浮条**（可选交互，不占布局），而不是移出独立底栏。

### P2-2　评论浮层视觉层级与归属【实测确认】
- 浅色下浮层（`systemBackground` 纯白）与纸页 `#FBF9F7` 几乎同色，仅靠轻阴影区分；没有变暗遮罩，只有 `Color.black.opacity(0.001)` 点击层（`ReaderView.swift:133-141`）。
- 浮层顶部只显示评论数，未标明"评论属于哪位作者/哪条回答"（上一轮 UX 研究 §3 建议未落实）。
- 评论树中"回复 2"在未加载任何回复时就显示 `chevron.up`（收起）图标（`:492-505`），语义与状态不一致。
- 建议：浮层加 `.regularMaterial` 或加深底色 + 更明显阴影；标题标注作者；回复按钮初始状态改为"查看 N 条回复"。

### P2-3　对比度与选中态【代码计算确认】
- 链接色 `#6d9280`：浅色 3.31:1、纸色 3.05:1、深色纸卡 4.22:1（<4.5:1，`ReaderView.swift:1153`）；
- 12px 计数 `opacity .58` 浅色 3.71:1；目录选中态 `accent.opacity(0.13)` 仅 **1.19:1**（`:735`），几乎无法辨认选中项；
- 建议：链接色分主题加深、计数 opacity ≥ .68、选中态提至 0.18–0.22 并加**非颜色**提示（左侧 2pt 强调条）。

### P2-4　可访问性收尾【代码确认】
- 评论浮层无 `.accessibilityAddTraits(.isModal)`、背景未 `accessibilityHidden`；scrim 是可点击 `Color`；评论图片 `AnimatedCommentImage` 无标签；WebView 连续回答只有顶部一个 `h1`，回答之间无 heading/aria。
- Reduce Motion：仅 `LoadingSkeleton` 处理，评论浮层滑入动画未降级；无 `colorSchemeContrast`/Bold Text 适配。
- 建议按上述逐项补齐。

### P2-5　键盘与指针【代码确认】
- 无 `.keyboardShortcut`（⌘1/⌘2 切栏目、Esc 关评论）、无 `.hoverEffect`、无 `focusable`、无菜单栏命令。iPad + 妙控键盘/指针用户缺失生产力体验。

### P2-6　iPhone 方向声明与产品决策【实测确认：横屏可用】
- 工程只声明了 iPad 方向键（`project.yml:17`），构建产物 Info.plist 无 iPhone 方向键；**实测 iPhone 横屏是可用且会重排的**（顶部栏横跨 80–788pt、左右安全区各 59pt），因此这不是"仅竖屏"的功能缺失，而是**声明缺失 + 横屏体验未设计**。
- 建议：产品拍板——① 明确仅竖屏：显式声明 `UIInterfaceOrientationPortrait` 并写入 PLAN/README；② 支持横屏：补方向键并按横屏重新设计顶部栏/底部浮条（横屏高度约 390pt，浮条占比过大）。

### P2-7　状态恢复【代码确认】
- `WizeApp` 仅 `WindowGroup { ReaderView() }`（`WizeApp.swift:18`），无 `@SceneStorage`/`scenePhase`；冷启动回到 feed 顶部，阅读位置与当前问题/回答丢失。

### P2-8　其他打磨项
- 左栏固定 36%（`ReaderView.swift:108`）：13" 横屏左栏 492pt 偏宽、11" 竖屏约 300pt 偏窄；评论浮层已有 `min(max(W*0.36,320),420)` 上下限，可复用到左栏。
- 宽栏 toolbar 标题宽度按外层 geometry 硬算（`:113-116`），hot 栏 + 排序 Picker 同时出现时有挤压风险。
- 阅读页 iPhone 工具栏标题 `lineLimit(1)`（`:432`），长标题必然截断（可接受但可改两行/`minimumScaleFactor`）。
- iPad 13" 横屏正文 `max-width: 800px`，18px 下约 44 汉字/行，偏长（设计取舍）。
- 缺共享 scheme（新机器/CI 的 `xcodebuild -scheme` 可能失败）、缺 `PrivacyInfo.xcprivacy`（UserDefaults required-reason）。
- iPadOS 27 状态栏在应用内显示应用名（系统行为，非缺陷；截图可见 "09:41 Thu Nov 5 无知"）。

---

## 3. 已确认良好的适配点

1. **iPad 双栏 + 纸页 + 覆盖式评论**完全按 PLAN 落地（Pro 13 横/竖屏实测）；评论不改变正文宽度。
2. **进入栏目自动打开首条内容**（宽布局）；左栏二级回答列表带"返回列表 + 热度/时间排序"；热榜工具栏有排序 Picker。
3. **安全区**：顶部自绘栏用 `.safeAreaInset`；评论 sheet 用系统 detent + drag indicator；宽栏评论浮层不贴 Home indicator；iPhone 横屏左右安全区自动避让（实测 59pt）。
4. **WebView 内容适配**：`max-width` 行宽、`img/video max-width:100%`、表格横向滚动、懒加载、`light-dark()` 主题、换字号/行距时用 `caretRangeFromPoint` 保持视口位置、前序回答插入保位、动作归属按 35% 阅读焦点——后三项都有单元测试覆盖并 PASS。
5. **iPhone 单列导航 + 左右滑切栏目 + 评论底部 sheet** 结构成立；横屏 feed 布局正常（无"半屏 bug"，此前疑点为 ItemRow 固有宽度 + 透明行背景造成的视觉误判）。
6. **深色/浅色/纸色** 在 iPad 与 iPhone 均正确反色，悬浮玻璃在两种外观下可用。
7. **工程一致性**：`project.yml` 与 `pbxproj` 同步（xcodegen 重生成 diff=0）；target 覆盖 iPhone+iPad；无 `UIRequiresFullScreen`（可多任务）；无调试入口泄漏到 Release；5/5 单元测试通过。

---

## 4. 未验证 / 残留风险（本轮环境限制）

1. **XCUITest 在本环境不可用**：DSH 沙箱禁 `openpty` → `IDEPseudoTerminalDomain Code 7`，模拟器 testmanagerd 连接失败（`DTServiceHubClient failed to bless service hub`）。因此所有交互场景改用「启动环境变量注入场景 + `simctl` 截图 + `devicectl orientation` 旋转」的管线；**注入的 review 构建只在仓库源码上增加了 `reviewAutoScene()`（导航注入），布局代码逐字未改**。
2. **未实测设备**：iPad Pro 11 (M5)、iPad Air 11、iPad (A16) 因宿主过载未跑；按代码推断均为双栏（834/820/820pt ≥ 760）。
3. **未验证场景**：Split View 50/50（约 683pt → 按代码单列）、Slide Over、Stage Manager 任意宽度连续缩放；真机 iPad（设备锁屏）；iPhone 真机阅读页/评论/设置（自动锁屏窗口仅 1–2 分钟）；真实知乎长文/长标题换行/长图/GIF；VoiceOver 与动态字体下的实际朗读/截断。
4. **本次观察到但需人工点按复核**：iPhone 17e 竖屏阅读页出现稳定空白 WebView（见 §2 P1-5），审查管线复现、等待 20 秒不变；需用真实点按路径复核，详见该条。
5. **审阅环境噪声**：另一条外部工作流（`/Users/hugh/Work/supen`）占用 iPhone 17 Pro 模拟器并跑 XCUITest，导致 Host load 峰值 500–830、`simctl launch/screenshot` 与 `devicectl` 频繁挂起；部分早期截图为主屏无效图，已隔离为 `_INVALID-*`。

---

## 5. 建议修复顺序

| 顺序 | 内容 | 工作量 | 验收 |
|---|---|---|---|
| 1 | Dynamic Type 全链路（列表语义字体 + WebView 系统字号缩放 + 浮条计数） | 0.5–1 天 | AX XXXL 下层级不倒置、正文放大 |
| 2 | iPad 宽栏右侧浮条横向避让（WebView `padding-right:72px`，**不做底部不透明安全区**） | 0.5 天 | mini 横屏/Pro13 竖屏浮条不压正文；阅读页底部无新增色带 |
| 3 | 跨阈值旋转保持阅读位置（位置持久化或共享 WebView 身份） | 1–2 天 | 横→竖→横仍在原回答原段落 |
| 4 | iPad 首帧不闪单列（`availableWidth==0` 视为未知 / `onGeometryChange`） | 0.5 天 | 冷启动录屏无双栏闪烁 |
| 5 | 产品决策：iPad mini 竖屏阈值 + iPhone 横屏/仅竖屏 | 决策 + 0.5 天 | PLAN/README 与实现一致 |
| 6 | 空白 WebView 兜底与复现（`data-wize-pending` 超时清除） | 0.5 天 | 冷启动 20 次无空白 |
| 7 | 可访问性包（对比度、选中态非颜色提示、浮层 modal、评论图标签、Reduce Motion） | 1 天 | VoiceOver 走查通过 |
| 8 | 状态恢复（`@SceneStorage`）、键盘快捷键/指针 hover、共享 scheme、隐私清单 | 1–2 天 | 冷启动恢复阅读位置 |

---

## 附录 A：设备与工具矩阵

| 设备 | 系统 | 方式 | 覆盖 |
|---|---|---|---|
| iPhone 17 | iOS 27.0 模拟器 | simctl + devicectl 旋转 | 竖屏/横屏 feed |
| iPhone 17e | iOS 27.0 模拟器 | 同上 + 场景注入 | 竖/横 feed、reader、reader-scroll、comments、settings、answerlist、深色 |
| iPhone 16 Pro | iOS 27.2 真机 | devicectl install/launch/screenshot | 竖屏 feed（深色）；其余被自动锁屏阻塞 |
| iPad Pro 13 (M5) | iOS 27.0 模拟器 | 同上 + 场景注入 | 横/竖 × feed、reader、comments、settings、account、hot、answerlist、浅/深色、AX XXXL |
| iPad mini (A17 Pro) | iOS 27.0 模拟器 | 同上 | 竖屏单栏、横屏双栏、横→竖→横旋转 |
| iPad Pro 11 (M5) / Air 11 / A16 | iOS 27.0 模拟器 | 未跑（宿主过载） | 代码推断 |

- 构建：`xcodebuild -project Wize.xcodeproj -scheme Wize -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator'`；fixture 启动 `SIMCTL_CHILD_WIZE_VISUAL_FIXTURE=1`。
- 旋转：`xcrun devicectl device orientation set --device <UDID> portrait|landscapeLeft`（模拟器实测有效；真机无效）。
- 外观/字号：`xcrun simctl ui <UDID> appearance dark|light`、`xcrun simctl ui <UDID> content_size accessibility-extra-extra-extra-large`。
- 真机构建（供复核）：`DEVELOPMENT_TEAM=37CALUWQ3M CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'`，产物 `.build/dd-device/Build/Products/Debug-iphoneos/Wize.app`。

## 附录 B：证据文件

- 截图（本报告引用）：`docs/media/adaptation-review/`（13 张）。
- 完整设备截图与逐项数据：`.build/review/iphone/`、`.build/review/ipad/`、`.build/review/real/`（被 `.gitignore` 忽略，仅本机留存）。
- 子报告：`.build/review/ipad/ipad-report.md`、`.build/review/iphone/iphone-report.md`、`.build/review/real/real-device-report.md`。
- 静态审计与单元测试：`.build/review/code/audit.md`（371 行，28 条结论，P1×5/P2×20/已验证良好×17，含对比度计算与 file:line）、`.build/review/code/tests.md`（5/5 PASS）。
- 可复用测试脚本：`.build/review/iphone/run-matrix.sh`、`.build/review/iphone/lead-capture.sh`。
