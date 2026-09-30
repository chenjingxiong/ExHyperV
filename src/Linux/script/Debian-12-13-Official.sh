#!/bin/bash
# @Name: Debian-12-13-Official
# @Description: Debian 12/13: CUDA√ Mesa-d3d12√ (Vulkan 需 Mesa 24+)
# @Author: chenjingxiong
# @Version: 1.0.0

set -e

# ---------- 参数与运行环境 ----------
ACTION=${1:-"deploy"}
ENABLE_GRAPHICS=${2:-"true"}
PROXY_URL=${3:-""}

# ExHyperV 通过 sudo -S 以 root 运行本脚本；手工执行时自动提权。
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
fi

MACHINE_ARCH=$(uname -m)
case "$MACHINE_ARCH" in
    x86_64)
        ARCH_DIR="x64"
        ;;
    aarch64|arm64)
        ARCH_DIR="arm64"
        ;;
    *)
        echo "[ERROR] Unsupported architecture: $MACHINE_ARCH"
        exit 1
        ;;
esac

KERNEL="$(uname -r)"
DEPLOY_DIR="$(dirname "$(realpath "$0")")"
LIB_DIR="$DEPLOY_DIR/lib"
GITHUB_LIB_URL="https://raw.githubusercontent.com/Justsenger/ExHyperV/main/src/Linux/lib/$ARCH_DIR"
ASSETS_BASE_URL="https://raw.githubusercontent.com/Justsenger/ExHyperV/kernel-assets"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

retry_cmd() {
    local n=1
    local max=5
    local delay=5
    while true; do
        if "$@"; then
            break
        else
            if [ $n -lt $max ]; then
                log " -> [WARNING] 命令执行失败，等待 $delay 秒后进行第 $n 次重试: $*"
                sleep $delay
                n=$((n + 1))
            else
                log " -> [ERROR] 已达到最大重试次数 ($max)，执行失败: $*"
                return 1
            fi
        fi
    done
}

# 更新 /etc/environment 中的环境变量（PAM 级别，对 systemd 服务外的登录会话生效）
update_env() {
    local key=$1
    local val=$2
    sed -i "/^$key=/d" /etc/environment
    echo "$key=$val" >> /etc/environment
}

if [ -n "$PROXY_URL" ]; then
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    log "[+] Using proxy: $PROXY_URL"
fi

# ---------- 发行版检查 ----------
if [ -r /etc/os-release ]; then
    . /etc/os-release
    log "[+] Detected OS: ${PRETTY_NAME:-unknown} (ID=${ID:-unknown}, kernel $KERNEL)"
    case "${ID:-}" in
        debian|pve)
            ;;
        ubuntu)
            log "[ERROR] 这是 Ubuntu 系统，请改用 Ubuntu 官方脚本。"
            exit 1
            ;;
        *)
            log "[WARNING] 未经测试的发行版 (ID=${ID:-unknown})，按 Debian 兼容流程继续..."
            ;;
    esac
else
    log "[WARNING] /etc/os-release 不存在，无法识别发行版，按 Debian 兼容流程继续..."
fi

# ---------- 依赖安装 ----------
echo "[STEP: Installing basic dependencies...]"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget ca-certificates unzip kmod \
    dkms build-essential \
    bc bison flex libelf-dev libssl-dev zlib1g-dev dwarves

# ---------- 内核头文件 ----------
echo "[STEP: Checking Kernel Headers...]"
if [ ! -e "/lib/modules/$KERNEL/build" ]; then
    log " -> Kernel headers not found for $KERNEL. Attempting installation..."
    if ! apt-get install -y -qq "linux-headers-$KERNEL"; then
        # 当前内核的精确 headers 包不在源里（例如装完系统后内核已升级），
        # 改装发行版当前内核 + 配套头文件并要求重启。
        case "$KERNEL" in
            *cloud*) FLAVOR="cloud-amd64" ;;
            *)       FLAVOR="amd64" ;;
        esac
        log " -> Exact header package unavailable. Installing linux-image-$FLAVOR + linux-headers-$FLAVOR ..."
        apt-get install -y -qq "linux-image-$FLAVOR" "linux-headers-$FLAVOR"
        echo "[STATUS: REBOOT_REQUIRED]"
        exit 0
    fi
fi

# ---------- dxgkrnl 模块编译与安装 ----------
# modinfo 按"当前运行内核"解析模块路径：模块已在且属于当前内核时跳过重复编译，
# 内核升级后旧 dkms 记录不再命中、会走重编译分支。
MODULE_PATH="$(modinfo -n dxgkrnl 2>/dev/null || true)"
if lsmod | grep -q dxgkrnl || { [ -n "$MODULE_PATH" ] && [ -e "$MODULE_PATH" ]; }; then
    log " -> dxgkrnl is already installed or loaded."
else
    echo "[STEP: Preparing Pre-patched Source...]"
    KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1)
    KERNEL_MINOR=$(echo "$KERNEL" | cut -d. -f2)

    if [ "$KERNEL_MAJOR" -eq 5 ]; then
        PKG_VER="5.15"
    elif [ "$KERNEL_MAJOR" -eq 6 ] && [ "$KERNEL_MINOR" -le 6 ]; then
        PKG_VER="6.6"
    else
        # 6.7+（Debian 13 的 6.12 等）统一使用 6.12 适配包
        PKG_VER="6.12"
    fi

    PKG="dxgkrnl-${PKG_VER}-patched"
    log " -> Detected Kernel $KERNEL, using pre-patched assets: $PKG"

    rm -rf /tmp/kernel_src.tar.gz "/tmp/$PKG"

    ZIP_URL="$ASSETS_BASE_URL/$PKG.tar.gz"
    log " -> Downloading from: $ZIP_URL"
    retry_cmd curl -fL --connect-timeout 20 -o /tmp/kernel_src.tar.gz "$ZIP_URL"

    tar -xzf /tmp/kernel_src.tar.gz -C /tmp/

    VERSION="custom"
    dkms remove -m dxgkrnl -v "$VERSION" --all >/dev/null 2>&1 || true
    rm -rf "/usr/src/dxgkrnl-$VERSION"
    cp -r "/tmp/$PKG" "/usr/src/dxgkrnl-$VERSION"

    echo "[STEP: Compiling and Installing DXG Module...]"

    # 覆写为独立外置模块 Makefile：原包为 CONFIG_DXGKRNL 条件编译，外置构建时该
    # 配置未定义会导致 obj- 展开为空、什么都不编译。
    cat > "/usr/src/dxgkrnl-$VERSION/Makefile" <<'EOF'
obj-m := dxgkrnl.o
dxgkrnl-y := dxgmodule.o hmgr.o misc.o dxgadapter.o ioctl.o dxgvmbus.o dxgprocess.o dxgsyncfile.o
ccflags-y := -I$(src)/include -D_MAIN_KERNEL_

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules
clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
EOF

    cat > "/usr/src/dxgkrnl-$VERSION/dkms.conf" <<EOF
PACKAGE_NAME="dxgkrnl"
PACKAGE_VERSION="$VERSION"
BUILT_MODULE_NAME="dxgkrnl"
DEST_MODULE_LOCATION="/kernel/drivers/hv/dxgkrnl/"
AUTOINSTALL="yes"
EOF

    dkms add -m dxgkrnl -v "$VERSION"

    log " -> Building dxgkrnl module for kernel $KERNEL ..."
    if ! dkms build -m dxgkrnl -v "$VERSION" -k "$KERNEL"; then
        # 把 make.log 尾部直接吐回部署控制台，方便远程定位编译错误
        BUILD_LOG="/var/lib/dkms/dxgkrnl/$VERSION/build/make.log"
        log " -> [ERROR] dkms build failed for kernel $KERNEL"
        if [ -f "$BUILD_LOG" ]; then
            log " -> ---- make.log (last 120 lines) ----"
            tail -n 120 "$BUILD_LOG"
            log " -> ---- end of make.log ----"
        else
            log " -> make.log not found at $BUILD_LOG"
        fi
        exit 1
    fi

    dkms install -m dxgkrnl -v "$VERSION" -k "$KERNEL" --force
fi

echo "[STEP: Testing module load...]"
if ! modprobe dxgkrnl 2>/dev/null; then
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
        log " -> [WARNING] 模块加载失败：虚拟机开启了 Secure Boot，未签名模块无法加载。请关闭虚拟机 Secure Boot 后重试。"
    else
        log " -> [WARNING] dxgkrnl could not be loaded. Check dmesg for details."
    fi
fi

# ---------- 图形栈配置（Debian 仓库版 Mesa，无 PPA） ----------
if [ "$ENABLE_GRAPHICS" == "true" ]; then
    echo "[STEP: Configuring Graphics Stack...]"
    # Debian 12 (Mesa 22.3) 起仓库 Mesa 自带 d3d12 Gallium OpenGL 驱动；
    # Vulkan 的 d3d12 后端 (dozen) 需要 Mesa 24+ (Debian 13 backports 起)。
    apt-get install -y -qq mesa-utils vulkan-tools mesa-vulkan-drivers mesa-va-drivers vainfo
    log " -> Installed Mesa: $(dpkg-query -W -f='${Version}' libgl1-mesa-dri 2>/dev/null || echo unknown)"
fi

# ---------- WSL 核心库部署 ----------
echo "[STEP: Deploying WSL Core Libraries...]"
LIBS=("libd3d12.so" "libd3d12core.so" "libdxcore.so")
mkdir -p "$LIB_DIR"
for lib in "${LIBS[@]}"; do
    if [ ! -f "$LIB_DIR/$lib" ]; then
        log " -> $lib not found locally, downloading for $ARCH_DIR..."
        if ! retry_cmd curl -fL --connect-timeout 20 -o "$LIB_DIR/$lib" "$GITHUB_LIB_URL/$lib"; then
            log " -> [ERROR] Failed to download $lib from $GITHUB_LIB_URL/$lib"
            exit 1
        fi
    fi
done

if [ -f "$LIB_DIR/nvidia-smi" ]; then
    log "[+] Found nvidia-smi uploaded from host, deploying to /usr/bin..."
    cp "$LIB_DIR/nvidia-smi" /usr/bin/nvidia-smi
    chmod 755 /usr/bin/nvidia-smi
fi

rm -rf /usr/lib/wsl/lib
mkdir -p /usr/lib/wsl/lib
if ls "$LIB_DIR"/*.so* >/dev/null 2>&1; then
    cp -a "$LIB_DIR"/*.so* /usr/lib/wsl/lib/
fi
ln -sf /usr/lib/wsl/lib/libd3d12core.so /usr/lib/wsl/lib/libD3D12Core.so
chmod -R 0555 /usr/lib/wsl
chown -R root:root /usr/lib/wsl

# 部分程序硬编码系统库路径查找 libcuda，补一组常规路径符号链接
if [ "$MACHINE_ARCH" == "x86_64" ] && [ -e /usr/lib/wsl/lib/libcuda.so.1 ]; then
    mkdir -p /usr/lib/x86_64-linux-gnu
    ln -sf /usr/lib/wsl/lib/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so.1
    ln -sf /usr/lib/x86_64-linux-gnu/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so
fi

echo "/usr/lib/wsl/lib" > /etc/ld.so.conf.d/ld.wsl.conf
ldconfig

# ---------- 内核模块加载策略（vgem + dxgkrnl 延迟加载） ----------
echo "[STEP: Configuring Kernel Modules Strategy (vgem & dxgkrnl)...]"

echo "vgem" > /etc/modules-load.d/vgem.conf
modprobe vgem 2>/dev/null || true

# dxgkrnl 延后加载以避免启动冲突（显式 modprobe 不受 blacklist 影响）。
echo "blacklist dxgkrnl" > /etc/modprobe.d/blacklist-dxgkrnl.conf

update-initramfs -u

cat > /usr/local/bin/load_dxg_driver.sh <<'EOF'
#!/bin/bash
modprobe dxgkrnl 2>/dev/null || true
if [ -e /dev/dxg ]; then
    chmod 666 /dev/dxg
fi
# Hyper-V 的虚拟显卡通常是 card1，但很多旧程序只认 card0
if [ -e /dev/dri/card1 ] && [ ! -e /dev/dri/card0 ]; then
    ln -sf /dev/dri/card1 /dev/dri/card0
fi
exit 0
EOF
chmod +x /usr/local/bin/load_dxg_driver.sh

systemctl stop load-dxg-late.service 2>/dev/null || true
systemctl disable load-dxg-late.service 2>/dev/null || true
rm -f /etc/systemd/system/load-dxg-late.service

cat > /etc/systemd/system/load-dxg-late.service <<'EOF'
[Unit]
Description=Late load dxgkrnl
After=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/load_dxg_driver.sh
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl unmask load-dxg-late.service 2>/dev/null || true
systemctl enable load-dxg-late.service
systemctl start load-dxg-late.service

# ---------- 环境变量与权限 ----------
if [ "$ENABLE_GRAPHICS" == "true" ]; then
    echo "[STEP: Finalizing environment variables...]"
    # Gallium D3D12 后端配置
    update_env "GALLIUM_DRIVER" "d3d12"
    update_env "DRI_PRIME" "1"
    update_env "LIBVA_DRIVER_NAME" "d3d12"

    cat > /etc/profile.d/gpu-pv-d3d12.sh <<'EOF'
# GPU-PV Configuration (ExHyperV)
export GALLIUM_DRIVER=d3d12
export DRI_PRIME=1
export LIBVA_DRIVER_NAME=d3d12
EOF
    chmod 644 /etc/profile.d/gpu-pv-d3d12.sh

    # 授予发起部署的 SSH 用户渲染权限（脚本以 root 运行，$USER 是 root）
    TARGET_USER="${SUDO_USER:-}"
    if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] && id "$TARGET_USER" >/dev/null 2>&1; then
        usermod -a -G video,render "$TARGET_USER"
    fi

    chmod 666 /dev/dri/* 2>/dev/null || true
    if [ -e /dev/dri/card1 ] && [ ! -e /dev/dri/card0 ]; then
        ln -sf /dev/dri/card1 /dev/dri/card0
    fi
fi

# ---------- 最终验证与清理 ----------
echo "[STEP: Final verification...]"
if [ -e /dev/dxg ]; then
    log "[+] /dev/dxg is present."
else
    log " -> /dev/dxg not found. 确认虚拟机已挂载 GPU-PV 分区后重启虚拟机。"
fi
lsmod | grep -E 'dxgkrnl|vgem' || true
ldconfig -p 2>/dev/null | grep -E 'libcuda|libdxcore|libd3d12' || true

echo "[STEP: Cleaning up deployment files...]"
cd /
rm -rf "$DEPLOY_DIR"

echo "[STATUS: SUCCESS]"
