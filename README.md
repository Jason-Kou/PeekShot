# PeekShot

macOS 菜单栏截图工具：区域 / 窗口 / 全屏截图、悬浮预览、标注编辑器、贴图、历史。
原生 Swift + AppKit + ScreenCaptureKit，要求 macOS 14 及以上。

## 构建与运行

需要 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```bash
scripts/build.sh          # 生成 dist/PeekShot.app
open dist/PeekShot.app
```

PeekShot 只在菜单栏显示图标。图标被刘海或其他图标挡住时，再执行一次 `open dist/PeekShot.app`（或再次双击应用）会弹出设置窗口，里面可以打开历史和退出。

首次截图时 macOS 会要求“录屏与系统录音”权限：在 系统设置 → 隐私与安全性 里打开 PeekShot，然后重启 PeekShot。

也可以用 URL 触发，适合脚本和启动器：`open peekshot://capture-area`。
可用的动作：`capture-area`、`capture-window`、`capture-fullscreen`、`capture-previous-area`、`capture-timer`、`history`、`settings`。

## 签名

`scripts/build.sh` 用本机自签名证书 “PeekShot Local Signing” 签名，这样重新构建后录屏授权仍然有效。
每台机器先运行一次 `scripts/setup-signing.sh` 创建证书；之后第一次构建会弹出钥匙串授权框，输入登录密码并选“始终允许”。
没有这张证书时脚本会退回 ad-hoc 签名，此时每次重新构建后 macOS 都会要求重新授权。

磁盘上只保留 `dist/` 里这一份正式版，Debug 构建（同时是测试宿主）使用单独的应用标识 `app.peekshot.PeekShot.debug`。
否则 macOS 在“退出并重新打开”时可能按应用标识启动另一份没有授权的副本，表现为授权后仍然提示没有权限。

## 测试

```bash
xcodegen generate
xcodebuild -project PeekShot.xcodeproj -scheme PeekShot -derivedDataPath build test
```

交互测试会在屏幕上短暂弹出选区遮罩和编辑器窗口。
设置 `TEST_RUNNER_PEEKSHOT_SNAPSHOT_DIR=<目录>` 可以把各界面渲染成 PNG 供肉眼检查。

## 默认快捷键

| 功能 | 快捷键 |
| --- | --- |
| 截取区域 | ⌃⌥A |
| 截取窗口 | ⌃⌥W |
| 截取全屏 | ⌃⌥F |
| 截取上次区域 | ⌃⌥R |
| 延时截图 | ⌃⌥T |
| 截图历史 | ⌃⌥H |

选区中：空格切换区域 / 窗口模式，拖动时按住空格移动选区，⇧ 正方形，⌥ 从中心拉伸，Esc 或右键取消。

编辑器中：V 选择、C 裁剪、A 箭头、L 直线、R 矩形、O 椭圆、P 画笔、H 高亮、T 文字、N 序号、X 马赛克、B 模糊、S 聚焦；
⌘Z / ⇧⌘Z 撤销重做，⌘C 复制并关闭，⌘S 保存，⇧⌘S 另存为，⌘0 适应窗口。

## 代码结构

- `Sources/PeekShot/App`：入口、菜单栏、偏好设置、全局快捷键
- `Sources/PeekShot/Capture`：ScreenCaptureKit 截屏、选区遮罩、截图流程
- `Sources/PeekShot/Output`：编码与保存、剪贴板、历史存储
- `Sources/PeekShot/QuickAccess`：截图后的悬浮预览卡片
- `Sources/PeekShot/Editor`：标注模型、渲染、画布、编辑器窗口
- `Sources/PeekShot/Pin`、`History`、`Settings`：贴图、历史窗口、设置窗口
- `scripts/make_icon.swift`：生成应用图标
