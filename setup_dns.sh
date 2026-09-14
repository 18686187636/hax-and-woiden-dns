#!/bin/bash
# ================================================================
# 统一 DNS 配置脚本（全部静态方案，IPv6 优先）
# 主机名包含 "woiden" 或 "hax" → 静态 resolv.conf + 锁定
# 也可手动指定： --static
# ================================================================

set -e

# ========== DNS 配置（IPv6 优先，IPv4 作为后备） ==========
# 注意：如果主机没有 IPv6 出口，IPv6 DNS 会超时后再回落 IPv4
# 已通过 options timeout:1 attempts:1 加速回落
DNS_SERVERS_V6="2001:4860:4860::8888 2001:4860:4860::8844"
DNS_SERVERS_V4="1.1.1.1 8.8.8.8"

# ========== 颜色 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ========== 检查 root ==========
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 权限运行此脚本 (sudo)。${NC}"
    exit 1
fi

# ========== 获取主机名 ==========
HOST_NAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
echo -e "${YELLOW}检测到主机名: $HOST_NAME${NC}"

# ================================================================
# 函数：静态 resolv.conf 方案
# ================================================================
configure_static() {
    echo "=== 配置静态 DNS（锁定 /etc/resolv.conf，IPv6 优先） ==="

    # 1. 停止并禁用 systemd-resolved
    echo ">>> [1/6] 停止并禁用 systemd-resolved ..."
    if systemctl status systemd-resolved >/dev/null 2>&1; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        echo "    systemd-resolved 已停止并禁用。"
    else
        echo "    systemd-resolved 未运行，跳过。"
    fi

    # 2. 禁用可能覆盖 DNS 的服务
    echo ">>> [2/6] 禁用可能覆盖 DNS 的服务 ..."
    systemctl disable --now resolvconf 2>/dev/null || true
    systemctl mask resolvconf 2>/dev/null || true

    mkdir -p /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
    echo "    resolvconf / cloud-init 网络配置已处理。"

    # 3. 解除文件锁定（如果之前锁过）
    echo ">>> [3/6] 解除 /etc/resolv.conf 锁定（如果存在）..."
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # 4. 删除旧文件并写入 DNS
    echo ">>> [4/6] 写入 DNS 到 /etc/resolv.conf ..."
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    elif [ -f /etc/resolv.conf ]; then
        mv /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s) 2>/dev/null || true
    fi

    > /etc/resolv.conf
    # 先写 IPv6 DNS
    for dns in $DNS_SERVERS_V6; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    # 再写 IPv4 DNS 作为后备
    for dns in $DNS_SERVERS_V4; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    # 加速 IPv6 不可达时的回落
    echo "options timeout:1 attempts:1 rotate" >> /etc/resolv.conf

    echo "    写入完成，内容如下："
    cat /etc/resolv.conf

    # 5. 锁定文件
    echo ">>> [5/6] 锁定 /etc/resolv.conf（不可变属性）..."
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "    文件已锁定。"

    # 6. 验证解析
    echo ">>> [6/6] 测试 DNS 解析（google.com）..."
    if ping -c 2 google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 解析成功：${NC}"
        ping -c 2 google.com | head -5
    else
        echo -e "${RED}⚠️  解析失败，请检查网络连通性。${NC}"
    fi

    echo ""
    echo "=== 当前 /etc/resolv.conf 内容 ==="
    cat /etc/resolv.conf
    echo ""
    echo "=== 文件锁定状态 ==="
    lsattr /etc/resolv.conf 2>/dev/null | grep -i "i" || echo "未锁定（异常）"
    echo ""
    echo -e "${GREEN}✅ 静态 DNS 配置完成！${NC}"
    echo "如需修改，请先执行： chattr -i /etc/resolv.conf"
}

# ================================================================
# 主逻辑
# ================================================================
if [ "$1" = "--static" ]; then
    echo -e "${YELLOW}强制使用静态方案。${NC}"
    configure_static
    exit 0
fi

HOST_LOWER=$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')
if [[ "$HOST_LOWER" == *woiden* ]]; then
    echo -e "${YELLOW}检测到 woiden 主机，执行静态方案。${NC}"
    configure_static
elif [[ "$HOST_LOWER" == *hax* ]]; then
    echo -e "${YELLOW}检测到 hax 主机，执行静态方案。${NC}"
    configure_static
else
    echo -e "${RED}无法自动识别主机类型。请使用 --static 参数手动指定。${NC}"
    echo "用法: $0 [--static]"
    exit 1
fi
