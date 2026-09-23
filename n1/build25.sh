#!/bin/bash

# ==============================================================================
# ImmortalWrt 25.12.x - Phicomm N1 (Fully Hardened & Fixed Build Script)
# ==============================================================================

set -e

# 1. 锁定根目录与基础变量
export IB_ROOT="/home/build/immortalwrt"
cd "$IB_ROOT"

export PROFILE="${PROFILE:-generic}"
if [ -z "${KERNEL_PATCHVER}" ] && [ -n "${OPENWRT_KERNEL}" ]; then
    export KERNEL_PATCHVER=$(echo "${OPENWRT_KERNEL}" | cut -d. -f1,2)
else
    export KERNEL_PATCHVER="${KERNEL_PATCHVER:-6.6}"
fi

echo "============================================================"
echo "🎯 [INIT] 开始初始化 ImmortalWrt 25.12.x N1 构建环境"
echo "   - IB_ROOT         = $IB_ROOT"
echo "   - PROFILE         = $PROFILE"
echo "   - KERNEL_PATCHVER = $KERNEL_PATCHVER"
echo "   - ROOTFS_PARTSIZE = $ROOTFS_PARTSIZE"
echo "============================================================"

# 2. 提前在绝对路径下修复 ImageBuilder 的内核版本映射文件（根除 target.mk 报错）
echo "🛠️ 正在检查并修复内核版本映射文件..."
TARGET_GENERIC_DIR="$IB_ROOT/target/linux/generic"
if [ -d "$TARGET_GENERIC_DIR" ]; then
    if [ ! -f "$TARGET_GENERIC_DIR/kernel-${KERNEL_PATCHVER}" ]; then
        FOUND_KERNEL_FILE=$(ls "$TARGET_GENERIC_DIR"/kernel-${KERNEL_PATCHVER}.* 2>/dev/null | head -n 1 || true)
        if [ -n "${FOUND_KERNEL_FILE}" ]; then
            echo "   -> 找到匹配内核文件: $(basename "$FOUND_KERNEL_FILE")，建立软链接..."
            ln -sf "$(basename "$FOUND_KERNEL_FILE")" "$TARGET_GENERIC_DIR/kernel-${KERNEL_PATCHVER}"
        else
            echo "LINUX_VERSION=${OPENWRT_KERNEL:-6.6.0}" > "$TARGET_GENERIC_DIR/kernel-${KERNEL_PATCHVER}"
            echo "LINUX_KERNEL_HASH=x" >> "$TARGET_GENERIC_DIR/kernel-${KERNEL_PATCHVER}"
            echo "   ⚠️ 已自动生成 kernel-${KERNEL_PATCHVER} 占位文件"
        fi
    fi
else
    echo "⚠️ 警告: 未找到 $TARGET_GENERIC_DIR 目录，跳过内核文件补全。"
fi

# 3. 加载第三方 APK 软件包选择
if [ -f "shell/apk-custom-packages.sh" ]; then
    source shell/apk-custom-packages.sh
fi
echo "📦 第三方 APK 软件包: $CUSTOM_PACKAGES"

LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting N1 25.12 build at $(date)" >> "$LOGFILE"

# 4. 基础软件包组合
PACKAGES=""
PACKAGES="$PACKAGES curl fdisk"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-filebrowser-go-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 5. Docker 支持
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "✅ 已选择 Docker: luci-i18n-dockerman-zh-cn"
fi

# 6. Phicomm N1 WiFi & 硬件驱动
PACKAGES="$PACKAGES kmod-brcmfmac wpad-basic-mbedtls iw iwinfo"
PACKAGES="$PACKAGES perlbase-base perlbase-file perlbase-time perlbase-utf8 perlbase-xsloader"

# 7. Amlogic / 晶晨宝盒
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-amlogic luci-i18n-amlogic-zh-cn"

# 8. 同步第三方 APK 软件仓库
if [ -z "$CUSTOM_PACKAGES" ]; then
    echo "⚪️ 未选择任何第三方 APK 软件包"
else
    echo "🔄 正在同步第三方 APK 软件仓库..."
    rm -rf /tmp/store-apk-repo
    git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

    mkdir -p "$IB_ROOT/extra-packages"
    cp -r /tmp/store-apk-repo/run/arm64/* "$IB_ROOT/extra-packages/"
    echo "✅ APK / RUN 文件已复制到 extra-packages"

    if [ -f "shell/apk-prepare-packages.sh" ]; then
        sh shell/apk-prepare-packages.sh
    fi
    echo "=== APK packages ==="
    ls -lah "$IB_ROOT/packages/" || true
fi

# 9. 架构优先级配置
if [ -f "repositories.conf" ]; then
    if ! grep -q '^arch aarch64_generic ' repositories.conf; then
        sed -i '1i\
arch aarch64_generic 10\
arch aarch64_cortex-a53 15' repositories.conf
    fi
fi

# 10. 合并自定义包
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 11. OpenClash 核心与插件处理
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 OpenClash core"
    mkdir -p files/etc/openclash/core

    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
    wget -qO- "$META_URL" | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta

    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat

    URL=$(curl -fsSL https://api.github.com/repos/vernesong/OpenClash/releases/latest | grep 'browser_download_url.*apk' | head -n1 | cut -d '"' -f 4)
    if [ -z "$URL" ]; then
        echo "❌ 无法取得 OpenClash APK 下载地址"
        exit 1
    fi
    wget "$URL" -P "$IB_ROOT/packages/"
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 12. SSR Plus / Mihomo 处理
if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-arm64-v1.19.24.gz"
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# 13. 执行最终镜像编译 (强制锁定绝对路径与 TOPDIR，杜绝 Makefile 丢失错误)
echo "============================================================"
echo "🚀 开始构建 ImmortalWrt 25.12.x N1 镜像..."
echo "============================================================"

make image \
    TOPDIR="$IB_ROOT" \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGES" \
    FILES="$IB_ROOT/files" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"

echo "============================================================"
echo "✅ ImmortalWrt 25.12.x N1 build completed successfully."
echo "============================================================"
