#!/bin/bash
# @Name: PVE-9-Official
# @Description: Proxmox VE 9.x (内核 6.14+): CUDA√ 无图形栈
# @Author: chenjingxiong
# @Version: 1.0.0

set -e

# ---------- 参数与运行环境 ----------
ACTION=${1:-"deploy"}
ENABLE_GRAPHICS=${2:-"true"}
PROXY_URL=${3:-""}

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
        debian|pve|proxmox)
            ;;
        *)
            log "[WARNING] 未经测试的发行版 (ID=${ID:-unknown})，按 PVE 兼容流程继续..."
            ;;
    esac
else
    log "[WARNING] /etc/os-release 不存在，按 PVE 兼容流程继续..."
fi

# ---------- APT 仓库准备 ----------
# PVE 出厂默认启用企业仓库，无订阅时 apt update 会失败。切换到无订阅仓库（USTC 镜像，
# download.proxmox.com 在部分网络下不可达）。PVE 9 基于 trixie。
echo "[STEP: Preparing APT repositories...]"
PVE_MAJOR_CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-trixie}")
if [ -z "$PVE_MAJOR_CODENAME" ] || [ "$PVE_MAJOR_CODENAME" = "n/a" ]; then
    PVE_MAJOR_CODENAME="trixie"
fi

rm -f /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.sources
rm -f /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.sources
echo "deb https://mirrors.ustc.edu.cn/proxmox/debian/pve $PVE_MAJOR_CODENAME pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-no-subscription.list

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
    # PVE 内核的头文件包名为 pve-headers-<kernel>
    if ! apt-get install -y -qq "pve-headers-$KERNEL" 2>/dev/null; then
        # 精确微版本包不在源里时，安装 pve-headers 元包（当前最新内核+头文件）并要求重启
        log " -> Exact header package unavailable. Installing pve-headers (latest)..."
        apt-get install -y -qq "pve-headers"
        echo "[STATUS: REBOOT_REQUIRED]"
        exit 0
    fi
fi

# ---------- dxgkrnl 模块编译与安装 ----------
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
        # 6.7+（PVE 9 的 6.14 等）使用 6.12 适配包
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

    # 内核 6.17+（PVE 9.2）API 漂移适配：
    # - dma_fence_ops 移除了 fence_value_str/timeline_value_str 回调（旧内核上该成员可选，删除同样安全）
    # - __get_task_comm 并入 get_task_comm 两参宏
    # - __dma_fence_is_later 改为 (fence, f1, f2) 三参签名（仅 6.17+ 应用）
    log "[STEP: Patching source for kernel $KERNEL ...]"
    sed -i '/^static void dxgdmafence_value_str/,/^\}/d' "/usr/src/dxgkrnl-$VERSION/dxgsyncfile.c"
    sed -i '/^static void dxgdmafence_timeline_value_str/,/^\}/d' "/usr/src/dxgkrnl-$VERSION/dxgsyncfile.c"
    sed -i '/\.fence_value_str = /d; /\.timeline_value_str = /d' "/usr/src/dxgkrnl-$VERSION/dxgsyncfile.c"
    sed -i 's/__get_task_comm(s, WIN_MAX_PATH, current)/get_task_comm(s, current)/' "/usr/src/dxgkrnl-$VERSION/dxgvmbus.c"
    if [ "$KERNEL_MAJOR" -ge 7 ] || { [ "$KERNEL_MAJOR" -eq 6 ] && [ "$KERNEL_MINOR" -ge 17 ]; }; then
        sed -i 's/__dma_fence_is_later(syncpoint->fence_value, fence->seqno,/__dma_fence_is_later(fence, syncpoint->fence_value, fence->seqno);/' "/usr/src/dxgkrnl-$VERSION/dxgsyncfile.c"
        sed -i '/^[[:space:]]*fence->ops);$/d' "/usr/src/dxgkrnl-$VERSION/dxgsyncfile.c"
    fi

    echo "[STEP: Compiling and Installing DXG Module...]"

    # 覆写为独立外置模块 Makefile；Debian/PVE 系头文件不再传递引入
    # linux/vmalloc.h，vzalloc/vmap/vfree 隐式声明导致编译失败，强制引入
    cat > "/usr/src/dxgkrnl-$VERSION/Makefile" <<'EOF'
obj-m := dxgkrnl.o
dxgkrnl-y := dxgmodule.o hmgr.o misc.o dxgadapter.o ioctl.o dxgvmbus.o dxgprocess.o dxgsyncfile.o
ccflags-y := -I$(src)/include -D_MAIN_KERNEL_ -include linux/vmalloc.h

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
        log " -> [WARNING] 模块加载失败：虚拟机开启了 Secure Boot，未签名模块无法加载。"
    else
        log " -> [WARNING] dxgkrnl could not be loaded. Check dmesg for details."
    fi
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

# NVML/CUDA 的 lxss 加载器 shim 会到 /usr/lib/wsl/drivers/<驱动包目录>/ 加载完整版
# 用户态库，缺它则 nvidia-smi 报 Driver Not Loaded、cuInit 报 100。
echo "[STEP: Deploying WSL Driver Libraries...]"
mkdir -p /usr/lib/wsl/drivers
if [ -d "$DEPLOY_DIR/drivers" ]; then
    for pkg in "$DEPLOY_DIR/drivers"/*/; do
        if ls "$pkg"*.so* >/dev/null 2>&1 || [ -f "$pkg/nvcubins.bin" ]; then
            cp -a "$pkg" /usr/lib/wsl/drivers/
        fi
    done
fi

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

echo "blacklist dxgkrnl" > /etc/modprobe.d/blacklist-dxgkrnl.conf

cat > /usr/local/bin/load_dxg_driver.sh <<'EOF'
#!/bin/bash
modprobe dxgkrnl 2>/dev/null || true
if [ -e /dev/dxg ]; then
    chmod 666 /dev/dxg
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
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/load_dxg_driver.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable load-dxg-late.service
systemctl start load-dxg-late.service

# ---------- 最终验证与清理 ----------
echo "[STEP: Final verification...]"
if [ -e /dev/dxg ]; then
    log "[+] /dev/dxg is present."
else
    log " -> /dev/dxg not found. 确认虚拟机已挂载 GPU-PV 分区后重启虚拟机。"
fi
lsmod | grep -E 'dxgkrnl|vgem' || true
ldconfig -p 2>/dev/null | grep -E 'libnvidia-ml|libdxcore' || true

echo "[STEP: Cleaning up deployment files...]"
cd /
rm -rf "$DEPLOY_DIR"

echo "[STATUS: SUCCESS]"
