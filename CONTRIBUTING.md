# 参与贡献

欢迎提交问题、改进建议和代码。较大的行为或架构变更建议先通过 GitHub Issue 讨论，说明使用场景与预期结果。

1. Fork 仓库并创建分支，保持每次改动聚焦。
2. 按 [README](README.md) 配置 Xcode 和运行环境；涉及布局时可使用调试样本或模拟器验证。
3. 修改 `project.yml` 后运行 `xcodegen generate`，并一并提交生成的工程变更。
4. 运行下列适用的检查并构建应用；在 Pull Request 中说明改动、验证方式及未覆盖的设备或场景。
5. 不要提交 Cookie、账号凭据、设备标识或包含个人信息的日志与截图。

提交的代码按项目的 [MIT 许可](LICENSE) 发布。第三方图片、字体或其他素材请附上明确的来源和允许再分发的许可；不要假设代码许可自动覆盖素材。

## 开发与验证

工程由 `project.yml` 生成；修改工程配置后，安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 并运行 `xcodegen generate`。调试构建可在 Xcode scheme 的运行环境中设置 `WIZE_VISUAL_FIXTURE=1`，使用无需知乎账号的阅读样本检查布局；Release 构建不包含该入口。

在 macOS 上使用 Xcode 工具链运行以下检查。如果默认选择的是命令行工具，先设置 `DEVELOPER_DIR` 指向 Xcode 的 `Contents/Developer`。

```sh
swift Tests/ReaderInsertionTest.swift Wize/ReaderView.swift
swift Tests/ReaderStyleTest.swift Wize/ReaderView.swift
swift Tests/ReaderFocusTest.swift Wize/ReaderView.swift
swiftc Wize/ZhihuSource.swift Tests/CommentFragmentsTest.swift -o /tmp/wize-comment-test && /tmp/wize-comment-test
swiftc Wize/ZhihuSource.swift Wize/ReaderModel.swift Tests/ReaderModelTest.swift -o /tmp/wize-model-test && /tmp/wize-model-test
```

项目使用 Beads 跟踪部分工作。运行 `bd ready` 查看可开始的工作；数据保存在本地 Dolt 数据库，跨机器同步需要单独执行 Beads 同步命令。公开讨论和贡献可以直接通过 GitHub Issue 与 Pull Request 进行，不要求贡献者安装 Beads。
