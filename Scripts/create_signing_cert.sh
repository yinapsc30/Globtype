#!/bin/zsh
# 创建固定的自签名代码签名证书 "Globtype Self-Signed" 并导入登录钥匙串（命令行版，等同 create_signing_cert.md 的手动步骤）。
#
# - 已存在同名证书时什么也不做
# - 备份（.p12 + 密码）写到 ~/Documents/Globtype-signing-backup/，不在仓库内
# - 不修改任何系统信任设置
# 删除：钥匙串访问 → 登录 → 我的证书 → 删除 "Globtype Self-Signed"
set -euo pipefail

NAME="${GLOBTYPE_SIGN_IDENTITY:-Globtype Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP="$HOME/Documents/Globtype-signing-backup"
OPENSSL=/usr/bin/openssl   # 系统自带 LibreSSL，生成的 .p12 钥匙串可直接导入

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✓ 证书 \"$NAME\" 已存在，跳过"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" -extensions ext 2>/dev/null

PASSWORD="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign

mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
cp "$WORK/identity.p12" "$BACKUP/Globtype-Self-Signed.p12"
print -r -- "$PASSWORD" > "$BACKUP/p12-password.txt"
chmod 600 "$BACKUP"/*
echo "✓ 已导入证书 \"$NAME\""
echo "  备份：$BACKUP（请转存到安全位置，证书丢失后所有用户需重新授权）"
