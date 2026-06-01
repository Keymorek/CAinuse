#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# linux-init.sh  (v2)
#
# 适配范围:
#   - Ubuntu LTS: 22.04 (jammy) / 24.04 (noble) / 26.04 及以后 (按系统自带 codename)
#   - Debian:     10 (buster, EOL→archive) / 11 (bullseye) / 12 (bookworm) / 13 (trixie)
#   - 主要面向 PVE 宿主 / 虚机 / LXC。PVE 宿主一般为 root。
#
# 设计要点:
#   1. root 与非 root 通用。非 root 时自动探测当前用户名，再配置免密 sudo。
#   2. 先装基础证书 + 软件源，再做其它联网操作（应对 Surge HTTPS MitM 解密）。
#   3. CA 证书已内置在脚本中（与上传的 .crt/.pem 同一张, SHA256 36:1F:80:31:...）。
#   4. 源全部走清华 TUNA，按发行版/版本/格式(one-line 或 deb822)自动选择。
#   5. 不再安装 Homebrew，改用 Docker 官方一键脚本；非 root 加入 docker 组。
#   6. SSH 的 MaxAuthTries 调整为 20（适配 1Password SSH agent 多公钥）。
#
# 用法:
#   - root:     ./linux-init.sh        或  bash linux-init.sh
#   - 非 root:  ./linux-init.sh        （请勿用 sudo 运行，脚本会自行调用 sudo）
#
# 可调环境变量(可选):
#   DOCKER_MIRROR=""            # Docker 官方脚本镜像; 默认空=官方直连; 可填 Aliyun 等
#   SSH_MAX_AUTH_TRIES=20       # sshd MaxAuthTries
#   ENABLE_PASSWORDLESS_SUDO=1  # 非 root 时是否开免密 sudo (1=开, 0=不开)
#   NODE_MAJOR=24               # nvm 安装的 Node 主版本
# =============================================================================

DOCKER_MIRROR="${DOCKER_MIRROR:-}"
SSH_MAX_AUTH_TRIES="${SSH_MAX_AUTH_TRIES:-20}"
ENABLE_PASSWORDLESS_SUDO="${ENABLE_PASSWORDLESS_SUDO:-1}"
NODE_MAJOR="${NODE_MAJOR:-24}"

log()  { printf "[%s] %s\n" "$(date '+%F %T')" "$*"; }
warn() { printf "[%s] [WARN] %s\n" "$(date '+%F %T')" "$*" >&2; }
die()  { printf "[%s] [ERROR] %s\n" "$(date '+%F %T')" "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Step 0: 基础探测 (OS / root 与否 / sudo 包装 / 目标用户)
# ----------------------------------------------------------------------------
log "Step 0: 系统探测"
[ -f /etc/os-release ] || die "无法识别系统 (缺少 /etc/os-release)"
# shellcheck disable=SC1091
. /etc/os-release
log "Detected: ${PRETTY_NAME:-unknown}"

OS_ID="${ID:-}"                                   # ubuntu / debian
CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ] && has lsb_release; then CODENAME="$(lsb_release -cs)"; fi
VID="${VERSION_ID:-}"                             # 22.04 / 24.04 / 11 / 12 ...

case "$OS_ID" in
  ubuntu|debian) : ;;
  *) die "仅支持 Ubuntu / Debian, 当前为: ${OS_ID:-unknown}" ;;
esac
[ -n "$CODENAME" ] || die "无法获取版本代号 (VERSION_CODENAME)"

# root / 非 root 包装
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  IS_ROOT=1
  TARGET_USER="root"
  log "以 root 运行：跳过免密 sudo 配置与 docker 用户组配置"
else
  IS_ROOT=0
  has sudo || die "非 root 运行但系统没有 sudo，请先安装 sudo 或改用 root 运行"
  SUDO="sudo"
  TARGET_USER="$(id -un)"
  log "以非 root 用户运行：检测到当前用户 = ${TARGET_USER}"
  if ! sudo -n true >/dev/null 2>&1; then
    log "sudo 需要密码（非 NOPASSWD），过程中可能提示输入一次"
  fi
fi

# ----------------------------------------------------------------------------
# Step 1: (仅非 root) 为当前用户配置免密 sudo
# ----------------------------------------------------------------------------
if [ "$IS_ROOT" -eq 0 ] && [ "$ENABLE_PASSWORDLESS_SUDO" = "1" ]; then
  log "Step 1: 为用户 '${TARGET_USER}' 配置免密 sudo"
  SUDOERS_D="/etc/sudoers.d/90-${TARGET_USER}-nopasswd"
  TMP_SUDO="$(mktemp)"
  printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$TARGET_USER" > "$TMP_SUDO"
  # 先用 visudo -c 校验语法，通过后再落盘
  if $SUDO visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
    $SUDO install -m 0440 -o root -g root "$TMP_SUDO" "$SUDOERS_D"
    rm -f "$TMP_SUDO"
    if sudo -n true >/dev/null 2>&1; then
      log "免密 sudo 已生效: $SUDOERS_D"
    else
      warn "免密 sudo 文件已写入，但当前 shell 暂未生效（重新登录后生效）"
    fi
  else
    rm -f "$TMP_SUDO"
    warn "visudo 语法校验失败，跳过免密 sudo 配置"
  fi
else
  log "Step 1: 跳过免密 sudo（root 或 ENABLE_PASSWORDLESS_SUDO=0）"
fi

# ----------------------------------------------------------------------------
# Step 2: 内置 CA 证书 → 系统信任库（尽量最先做，让后续 HTTPS 经 MitM 不报错）
# ----------------------------------------------------------------------------
log "Step 2: 安装内置 SurgeCA 到系统信任库"
CA_DST_DIR="/usr/local/share/ca-certificates"
CA_DST="${CA_DST_DIR}/SurgeCA.crt"          # update-ca-certificates 要求 PEM 内容 + .crt 后缀
CA_ACTIVATED=0

$SUDO mkdir -p "$CA_DST_DIR"
# 注意：以下 PEM 与你上传的 SurgeCA.crt / SurgeCA.pem 为同一张证书
$SUDO tee "$CA_DST" >/dev/null <<'SURGE_CA_PEM'
-----BEGIN CERTIFICATE-----
MIIDcjCCAlqgAwIBAgIQGNMobJhtljv1C+hSoQ4TdTANBgkqhkiG9w0BAQsFADBM
MSQwIgYDVQQKDBtTdXJnZSBHZW5lcmF0ZWQgQ0EgRTFGRTYxMjUxJDAiBgNVBAMM
G1N1cmdlIEdlbmVyYXRlZCBDQSBFMUZFNjEyNTAeFw0yNDAyMDcxNjEyNDZaFw0z
NDAyMDQxNjEyNDZaMEwxJDAiBgNVBAoMG1N1cmdlIEdlbmVyYXRlZCBDQSBFMUZF
NjEyNTEkMCIGA1UEAwwbU3VyZ2UgR2VuZXJhdGVkIENBIEUxRkU2MTI1MIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvjaRI/A9pgWvQfr88XPYifl7kpLk
AifFDQhDmT+HURnx2PmtB7NbxFgrPGcGCW6IGv3kxIVB5zHKQuZjIwqM8V4O9Sgg
uEIYcED/PeEZamrqFHc8dYtNIUwe5JATi3ow7jr9Dm3njrQkQ36dsAkLZ7ADpOdm
779ooUL6lEU63yAzKrHNRKb+KDM4dr/TZurTaOcq1L2XiujdbFTI3lke04bQBSJ0
548y7JoY5TH7WYJYfNfYTgCwllK+MTH267oHfoxymrQi0X1UuHBV+7JD5g+0SsLE
41rozWKO1eQTrmk25MVvLzATloLqoiOGr18Q0z/sRthyYKRItXZDA2iCdwIDAQAB
o1AwTjAdBgNVHQ4EFgQU8gWQD2ExBkZiceT04Bk26ZTrbM4wHwYDVR0jBBgwFoAU
8gWQD2ExBkZiceT04Bk26ZTrbM4wDAYDVR0TBAUwAwEB/zANBgkqhkiG9w0BAQsF
AAOCAQEATpXVLOdEYvVEZfvluR02IugiD9vAZTncCnXoh08BjlePFZ9sheUSEe4f
GTTgMctuRyhlu1Nd914Qg7l+G0QWYB94CoMmIH+A/Ttl1Znf2ZL/BbBvmKqWVlDP
Pohyn/MpwzfwhgIAwsiAvFij7ZLPe4+vxaMsnwlerJt7NIHiw3ITh1ytuaUbD2t9
WUZErYkhsQxrNnzIfWHomlUzV8S08q2zRa1amD8FVfWMAP3D1lI+dOhTgs6gxmLY
+bcAW0VHMMZHZ2ukxmiE+mGEJ+qv21DRzaYS05QdQ9OsZdAte44WaV9j11lQNREI
rx6/o6bKeCm6bUd0IJFutrHIihj8iw==
-----END CERTIFICATE-----
SURGE_CA_PEM
$SUDO chmod 0644 "$CA_DST"

if has update-ca-certificates; then
  $SUDO update-ca-certificates >/dev/null 2>&1 && CA_ACTIVATED=1 || true
fi
if [ "$CA_ACTIVATED" = "1" ]; then
  log "CA 已写入并激活（系统信任库已更新）"
else
  warn "暂时无法激活 CA（缺少 update-ca-certificates，将在安装 ca-certificates 后再激活）"
fi

# ----------------------------------------------------------------------------
# Step 3: 替换 APT 源为清华 TUNA（按发行版 / 版本 / 格式自动适配）
# ----------------------------------------------------------------------------
log "Step 3: 配置 TUNA 软件源 (${OS_ID} ${CODENAME})"

TUNA="mirrors.tuna.tsinghua.edu.cn"
# CA 已激活则用 https，否则先用 http 引导，待 ca-certificates 装好再切回 https
if [ "$CA_ACTIVATED" = "1" ]; then SCHEME="https"; else SCHEME="http"; fi

backup_file() {
  local f="$1"
  [ -e "$f" ] || return 0
  local bdir="/var/backups/linux-init"
  $SUDO mkdir -p "$bdir"
  local b
  b="${bdir}/$(printf '%s' "$f" | sed 's#/#_#g').bak.$(date +%s)"
  $SUDO cp -a "$f" "$b"
  log "已备份: $f -> $b"
}

neutralize_file() {
  # 备份后清空旧源文件，避免与新源产生重复条目告警
  local f="$1"
  [ -e "$f" ] || return 0
  backup_file "$f"
  $SUDO bash -c "printf '# 已由 linux-init.sh 接管，源见对应 *.sources / sources.list\n' > '$f'"
}

# Ubuntu 是否走 deb822 (24.04+ 或已存在 ubuntu.sources)
ubuntu_is_deb822() {
  [ -f /etc/apt/sources.list.d/ubuntu.sources ] && return 0
  dpkg --compare-versions "${VID:-0}" ge 24.04 2>/dev/null && return 0
  return 1
}
# Debian 是否走 deb822 (13+ 或已存在 debian.sources, 含 bookworm 容器镜像)
debian_is_deb822() {
  [ -f /etc/apt/sources.list.d/debian.sources ] && return 0
  dpkg --compare-versions "${VID:-0}" ge 13 2>/dev/null && return 0
  return 1
}

write_sources() {
  local scheme="$1"
  if [ "$OS_ID" = "ubuntu" ]; then
    local comps="main restricted universe multiverse"
    if ubuntu_is_deb822; then
      local f="/etc/apt/sources.list.d/ubuntu.sources"
      backup_file "$f"
      neutralize_file "/etc/apt/sources.list"
      $SUDO tee "$f" >/dev/null <<EOF
Types: deb
URIs: ${scheme}://${TUNA}/ubuntu
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports ${CODENAME}-security
Components: ${comps}
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    else
      local f="/etc/apt/sources.list"
      backup_file "$f"
      $SUDO tee "$f" >/dev/null <<EOF
deb ${scheme}://${TUNA}/ubuntu/ ${CODENAME} ${comps}
deb ${scheme}://${TUNA}/ubuntu/ ${CODENAME}-updates ${comps}
deb ${scheme}://${TUNA}/ubuntu/ ${CODENAME}-backports ${comps}
deb ${scheme}://${TUNA}/ubuntu/ ${CODENAME}-security ${comps}
EOF
    fi

  else  # debian
    # 组件：12(bookworm)+ 增加 non-free-firmware
    local comps="main contrib non-free"
    if dpkg --compare-versions "${VID:-0}" ge 12 2>/dev/null \
       || [ "$CODENAME" = "bookworm" ] || [ "$CODENAME" = "trixie" ]; then
      comps="main contrib non-free non-free-firmware"
    fi

    # Debian 10 buster 已 EOL，TUNA 主仓已下线，改用官方 archive 归档源
    if [ "$CODENAME" = "buster" ] || [ "${VID:-}" = "10" ]; then
      warn "Debian 10 (buster) 已 EOL：使用 archive.debian.org 归档源，且关闭过期校验"
      backup_file "/etc/apt/sources.list"
      $SUDO tee "/etc/apt/sources.list" >/dev/null <<EOF
deb http://archive.debian.org/debian/ buster ${comps}
deb http://archive.debian.org/debian/ buster-updates ${comps}
deb http://archive.debian.org/debian-security/ buster/updates ${comps}
EOF
      $SUDO tee "/etc/apt/apt.conf.d/99no-check-valid-until" >/dev/null <<'EOF'
Acquire::Check-Valid-Until "false";
EOF
      return 0
    fi

    if debian_is_deb822; then
      local f="/etc/apt/sources.list.d/debian.sources"
      backup_file "$f"
      neutralize_file "/etc/apt/sources.list"
      $SUDO tee "$f" >/dev/null <<EOF
Types: deb
URIs: ${scheme}://${TUNA}/debian
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: ${comps}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${scheme}://${TUNA}/debian-security
Suites: ${CODENAME}-security
Components: ${comps}
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    else
      local f="/etc/apt/sources.list"
      backup_file "$f"
      $SUDO tee "$f" >/dev/null <<EOF
deb ${scheme}://${TUNA}/debian/ ${CODENAME} ${comps}
deb ${scheme}://${TUNA}/debian/ ${CODENAME}-updates ${comps}
deb ${scheme}://${TUNA}/debian/ ${CODENAME}-backports ${comps}
deb ${scheme}://${TUNA}/debian-security/ ${CODENAME}-security ${comps}
EOF
    fi
  fi
}

write_sources "$SCHEME"
log "已写入 ${SCHEME} 源 (${OS_ID} ${CODENAME})"

# ----------------------------------------------------------------------------
# Step 4: apt 更新
# ----------------------------------------------------------------------------
log "Step 4: apt-get update"
$SUDO apt-get update

# ----------------------------------------------------------------------------
# Step 5: 安装基础软件（含 ca-certificates）
# ----------------------------------------------------------------------------
log "Step 5: 安装基础软件包"
PKGS=(
  build-essential ca-certificates git unzip qemu-guest-agent spice-vdagent
  bash-completion wget curl axel net-tools iputils-ping iputils-arping
  iputils-tracepath nano most screen less vim bzip2 lldpd mtr-tiny htop
  dnsutils zstd
)
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y install "${PKGS[@]}"

# 若此前 CA 未激活（极简系统刚装上 ca-certificates），现在激活，并把源切回 https
if [ "$CA_ACTIVATED" != "1" ] && has update-ca-certificates; then
  log "激活内置 CA 并将源切换为 https"
  $SUDO update-ca-certificates >/dev/null 2>&1 || true
  CA_ACTIVATED=1
  if [ "$CODENAME" != "buster" ] && [ "${VID:-}" != "10" ]; then
    write_sources "https"
    $SUDO apt-get update
  fi
fi

# ----------------------------------------------------------------------------
# Step 6: 安装 Docker（官方一键脚本）
# ----------------------------------------------------------------------------
log "Step 6: 安装 Docker (get.docker.com 官方脚本)"
if has docker; then
  log "Docker 已安装: $(docker --version 2>/dev/null || echo present)"
else
  GET_DOCKER="/tmp/get-docker.sh"
  curl -fsSL https://get.docker.com -o "$GET_DOCKER"
  if [ -n "$DOCKER_MIRROR" ]; then
    log "使用 Docker 安装镜像: ${DOCKER_MIRROR}"
    $SUDO sh "$GET_DOCKER" --mirror "$DOCKER_MIRROR"
  else
    $SUDO sh "$GET_DOCKER"
  fi
  rm -f "$GET_DOCKER"
fi

# 启用并启动 docker 服务（仅在 systemd 环境）
if [ -d /run/systemd/system ]; then
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || warn "docker 服务 enable/start 失败（容器内无 systemd 可忽略）"
else
  warn "未检测到 systemd，跳过 docker 服务自启配置"
fi

# 非 root：把当前用户加入 docker 组
if [ "$IS_ROOT" -eq 0 ]; then
  if getent group docker >/dev/null 2>&1; then
    $SUDO usermod -aG docker "$TARGET_USER"
    log "已将用户 '${TARGET_USER}' 加入 docker 组（需重新登录或 'newgrp docker' 生效）"
  else
    warn "未找到 docker 组，跳过用户组配置"
  fi
fi

# ----------------------------------------------------------------------------
# Step 7: 安装 nvm + Node ${NODE_MAJOR}
# ----------------------------------------------------------------------------
log "Step 7: 安装 nvm + Node.js ${NODE_MAJOR}"
NVM_VERSION="v0.40.3"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# Node 二进制走 TUNA 镜像，国内更快更稳
export NVM_NODEJS_ORG_MIRROR="${NVM_NODEJS_ORG_MIRROR:-https://${TUNA}/nodejs-release/}"

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
# shellcheck disable=SC1090
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_MAJOR"
nvm alias default "$NODE_MAJOR"

ensure_line() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  touch "$file"
  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  ensure_line "$rc" 'export NVM_DIR="$HOME/.nvm"'
  ensure_line "$rc" '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
  ensure_line "$rc" "export NVM_NODEJS_ORG_MIRROR=https://${TUNA}/nodejs-release/"
done
log "Node: $(node -v 2>/dev/null)  npm: $(npm -v 2>/dev/null)"

# ----------------------------------------------------------------------------
# Step 8: 调整 sshd MaxAuthTries（适配 1Password 多公钥）
# ----------------------------------------------------------------------------
log "Step 8: 设置 sshd MaxAuthTries = ${SSH_MAX_AUTH_TRIES}"
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/99-maxauthtries.conf"

if [ ! -f "$SSHD_MAIN" ]; then
  warn "未发现 ${SSHD_MAIN}（可能未安装 openssh-server），跳过 SSH 配置"
else
  applied=0
  # 优先用 drop-in（主配置含 Include sshd_config.d/*.conf 时）
  if [ -d "$SSHD_DROPIN_DIR" ] && grep -Eq '^\s*Include\s+.*sshd_config\.d/\*\.conf' "$SSHD_MAIN"; then
    $SUDO tee "$SSHD_DROPIN" >/dev/null <<EOF
# Managed by linux-init.sh
MaxAuthTries ${SSH_MAX_AUTH_TRIES}
EOF
    $SUDO chmod 0644 "$SSHD_DROPIN"
    applied=1
    log "已写入 drop-in: ${SSHD_DROPIN}"
  else
    # 回退到直接改主配置：替换已有(含注释)行，否则追加
    backup_file "$SSHD_MAIN"
    if $SUDO grep -Eq '^\s*#?\s*MaxAuthTries' "$SSHD_MAIN"; then
      $SUDO sed -i -E "s/^\s*#?\s*MaxAuthTries.*/MaxAuthTries ${SSH_MAX_AUTH_TRIES}/" "$SSHD_MAIN"
    else
      echo "MaxAuthTries ${SSH_MAX_AUTH_TRIES}" | $SUDO tee -a "$SSHD_MAIN" >/dev/null
    fi
    applied=1
    log "已修改主配置: ${SSHD_MAIN}"
  fi

  # 校验配置并重载
  if [ "$applied" = "1" ]; then
    if $SUDO sshd -t 2>/dev/null; then
      if [ -d /run/systemd/system ]; then
        $SUDO systemctl reload ssh 2>/dev/null \
          || $SUDO systemctl reload sshd 2>/dev/null \
          || warn "ssh 服务 reload 失败（请手动重载 sshd）"
      else
        warn "未检测到 systemd，请在需要时手动重启 sshd 使配置生效"
      fi
      log "sshd 配置校验通过并已尝试重载"
    else
      warn "sshd -t 校验失败！已保留备份，请手动检查 ${SSHD_MAIN}"
    fi
  fi
fi

# ----------------------------------------------------------------------------
# 完成
# ----------------------------------------------------------------------------
log "全部完成。"
echo
echo "后续提醒:"
echo "  - 打开新终端以加载更新后的环境 (.bashrc / .zshrc, nvm)"
if [ "$IS_ROOT" -eq 0 ]; then
  echo "  - docker 组权限需重新登录（或执行 newgrp docker）后生效"
fi
echo "  - sshd MaxAuthTries 已设为 ${SSH_MAX_AUTH_TRIES}"
