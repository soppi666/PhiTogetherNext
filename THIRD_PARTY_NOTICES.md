# 第三方声明

本仓库的代码按 **GPL-3.0** 发布（见根目录 `LICENSE`），因为下面第一项的噪域 shader 是
GPL-3.0 作品的衍生。各项素材各按上游许可，列举如下。

## 1. Phira-Pro — GPL-3.0

- 上游：<https://github.com/Phira-Pro/Phira-Pro>
- 涉及文件：`shaders/block_area.gdshader`、`shaders/block_area_disabled.gdshader`
- 说明：这两个文件是对其 `prpr/src/core/block_shader_full.frag` 的**逐式移植**
  （GLSL → Godot gdshader，含常量表与 `blockPalette()` 等辅助函数），其中部分代码行与上游
  逐字相同。按 GPL-3.0，本仓库整体以 GPL-3.0 分发，完整源码即本仓库。
- 与本项目其余部分的关系：噪域的几何、掩码、RPE 标记协议解析均为本仓库自行实现，
  但表现层 shader 属上述衍生，故整仓统一按 GPL-3.0。

## 2. fluXis — MIT

- 上游：<https://github.com/InventiveRhythm/fluXis>
- 涉及文件：`shaders/glitch_chroma.gdshader`（移植自 `sh_Glitch.fs` 与 `sh_ChromaticAberration.fs`）
- 许可全文：

```
MIT License

Copyright (c) 2024 Flustix

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 3. 寒蝉全圆体 ChillRound — SIL OFL 1.1

- 上游：<https://github.com/Warren2060/ChillRound>
- 版权：© 2023 ChillType，保留字体名 `ChillRoundF` / `ChillRoundM`
- 涉及文件：`fonts/*.woff2`（由上游 ttf 转格式，未改动字形）、`fonts_src/*.ttf`
- 许可全文：见 [`fonts/LICENSE-ChillRound.txt`](fonts/LICENSE-ChillRound.txt)

## 4. godotshaders.com — CC0

- 上游：<https://godotshaders.com/>
- 涉及文件：`shaders/blur_dir.gdshader`、`dither.gdshader`、`round_clip.gdshader`、
  `stripes.gdshader`（在其 CC0 实现基础上修改）
- CC0 不要求署名，此处仅致谢。

## 5. 其他

- 界面与交互设计参考 <https://github.com/Team-PhiTogether/PhiTogether>（AGPL-3.0）。
  仅作为视觉/交互参照，未复制其代码。
- 谱面格式（RPE / PE / PhiZone）的解析在本仓库 `gdextension` 内自行实现。