# 无知 / Wize

一个为 iPadOS 27 和 iOS 27 设计的个人阅读器。首个内容来源是知乎，聚焦推荐、热榜、回答和评论。产品目标与交互约定见 [PLAN.md](PLAN.md)，项目工作使用 Beads 跟踪。

## 运行

需要 macOS、包含 iOS 27 SDK 的 Xcode，以及运行 iOS 27 或 iPadOS 27 的设备或模拟器。用 Xcode 打开 `Wize.xcodeproj`，选择 Wize scheme。运行到真机前，在 Signing & Capabilities 中配置自己的 Apple 开发团队和 Bundle Identifier。工程由 `project.yml` 生成；修改工程配置后，安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 并运行 `xcodegen generate`。

调试构建可在 Xcode scheme 的运行环境中设置 `WIZE_VISUAL_FIXTURE=1`，使用不依赖知乎账号的阅读样本检查布局。该入口不包含在 Release 构建中。

## 验证

在 macOS 上使用 Xcode 工具链运行以下检查（如果默认选择的是命令行工具，可先设置 `DEVELOPER_DIR` 指向 Xcode 的 `Contents/Developer`）：

阅读流位置保持的 WebKit 回归检查可在 macOS 上运行：`swift Tests/ReaderInsertionTest.swift Wize/ReaderView.swift`。它验证前插、后追加和前方内容高度变化时的阅读位置。

阅读设置调整时的位置保持检查：`swift Tests/ReaderStyleTest.swift Wize/ReaderView.swift`。

回答边界的操作对象检查：`swift Tests/ReaderFocusTest.swift Wize/ReaderView.swift`。

评论图文顺序检查：`swiftc Wize/ZhihuSource.swift Tests/CommentFragmentsTest.swift -o /tmp/wize-comment-test && /tmp/wize-comment-test`。

阅读状态与排序检查：`swiftc Wize/ZhihuSource.swift Wize/ReaderModel.swift Tests/ReaderModelTest.swift -o /tmp/wize-model-test && /tmp/wize-model-test`。

应用内通过知乎网页登录，Cookie 使用系统 WebKit 存储，不需要输入到本项目的配置文件。知乎接口可能要求登录、安全验证或改变响应格式。已在 iPhone 和 iPad 真机验证登录、推荐、热榜及部分回答与评论；动图等媒体类型仍需进一步验证，不保证所有内容类型或富文本均可用。

## 项目任务

运行 `bd ready` 查看可开始的工作，`bd list` 查看全部事项。Beads 使用本地 Dolt 数据库，跨机器同步需要单独执行 Beads 的同步命令；代码推送不自动同步任务数据库。

## 许可与来源

Wize 的代码采用 [MIT License](LICENSE)。当前书法图标的来源和再使用限制见 [图标来源](Design/README.md)。知乎接口的路径和参数参考了 [BAIGUANGMEI/zhihu-cli](https://github.com/BAIGUANGMEI/zhihu-cli)（Apache-2.0）；本项目未包含该项目代码。知乎与其商标属于相应权利人，本项目与知乎无关联或授权关系。

欢迎通过 [贡献指南](CONTRIBUTING.md) 参与；请遵守 [行为准则](CODE_OF_CONDUCT.md)。安全问题请按 [安全说明](SECURITY.md) 私下报告。
