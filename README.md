# Globtype

给中文母语者的 macOS 系统级英文写作工具。在任意 App 的输入框里用中文写完，**双击 Shift**，悬浮面板就地显示地道的英文译文，按 Enter 替换原文。每次翻译都会自动保存到本地表达库，并挑出值得学的表达，用间隔重复帮你记住。

- 中文 / 中英混写 → 英文翻译；英文 / 中式英语 → 润色
- 保留换行、列表、URL、@提及、emoji 和代码片段
- 按 Tab 查看中文讲解：为什么这样说、哪里是中式英语
- 表达库可检索"我以前是怎么说的"，复习在翻译面板和菜单栏中顺手完成
- 开源（MIT）、自带 API Key、无账号、无统计上报，数据只存在本机

## 面板快捷键

| 按键 | 作用 |
|---|---|
| Enter / 点击译文 | 替换原文并记录 |
| ⌥Enter | 替换但本次不记录 |
| R / 再次双击 Shift | 换个说法 |
| Tab | 展开 / 收起中文讲解 |
| ⌘C | 复制译文并关闭 |
| Esc / 点击面板外 | 关闭，原文不变 |
| 其他任意键 | 关闭面板并照常输入 |

有选区时只翻译选区，没有选区时翻译整个输入框。替换后可以用 ⌘Z 撤销（取决于目标 App）。

## 安装

需要 macOS 15 或更新版本，支持 Apple 芯片与 Intel Mac。打包与分享流程见 [docs/distribution.md](docs/distribution.md)。

1. 从 Releases 下载 `Globtype-x.y.z.zip`，解压后把 `Globtype.app` 拖到「应用程序」
2. **首次打开会被系统拦截**（Globtype 没有使用付费的 Apple 开发者账号签名）。任选一种方式放行：
   - 双击打开被拦截后，前往 **系统设置 → 隐私与安全性**，在页面底部点 **仍要打开**
   - 或在终端执行：

     ```bash
     xattr -dr com.apple.quarantine /Applications/Globtype.app
     ```

   macOS 15 起，右键"打开"已经不能绕过这一步。
3. 按引导授予两项权限：
   - **辅助功能**：读取当前输入框文字、回填译文、拦截面板按键
   - **输入监控**：识别双击 Shift 与自定义快捷键

Globtype 会硬性跳过密码框和系统安全输入状态，不读取其中任何内容。

## 配置翻译服务商

打开菜单栏图标 → 设置 → 翻译服务商。

| 服务商 | 说明 |
|---|---|
| DeepSeek（推荐）/ 通义千问 / Kimi / 智谱 GLM / 硅基流动 | 国内直连 |
| OpenAI / Anthropic Claude / Google Gemini | 需要自行解决网络访问 |
| Ollama / LM Studio | 本地模型，数据不出本机 |
| 自定义 | 任意 OpenAI 兼容接口 |
| Apple 翻译 | 免 Key、离线，只有直译，没有润色、换个说法、讲解与学习卡片 |

预设中的推荐模型名写在 `Sources/Globtype/Resources/providers.json`，服务商更新模型后可在设置里直接修改。API Key 保存在 macOS 钥匙串中。设置页会显示本月调用次数和估算的 token 用量。

## 输入法说明

系统拼音、搜狗、微信输入法都用 Shift 切换中英文。双击 Shift 会切换两次，通常会回到原状态。如果你的输入法在双击后状态不一致，请在 设置 → 通用 中关闭双击 Shift，改用自定义快捷键（如 ⌥Space）。输入法正在显示候选词时，双击 Shift 不会触发。

## 隐私

- 源文本只发送给你配置的翻译服务商（或本机的 Apple 翻译），请求中不包含 App 名称、窗口标题等上下文
- 没有账号、没有统计、没有崩溃上报
- 表达库存放在 `~/Library/Application Support/Globtype/`，写入前会把手机号、身份证号、邮箱、银行卡号替换为占位符
- 可以按 App 设置"不记录"，也可以按时间段删除或一键清空
- 日志只记录事件类型，不记录任何文本或 Key

## 从源码构建

只需要 Command Line Tools，不需要 Xcode。需要 Swift 6.0 及以上工具链。

```bash
# 运行单元测试
swift test

# 打包 build/Globtype.app
# 首次打包会自动生成本地词典（下载 ECDICT 约 65MB，产出约 5MB 的 dictionary.sqlite）
# 不想要词典可以跳过：GLOBTYPE_SKIP_DICT=1 Scripts/bundle.sh
Scripts/bundle.sh
```

词典只影响单词卡的音标和基础词过滤，缺失时 App 仍可正常运行。`swift build` 与 `swift test` 不需要词典。

`Scripts/swift-env.sh` 会优先使用 `~/Library/Developer/Toolchains/swift-latest.xctoolchain`，也可以用 `GLOBTYPE_SWIFT=/path/to/swift` 指定。

### 签名

辅助功能与输入监控权限绑定在代码签名上。`bundle.sh` 在找不到证书时使用临时签名，**每次重新构建后都需要重新授权**（在系统设置中移除旧的 Globtype 条目后再添加）。运行 `Scripts/create_signing_cert.sh` 可以一步创建固定的自签名证书（手动方式见 [Scripts/create_signing_cert.md](Scripts/create_signing_cert.md)），之后每次打包都使用它，权限不会丢失。

发布（打包 + 创建 GitHub Release 并上传 zip，详见 [docs/distribution.md](docs/distribution.md)）：

```bash
GLOBTYPE_VERSION=0.1.0 GLOBTYPE_PUBLISH=1 Scripts/release.sh
```

### 诊断模式

菜单栏 → 诊断… 中开启诊断模式后，双击 Shift 不会调用翻译，而是把输入框内容替换为 `[GT] + 原文`，并记录读取方式、回填方式和校验结果（不记录文本内容），可复制为 Markdown 表格，用于测试各 App 的兼容性。

## 项目结构

```
Sources/GlobtypeCore/   与系统界面无关的核心逻辑（可单元测试）
  Input/                双击 Shift 状态机、模式判定、UTF-16 范围
  Engine/               Prompt、流式解析、OpenAI 兼容与 Anthropic 协议
  Learning/             归一化、隐私过滤、选卡、复习调度、表达库
  Storage/              SQLite 封装与迁移
  Dictionary/           ECDICT 词典查询
Sources/Globtype/       菜单栏 App
  Platform/             事件监听、辅助功能读写、剪贴板、钥匙串、Apple 翻译
  Panel/                悬浮面板
  Windows/              设置、表达库、复习、引导、诊断
Tests/GlobtypeCoreTests/
Scripts/                打包、发布、词典生成、签名说明
```

## 许可

MIT，见 [LICENSE](LICENSE)。第三方数据许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
