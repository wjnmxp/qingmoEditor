# 清墨 Qingmo

清墨是一个为 Apple Silicon Mac 编写的原生 Markdown 编辑器。直接在文档中写作，标题、列表、表格和图片会在编辑时排版。光标进入段落时显示 Markdown 标记，移开后收起。文档保存为普通 Markdown 文件。

当前版本为 `0.1.0`。

## 功能

- 每份文档打开在独立窗口，支持标题大纲、查找替换和自动保存。
- 直接编辑 Markdown 表格单元格，支持增删行列、列对齐和宽表横向滚动。
- 预览本地和网络图片，支持从文件插入、拖入图片和粘贴截图。导入图片存入文稿旁的 `.assets` 目录。
- 从「文件 → 导出为 PDF」生成包含正文、表格和图片的 A4 文档。
- 保留原文编码和换行格式，支持 UTF-8、UTF-8 BOM 和带 BOM 的 UTF-16。
- 可跟随系统使用深色外观，也可调整字号和隐藏大纲。

常用快捷键和操作说明见[使用指南](使用指南.md)。

## 构建与安装

需要 Apple Silicon Mac、macOS 13 或更新版本、Xcode Command Line Tools 和 Python 3。

**交给 Agent 自动构建打包**：把下面这行复制给你的 Agent，Codex、Claude Code 和 WorkBuddy 都可以。

```text
请帮我在本机的 Apple Silicon Mac 上构建并打包清墨。克隆 https://github.com/wjnmxp/qingmoEditor.git（已克隆就使用现有目录），阅读 README，检查 macOS、Python 3 和 Xcode Command Line Tools，然后在仓库根目录运行 `python3 build.py`。如果构建提示 macOS 26.4 SDK 缺少头文件，按 README 运行 `python3 tools/prepare_sdk.py` 后重试。完成后验证 `build/.staging/清墨.app` 的签名，并告诉我构建结果和 App 的绝对路径。
```

```sh
git clone https://github.com/wjnmxp/qingmoEditor.git
cd qingmoEditor
python3 build.py
python3 tools/install.py
```

构建生成 `build/.staging/清墨.app`，并进行本机临时签名。安装脚本将应用安装到 `~/Applications/清墨.app`。更新前请退出正在运行的清墨。

如果本机使用的 macOS 26.4 Command Line Tools SDK 缺少构建所需头文件，可先运行 `python3 tools/prepare_sdk.py`。该脚本从固定版本获取并校验缺少的文件，将它们存放在项目的 `build/` 下。

如需将清墨设为 Markdown 文件的默认打开应用，安装后运行 `python3 tools/default_markdown.py --apply`。使用 `--inspect` 可查看当前关联。

## 开发与测试

`Sources/` 是 Swift 和 AppKit 应用源码，`tools/` 包含图标生成、构建环境和安装工具，`Tests/` 是回归测试。

```sh
python3 test.py
```

测试覆盖 Markdown 解析、表格、图片、文件编码和多窗口行为。网络图片相关测试使用本地 HTTP 服务。
