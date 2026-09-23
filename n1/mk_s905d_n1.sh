#!/bin/bash

echo "========================= begin $0 ==========================="
source make.env
source public_funcs
init_work_env

# ==============================================================================
# 【新增修复】防止底层 make 调用时因为变量丢失导致的 /Makefile 找不到错误
# ==============================================================================
if [ -n "$IB_ROOT" ]; then
    export TOPDIR="$IB_ROOT"
elif [ -d "/home/build/immortalwrt" ]; then
    export TOPDIR="/home/build/immortalwrt"
else
    export TOPDIR="$(pwd)"
fi
# ==============================================================================

# 盒子型号识别参数
PLATFORM=amlogic
SOC=s905d
BOARD=n1

# 让N1一直有wifi可用，以减少抱怨
# 5.10(及以上)内核是否启用wifi  1:启用 0:禁用
ENABLE_WIFI_K510=0

SUBVER=$1

# Kernel image sources
###################################################################
KERNEL_TAGS="stable"
KERNEL_BRANCHES="mainline:all:>=:5.4"
MODULES_TGZ=${KERNEL_PKG_HOME}/modules-${KERNEL_VERSION}.tar.gz
check_file ${MODULES_TGZ}
BOOT_TGZ=${KERNEL_PKG_HOME}/boot-${KERNEL_VERSION}.tar.gz
check_file ${BOOT_TGZ}
DTBS_TGZ=${KERNEL_PKG_HOME}/dtb-amlogic-${KERNEL_VERSION}.tar.gz
check_file ${DTBS_TGZ}
K510=$(get_k510_from_boot_tgz "${BOOT_TGZ}" "vmlinuz-${KERNEL_VERSION}")
export K510
###########################################################################

# Openwrt root 源文件
OPWRT_ROOTFS_GZ=$(get_openwrt_rootfs_archive ${PWD})
check_file ${OPWRT_ROOTFS_GZ}
echo "Use $OPWRT_ROOTFS_GZ as openwrt rootfs!"

# 目标镜像文件
TGT_IMG="${WORK_DIR}/openwrt_${SOC}_${BOARD}_${OPENWRT_VER}_k${KERNEL_VERSION}${SUBVER}.img"

# 补丁和脚本
###########################################################################
KMOD="${PWD}/files/kmod"
KMOD_BLACKLIST="${PWD}/files/kmod_blacklist"
CPUSTAT_SCRIPT="${PWD}/files/cpustat"
CPUSTAT_SCRIPT_PY="${PWD}/files/cpustat.py"
GETCPU_SCRIPT="${PWD}/files/getcpu"
FLIPPY="${PWD}/files/scripts_deprecated/flippy_cn"
BANNER="${PWD}/files/banner"

FMW_HOME="${PWD}/files/firmware"
SMB4_PATCH="${PWD}/files/smb4.11_enable_smb1.patch"
SYSCTL_CUSTOM_CONF="${PWD}/files/99-custom.conf"

BAL_ETH_IRQ="${PWD}/files/balethirq.pl"
FIX_CPU_FREQ="${PWD}/files/fixcpufreq.pl"
SYSFIXTIME_PATCH="${PWD}/files/sysfixtime.patch"

BAL_CONFIG="${PWD}/files/s905d/balance_irq"
CPUFREQ_INIT="${PWD}/files/s905d/cpufreq"

FIP_HOME="${PWD}/files/meson_btld/with_fip/s905d"
UBOOT_WITH_FIP="${FIP_HOME}/n1-u-boot.bin.sd.bin"
UBOOT_WITHOUT_FIP_HOME="${PWD}/files/meson_btld/without_fip"
UBOOT_WITHOUT_FIP="u-boot-n1.bin"

FIRMWARE_TXZ="${PWD}/files/firmware_armbian.tar.xz"
BOOTFILES_HOME="${PWD}/files/bootfiles/amlogic"
GET_RANDOM_MAC="${PWD}/files/get_random_mac.sh"

SYSINFO_SCRIPT="${PWD}/files/30-sysinfo.sh"

OPENWRT_INSTALL="${PWD}/files/openwrt-install-amlogic"
OPENWRT_UPDATE="${PWD}/files/openwrt-update-amlogic"
OPENWRT_KERNEL="${PWD}/files/openwrt-kernel"
OPENWRT_BACKUP="${PWD}/files/openwrt-backup"

FIRSTRUN_SCRIPT="${PWD}/files/first_run.sh"
BTLD_BIN="${PWD}/files/s905d/u-boot-2015-phicomm-n1.bin"
MODEL_DB="${PWD}/files/amlogic_model_database.txt"
DDBR="${PWD}/files/openwrt-ddbr"
###########################################################################

check_depends

SKIP_MB=4
BOOT_MB=256
ROOTFS_MB=960
SIZE=$((SKIP_MB + BOOT_MB + ROOTFS_MB))
create_image "$TGT_IMG" "$SIZE"
create_partition "$TGT_DEV" "msdos" "$SKIP_MB" "$BOOT_MB" "fat32" "0" "-1" "btrfs"
make_filesystem "$TGT_DEV" "B" "fat32" "BOOT" "R" "btrfs" "ROOTFS"
mount_fs "${TGT_DEV}p1" "${TGT_BOOT}" "vfat"
mount_fs "${TGT_DEV}p2" "${TGT_ROOT}" "btrfs" "compress=zstd:${ZSTD_LEVEL}"
echo "创建 /etc 子卷 ..."
btrfs subvolume create $TGT_ROOT/etc
extract_rootfs_files
extract_amlogic_boot_files

echo "修改引导分区相关配置 ... "
cd $TGT_BOOT
rm -f uEnv.ini
cat >uEnv.txt <<EOF
LINUX=/zImage
INITRD=/uInitrd

# 用于 Phicomm N1
FDT=/dtb/amlogic/meson-gxl-s905d-phicomm-n1.dtb

APPEND=root=UUID=${ROOTFS_UUID} rootfstype=btrfs rootflags=compress=zstd:${ZSTD_LEVEL} console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
EOF

echo "uEnv.txt -->"
echo "==============================================================================="
cat uEnv.txt
echo "==============================================================================="
echo

echo "修改根文件系统相关配置 ... "
cd $TGT_ROOT
copy_supplement_files
adjust_getty_config
create_fstab_config
adjust_kernel_env
copy_uboot_to_fs
write_release_info
write_banner
config_first_run
create_snapshot "etc-000"
write_uboot_to_disk
clean_work_env
mv ${TGT_IMG} ${OUTPUT_DIR} && sync
echo "镜像已生成! 存放在 ${OUTPUT_DIR} 下面!"
echo "========================== end $0 ================================"
echo
