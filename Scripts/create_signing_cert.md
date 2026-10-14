# 创建固定的自签名代码签名证书

Globtype 不使用 Apple 开发者账号。macOS 把辅助功能、输入监控权限绑定在 App 的代码签名上：

- 临时签名（ad-hoc）每次构建都不同，用户每次更新都要重新授权
- 所有版本都用**同一张**自签名证书签名，系统会把新版本认作同一个 App，权限得以保留

证书一旦更换，所有用户都需要重新授权，所以请务必备份。

## 创建证书

最简单的方式是运行脚本，它会生成证书、导入登录钥匙串，并把 `.p12` 备份和密码写到 `~/Documents/Globtype-signing-backup/`：

```bash
Scripts/create_signing_cert.sh
```

也可以手动创建：

1. 打开「钥匙串访问」
2. 菜单：钥匙串访问 → 证书助理 → 创建证书…
3. 填写：
   - 名称：`Globtype Self-Signed`（必须与 `Scripts/bundle.sh` 中的名称一致）
   - 身份类型：自签名根证书
   - 证书类型：**代码签名**
4. 点击「创建」，证书会存入「登录」钥匙串
5. 验证：

   ```bash
   security find-identity -v -p codesigning
   ```

   输出中应包含 `"Globtype Self-Signed"`，后面标着 `CSSMERR_TP_NOT_TRUSTED` 是正常的：自签名证书不受系统信任，但 `codesign` 可以正常使用，也足以让系统在升级后识别为同一个 App。注意不要加 `-v` 参数，否则它会被隐藏。

## 备份

在「钥匙串访问」中右键该证书 → 导出 → 选择 `.p12` 格式并设置密码。把 `.p12` 文件和密码保存在安全的位置（不要提交到仓库）。

## 在另一台机器或 CI 上导入

```bash
security import Globtype-Self-Signed.p12 -k ~/Library/Keychains/login.keychain-db -P "<密码>" -T /usr/bin/codesign
```

如果将来使用 GitHub Actions 发布，把 `.p12` 以 base64 形式存入仓库 Secrets，在工作流中解码后导入临时钥匙串。

## 使用其他名称

```bash
GLOBTYPE_SIGN_IDENTITY="你的证书名" Scripts/bundle.sh
```
