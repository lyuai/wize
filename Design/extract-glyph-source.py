#!/usr/bin/env python3
"""把单字拓片/扫描图转成 1024×1024 透明字形源，供图标生成使用。

用法：
    python3 Design/extract-glyph-source.py <输入图片> [输出 png]

处理原则：按亮度做平滑的 alpha（而不是硬阈值），避免放大后笔画断裂或出现锯齿；
再用连通域去掉零散纸面噪点，但保留「灬」这类独立笔画。
"""
from collections import deque
from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageFilter

CANVAS = 1024
GLYPH_HEIGHT_RATIO = 0.80
MIN_COMPONENT_AREA = 24


def keep_glyph_components(mask):
    """保留面积足够大的连通域（包含独立点画），去掉纸面小噪点。"""
    h, w = mask.shape
    visited = np.zeros_like(mask, dtype=bool)
    keep = np.zeros_like(mask, dtype=bool)
    for start_y in range(h):
        for start_x in range(w):
            if not mask[start_y, start_x] or visited[start_y, start_x]:
                continue
            queue = deque([(start_y, start_x)])
            visited[start_y, start_x] = True
            component = []
            while queue:
                y, x = queue.popleft()
                component.append((y, x))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dy == 0 and dx == 0:
                            continue
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not visited[ny, nx]:
                            visited[ny, nx] = True
                            queue.append((ny, nx))
            if len(component) >= MIN_COMPONENT_AREA:
                for y, x in component:
                    keep[y, x] = True
    return keep


def main():
    source_path = Path(sys.argv[1] if len(sys.argv) > 1 else "Design/wu-glyph-scan.jpg")
    output_path = Path(sys.argv[2] if len(sys.argv) > 2 else "Design/Wize-wu-glyph-source.png")

    gray = Image.open(source_path).convert("L")
    gray = gray.filter(ImageFilter.MedianFilter(3))
    pixels = np.asarray(gray, dtype=np.float32)

    # 用 Otsu 自动阈值区分墨迹与纸张；墨迹通常只占版面的 10% 左右，
    # 不能按分位数猜阈值，否则会把纸纹当成墨迹。
    hist, _ = np.histogram(pixels, bins=256, range=(0, 256))
    total = pixels.size
    sum_all = float((np.arange(256) * hist).sum())
    weight_background = 0
    sum_background = 0.0
    best_variance = 0.0
    threshold = 128.0
    for level in range(256):
        weight_background += int(hist[level])
        if weight_background == 0:
            continue
        weight_foreground = total - weight_background
        if weight_foreground == 0:
            break
        sum_background += level * int(hist[level])
        mean_background = sum_background / weight_background
        mean_foreground = (sum_all - sum_background) / weight_foreground
        variance = weight_background * weight_foreground * (mean_background - mean_foreground) ** 2
        if variance > best_variance:
            best_variance = variance
            threshold = level + 0.5
    mask_image = Image.fromarray(((pixels < threshold) * 255).astype(np.uint8), "L")
    # 闭运算：先膨胀 5px 再腐蚀 5px，填孔但保持外轮廓
    mask_image = mask_image.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
    # 去掉纸面孤立小点（保留「灬」等独立笔画，面积阈值很低）
    kept = keep_glyph_components(np.asarray(mask_image) > 128)
    if not kept.any():
        raise SystemExit("未找到笔画")
    outline = Image.fromarray((kept * 255).astype(np.uint8), "L").filter(ImageFilter.MaxFilter(3))
    # 用平滑后的二值轮廓生成抗锯齿 alpha
    alpha_image = outline.filter(ImageFilter.GaussianBlur(1.2))
    alpha = np.asarray(alpha_image, dtype=np.float32) / 255.0

    ys, xs = np.where(alpha > 0.05)
    if len(ys) == 0:
        raise SystemExit("未找到笔画")
    glyph = alpha[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    gh, gw = glyph.shape

    target_h = int(CANVAS * GLYPH_HEIGHT_RATIO)
    target_w = int(target_h * gw / gh)
    if target_w > CANVAS * 0.88:
        target_w = int(CANVAS * 0.88)
        target_h = int(target_w * gh / gw)

    alpha_image = Image.fromarray((glyph * 255).astype(np.uint8), "L").resize((target_w, target_h), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 0))
    canvas.paste(Image.new("RGBA", (target_w, target_h), (255, 255, 255, 255)),
                 ((CANVAS - target_w) // 2, (CANVAS - target_h) // 2), alpha_image)
    canvas.save(output_path)
    print(f"wrote {output_path} ({target_w}×{target_h} on {CANVAS} canvas)")


if __name__ == "__main__":
    main()
