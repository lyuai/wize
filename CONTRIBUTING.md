# 参与贡献

欢迎提交问题、改进建议和代码。较大的行为或架构变更建议先通过 GitHub Issue 讨论，说明使用场景与预期结果。

1. Fork 仓库并创建分支，保持每次改动聚焦。
2. 按 [README](README.md) 配置 Xcode 和运行环境；涉及布局时可使用调试样本或模拟器验证。
3. 修改 `project.yml` 后运行 `xcodegen generate`，并一并提交生成的工程变更。
4. 运行下列适用的检查并构建应用；在 Pull Request 中说明改动、验证方式及未覆盖的设备或场景。
5. 不要提交 Cookie、账号凭据、设备标识或包含个人信息的日志与截图。

提交的代码按项目的 [MIT 许可](LICENSE) 发布。第三方图片、字体或其他素材请附上明确的来源和允许再分发的许可；不要假设代码许可自动覆盖素材。

## 版本号与发布

版本信息维护在 `project.yml`：`MARKETING_VERSION`（对外版本号）、`CURRENT_PROJECT_VERSION`（构建号）和 `WIZE_RELEASE_DATE`（发布时间，显示在应用内「关于」页）。每次发布前运行：

```sh
Scripts/bump-version.sh 0.2.1
```

脚本会递增构建号、把发布日期改为当天，并重新生成工程。请把 `project.yml`、`Wize.xcodeproj` 的改动一起提交；`Wize/Info.plist` 会从这些设置取值，一般无需改动。

## 应用内反馈通道（本地配置）

主菜单里的「问题反馈与建议」会把内容（含可选图片附件与可选邮箱）直接提交到仓库的 GitHub Issues。构建时需要一个对仓库有 **Issues** 与 **Contents** 写权限的 token，放在本机的 `Config/Local.xcconfig`（已被 `.gitignore` 忽略，**请勿提交**）：

```sh
# Config/Local.xcconfig
WIZE_GITHUB_TOKEN = github_pat_...
```

`Config/Build.xcconfig` 会可选地 include 这个文件；未配置 token 时应用仍可正常构建使用，只是反馈提交会给出可恢复的失败提示。不要把包含 token 的构建产物分发给他人。

## 开发与验证

工程由 `project.yml` 生成；修改工程配置后，安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 并运行 `xcodegen generate`。调试构建可在 Xcode scheme 的运行环境中设置 `WIZE_VISUAL_FIXTURE=1`，使用无需知乎账号的阅读样本检查布局；Release 构建不包含该入口。

在 macOS 上使用 Xcode 工具链运行以下检查。如果默认选择的是命令行工具，先设置 `DEVELOPER_DIR` 指向 Xcode 的 `Contents/Developer`。

```sh
swift Tests/ReaderInsertionTest.swift Wize/ReaderView.swift
swift Tests/ReaderStyleTest.swift Wize/ReaderView.swift
swift Tests/ReaderFocusTest.swift Wize/ReaderView.swift
swiftc Wize/ZhihuSource.swift Tests/CommentFragmentsTest.swift -o /tmp/wize-comment-test && /tmp/wize-comment-test
swiftc Wize/ZhihuSource.swift Tests/ReaderLinkTest.swift -o /tmp/wize-link-test && /tmp/wize-link-test Wize/ReaderView.swift
swiftc Wize/ZhihuSource.swift Tests/VideoHTMLTest.swift -o /tmp/wize-video-test && /tmp/wize-video-test
swiftc Wize/ZhihuSource.swift Wize/ReaderModel.swift Tests/ReaderModelTest.swift -o /tmp/wize-model-test && /tmp/wize-model-test
```

项目使用 Beads 跟踪部分工作。运行 `bd ready` 查看可开始的工作；数据保存在本地 Dolt 数据库，跨机器同步需要单独执行 Beads 同步命令。公开讨论和贡献可以直接通过 GitHub Issue 与 Pull Request 进行，不要求贡献者安装 Beads。
