#!/bin/bash

# ImmortalWrt 25.12.x - Phicomm N1
# Based on the existing N1 24.x build logic.
#
# 重要原则：
#   - N1 硬件相关逻辑沿用 24.x
#   - BCM43455 / Amlogic 相关包保持不变
#   - 仅将 24.x 的 IPK 第三方包流程切换为 25.12 APK 流程
#   - PROFILE / ROOTFS_PARTSIZE / INCLUDE_DOCKER 等继续由 GitHub Actions 传入

set -e

# ==============================================================================
# 0. 自动对齐 KERNEL_PATCHVER 与 PROFILE（修复 ImageBuilder 内核匹配报错的关键）
# ==============================================================================
if [ -z "${KERNEL_PATCHVER}" ] && [ -n "${OPENWRT_KERNEL}" ]; then
    export KERNEL_PATCHVER=$(echo "${OPENWRT_KERNEL}" | cut -d. -f1,2)
fi
export PROFILE="${PROFILE:-generic}"

###############################################################################
# 1. 25.12.x APK package selection
###############################################################################

source shell/apk-custom-packages.sh

echo "第三方 APK 软件包: $CUSTOM_PACKAGES"

LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting N1 25.12 build at $(date)" >> "$LOGFILE"

###############################################################################
# 2. GitHub Actions parameters
###############################################################################

echo "Building for profile: $PROFILE"
echo "Building for ROOTFS_PARTSIZE: $ROOTFS_PARTSIZE"
echo "Building for KERNEL_PATCHVER: $KERNEL_PATCHVER"

###############################################################################
# 3. Base packages
#
# 保留 N1 24.x 原有包列表。
###############################################################################

PACKAGES=""

PACKAGES="$PACKAGES curl fdisk"

PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"

# FileBrowser
PACKAGES="$PACKAGES luci-i18n-filebrowser-go-zh-cn"

# Argon
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"

# ttyd
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"

# SSH SFTP
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

###############################################################################
# 4. Docker
#
# 保留原 N1 Actions 的 INCLUDE_DOCKER 机制。
###############################################################################

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "✅ 已选择 Docker: luci-i18n-dockerman-zh-cn"
fi

###############################################################################
# 5. Phicomm N1 WiFi
#
# 这一部分不要因为升级 25.12 而删除。
#
# N1 = BCM43455。
# 24.x 已经验证的驱动/用户空间组件继续保留。
###############################################################################

PACKAGES="$PACKAGES kmod-brcmfmac wpad-basic-mbedtls iw iwinfo"

PACKAGES="$PACKAGES perlbase-base perlbase-file perlbase-time perlbase-utf8 perlbase-xsloader"

###############################################################################
# 6. Amlogic / N1
#
# 晶晨宝盒是 N1 方案的重要组成部分，继续保留。
###############################################################################

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-amlogic luci-i18n-amlogic-zh-cn"

###############################################################################
# 7. Third-party APK repository
#
# 24.x:
#   wukongdaily/store.git
#   prepare-packages.sh
#
# 25.12:
#   wukongdaily/apk.git
#   apk-prepare-packages.sh
###############################################################################

if [ -z "$CUSTOM_PACKAGES" ]; then

    echo "⚪️ 未选择任何第三方 APK 软件包"

else

    echo "🔄 正在同步第三方 APK 软件仓库..."

    rm -rf /tmp/store-apk-repo

    git clone \
        --depth=1 \
        https://github.com/wukongdaily/apk.git \
        /tmp/store-apk-repo

    mkdir -p /home/build/immortalwrt/extra-packages

    cp -r \
        /tmp/store-apk-repo/run/arm64/* \
        /home/build/immortalwrt/extra-packages/

    echo "✅ APK / RUN 文件已复制到 extra-packages"

    # 25.12.x APK package preparation
    sh shell/apk-prepare-packages.sh

    echo "=== APK packages ==="

    ls -lah /home/build/immortalwrt/packages/ || true

fi

###############################################################################
# 8. Repository architecture priority
#
# 保留 N1 24.x 的架构优先级。
#
# N1 / S905D = Cortex-A53 / aarch64。
###############################################################################

if [ -f repositories.conf ]; then

    if ! grep -q '^arch aarch64_generic ' repositories.conf; then
        sed -i '1i\
arch aarch64_generic 10\
arch aarch64_cortex-a53 15' repositories.conf
    fi

fi

###############################################################################
# 9. Merge custom packages
###############################################################################

PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

echo "============================================================"
echo "N1 25.12 package list:"
echo "$PACKAGES"
echo "============================================================"

###############################################################################
# 10. OpenClash
#
# 25.12.x 使用 APK。
###############################################################################

if echo "$PACKAGES" | grep -q "luci-app-openclash"; then

    echo "✅ 已选择 luci-app-openclash，添加 OpenClash core"

    mkdir -p files/etc/openclash/core

    # Clash Meta core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"

    wget -qO- "$META_URL" \
        | tar xOvz \
        > files/etc/openclash/core/clash_meta

    chmod +x files/etc/openclash/core/clash_meta

    # GeoIP
    wget -q \
        https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat \
        -O files/etc/openclash/GeoIP.dat

    # GeoSite
    wget -q \
        https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat \
        -O files/etc/openclash/GeoSite.dat

    # OpenClash APK
    URL=$(
        curl -fsSL \
            https://api.github.com/repos/vernesong/OpenClash/releases/latest \
        | grep 'browser_download_url.*apk' \
        | head -n1 \
        | cut -d '"' -f 4
    )

    if [ -z "$URL" ]; then
        echo "❌ 无法取得 OpenClash APK 下载地址"
        exit 1
    fi

    echo "OpenClash APK:"
    echo "$URL"

    wget "$URL" \
        -P /home/build/immortalwrt/packages/

else

    echo "⚪️ 未选择 luci-app-openclash"

fi

###############################################################################
# 11. SSR Plus / Mihomo
#
# 保留原 N1 逻辑。
###############################################################################

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then

    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"

    mkdir -p files/usr/bin

    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-arm64-v1.19.24.gz"

    wget -qO- "$MIHOMO_URL" \
        | gzip -dc \
        > files/usr/bin/mihomo

    chmod +x files/usr/bin/mihomo

    echo "✅ 已下载 mihomo core"

    ls -lah files/usr/bin/mihomo

else

    echo "⚪️ 未选择 luci-app-ssr-plus"

fi

###############################################################################
# 11.5 自动修复 ImageBuilder 缺少 kernel-<version> 文件的兼容逻辑
###############################################################################
echo "🛠️ 正在检查并修复内核版本映射文件..."
if [ -d "target/linux/generic" ]; then
    cd target/linux/generic
    if [ ! -f "kernel-${KERNEL_PATCHVER}" ]; then
        FOUND_KERNEL_FILE=$(ls kernel-${KERNEL_PATCHVER}.* 2>/dev/null | head -n 1 || true)
        if [ -n "${FOUND_KERNEL_FILE}" ]; then
            echo "找到匹配的内核文件: ${FOUND_KERNEL_FILE}，正在为 ${KERNEL_PATCHVER} 建立软链接..."
            ln -sf "${FOUND_KERNEL_FILE}" "kernel-${KERNEL_PATCHVER}"
        else
            echo "LINUX_VERSION=${OPENWRT_KERNEL}" > "kernel-${KERNEL_PATCHVER}"
            echo "LINUX_KERNEL_HASH=x" >> "kernel-${KERNEL_PATCHVER}"
            echo "⚠️ 已自动生成 kernel-${KERNEL_PATCHVER} 占位文件"
        fi
    fi
    cd - > /dev/null
fi

###############################################################################
# 12. Build N1 image
#
# PROFILE / ROOTFS_PARTSIZE 继续由 GitHub Actions 提供。
#
# FILES 使用原 N1 24.x 的 /home/build/immortalwrt/files。
###############################################################################

echo "============================================================"
echo "开始构建 ImmortalWrt 25.12.x N1"
echo "PROFILE         = $PROFILE"
echo "ROOTFS_PARTSIZE = $ROOTFS_PARTSIZE"
echo "KERNEL_PATCHVER = $KERNEL_PATCHVER"
echo "============================================================"

make image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="/home/build/immortalwrt/files" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"

###############################################################################
# 13. Result
###############################################################################

echo "============================================================"
echo "✅ ImmortalWrt 25.12.x N1 build completed successfully."
echo "============================================================"
