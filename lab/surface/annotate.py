#!/usr/bin/env python3
"""标注器：给截图叠几何参考层（标尺+窗体线框+caret 虚线框）。

防暗示纪律（lab/surface/vision-probe.md）：只画几何参考——绝不画期望
位置框/箭头/高亮，不标注哪个窗是被测对象。输出供 vision 子智能体按
标尺读数，返回客观数值偏差。

用法：annotate.py <输入.png> <meta.json> <输出.png>
meta.json：{"windows":[{"x":..,"y":..,"w":..,"h":..,"label":"R1"}],
            "caret":{"x":..,"y":..,"w":..,"h":..}}
（坐标为截图像素系；label 可省略，自动编号）
"""

import json
import sys

from PIL import Image, ImageDraw, ImageFont

RULER_STEP = 100
FONT = ImageFont.load_default()


def main():
    src, meta_path, dst = sys.argv[1:4]
    im = Image.open(src).convert("RGB")
    meta = json.load(open(meta_path))
    ov = Image.new("RGBA", im.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)

    # 窗体线框（白，含标签）
    for i, w in enumerate(meta.get("windows", [])):
        label = w.get("label", f"R{i+1}")
        x0, y0 = w["x"], w["y"]
        x1, y1 = x0 + w["w"], y0 + w["h"]
        for k in range(2):
            d.rectangle([x0 - k, y0 - k, x1 + k, y1 + k],
                        outline=(255, 255, 255, 220))
        d.text((x0 + 6, y0 + 6), label, fill=(255, 255, 255, 255), font=FONT)

    # caret 虚线框（黄）
    c = meta.get("caret")
    if c:
        x0, y0 = c["x"], c["y"]
        x1, y1 = x0 + c["w"], y0 + c["h"]
        dash = 8
        x = x0
        while x < x1:
            d.line([x, y0, min(x + dash, x1), y0], fill=(255, 220, 0, 255), width=2)
            d.line([x, y1, min(x + dash, x1), y1], fill=(255, 220, 0, 255), width=2)
            x += dash * 2
        y = y0
        while y < y1:
            d.line([x0, y, x0, min(y + dash, y1)], fill=(255, 220, 0, 255), width=2)
            d.line([x1, y, x1, min(y + dash, y1)], fill=(255, 220, 0, 255), width=2)
            y += dash * 2
        d.text((x1 + 6, y0 - 4), "caret", fill=(255, 220, 0, 255), font=FONT)

    # 标尺：顶部/左侧每 100px 刻度+数字（灰白半透明底带防淹没）
    d.rectangle([0, 0, im.size[0], 22], fill=(0, 0, 0, 120))
    d.rectangle([0, 0, 26, im.size[1]], fill=(0, 0, 0, 120))
    for x in range(0, im.size[0] + 1, RULER_STEP):
        d.line([x, 0, x, 18], fill=(255, 255, 255, 200), width=1)
        d.text((x + 3, 3), str(x), fill=(255, 255, 255, 230), font=FONT)
    for y in range(0, im.size[1] + 1, RULER_STEP):
        d.line([0, y, 18, y], fill=(255, 255, 255, 200), width=1)
        d.text((2, y + 3), str(y), fill=(255, 255, 255, 230), font=FONT)

    Image.alpha_composite(im.convert("RGBA"), ov).convert("RGB").save(dst)
    print(dst)


if __name__ == "__main__":
    main()
