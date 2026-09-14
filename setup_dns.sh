#!/bin/bash
# ================================================================
# 统一 DNS 配置脚本（增强版）
# 根据主机名自动选择方案：
#   - 主机名包含 "woiden" → 静态 resolv.conf + 锁定
#   - 主机名包含 "hax"   → systemd-resolved 方案（全面防覆盖）
# 也可通过命令行参数强制指定： --static 或 --resolved
# ================================================================

set -e

# ========== 可自定义 DNS ==========
# 建议同时配置 IPv4 和 IPv6，避免只有 IPv6 时解析失败
DNS_SERVERS="8.8.8.8 1.1.1.1 2001:4860:4860::8888 2001:4860:4860::8844"
FALLBACK_DNS="8.8.4.4 1.0.0.1 2001:4860:4860::8844"

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
# 函数：静态 resolv.conf 方案（用于 woiden）
# ================================================================
configure_static() {
    echo "=== 配置静态 DNS（锁定 /etc/resolv.conf） ==="

    # 1. 停止并禁用 systemd-resolved
    echo ">>> [1/5] 停止并禁用 systemd-resolved..."
    if systemctl status systemd-resolved >/dev/null 2>&1; then
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        echo "    systemd-resolved 已停止并禁用。"
    else
        echo "    systemd-resolved 未运行，跳过。"
    fi

    # 2. 删除现有 /etc/resolv.conf
    echo ">>> [2/5] 删除现有 /etc/resolv.conf..."
    rm -f /etc/resolv.conf
    echo "    已删除（如果存在）。"

    # 3. 写入自定义 DNS
    echo ">>> [3/5] 写入 DNS 到 /etc/resolv.conf ..."
    > /etc/resolv.conf
    for dns in $DNS_SERVERS; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    echo "    写入完成，内容如下："
    cat /etc/resolv.conf

    # 4. 锁定文件
    echo ">>> [4/5] 锁定 /etc/resolv.conf（不可变属性）..."
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "    文件已锁定。"

    # 5. 验证解析
    echo ">>> [5/5] 测试 DNS 解析（google.com）..."
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
# 函数：systemd-resolved 方案（用于 hax，全面防覆盖）
# ================================================================
configure_resolved() {
    echo "=== 配置 systemd-resolved DNS（防覆盖增强版） ==="

    # ---------- 1. 停止可能覆盖 DNS 的服务 ----------
    echo ">>> [1/8] 停止可能覆盖 DNS 的服务..."
    systemctl disable --now resolvconf 2>/dev/null || true
    systemctl mask resolvconf 2>/dev/null || true
    echo "    resolvconf 已处理（如果存在）。"

    # 禁用 cloud-init 网络配置
    mkdir -p /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<EOF
network: {config: disabled}
EOF
    echo "    cloud-init 网络配置已禁用。"

    # ---------- 2. 确保 systemd-resolved 启用 ----------
    echo ">>> [2/8] 启用并启动 systemd-resolved ..."
    systemctl unmask systemd-resolved 2>/dev/null || true
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true

    # ---------- 3. 写入 resolved.conf ----------
    echo ">>> [3/8] 写入 /etc/systemd/resolved.conf ..."
    cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=$DNS_SERVERS
FallbackDNS=$FALLBACK_DNS
Domains=~.
DNSStubListener=yes
#DNSSEC=no
#DNSOverTLS=no
#MulticastDNS=yes
#LLMNR=yes
EOF
    echo "    resolved.conf 已更新。"

    # ---------- 4. 切换 /etc/resolv.conf 为 stub 软链接 ----------
    echo ">>> [4/8] 切换 /etc/resolv.conf 为 stub 模式 ..."
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    elif [ -f /etc/resolv.conf ]; then
        mv /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s) 2>/dev/null || true
    fi
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    echo "    已创建软链接：/etc/resolv.conf -> /run/systemd/resolve/stub-resolv.conf"

    # ---------- 5. 处理 systemd-networkd ----------
    echo ">>> [5/8] 检查 systemd-networkd ..."
    if systemctl is-active --quiet systemd-networkd; then
        echo "    检测到 systemd-networkd 正在运行，配置防 DHCP DNS 覆盖..."
        NETWORK_DIR="/etc/systemd/network"
        mkdir -p "$NETWORK_DIR"

        # 如果没有任何 .network 文件，创建一个默认的
        if ! ls "$NETWORK_DIR"/*.network >/dev/null 2>&1; then
            echo "    未找到 .network 文件，创建默认配置 20-wired.network"
            cat > "$NETWORK_DIR/20-wired.network" <<EOF
[Match]
Name=*

[Network]
DHCP=yes
EOF
        fi

        # 为每个 .network 文件创建 drop-in，禁用 DHCP 下发的 DNS 并设置静态 DNS
        for netfile in "$NETWORK_DIR"/*.network; do
            [ -e "$netfile" ] || continue
            dropin_dir="${netfile}.d"
            mkdir -p "$dropin_dir"
            cat > "$dropin_dir/99-dns-override.conf" <<EOF
[Network]
DNS=$DNS_SERVERS

[DHCPv4]
UseDNS=no

[DHCPv6]
UseDNS=no

[IPv6AcceptRA]
UseDNS=no
EOF
            echo "    已为 $(basename "$netfile") 创建 drop-in：$dropin_dir/99-dns-override.conf"
        done

        systemctl restart systemd-networkd 2>/dev/null || true
        echo "    systemd-networkd 已重启。"
    else
        echo "    systemd-networkd 未运行，跳过。"
    fi

    # ---------- 6. 处理 NetworkManager ----------
    echo ">>> [6/8] 检查 NetworkManager ..."
    if systemctl is-active --quiet NetworkManager; then
        echo "    检测到 NetworkManager 正在运行，配置防 DHCP DNS 覆盖..."
        # 获取所有活动连接名称
        CONNECTIONS=$(nmcli -t -f NAME connection show --active 2>/dev/null || true)
        if [ -n "$CONNECTIONS" ]; then
            while IFS= read -r conn; do
                [ -z "$conn" ] && continue
                echo "    配置连接: $conn"
                nmcli connection modify "$conn" ipv4.ignore-auto-dns yes 2>/dev/null || true
                nmcli connection modify "$conn" ipv6.ignore-auto-dns yes 2>/dev/null || true
                # 将 DNS_SERVERS 转换为逗号分隔，分别设置 IPv4 和 IPv6
                IPV4_DNS=""
                IPV6_DNS=""
                for dns in $DNS_SERVERS; do
                    if [[ "$dns" == *:* ]]; then
                        IPV6_DNS="${IPV6_DNS:+$IPV6_DNS,}$dns"
                    else
                        IPV4_DNS="${IPV4_DNS:+$IPV4_DNS,}$dns"
                    fi
                done
                [ -n "$IPV4_DNS" ] && nmcli connection modify "$conn" ipv4.dns "$IPV4_DNS" 2>/dev/null || true
                [ -n "$IPV6_DNS" ] && nmcli connection modify "$conn" ipv6.dns "$IPV6_DNS" 2>/dev/null || true
                nmcli connection up "$conn" 2>/dev/null || true
            done <<< "$CONNECTIONS"
        else
            echo "    没有活动连接，跳过。"
        fi
    else
        echo "    NetworkManager 未运行，跳过。"
    fi

    # ---------- 7. 重启 systemd-resolved 并验证 ----------
    echo ">>> [7/8] 重启 systemd-resolved ..."
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 1

    echo ""
    echo "=== 当前 DNS 状态 ==="
    resolvectl status 2>/dev/null | grep -E "Global|DNS Servers|DNS Domain|resolv.conf mode" | head -20 || true

    echo ""
    echo "=== 测试域名解析 (google.com) ==="
    if resolvectl query google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 解析成功：${NC}"
        resolvectl query google.com 2>/dev/null | head -5
    else
        echo -e "${RED}⚠️  解析失败，请检查网络连通性。${NC}"
    fi

    # ---------- 8. 最终检查 ----------
    echo ""
    echo "=== /etc/resolv.conf 链接状态 ==="
    ls -l /etc/resolv.conf

    echo ""
    echo -e "${GREEN}✅ systemd-resolved 配置完成！${NC}"
    echo "如果重启后仍丢失，请检查是否还有其他服务（如 dhclient、dhcpcd）在修改 DNS。"
    echo "可执行以下命令排查："
    echo "  ls -l /etc/resolv.conf"
    echo "  resolvectl status"
    echo "  systemctl status systemd-resolved systemd-networkd NetworkManager --no-pager"
}

# ================================================================
# 主逻辑
# ================================================================
if [ "$1" = "--static" ]; then
    echo -e "${YELLOW}强制使用静态方案。${NC}"
    configure_static
    exit 0
elif [ "$1" = "--resolved" ]; then
    echo -e "${YELLOW}强制使用 systemd-resolved 方案。${NC}"
    configure_resolved
    exit 0
fi

# 自动检测主机名（支持部分匹配，忽略大小写）
HOST_LOWER=$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')
if [[ "$HOST_LOWER" == *woiden* ]]; then
    echo -e "${YELLOW}检测到 woiden 主机，执行静态方案。${NC}"
    configure_static
elif [[ "$HOST_LOWER" == *hax* ]]; then
    echo -e "${YELLOW}检测到 hax 主机，执行 systemd-resolved 方案。${NC}"
    configure_resolved
else
    echo -e "${RED}无法自动识别主机类型。请使用 --static 或 --resolved 参数手动指定。${NC}"
    echo "用法: $0 [--static | --resolved]"
    exit 1
fi
