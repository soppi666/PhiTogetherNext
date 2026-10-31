# PhiTogetherNext

> 事先声明：此软件与 PhiTogether 没有任何关系，此项目纯属个人兴趣驱动的 AI 学习实践，
> 所有代码与架构设计由个人使用 AI 工具编写。本模拟器仅用于本地离线打歌，
> 请勿用于任何商业用途或传播。**!!!不建议下载!!!**

Godot 4.7 写的 PhiTogether风格播放器。

## 下载

[Releases](https://github.com/soppi666/PhiTogetherNext/releases) 里每版三个文件（`26W44` = 2026 年第 44 周）：

- `PhiTogetherNext_26W44_win64.zip` — Windows，解压即用（exe + pck + `chart_ext…dll`）
- `PhiTogetherNext_26W44_win64.exe` — 单文件（pck 已内嵌），仍需要把上面 zip 里那个 `chart_ext…dll` 放在旁边
- `PhiTogetherNext_26W44_arm64.apk` — Android，仅 arm64-v8a

## 已知问题

- glsl 转 gdshader 后和原 glsl 表现不一致
- 部分 HUD 显示异常
- 渲染视频容易出错，导出文件夹也是错的
- UI 显示异常，UI 很难看
- 很多功能没做
- 性能要求高

## 依赖

| 用途 | 需要 |
|---|---|
| 运行 / 导出 | Godot 4.7 stable |
| 编译原生扩展 | Python 3.8+、SCons |
| Windows 编译 | MSVC（VS 2022 Build Tools） |
| Android 编译 | Android SDK + NDK 26.1.10909125 |

## godot-cpp

不随仓库分发（`gdextension/godot-cpp/` 已忽略）。clone 后切到这个提交：

```bash
git clone https://github.com/godotengine/godot-cpp.git gdextension/godot-cpp
git -C gdextension/godot-cpp checkout 507ed9d840c01a3c5b2a39af8bb4000bfac30bf5
```

该提交带 `gdextension/extension_api-4-7.json`。

## 编译扩展 chart_ext

进 `gdextension/`，产物路径必须写出来（只写 `target=` 不编本项目源码）。

```bash
cd gdextension

# Windows
scons -j8 platform=windows target=template_release api_version=4.7 \
  bin/chart_ext.windows.template_release.x86_64.dll

# Android arm64
export ANDROID_HOME=/path/to/Android/Sdk      # Windows: $LOCALAPPDATA/Android/Sdk
scons -j8 platform=android target=template_release arch=arm64 api_version=4.7 \
  ndk_version=26.1.10909125 \
  bin/libchart_ext.android.template_release.arm64.so
```

产物在 `gdextension/bin/`（已忽略）。`chart_ext.gdextension` 里就是这两个文件名，改名要同步。

## 运行

```bash
godot --headless --path . --import   # 首次
godot --path .
```

## 导出

预设：`Android`、`Windows Desktop`。keystore 信息不在仓库里（预设里留空），导出后自己签：

```bash
bt="$LOCALAPPDATA/Android/Sdk/build-tools/35.0.0"
"$bt/zipalign.exe" -p -f 4 app.apk app-aligned.apk
"$bt/apksigner.bat" sign --ks your.keystore --ks-pass pass:YOUR_PASS \
  --ks-key-alias your_alias app-aligned.apk
```

Android 只打 arm64-v8a。包里没 `lib/arm64-v8a/libchart_ext…so` 会灰屏。

## 目录

```
scripts/          GDScript：game / chart_stage / song_select / settings_page / result_page …
gdextension/src/  原生扩展：谱面解析与渲染、噪域、视频编码、android_rate（高刷投票）
shaders/          噪域与 UI 的 gdshader
assets/           图标、背景、打击音（.f32 = 48k 立体声旁车）
fonts/            运行时字体（woff2）
```

## 许可

- 代码：**GPL-3.0**（根目录 `LICENSE`）。原因见下：噪域 shader 是 GPL-3.0 作品的衍生，
  所以整仓按同一协议分发。
- 完整的第三方清单与许可全文：[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
- 噪域 shader（`shaders/block_area*.gdshader`）移植自 [Phira-Pro](https://github.com/Phira-Pro/Phira-Pro)（GPL-3.0）。
- 故障特效（`shaders/glitch_chroma.gdshader`）来自 [fluXis](https://github.com/InventiveRhythm/fluXis)（MIT）。
- UI shader（`blur_dir` / `dither` / `round_clip` / `stripes`）改自 godotshaders.com 的 CC0 实现。
- 字体寒蝉全圆体 ChillRound 为 SIL OFL 1.1，© 2023 ChillType，全文见 `fonts/LICENSE-ChillRound.txt`。

## 感谢
- 感谢 [PhiZonePlayer](https://github.com/PhiZone/player) 的渲染代码
- 感谢 [PhiTogether](https://github.com/Team-PhiTogether/PhiTogether) 的界面与交互参考
- 感谢 [Phira-Pro](https://github.com/Phira-Pro/Phira-Pro) 的噪域 shader
- 感谢 [fluXis](https://github.com/InventiveRhythm/fluXis) 的故障特效
- 感谢 [godotshaders.com](https://godotshaders.com/) 的 CC0 实现
- 感谢 [寒蝉全圆体 ChillRound](https://github.com/Warren2060/ChillRound) 的字体

谱面格式（RPE / PE / PhiZone）解析都在本仓库 `gdextension` 里自己实现，不含上游源码或转译产物。