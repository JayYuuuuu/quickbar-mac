#!/usr/bin/env python3
"""把 src/ 里的样式和各画板内容拼成可用的 .dc.html。

六块画板共用一份样式，所以内容和样式是分开写的——不然改一个颜色要动六个文件。
在 design/ 目录下跑：python3 src/build.py
"""

import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent

# 画板名、深色开关的默认值、画板尺寸
SPECS = [
    ("Main", False, 720, 480),
    ("Panel", True, 720, 480),
    ("Settings", False, 760, 560),
    ("Trigger", True, 760, 600),
    ("MenuBar", False, 560, 420),
    ("Onboarding", True, 560, 540),
]

TEMPLATE = """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
%s
%s
</x-dc>
<script data-dc-script data-props='%s'>
class Component extends DCLogic {
  renderVals() {
    return { themeClass: this.props.dark ? 'qb dark' : 'qb' };
  }
}
</script>
</body>
</html>
"""


def main() -> None:
    style = (HERE / "_style.txt").read_text().rstrip()
    for name, dark, width, height in SPECS:
        body = (HERE / f"{name}.body.html").read_text().rstrip()
        props = json.dumps(
            {
                "dark": {"editor": "boolean", "default": dark, "section": "外观"},
                "$preview": {"width": width, "height": height},
            },
            ensure_ascii=False,
        )
        # data-props 是单引号属性，值里出现单引号或 & 会把属性截断
        assert "'" not in props and "&" not in props, f"{name} 的 props 需要转义"
        (OUT / f"{name}.dc.html").write_text(TEMPLATE % (style, body, props))
        print(f"生成 {name}.dc.html  {width}x{height}  {'深色' if dark else '浅色'}")


if __name__ == "__main__":
    main()
