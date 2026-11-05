# 无知 / Wize

一个安静的 iPhone 和 iPad 阅读器。目前支持知乎推荐、热榜、回答与评论，让阅读回到内容本身。

<img src="docs/media/iphone-demo.gif" alt="iPhone 演示：浏览内容、阅读连续回答和上拉展开评论 sheet" width="280">

[观看演示视频](docs/media/iphone-demo.mp4) · 演示使用应用内置样本

## 开始使用

需要 macOS、包含 iOS 27 SDK 的 Xcode，以及运行 iOS 27 或 iPadOS 27 的设备或模拟器。用 Xcode 打开 `Wize.xcodeproj`，选择 Wize scheme 并运行。安装到真机前，请在 Signing & Capabilities 中配置自己的开发团队和 Bundle Identifier。

在应用内使用知乎网页登录；登录状态保存在设备的 WebKit 中。应用内「问题反馈与建议」可直接提交文字、截图与可选邮箱，也可选择附带当前账号与设备信息（表单内可关闭）；「关于」页显示版本号与发布时间。知乎接口可能要求登录或安全验证，也可能发生变化；部分图片、动图和富文本仍在完善中。

## 许可与来源

Wize 的代码采用 [MIT License](LICENSE)。当前书法图标的来源和再使用限制见 [图标来源](Design/README.md)。阅读设置中可按需下载的开源字体（[霞鹜新致宋](https://github.com/lxgw/LxgwNeoZhiSong)、[思源宋体](https://github.com/adobe-fonts/source-han-serif)、[霞鹜文楷](https://github.com/lxgw/LxgwWenKai-Lite)、[霞鹜新晰黑](https://github.com/lxgw/LxgwNeoXiHei)、[思源黑体](https://github.com/adobe-fonts/source-han-sans)）均采用 [SIL Open Font License 1.1](https://openfontlicense.org/) 许可，仓库不预置字体文件，由应用在用户选择时按需下载至本地。知乎接口的路径和参数参考了 [BAIGUANGMEI/zhihu-cli](https://github.com/BAIGUANGMEI/zhihu-cli)（Apache-2.0）；本项目未包含该项目代码。知乎与其商标属于相应权利人，本项目与知乎无关联或授权关系。

欢迎通过 [贡献指南](CONTRIBUTING.md) 参与；开发与测试方法也在其中。请遵守 [行为准则](CODE_OF_CONDUCT.md)，安全问题请按 [安全说明](SECURITY.md) 私下报告。
