# Globtype 发布与分享指南

Globtype 不使用付费的 Apple 开发者账号，不经过苹果公证，而是用一张固定的自签名证书签名后直接分发 zip。本文分三部分：

1. [发布者：打包与发版](#一发布者打包与发版)
2. [使用者：安装说明](#二使用者安装说明)（可以直接复制发给别人）
3. [通过 GitHub 发布](#三通过-github-发布可选)

---

## 一、发布者：打包与发版

### 1. 一次性准备

| 项目 | 说明 |
|---|---|
| Swift 工具链 | Command Line Tools + Swift 6.0 及以上，`Scripts/swift-env.sh` 会自动选择 |
| 本地词典 | 无需手动准备：`bundle.sh` 与 `release.sh` 在缺少 `Sources/Globtype/Resources/dictionary.sqlite`（约 5MB，不入库）时会自动调用 `Scripts/build_dictionary.py` 生成，首次需下载 ECDICT（约 65MB，缓存在 `build/ecdict.csv`） |
| 签名证书 | `Scripts/create_signing_cert.sh`，创建 `Globtype Self-Signed` 证书并导入登录钥匙串 |

**证书是分发的关键。** macOS 把辅助功能、输入监控权限绑定在 App 的签名上：

- 所有版本都用**同一张**证书签名，用户覆盖升级后权限仍然有效
- 证书一旦更换或丢失，**所有用户**升级后都必须重新授权

证书备份位于 `~/Documents/Globtype-signing-backup/`（`.p12` 文件和密码），请转存到密码管理器或其他安全位置，**不要提交到仓库、不要发给任何人**。换电脑时导入方法见 [Scripts/create_signing_cert.md](../Scripts/create_signing_cert.md)。

### 2. 打包

```bash
cd ~/Globtype
GLOBTYPE_VERSION=0.1.0 GLOBTYPE_BUILD=1 Scripts/release.sh
```

脚本依次执行：

0. 缺少词典时自动生成（发布版本必须包含词典，生成失败即停止）
1. 运行全部单元测试，失败即停止
2. 分别编译 Apple 芯片（arm64）和 Intel（x86_64）版本，合并为通用二进制
3. 组装 `Globtype.app`，放入词典、服务商预设和图标
4. 用 `Globtype Self-Signed` 证书签名并校验；找不到证书时直接失败，不会退回临时签名
5. 生成 `build/Globtype-<版本>.zip`，并打印 SHA-256 校验值

**只分享这个 zip。** 不要分享整个项目文件夹：里面是源码和编译缓存，对方还得自己编译。

### 3. 版本号

| 变量 | 含义 | 规则 |
|---|---|---|
| `GLOBTYPE_VERSION` | 显示版本，如 `0.1.1` | 修复问题改第三位，新功能改第二位 |
| `GLOBTYPE_BUILD` | 构建号，如 `2` | 每次发版递增 |

### 4. 发版前检查

- [ ] `release.sh` 输出中有"使用证书：Globtype Self-Signed"
- [ ] 输出中的架构为 `x86_64 arm64`
- [ ] 本机覆盖安装新版后，双击 Shift 仍能唤起（验证权限未丢失）
- [ ] 翻译、替换、表达库、复习各走一遍
- [ ] 记下 zip 的 SHA-256，随版本说明一起发布

### 5. 不会被打包的内容

以下内容只在发布者自己的电脑上，不会出现在 zip 中：

- API Key：保存在 macOS 钥匙串
- 表达库与复习数据：`~/Library/Application Support/Globtype/`
- 签名证书私钥：登录钥匙串与备份目录

---

## 二、使用者：安装说明

> 以下内容可以直接复制发给使用者。

### 系统要求

- macOS 15（Sequoia）或更新版本
- Apple 芯片或 Intel 处理器的 Mac 均可

### 安装步骤

1. 解压 `Globtype-x.y.z.zip`，把 `Globtype.app` 拖到「应用程序」文件夹
2. 双击打开。第一次会被系统拦截，提示"无法验证开发者"或"Apple 无法检查其是否包含恶意软件"，这是因为 Globtype 没有使用付费的苹果开发者账号。放行方法：
   - 打开 **系统设置 → 隐私与安全性**，滚动到页面底部，点击 **仍要打开**，再输入开机密码确认
   - 如果提示 **"已损坏，无法打开"**，打开「终端」执行下面这行，然后重新打开：

     ```bash
     xattr -dr com.apple.quarantine /Applications/Globtype.app
     ```

   macOS 15 起，右键"打开"已经不能绕过这一步。
3. 按引导授予两项权限：
   - **辅助功能**：读取输入框文字、填回译文
   - **输入监控**：识别双击 Shift

   如果系统设置列表里没有 Globtype，点"+"手动添加 `/Applications/Globtype.app`。
4. 配置翻译服务商：菜单栏图标 → 设置 → 翻译服务商。推荐 DeepSeek（国内直连），填入自己的 API Key 后点"测试连接"。不填也能用，会使用 Apple 翻译，只有直译。

### 怎么用

在任意 App 的输入框里用中文写完，**双击 Shift**，面板里出现英文后按 **Enter** 替换原文。

| 按键 | 作用 |
|---|---|
| Enter | 替换原文并保存到表达库 |
| ⌥Enter | 替换但不保存 |
| R | 换个说法 |
| Tab | 查看中文讲解 |
| Esc | 关闭 |

学习进度、复习、表达库都在 **学习中心**：从启动台或 Spotlight 打开 Globtype，或者点菜单栏图标 → 打开学习中心。

### 升级

下载新版 zip，解压后覆盖「应用程序」里的旧版即可，数据和权限都会保留。新版同样需要按第 2 步放行一次。

### 隐私

- 你写的文字只会发送给你自己配置的翻译服务商，不经过开发者
- 没有账号、没有统计、没有上报
- API Key 存在你电脑的钥匙串里，学习数据只保存在你的电脑上

### 常见问题

| 现象 | 处理 |
|---|---|
| 双击 Shift 没反应 | 菜单栏图标有感叹号说明缺权限，点"修复权限…"；密码框里不会响应，这是正常的 |
| 双击 Shift 后输入法中英状态变了 | 设置 → 通用，关闭双击 Shift，改用自定义快捷键（如 ⌥Space） |
| 升级后突然不能用了 | 系统设置 → 隐私与安全性 → 辅助功能 / 输入监控，删掉 Globtype 后重新添加 |
| 翻译报错"API Key 无效""余额不足" | 检查服务商控制台里的 Key 和余额 |
| 某个 App 里替换失败 | 译文会自动复制到剪贴板，手动 ⌘V 粘贴；并请把 App 名称反馈给发布者 |

---

## 三、通过 GitHub 发布（可选）

用微信、网盘分享 zip 也可以。放到 GitHub 的好处是有固定下载地址、版本历史，别人也能看到源码。

### 首次设置

```bash
cd ~/Globtype
git init
git add .
git commit -m "Globtype 0.1.0"
# 在 GitHub 网页上新建一个空仓库（不要勾选添加 README），然后：
git remote add origin git@github.com:<你的用户名>/Globtype.git
git branch -M main
git push -u origin main
```

`.gitignore` 已排除编译产物、生成的词典和 `.p12` 证书文件。提交前用 `git status` 再确认一遍，没有 `.p12`、`p12-password.txt` 之类的文件。

### 每次发版

先提交所有改动（标签会指向当前提交），然后一条命令完成打包与发布：

```bash
GLOBTYPE_VERSION=0.1.1 GLOBTYPE_BUILD=2 GLOBTYPE_PUBLISH=1 Scripts/release.sh
```

`GLOBTYPE_PUBLISH=1` 会创建标签 `v0.1.1`、新建 GitHub Release 并上传 zip，说明里自动带上 SHA-256 和安装指引。不加这个变量时只打包，不碰远端。

发布需要 GitHub API 认证（SSH 密钥不能用于 API），二选一：

```bash
brew install gh && gh auth login      # 方式一：GitHub CLI
export GITHUB_TOKEN=<有 repo 权限的 token>   # 方式二：https://github.com/settings/tokens
```

发布前脚本会检查：工作区是否干净、远端是否已存在同名标签。发布后本地没有该标签，用 `git fetch --tags` 拉回。

想手工发布也可以：跑不带 `GLOBTYPE_PUBLISH` 的 `release.sh`，然后在 GitHub 的 **Releases → Draft a new release** 里上传 `build/Globtype-0.1.1.zip`，说明里写上本版改动、zip 的 SHA-256 和安装说明链接。

### 暂不支持的分发方式

- **Homebrew**：从 2026-09-01 起，Homebrew 官方仓库停用了所有无法通过 Gatekeeper 检查的 cask，未公证的 App 无法上架
- **Mac App Store**：读写其他 App 输入框需要辅助功能权限，沙盒不允许
- **免放行安装**：需要 Apple 开发者账号（每年 99 美元）签名并公证。以后如果申请了账号，只需修改签名脚本并增加公证步骤，但证书变化会让所有用户重新授权一次
