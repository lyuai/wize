# 图标来源

应用图标中的「無」取自项目维护者提供的透明图片 `Wang-Xizhi-wu-source.png`，以该图片的 alpha 通道保留字形，仅调整颜色、位置和背景。参考网页将该字标注为王羲之《临钟繇千字文》：https://sfzd.jiguzuo.com/shufa/zi-574564219ibuhjjzu.html 。图片提供者已确认有权在本仓库中再分发；具体来源版本及供第三方复用的许可条款尚未核实。项目的 MIT 代码许可不自动适用于该原图及其派生图标，其他使用者应自行确认使用授权。

图标提供明亮与深色两套（iOS 18+ 会随系统外观/主屏幕图标设置自动切换）：

- 明亮：`swift Design/render-wang-icon.swift Design/Wang-Xizhi-wu-source.png Wize/Assets.xcassets/AppIcon.appiconset/AppIcon-wang-xizhi-light.png "#F5F0E6" "#283939"`
- 深色：`swift Design/render-wang-icon.swift Design/Wang-Xizhi-wu-source.png Wize/Assets.xcassets/AppIcon.appiconset/AppIcon-wang-xizhi-dark.png "#283939" "#F7F3E8"`

脚本第 3、4 个参数分别是背景色与字形颜色；两套图保存在 `Wize/Assets.xcassets/AppIcon.appiconset/`，在 `Contents.json` 中通过 `appearances` 标记深色变体。

## 当前图标使用的「無」字形

当前 App 图标使用维护者提供的单字扫描图 `Design/wu-glyph-scan.jpg`（黑墨浅纸）。为保证笔画完整、放大后不断裂，处理流程是：

1. 中值滤波去噪；
2. 用 **Otsu 自动阈值**做二值化（不按固定分位数猜阈值，避免把纸纹当墨迹或把笔画打碎）；
3. 3px 闭运算填补笔画内部的小孔/反光点，再做一次小膨胀恢复笔画边缘；
4. 连通域过滤只去掉纸面孤立噪点（面积阈值很低，保留「灬」等独立点画）；
5. 高斯羽化生成抗锯齿 alpha，按高度 80% 居中放入 1024×1024 透明画布。

对应脚本：

```sh
# 1) 单字扫描图 -> 1024 透明字形源
python3 Design/extract-glyph-source.py Design/wu-glyph-scan.jpg Design/Wize-wu-glyph-source.png
# 2) 字形源 -> 明亮/深色 App 图标 + 关于页 logo
python3 Design/render-wu-glyph.py
```

原扫描图的出处尚未核实；如果找到更高清的原始拓片，替换 `Design/wu-glyph-scan.jpg` 后重跑上面两条命令即可。
