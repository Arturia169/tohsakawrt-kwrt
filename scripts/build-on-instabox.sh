#!/bin/bash
# TohsakaWrt 固件构建（InstaBox 上跑）
# 复现 .github/workflows/Openwrt-AutoBuild.yml 的步骤
set -euo pipefail

KWRT_REL=25.12
IB_NAME="kwrt-imagebuilder-mediatek-filogic.Linux-x86_64"
IB_URL="https://dl.openwrt.ai/releases/${KWRT_REL}/targets/mediatek/filogic/${IB_NAME}.tar.zst"
# 2026-11-16 上游重建了 ImageBuilder，旧 pin（65bb2db7...）已失效。
# 当前值来自与上游 content-length 完全一致的完整下载（684559760 字节）。
IB_SHA256="d7011488694eefb9232bbef44627c35f1b15953631bd430a9b19b4a7a72af18f"
PROFILE="cudy_tr3000-mod"
TARGET="mediatek_filogic"

WORK="${WORK:-/data/home/fwbuild}"
REPO="$WORK/repo"
OUT="$WORK/out"

# 关键：测试硬编码了 /tmp/.*runtime.yaml，TMPDIR 必须是 /tmp
export TMPDIR=/tmp

mkdir -p "$WORK" "$OUT"
cd "$WORK"

echo "=== [1/8] 检查仓库 ==="
test -f "$REPO/devices/$TARGET/packages.txt" || { echo "缺少仓库: $REPO"; exit 1; }
echo "包清单: $(grep -cvE '^\s*(#|$)' "$REPO/devices/$TARGET/packages.txt") 项"
echo "本地包: $(ls "$REPO/devices/$TARGET/local-packages/"*.ipk 2>/dev/null | wc -l) 个"

echo "=== [2/8] 依赖 ==="
for t in tar make curl sha256sum unzstd; do
  command -v "$t" >/dev/null || { echo "缺工具: $t"; exit 1; }
done
echo "ok"

echo "=== [3/8] 下载 ImageBuilder ==="
if [ ! -f ib.tar.zst ]; then
  curl -fL --retry 3 --progress-bar -o ib.tar.zst "$IB_URL"
fi
echo "$IB_SHA256  ib.tar.zst" | sha256sum -c -

echo "=== [4/8] 解压 ==="
if [ ! -d "$IB_NAME" ]; then
  tar --use-compress-program=unzstd -xf ib.tar.zst
fi
sed -i 's#file://www/wwwroot/dl.openwrt.ai#https://dl.openwrt.ai#' "$IB_NAME/repositories.conf"
grep -E '^src' "$IB_NAME/repositories.conf" | head -5

echo "=== [5/8] 构建 overlay（品牌 + 定制文件）==="
rm -rf /tmp/ov /tmp/brand
mkdir -p /tmp/ov /tmp/brand
cd /tmp/brand
tar -xf "$WORK/$IB_NAME"/packages/base-files_*.ipk
tar -xzf data.tar.gz ./etc/openwrt_release ./etc/banner
sed -i 's/Kwrt/TohsakaWrt/g' etc/openwrt_release etc/banner
mkdir -p /tmp/ov/etc && cp -a etc/. /tmp/ov/etc/
files_dir="$REPO/devices/$TARGET/files"
test -d "$files_dir"
cp -a "$files_dir/." /tmp/ov/
chmod +x /tmp/ov/usr/bin/* /tmp/ov/etc/init.d/* /tmp/ov/etc/hotplug.d/tty/* /tmp/ov/etc/uci-defaults/* 2>/dev/null || true
echo "overlay 文件数: $(find /tmp/ov -type f | wc -l)"

echo "=== [6/8] 本地包 ==="
local_packages_dir="$REPO/devices/$TARGET/local-packages"
if [ -d "$local_packages_dir" ]; then
  shopt -s nullglob
  ipks=("$local_packages_dir"/*.ipk)
  if ((${#ipks[@]})); then
    cp -f "${ipks[@]}" "$WORK/$IB_NAME/packages/"
    echo "注入: $(ls "${ipks[@]}" | xargs -n1 basename | tr '\n' ' ')"
  fi
fi

echo "=== [7/8] 构建镜像 ==="
cd "$WORK/$IB_NAME"
PKGS=$(grep -vE '^\s*(#|$)' "$REPO/devices/$TARGET/packages.txt" | tr '\n' ' ')
make image PROFILE="$PROFILE" PACKAGES="$PKGS" FILES="/tmp/ov" 2>&1 | tail -40

echo "=== [8/8] 收集产物 ==="
SRC="$WORK/$IB_NAME/bin/targets/mediatek/filogic"
ls -la "$SRC"
cp "$SRC"/*.bin "$SRC"/*.manifest "$SRC"/sha256sums "$OUT/" 2>/dev/null || true
echo ""
echo "=== 完成 ==="
ls -lh "$OUT"
