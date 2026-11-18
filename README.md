# X-ASR 听写

macOS 菜单栏听写工具。按一次麦克风键开始说话，识别文字直接出现在当前输入框，再按一次结束。安装包内置中英双语 X-ASR 流式模型和推理引擎，音频在本机处理，可离线使用。

## 下载与安装

**适用设备：Apple 芯片 Mac，macOS 26.0 或更高版本。**

1. 打开 [最新 Release](https://github.com/lijiaming0914-cmd/x-asr-dictation/releases/latest)，下载文件名以 `.dmg` 结尾的安装包。
2. 打开 DMG，将 **X-ASR 听写** 拖到 **Applications（应用程序）**，然后从「应用程序」打开它。模型随 App 一起安装。
3. 首次启动按提示在「系统设置 → 隐私与安全性 → 辅助功能」允许 **X-ASR 听写**。首次开麦时，允许麦克风访问。
4. 点进输入框，按 MacBook 内置键盘上带麦克风图标的键开始说话，再按一次停止。外接键盘可使用 **Control + Option + D**，也可以从菜单栏「听写」启动。

本版使用本地临时签名，未经过 Apple Developer ID 公证。如果 macOS 提示无法验证开发者，请核对下载来源和 Release 附带的 SHA-256，再到「系统设置 → 隐私与安全性」找到该 App 的「仍要打开」。受管理的 Mac 可能需要管理员许可。

## 听写时

- 使用系统默认麦克风。可输入时出现小圆点，收到声音时变绿。
- 点击另一个输入框或切换 App 后，听写会尝试跟随焦点。普通按钮等不可输入位置会暂停收音并隐藏圆点。
- 原生输入框和富文本编辑器使用不同的写入方式。焦点变化或编辑器拒绝写入时，可以查看菜单栏状态。
- 麦克风专用键映射针对 Apple 内置键盘。已在运行其他占用同一快捷键的听写工具时，请先退出其中一个。系统授权与 App 签名相关，升级后如果自动输入失效，请在隐私设置中重新授权。

## 从源码构建

维护者在 Apple 芯片 Mac 上安装带有 macOS 26 SDK 的 Xcode 命令行工具后执行：

```sh
./scripts/build.sh
```

脚本从官方上游下载固定版本的 Node、sherpa-onnx 和 X-ASR 模型包，逐个核对 SHA-256，再生成 `build/` 下的 DMG 和校验文件。构建缓存默认位于 `.cache/`，可用 `XASR_BUILD_CACHE` 指定其他目录。安装 Release 的用户无需执行上述命令。

```sh
# 在已下载 DMG 及同名 .sha256 文件的目录核对安装包
shasum -a 256 -c X-ASR-Dictation-1.0.0-macOS-arm64.dmg.sha256
```

## 模型与第三方组件

使用 X-ASR 480 ms INT8 中英流式模型、sherpa-onnx 1.13.3 和 Node.js 22.23.2。第三方许可证、运行库声明和模型来源随安装包保存在 `Contents/Resources/Notices` 和 `Contents/Resources/model/README.md` 中。[X-ASR 原项目](https://github.com/Gilgamesh-J/X-ASR) · [sherpa-onnx 模型发布页](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models) · [Node.js](https://nodejs.org/)
