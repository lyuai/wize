# 图标来源

应用图标中的「無」取自项目维护者提供的透明图片 `Wang-Xizhi-wu-source.png`，以该图片的 alpha 通道保留字形，仅调整颜色、位置和背景。参考网页将该字标注为王羲之《临钟繇千字文》：https://sfzd.jiguzuo.com/shufa/zi-574564219ibuhjjzu.html 。图片提供者已确认有权在本仓库中再分发；具体来源版本及供第三方复用的许可条款尚未核实。项目的 MIT 代码许可不自动适用于该原图及其派生图标，其他使用者应自行确认使用授权。

图标提供明亮与深色两套（iOS 18+ 会随系统外观/主屏幕图标设置自动切换）：

- 明亮：`swift Design/render-wang-icon.swift Design/Wang-Xizhi-wu-source.png Wize/Assets.xcassets/AppIcon.appiconset/AppIcon-wang-xizhi-light.png "#F5F0E6" "#283939"`
- 深色：`swift Design/render-wang-icon.swift Design/Wang-Xizhi-wu-source.png Wize/Assets.xcassets/AppIcon.appiconset/AppIcon-wang-xizhi-dark.png "#283939" "#F7F3E8"`

脚本第 3、4 个参数分别是背景色与字形颜色；两套图保存在 `Wize/Assets.xcassets/AppIcon.appiconset/`，在 `Contents.json` 中通过 `appearances` 标记深色变体。

## 第二版「無」字形（当前图标）

当前 App 图标使用维护者提供的另一张拓片风格「無」字（`Design/Wize-wu-glyph-source.png`）。原图分辨率为 447×447、带有拓片底噪与边框，已做如下处理并保存为 1024×1024 的透明字形源：

- 裁掉边框、按 2%~98% 分位拉伸亮度；
- 中值滤波去除 JPEG 噪点，阈值提取墨迹；
- 形态学开/闭运算去掉零散斑点、填补笔画内小孔；
- 羽化边缘后放大并居中，作为图标字形 alpha 通道。

两套图标（明亮/深色）由该 alpha 源生成，脚本化流程见 `Design/render-wu-glyph.py`。原拓片的出处尚未核实；如果后续找到更高清的原始拓片，可以替换 `Design/Wize-wu-glyph-source.png` 重新生成图标。
