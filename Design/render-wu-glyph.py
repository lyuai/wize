#!/usr/bin/env python3
"""从透明字形源生成明亮/深色 App 图标（以及关于页 logo）。

用法：
    python3 Design/render-wu-glyph.py

图标源：Design/Wize-wu-glyph-source.png（1024×1024 透明 alpha）。
输出：Wize/Assets.xcassets/AppIcon.appiconset/AppIcon-wang-xizhi-{light,dark}.png
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Design/Wize-wu-glyph-source.png"
LIGHT = ROOT / "Wize/Assets.xcassets/AppIcon.appiconset/AppIcon-wang-xizhi-light.png"
DARK = ROOT / "Wize/Assets.xcassets/AppIcon.appiconset/AppIcon-wang-xizhi-dark.png"
ABOUT = ROOT / "Wize/Assets.xcassets/AboutLogo.imageset/AboutLogo.png"

LIGHT_BG = (245, 240, 230)
LIGHT_INK = (40, 57, 57)
DARK_BG = (40, 57, 57)
DARK_INK = (247, 243, 232)


def compose(background, ink, destination):
    source = Image.open(SOURCE).convert("RGBA")
    alpha = source.getchannel("A")
    canvas = Image.new("RGBA", (1024, 1024), background + (255,))
    ink_layer = Image.new("RGBA", (1024, 1024), ink + (255,))
    canvas.paste(ink_layer, (0, 0), alpha)
    canvas.convert("RGB").save(destination)
    print("wrote", destination.relative_to(ROOT))


if __name__ == "__main__":
    compose(LIGHT_BG, LIGHT_INK, LIGHT)
    compose(DARK_BG, DARK_INK, DARK)
    Image.open(LIGHT).save(ABOUT)
    print("wrote", ABOUT.relative_to(ROOT))
