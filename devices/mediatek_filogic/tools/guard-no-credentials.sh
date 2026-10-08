#!/bin/sh
# 公开仓库的凭据闸门：扫描 devices/<target>/files/ 是否混入真实凭据或个人号码。
# 背景：本仓库是公开的，凭据一旦提交就永久留在 git 历史里；2026-10 就因为一次
#       「从设备 1:1 同步」把真实机器人令牌写回了本文件，令牌被爬虫抓走用来发垃圾广告。
#
# 用法：sh devices/<target>/tools/guard-no-credentials.sh [要扫描的目录]
# 退出码：0 = 干净（可以构建）；1 = 命中（构建必须中止）

set -u

dir="${1:-}"
if [ -z "$dir" ]; then
  here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  dir="$here/../files"
fi
if [ ! -d "$dir" ]; then
  echo "目录不存在: $dir"
  exit 1
fi

bad=0

hit() {
  _label="$1"
  _re="$2"
  if grep -rInE "$_re" "$dir" 2>/dev/null; then
    echo "::error::疑似凭据入库：$_label"
    bad=1
  fi
}

warn() {
  _label="$1"
  _re="$2"
  if grep -rInE "$_re" "$dir" 2>/dev/null; then
    echo "::warning::$_label（已知问题，不阻断构建，见脚本内注释）"
  fi
}

# —— 硬性拦截：这些值一旦入库就是事故 ——
hit "Telegram 机器人令牌" '[0-9]{8,10}:AA[A-Za-z0-9_-]{33,35}'
hit "Bark 推送密钥"       'api\.day\.app/[A-Za-z0-9]{18,}'
hit "私钥文件块"          '-----BEGIN [A-Z ]*PRIVATE KEY-----'
hit "机器人凭据字段非空"  "option (token|chat_id|bark_key|user_id|flowcard_no) +'[^']+'"

# —— 只报警告：Wi-Fi 明文密码 ——
# 它的暴露面不在仓库而在「公开发布的固件镜像」：镜像里烤着首启脚本，改仓库并不能让它消失
# （要让镜像干净就得改刷机流程/刷完再设密码，属于另一件事）。所以这里只提醒，不拦构建。
warn "Wi-Fi 明文密码"     "\.key=['\"][^'\"\$]{6,}['\"]"

if [ "$bad" -ne 0 ]; then
  echo "::error::files/ 中出现真实凭据 —— 构建中止。真实值只放设备 uci（tohsakawrt-tgbot.main.*）"
  exit 1
fi

echo "凭据扫描通过：$dir 内没有真实凭据"
