#!/bin/bash
# ================================================================
# 统一 DNS 配置脚本
# 根据主机名自动选择方案：
#   - 主机名包含 "woiden" → 静态 resolv.conf + 锁定（绕过 systemd-resolved）
#   - 主机名包含 "hax"   → systemd-resolved 方案（配置 resolved.conf + stub）
# 也可通过命令行参数强制指定： --static 或 --resolved
# ================================================================

set -e  # 遇到错误退出

# 定义 DNS 地址
PRIMARY_DNS="2001:4860:4860::8888"
SECONDARY_DNS="2001:4860:4860::8844"
DNS_LIST="$PRIMARY_DNS $SECONDARY_DNS"

# 颜色输出（可选）
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 权限运行此脚本 (sudo)。${NC}"
    exit 1
fi

# 获取主机名（去除可能的域名部分）
HOSTNAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
echo -e "${YELLOW}检测到主机名: $HOSTNAME${NC}"

# 函数：静态 resolv.conf 方案（用于 woiden）
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
    echo "nameserver $PRIMARY_DNS" > /etc/resolv.conf
    echo "nameserver $SECONDARY_DNS" >> /etc/resolv.conf
    echo "    写入完成，内容如下："
    cat /etc/resolv.conf

    # 4. 锁定文件
    echo ">>> [4/5] 锁定 /etc/resolv.conf（不可变属性）..."
    chattr +i /etc/resolv.conf
    echo "    文件已锁定。"

    # 5. 验证解析
    echo ">>> [5/5] 测试 DNS 解析（google.com）..."
    if ping -6 -c 2 google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 解析成功：${NC}"
        ping -6 -c 2 google.com | head -5
    else
        echo -e "${RED}⚠️  解析失败，请检查网络连通性。${NC}"
    fi

    echo ""
    echo "=== 当前 /etc/resolv.conf 内容 ==="
    cat /etc/resolv.conf
    echo ""
    echo "=== 文件锁定状态 ==="
    lsattr /etc/resolv.conf | grep -i "i" || echo "未锁定（异常）"
    echo ""
    echo -e "${GREEN}✅ 静态 DNS 配置完成！${NC}"
    echo "如需修改，请先执行： chattr -i /etc/resolv.conf"
}

# 函数：systemd-resolved 方案（用于 hax）
configure_resolved() {
    echo "=== 配置 systemd-resolved DNS ==="

    # 1. 启用 systemd-resolved
    echo ">>> [1/4] 启用 systemd-resolved ..."
    systemctl unmask systemd-resolved 2>/dev/null || true
    systemctl enable --now systemd-resolved
    systemctl status systemd-resolved --no-pager | head -5

    # 2. 配置 /etc/systemd/resolved.conf
    echo ">>> [2/4] 写入 DNS 到 resolved.conf ..."
    cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=$DNS_LIST
#FallbackDNS=
#Domains=
#DNSSEC=no
#DNSOverTLS=no
#MulticastDNS=yes
#LLMNR=yes
EOF
    echo "    resolved.conf 已更新。"

    # 3. 切换 /etc/resolv.conf 为 stub 软链接
    echo ">>> [3/4] 切换 /etc/resolv.conf 为 stub 模式 ..."
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    elif [ -f /etc/resolv.conf ]; then
        mv /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s)
    fi
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    echo "    已创建软链接。"

    # 4. 如果 systemd-networkd 在运行，配置其 DNS
    if systemctl status systemd-networkd >/dev/null 2>&1; then
        echo ">>> [4/4] 检测到 systemd-networkd，配置 DNS ..."
        NETWORK_FILE=$(ls /etc/systemd/network/*.network 2>/dev/null | head -1)
        if [ -z "$NETWORK_FILE" ]; then
            echo "    未找到 .network 文件，创建默认配置..."
            NETWORK_FILE="/etc/systemd/network/20-wired.network"
            cat > "$NETWORK_FILE" <<EOF
[Match]
Name=*

[Network]
DHCP=yes
DNS=$DNS_LIST
EOF
        else
            if ! grep -q "^DNS=" "$NETWORK_FILE"; then
                echo "DNS=$DNS_LIST" >> "$NETWORK_FILE"
            else
                sed -i "s/^DNS=.*/DNS=$DNS_LIST/" "$NETWORK_FILE"
            fi
        fi
        systemctl restart systemd-networkd
        echo "    systemd-networkd 已重启。"
    else
        echo ">>> [4/4] systemd-networkd 未运行，跳过。"
    fi

    # 重启 resolved 并验证
    echo ">>> 重启 systemd-resolved ..."
    systemctl restart systemd-resolved

    echo ""
    echo "=== 当前 DNS 状态 ==="
    resolvectl status | grep -E "Global|DNS Servers|resolv.conf mode" | head -10

    echo ""
    echo "=== 测试域名解析 (google.com) ==="
    if resolvectl query google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 解析成功：${NC}"
        resolvectl query google.com | head -5
    else
        echo -e "${RED}⚠️  解析失败，请检查网络连通性。${NC}"
    fi

    echo ""
    echo "=== /etc/resolv.conf 链接状态 ==="
    ls -l /etc/resolv.conf

    echo ""
    echo -e "${GREEN}✅ systemd-resolved 配置完成！${NC}"
}

# ---------- 主逻辑：根据参数或主机名选择方案 ----------
if [ "$1" == "--static" ]; then
    echo -e "${YELLOW}强制使用静态方案。${NC}"
    configure_static
    exit 0
elif [ "$1" == "--resolved" ]; then
    echo -e "${YELLOW}强制使用 systemd-resolved 方案。${NC}"
    configure_resolved
    exit 0
fi

# 自动检测主机名（支持部分匹配）
if [[ "${HOSTNAME,,}" == *woiden* ]]; then
    echo -e "${YELLOW}检测到 woiden 主机，执行静态方案。${NC}"
    configure_static
elif [[ "${HOSTNAME,,}" == *hax* ]]; then
    echo -e "${YELLOW}检测到 hax 主机，执行 systemd-resolved 方案。${NC}"
    configure_resolved
else
    echo -e "${RED}无法自动识别主机类型。请使用 --static 或 --resolved 参数手动指定。${NC}"
    echo "用法: $0 [--static | --resolved]"
    exit 1
fi
