#!/bin/bash

# ==============================================================================
# ImmortalWrt 25.12.x - Phicomm N1 (Environment-Adaptive Build Script)
# ==============================================================================

set -e

# 1. 动态智能寻找 ImageBuilder 根目录（兼容本地 /home/build 及 GitHub Actions 任意工作目录）
# 优先检查环境变量 IB_ROOT，其次检查当前目录，最后向下搜索包含 Makefile 的目录
if [ -n "$IB_ROOT" ] && [ -f "$IB_ROOT/Makefile" ]; then
    TARGET_DIR="$IB_ROOT"
elif [ -f "$(pwd)/Makefile" ]; then
    TARGET_DIR="$(pwd)"
else
    # 尝试在常见的几个候选路径中寻找
    for candidate in "/home/build/immortalwrt" "./ib_dir" "$(pwd)/ib_dir" "$(pwd)"; do
        if [ -d "$candidate" ] && [ -f "$candidate/Makefile" ]; then
            TARGET_DIR="$candidate"
            break
        fi
    done
fi

# 如果还没找到，用 find 在当前目录及上级目录深度查找
if [ -z "$TARGET_DIR" ] || [ ! -f "$TARGET_DIR/Makefile" ]; then
    echo "⚠️ 未能直接定位 Makefile，正在全盘搜索 ImageBuilder 根目录..."
    FOUND_MAKEFILE=$(find . -maxdepth 3 -name "Makefile" 2>/dev/null | head -n 1)
    if [ -n "$FOUND_MAKEFILE" ]; then
        TARGET_DIR="$(dirname "$(realpath "$FOUND_MAKEFILE")")"
    else
        # 终极兜底：检查 /home/runner 下的解压目录
        RUNNER_IB=$(find /home/runner -maxdepth 4 -name "Makefile" 2>/dev/null | head -n 1 || true)
        if [ -n "$RUNNER_IB" ]; then
            TARGET_DIR="$(dirname "$RUNNER_IB")"
        else
            echo "❌ 错误: 无论在本地还是 CI 环境中，都找不到包含 Makefile 的 ImageBuilder 目录！"
            exit 1
        fi
    fi
fi

export IB_ROOT="$(realpath "$TARGET_DIR")"
cd "$IB_ROOT"
echo "📂 成功锁定 ImageBuilder 根目录: $(pwd)"

# 2. 环境变量初始化
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

# 3. 修复 ImageBuilder 内核版本映射文件
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
fi

# 4. 加载第三方 APK 软件包选择
if [ -f "shell/apk-custom-packages.sh" ]; then
    source shell/apk-custom-packages.sh
fi
echo "📦 第三方 APK 软件包: $CUSTOM_PACKAGES"

LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting N1 25.12 build at $(date)" >> "$LOGFILE"

# 5. 基础软件包组合
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

# 6. Docker 支持
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "✅ 已选择 Docker: luci-i18n-dockerman-zh-cn"
fi

# 7. Phicomm N1 WiFi & 硬件驱动
PACKAGES="$PACKAGES kmod-brcmfmac wpad-basic-mbedtls iw iwinfo"
PACKAGES="$PACKAGES perlbase-base perlbase-file perlbase-time perlbase-utf8 perlbase-xsloader"

# 8. Amlogic / 晶晨宝盒
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-amlogic luci-i18n-amlogic-zh-cn"

# 9. 同步第三方 APK 软件仓库
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

# 10. 架构优先级配置
if [ -f "repositories.conf" ]; then
    if ! grep -q '^arch aarch64_generic ' repositories.conf; then
        sed -i '1i\
arch aarch64_generic 10\
arch aarch64_cortex-a53 15' repositories.conf
    fi
fi

# 11. 合并自定义包
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 12. OpenClash 核心与插件处理
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

# 13. SSR Plus / Mihomo 处理
if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-arm64-v1.19.24.gz"
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# 14. 执行最终镜像编译（强制通过绝对路径传入 TOPDIR，确保 Makefile 能够被正常索引）
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
