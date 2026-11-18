# Marksmith

一款原生 macOS Markdown 编辑器，Swift / SwiftUI + AppKit 编写，**零第三方 SwiftPM 依赖**，可完全离线构建。

名字取自 wordsmith（文字工匠）：Markdown 的锻造台。若想改名，只需改 `AppMetadata.swift`、`Package.swift`、`Info.plist`、`scripts/build-app.sh` 四处。

---

## 二、功能对照

| 功能 | Marksmith 实现 |
| --- | --- |
| 界面 | `NavigationSplitView` 文件侧栏 + 工具栏视图切换 + 编辑/预览分栏 + 底部状态栏，与原版一致 |
| 视图模式 | 分栏 / 仅编辑 / 仅预览（`⌘1` `⌘2` `⌘3`），工具栏分段控件 |
| 编辑器 | `NSTextView` 子类 + 自定义 `NSTextStorage`，正则语法高亮（浅/深色主题）、行号、自动换行、撤销、查找替换 |
| 预览 | `WKWebView` 加载本地模板，300ms 级防抖，滚动位置保持，明暗主题切换 |
| 数学 / 图表 / 代码高亮 | 内置 KaTeX、Mermaid、highlight.js，全部本地资源，离线可用；`$...$` 有价格保护（`$5 / $10` 不被误判为公式）；工具栏提供公式 / 流程图模板与语法速查 |
| 图片 | 粘贴 / 拖拽图片自动落盘到 `assets/`，相对路径；预览与导出统一转为 data URI |
| 文件夹侧栏 | FSEvents 递归监听、过滤框、手动刷新、展开状态保持；点击文件通过 `openDocument` 打开独立文档（不会覆盖当前文档） |
| 导出 PDF | 离屏 `WKWebView` 渲染（等待 Mermaid 完成后打印），WYSIWYG |
| 导出 HTML | **单文件自包含**：CSS、JS、KaTeX 字体全部内联为 data URI，双击即可离线打开 |
| 导出 Word | 直接生成原生 OOXML：真实标题样式、原生表格、任务列表、行内图片；纯 Swift ZIP 写入器，不依赖 `zip` 命令 |
| Vim 模式 | 常用子集（见下），设置中开关，状态栏显示模式 |
| 设置 | 字号 / 字体 / 自动换行 / 行号 / Vim / 预览主题 / 默认视图 / 防抖延迟 |
| 顶部工具栏 | **侧栏、三段视图切换、导出菜单全部保留**；格式按钮组（标题/字号、加粗、斜体、删除线、链接、表格）、**公式 ∑ / 流程图 两个向导按钮**、更多格式、导入 |
| 格式菜单 | 原有格式命令 + 「插入公式」/「插入图表」子菜单（各含模板与语法速查） |
| 导入 HTML | 标题、粗斜体、删除线、列表、任务列表、表格（含对齐）、链接、图片、代码块、引用；`script/style/nav` 与危险 URL 清洗；自动识别 UTF-8 / GB18030 / Big5 |
| 导入 Word | `.docx` OOXML：标题样式（兼容「标题 1」/「Heading 1」）、粗斜体、表格、列表、超链接、内嵌图片落 `assets/` |
| 导入 Excel | `.xlsx`：每个工作表转为一节 GFM 表格，共享字符串 / 内联字符串 / 公式缓存值 / 日期格式 |
| 导入 PDF | PDFKit 逐页提取纯文本；无文本层时用 Vision OCR（简中 + 英文）；**固定提示不还原排版** |
| 导入文本 | `.txt/.text/.md/.markdown/.log/.json/.yaml/.xml/.rst/.tex` 等：自动识别 UTF-8 / UTF-16(BOM) / UTF-32(BOM) / GB18030 / Big5，统一 CRLF、去 BOM；纯文本换行转硬换行并转义语法，Markdown 文件按原文导入；`.csv/.tsv` 转 GFM 表格；无扩展名文本自动嗅探 |

### 键盘快捷键

| 快捷键 | 动作 |
| --- | --- |
| `⌘N` `⌘O` `⌘S` | 新建 / 打开 / 保存（DocumentGroup 提供） |
| `⌘⇧O` | 打开文件夹 |
| `⌘⇧I` | 导入文件并转换为 Markdown |
| `⌘\` | 显示/隐藏侧栏 |
| `⌘1` `⌘2` `⌘3` | 分栏 / 仅编辑 / 仅预览 |
| `⌘F` / `⌘⌥F` | 查找 / 查找并替换 |
| `⌘B` `⌘I` `⌘\`` `⌘K` | 加粗 / 斜体 / 行内代码 / 链接 |
| `⌘⇧C` | 代码块 |
| `⌘,` | 设置 |

### Vim 子集

`h j k l`、`w b e`、`0 ^ $`、`gg G`、`i a I A o O`、`x`、`dd`、`yy`、`p`、`u`、`v / V`、`d/y + 动作`、计数前缀、`J`。`Esc` 回到普通模式。
**未实现**：宏、寄存器命名、文本对象、`.` 完整重复、Ex 命令。这是刻意保留的扩展点。

### 顶部格式工具栏

顶部工具栏**完整保留原有的侧栏、分栏/仅编辑/仅预览切换、导出菜单**，并在中间插入：

- **格式按钮组**：`Aa` 下拉（一/二/三级标题、正文、字号 ±、打开显示设置）、加粗、斜体、删除线、链接、表格、`⋯` 下拉（行内代码、代码块、引用、分割线、三种列表、插入图片）。
- **公式（∑）与流程图 两个向导按钮**（1.2.0 新增）：各是一个下拉菜单，列出可直接插入的模板 + 「语法速查…」弹窗。点模板后会自动选中示例内容，直接打字即可替换；若先选中一段文字再点公式模板，选中的文字会直接套进 `$…$`。「格式」菜单里也有同样的子菜单。
  - 公式模板：行内 `$…$`、独立 `$$…$$`、分数与上下标、求和、多行对齐方程组；速查含 `\frac` `\sum` `\begin{aligned}` 等。
  - 图表模板：`flowchart TD`（含判断分支）、`flowchart LR`、`sequenceDiagram`、`gantt`；速查含节点形状、连线、`subgraph` 与其它图表类型。
  - 插入的是标准 Markdown（`$$…$$` 与 mermaid 围栏代码块），预览、HTML 与 PDF 由本地 KaTeX / Mermaid 渲染；导出 Word 时保留为源文本。
- **导入按钮**：把 文本 / Markdown、HTML、Word、Excel、PDF 转成 Markdown。

按钮与「格式」菜单、快捷键共用同一条 `InsertCommand` 链，插入逻辑只有一份（含中文占位符与光标定位）；点击后焦点自动交回编辑区。Markdown 是语义标记，没有字体语法，所以 `Aa` 里的字号项改的是编辑器显示设置，不会往文档里写样式。为了让新增的两个向导按钮与原有导出按钮不被系统折叠进溢出菜单，窗口最小宽度由 700pt 调整为 880pt（实测 820pt 时「导入 / 导出」会被折叠，860pt 起 8 个工具栏项全部可见）。

### 导入文件

顶部「导入」按钮、`⌘⇧I` 或「文件」菜单 → 选择文件 → 后台转换 → 选择去向：

| 去向 | 行为 |
| --- | --- |
| 新建文档 | 开一个新窗口，内容直接填入 |
| 覆盖当前文档 | 若当前文档有未保存修改，先二次确认 |
| 追加到光标处 | 在当前光标位置插入，保持原文 |

解析失败时原文档保持不变并弹出错误；PDF 的降级说明、表格被裁剪、合并单元格退化等信息会出现在导入完成提示里。所有导入结果都只写 `document.text`，编辑器、预览、状态栏由现有 `onChange` 链路自动同步。

**文本文件（1.2.0）**：`.txt` / `.md` / `.text` / `.log` / `.csv` / `.tsv` / `.json` / `.yaml` / `.xml` / `.rst` / `.tex` 等，以及无扩展名但确实是可读文本的文件。读取时自动识别 UTF-8（含 BOM）、UTF-16/UTF-32（含 BOM、无 BOM 启发式）、GB18030/GBK 与 Big5，统一 CRLF/CR 换行并去掉 BOM；识别为非 UTF-8 时会在完成提示里说明，出现乱码可先把源文件另存为 UTF-8。

| 内容 | 导入结果 |
| --- | --- |
| `.md` 等 Markdown 文件、明显含标题/围栏代码/表格的文本 | 原文导入，只统一编码与换行 |
| 普通 `.txt` | 每个换行转成 Markdown 硬换行（行尾两个空格），并转义 `*`、`#`、`[` 等字符，避免在预览里被误当成语法 |
| `.csv` / `.tsv` | 转成 GFM 表格（首行表头，支持引号字段、字段内逗号与换行，最多 500 行数据） |

> 想逐字保留普通文本（包含原来的单个换行）时，直接用「文件 → 打开」打开 `.txt` 即可 —— Marksmith 本身就能把纯文本当文档打开；「导入」的价值在于归一化编码、追加到当前文档或转换成 Markdown 语义。

---

## 三、构建与运行

```bash
cd /Volumes/machack2/download/swift_program/Marksmith

swift build                       # 调试构建
swift test                        # 69 项单元测试（含 PDF/DOCX/XLSX/HTML/文本导入、导入同步回归、导出与真实预览渲染）
swift run Marksmith                # 命令行直接运行（开发期）

./scripts/build-app.sh             # 构建本机架构 .app
./scripts/build-app.sh --universal --dmg   # 通用二进制 + DMG（推荐）
```

产物：

- `build/Marksmith.app`
- `build/Marksmith.dmg`（需加 `--dmg`）

脚本通过 `swift build --show-bin-path` 询问 SwiftPM 真实产物路径，**不硬编码架构目录**；`--universal` 会同时编译 x86_64 与 arm64 并合并。默认做 ad-hoc 签名，本机直接双击即可运行，无需 Apple Developer 账号。若要正式分发，需自行签名 + 公证。

最低系统版本：macOS 14（用到的 `ContentUnavailableView` / 新版 `onChange` 需要 14）。

---

## 四、代码结构与扩展点

后续加功能时，建议按层修改，彼此不耦合：

```
Marksmith/
├── App/            MarksmithApp.swift（入口）、AppCommands.swift（菜单 + FocusedValue）
├── Model/          MarksmithDocument、AppSettings、ViewMode、DocumentStats
├── Core/           ★ 纯 Swift，无 UI 依赖，可单测
│   ├── MarkdownAST.swift          AST 定义
│   ├── MarkdownParser.swift       块级解析
│   ├── InlineParser.swift         行内解析
│   ├── HTMLRenderer.swift         AST → HTML 片段
│   ├── HTMLDocumentBuilder.swift  完整独立 HTML（内联 CSS/JS/字体）
│   ├── ExportService.swift        导出协议 + 注册表 + PDF 渲染 + 保存面板
│   ├── DOCXExporter.swift         AST → 原生 OOXML
│   ├── ZIPWriter.swift            纯 Swift ZIP 写入（stored + CRC32）
│   ├── OOXMLArchive.swift        纯 Swift ZIP 读取（stored + raw deflate / 系统 zlib）
│   ├── MarkdownSerializer.swift   ★ AST → Markdown 文本（所有导入器共用）
│   ├── ImportService.swift       导入协议 + 注册表 + 打开面板 + 目标选择
│   ├── ImportSupport.swift       轻量 XML DOM、实体/资产辅助
│   ├── Importers/                HTML / DOCX / XLSX / PDF / Text 五个转换器
│   └── RenderingSupport.swift     转义、URL 安全策略、图片 data URI
├── Views/          SwiftUI 界面 / AppKit 编辑器桥接 / 侧栏 / 预览
│   ├── FormatToolbar.swift       顶部格式按钮组（复用 InsertCommand）
│   └── InsertTemplates.swift     ★ 公式 / 流程图模板、语法速查（数据层）
└── Resources/      preview.html、preview-runtime.js、明暗 CSS、vendor（第三方 JS）
```

**关键设计：一次解析，多端渲染。** `MarkdownParser.parse()` 产出 `MarkdownModel`（AST），HTML 预览、HTML 导出、PDF、DOCX 都消费同一棵 AST，因此四种输出内容严格一致。导入侧与之对称：结构化转换器（HTML / DOCX / XLSX / PDF / CSV·TSV）都只**构造 AST**，再由 `MarkdownSerializer` 统一生成 Markdown 文本，避免每种格式各写一套转义规则；`.md` 等本来就是 Markdown 的文件则按原文导入。生成的文本写进 `document.text` 后，现有的 `onChange` 链路会自动同步编辑器与预览，编辑器层无需改动。

公式与流程图按钮同样只发一条 `InsertCommand.template`，模板数据集中在 `InsertTemplates.swift`，真正的插入、占位符选中与焦点回归只在 `MarkdownEditorTextView.apply(_:)` 里实现一次；`InlineParser` 把 `$…$` / `$$…$$` 当作原样文本保留（不把 LaTeX 的反斜杠、花括号、`_`、`*` 重新解释成 Markdown），交给预览里的 KaTeX / Mermaid 渲染。

常见扩展方式：

1. **新增导出格式**：写一个遵循 `DocumentExporter` 的类型，在 `ExportRegistry.bootstrap()` 里 `register(...)`。导出菜单由注册表自动生成。
2. **新增导入格式**：写一个遵循 `DocumentImporter` 的类型（`importDocument` 返回 `ImportResult`），在 `ImportRegistry.bootstrap()` 里 `register(...)`；打开面板与「文件」菜单自动支持新扩展名。转换器内部构造 AST，不要直接拼 Markdown 字符串。
3. **新增 Markdown 语法**：在 `MarkdownAST.swift` 加 case → `MarkdownParser` / `InlineParser` 解析 → `HTMLRenderer` 与 `DOCXExporter` 各加一个渲染分支 → `MarkdownSerializer` 补序列化分支 → 补测试。
4. **新增工具栏按钮 / 模板**：`FormatToolbar.swift` 里加一个发 `InsertCommand` 的按钮；如果命令是全新的，在 `AppCommands.swift` 的枚举里加 case 并在 `MarkdownEditorTextView.apply` 里实现一次，菜单/快捷键/工具栏三处共用。公式 / 流程图这类「带示例的插入」只需在 `InsertTemplates.swift` 的数组里再加一个 `InsertTemplate`，工具栏与「格式」菜单会自动列出。
5. **新增设置项**：`AppSettings` 加一个 `@AppStorage`，`SettingsView` 加一个控件。
6. **新增菜单命令**：`AppCommands.swift` 加 Button，需要操作编辑器时通过 `InsertAction` / `FindAction` 走 `EditorBridge`。
7. **新增 Vim 动作**：只改 `VimEngine.swift` 的 `handleNormal` / `motionRange`。
8. **换预览外观**：改 `preview-light.css` / `preview-dark.css`，无需改 Swift 代码。

---

## 五、已知限制

- Markdown 解析为自研 GFM 子集（标题、列表、表格、任务列表、代码块、引用、链接、图片、删除线、脚注式实体、YAML front matter），不是完整 CommonMark；极端嵌套与复杂引用式链接可能与 cmark-gfm 有差异。
- 原始 HTML 标签一律转义显示（安全策略），不会渲染成真实 HTML。
- Vim 为子集，见上。
- PDF 依赖 WebKit 打印，页面尺寸/分页由 CSS `@media print` 控制；如需精确排版可改 `HTMLDocumentBuilder` 中的打印样式。
- 应用为 ad-hoc 签名，跨机器分发前需重新签名并公证，否则 Gatekeeper 可能拦截。
- 图片写入 `assets/` 需要文档已保存（未保存文档使用 data URI 内联）。
- **导入保真度**：HTML 无法还原内联样式与 `<div>` 布局；DOCX 无法还原合并单元格（退化为重复文本）、文本框、脚注、目录与精确缩进，多级列表会扁平化为一级；XLSX 只保留单元格值（公式取缓存结果、图表与条件格式丢弃）；PDF **只有纯文字**，标题层级/表格/粗体/双栏阅读顺序全部不还原，扫描件依赖系统 OCR，识别可能有误。
- 旧版 `.doc` / `.xls`、加密或受保护文档不支持，选中时会提示另存为 `.docx` / `.xlsx` / HTML。
- **Markdown 没有「字体」语法**：字号、字体、颜色属于显示设置，工具栏的 `Aa` 菜单改的是编辑器字号与「设置」面板，不会写进文档；内联 `<span style>` 会被安全策略转义。
- **公式与图表只在预览 / HTML / PDF 中渲染**：KaTeX 与 Mermaid 都是本地 JS；导出 Word 时公式保留为 LaTeX 源文本、图表保留为 mermaid 代码块，不会变成原生公式对象或图片。
- **文本编码判别是启发式的**：GBK 与 Big5 的字节区间重叠，极少数 Big5 文件可能被判为 GB18030（默认倾向大陆常用编码）。出现乱码时把源文件另存为 UTF-8 再导入即可。
- **纯文本导入会重写换行与转义字符**：这是为了让 `.txt` 在 Markdown 预览里保持原样排版；想要逐字保留请用「文件 → 打开」。

---

## 六、许可与致谢

- 本项目 Swift 代码为新写实现；界面与功能参照 MIT 许可的 [nateober/markdown-editor](https://github.com/nateober/markdown-editor)。
- `Resources/vendor/` 下的第三方资源及许可见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

---

## 七、修订记录

### 1.0.1（2026-11-18）— 修复「预览正常、编辑器空白」

打开已有的 `.md`（如较大的 `DESIGN.md`）时，右侧预览与状态栏统计都正确，但左侧编辑区可能保持纯背景色。原因是文本同步与重绘只依赖 SwiftUI 的 `NSViewRepresentable.updateNSView`：当 `ReferenceFileDocument` 异步载入、或文本视图的字形缓存失效而没触发绘制时，这条链不会补齐，编辑器就停留在空白状态；同时自定义 `NSTextStorage` 在 `processEditing` 中直接改 `backing` 属性后没有通知布局管理器重绘。

修复内容：

- `EditorBridge.syncText()` 由 `ContentView.onChange(of: document.text)` 驱动（与预览同一信号），独立把文本推给 `NSTextView`；即使字符串一致也会强制一次重绘。视图出现时再补一次延迟同步。
- `MarkdownEditorTextView.applyProgrammaticText()` 统一处理外部文本：走 `NSTextStorage` 编辑管线 → 失效显示范围 → 强制 `layoutManager.glyphRange(for:)` 完成布局 → `setNeedsDisplay`。`updateNSView` 也改为调用它。
- `HighlightingTextStorage`：`setText` 不再因 `isHighlighting` 静默丢弃整篇文本；批量替换时抑制重复高亮；`processEditing` / `highlightAll` 追加 `invalidateDisplay(forCharacterRange:)`。
- `isRichText` 改为 `true`，避免 AppKit 在程序化替换时抹掉字体/颜色属性；`paste(_:)` 改为始终插入纯文本，保证 Markdown 编辑器语义不变。
- `configure` 显式设置 `textColor`，自动换行模式下容器宽度下限 240pt、非换行模式用有限宽度 1,000,000pt 代替 `CGFloat.greatestFiniteMagnitude`，避免宽度为 0 或溢出导致无字形。
- 新增 `Tests/MarksmithTests/EditorViewTests.swift`：校验文本同步后字符串一致、字形范围完整、字体/颜色属性存在，并对离屏渲染做像素统计，断言编辑器不是空白。

验证：`swift test` 23 项全部通过。

### 1.0.2（2026-11-18）— 修复「编辑器里中文、全角标点、emoji 不显示」

预览区中文正常，编辑区却把 `LANScanner（macOS / Swift）设计文档` 显示成 `LANScannermacOS / Swift`，`| 项目 | 内容 |` 显示成 `| | |`——中文不是被画成方块，而是**完全不占宽度地消失**。

根因：`HighlightingTextStorage` 在 `processEditing` 里直接把语法高亮属性写进 backing store，没有发布 `.editedAttributes` 通知。`NSLayoutManager` 因此对这一段保留了旧的字形运行状态，跳过 CJK 字体替换；等宽字体（SF Mono / Menlo）本身没有汉字字形，这些字符就生成了零宽度字形。文本本身是完整的（预览与字数统计都正常）。

修复内容：

- 新增 `Views/Editor/EditorFonts.swift`：对基准字体确实无法绘制的字符区间（CJK 汉字、假名、韩文、全角标点如 `（）：，`、`U+FF00–FF60` 全角字符、补充平面 emoji）显式指定含字形的字体（PingFang SC → Hiragino Sans GB → Heiti SC → Arial Unicode MS；emoji 用 Apple Color Emoji）。粗体区间自动取对应粗体变体，颜色与其他属性保持不变；若用户选择的字体本身已覆盖汉字，则不覆盖用户选择。
- `SyntaxHighlighter.apply` 末尾调用上述替换，使渲染不再依赖文本系统不确定的自动回退。
- `HighlightingTextStorage.processEditing` 在高亮写入后补发 `edited([.editedAttributes], range:)`，并让嵌套的 `processEditing` 也调用 `super.processEditing()`，确保布局管理器收到通知。
- 新增 `Tests/MarksmithTests/CJKRenderTests.swift` 共 7 项：程序化载入、增量编辑、通过 `NSTextView` 输入中文、粗体标题中文、用户自选 CJK 字体不被覆盖、全角标点与 emoji、离屏渲染中文像素统计。断言字形非空、包围盒宽度 > 1、有效字体确实含该字形。

扩展提示：以后要支持其他文字（西里尔、阿拉伯等），只需在 `EditorFonts.makeFamilies` 里再加一个 `Family`，高亮器与存储层无需改动。

验证：`swift test` 30 项全部通过。

### 1.1.0（2026-11-18）— 顶部格式工具栏 + 四种文件导入

**新增**

- `Views/FormatToolbar.swift`：顶部格式按钮组，复用既有 `InsertCommand`（含中文占位符、选区包裹、光标定位与焦点回归）。原有侧栏、三段视图切换、导出菜单三项**完全保留**。补了 `strikethrough`、`image`、`heading(0)`（清除标题）三个命令；「格式」菜单同步补齐，所有快捷键不变。
- `Core/ImportService.swift`：与导出侧对称的 `DocumentImporter` / `ImportRegistry` / `ImportResult`，打开面板自动按注册表收集扩展名；导入目标三选一（新建 / 覆盖 / 追加到光标处），覆盖前对未保存修改二次确认，失败保留原文。
- `Core/MarkdownSerializer.swift`：AST → Markdown 的唯一出口。四个导入器只构造 `MarkdownModel`，不各自拼字符串，因此转义、表格、围栏代码规则集中一处，导入结果与手写 Markdown 走同一套解析/渲染语义。
- `Core/OOXMLArchive.swift`：只读 ZIP（stored + raw deflate，系统 zlib），支持中央目录、data descriptor、ZIP64 明确拒绝与 64 MB 解压上限。
- `Core/Importers/`：
  - `HTMLImporter.swift` — 容错 tokenizer（隐式闭合标签、无引号属性、GB18030/Big5）、语义映射到 AST、`script/style/nav` 与危险 URL 清洗、本地图片落 `assets/`。
  - `DOCXImporter.swift` — `document.xml` / `styles.xml` / `numbering.xml` / rels / media，兼容「标题 1」「Heading 1」样式名，合并单元格与多级列表保守降级并输出警告。
  - `XLSXImporter.swift` — 每工作表一节 GFM 表格，共享字符串、内联字符串、公式缓存值、日期序列转换。
  - `PDFImporter.swift` — PDFKit 逐页纯文本，无文本层时 Vision OCR（简中 + 英文），**固定警告「不还原排版」**。
- 零第三方 SwiftPM 依赖保持不变；`zlib` / PDFKit / Vision / XMLParser 全部是系统框架。

**验证**：`swift test` 40 项全部通过（原 30 + 新增 10）：HTML 结构与脚本清洗、HTML 空格保真、导入结果再解析不丢块、本地图片落盘、项目自产 DOCX 往返、手工 WordprocessingML 原生结构（标题/编号列表/超链接/表格/图片）、XLSX 最小包、PDF 降级警告、deflate ZIP 读取、序列化往返、注册表覆盖。版本号 1.1.0 / build 4。

### 1.2.0（2026-11-18）— 公式 / 流程图向导 + 文本文件导入

**新增**

- `Views/InsertTemplates.swift`：9 个可直接编辑的模板（5 个 KaTeX 公式 + 4 个 Mermaid 图表）、两类中英文语法速查弹窗（带「插入示例」按钮）。模板自带占位符，插入后自动选中；已选中文字时直接套进模板。原有顶部按钮（侧栏、三段视图、格式组、导入、导出）全部保留。
- `Views/FormatToolbar.swift`：新增 `∑`「公式」与「流程图」两个向导下拉按钮；`App/AppCommands.swift` 的「格式」菜单同步加「插入公式」「插入图表」子菜单。所有入口复用 `InsertCommand.template`，插入逻辑只在 `MarkdownEditorTextView.apply(_:)` 一份；块级模板自动另起一行，行内公式保持在同一行。
- `Core/InlineParser.swift`：把 `$…$` / `$$…$$` 识别为原样文本区间，LaTeX 的 `\frac`、`\{`、`\_`、`\begin{aligned}` 不再被 Markdown 转义/强调规则吃掉；保留 `$5 / $10` 价格保护，独立公式允许跨行。
- `Core/Importers/TextImporter.swift`：
  - `TextFileDecoder` — UTF-8 / UTF-16 / UTF-32（含 BOM 与无 BOM 启发式）、GB18030 / GBK、Big5、Windows-1252 自动识别；BOM 剥离、CRLF/CR 统一、NUL 二进制拒绝、32 MB 上限、无扩展名文本嗅探。
  - `TextImporter` — Markdown 文件原文导入；普通文本经 AST 转成硬换行并转义语法字符；CSV/TSV 用引号感知的解析器转成 GFM 表格（最多 500 行数据）。
- `Core/ImportService.swift`：注册表加入 `TextImporter`；打开面板与「不支持该文件类型」说明同步更新；未注册扩展名但嗅探为文本的文件自动落到文本导入器。
- `ContentView.swift` 窗口最小宽度 700 → 880pt（用真机窗口逐档测量 macOS 工具栏折叠阈值），保证新增向导按钮与原有按钮都不进溢出菜单；版本号 1.2.0 / build 5（`Info.plist` + `AppMetadata.version`）。

**验证**：`swift test` **63 项全部通过**（原 40 + 新增 23）：模板占位符/围栏结构、LaTeX 原样保留与价格保护、真实 `NSTextView` 插入与选区替换、块级换行分离、UTF-8 BOM / CRLF / GB18030 / UTF-16LE BOM、Markdown 原文导入、CSV/TSV 表格与引号字段、空/二进制文件拒绝、无扩展名嗅探、注册表覆盖，以及在**真实 WKWebView 预览内核**中确认 ≥3 个 KaTeX 公式与 ≥2 个 Mermaid 图渲染成功。

### 1.2.1（2026-11-18）— 修复「导入文本后预览是新内容、编辑区仍是旧文档」

**问题**：导入 `备份手机app.txt` 并选择「新建文档」后，右侧预览已是导入内容，左侧编辑区却停留在「欢迎使用 Marksmith」模板（1.2.0 的回归）。

**根因**：`ContentView.initialise()` 先前把**导入前**的 `document.text` 捕获进一个 `DispatchQueue.main.async` 延迟补同步闭包，之后才消费 `PendingImport`。该闭包晚一步执行，把编辑器刷回旧文本；而预览是直接赋值 `previewHTML`，不受影响，于是左右分叉。此外 `EditorBridge.syncText()` 在 `makeNSView` 尚未连接真实 `NSTextView` 时会直接丢弃这次同步。

**修复**

- `EditorBridge` 记录 `latestText`，新增 `attach(...)`（首次连接时回放排队文本）与 `flush()`（**不带文本参数**的重放，只使用最新值）；`syncText()` 成为所有外部文本写入的唯一入口。
- `ContentView.initialise()` 先消费导入 payload，再用最终文本同步一次；延迟补同步改为 `flush()`，不再携带旧文本快照。
- `MarkdownEditorView.updateNSView()` 改走 `bridge.syncText(text)`，且只在值与 `latestText` 不同才写入，避免覆盖尚未回写到绑定的键盘输入。
- `ImportService` 新增 `writeImportedText(...)` / `consumePendingImport(...)`：覆盖、追加、新建文档三条路径都显式同步编辑器；追加不再使用延迟闭包。`PendingImport` 改为带 id 与创建时间的 payload，只有导入之后才创建的窗口能消费，防止旧窗口抢走内容。
- 界面与功能不变：侧栏、三段视图、格式组、公式/流程图向导、导入/导出按钮以及导入目标三选一全部保留。版本号 1.2.1 / build 6。

**验证**：`swift test` **69 项全部通过**（原 63 + 新增 6 项导入同步回归测试：连接前同步回放、`flush()` 重放最新值、新建文档交接、覆盖/追加写入编辑器、payload 按 id 取消与旧窗口不可抢占）。另用真实 App 进程导入该 `.txt` 并新建文档，确认新窗口编辑器为 3629 字符的导入内容、不含欢迎模板，payload 已被消费；启动时的旧窗口内容保持不变。
