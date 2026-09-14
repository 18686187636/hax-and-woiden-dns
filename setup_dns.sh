#!/bin/bash
# ================================================================
# 统一 DNS 配置脚本（全部静态方案，仅 IPv6）
# 主机名包含 "woiden" 或 "hax" → 静态 resolv.conf + 锁定
# ================================================================

set -e

# ========== DNS 配置（仅 IPv6） ==========
DNS_SERVERS_V6="2001:4860:4860::8888 2001:4860:4860::8844 2606:4700:4700::1111 2606:4700:4700::1001"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 权限运行此脚本 (sudo)。${NC}"
    exit 1
fi

HOST_NAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
echo -e "${YELLOW}检测到主机名: $HOST_NAME${NC}"

configure_static() {
    echo "=== 配置静态 DNS（仅 IPv6，锁定 /etc/resolv.conf） ==="

    # 1. 停止 systemd-resolved
    echo ">>> [1/6] 停止并禁用 systemd-resolved ..."
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    echo "    已处理。"

    # 2. 禁用覆盖服务
    echo ">>> [2/6] 禁用可能覆盖 DNS 的服务 ..."
    systemctl disable --now resolvconf 2>/dev/null || true
    systemctl mask resolvconf 2>/dev/null || true
    mkdir -p /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF
    echo "    已处理。"

    # 3. 解除锁定
    echo ">>> [3/6] 解除 /etc/resolv.conf 锁定 ..."
    chattr -i /etc/resolv.conf 2>/dev/null || true

    # 4. 写入 DNS（仅 IPv6）
    echo ">>> [4/6] 写入 DNS 到 /etc/resolv.conf ..."
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    elif [ -f /etc/resolv.conf ]; then
        mv /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s) 2>/dev/null || true
    fi

    > /etc/resolv.conf
    for dns in $DNS_SERVERS_V6; do
        echo "nameserver $dns" >> /etc/resolv.conf
    done
    # timeout:2 attempts:1: 2 秒超时，只试 1 次
    echo "options timeout:2 attempts:1" >> /etc/resolv.conf

    echo "    写入完成："
    cat /etc/resolv.conf

    # 5. 尝试锁定
    echo ">>> [5/6] 尝试锁定 /etc/resolv.conf ..."
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        echo -e "${GREEN}    文件已锁定。${NC}"
    else
        echo -e "${YELLOW}    ⚠️ chattr +i 失败（OpenVZ 文件系统可能不支持 immutable）。${NC}"
        echo -e "${YELLOW}    改用 cron @reboot 开机自动重写。${NC}"

        cat > /usr/local/bin/fix-resolv-conf.sh <<'SCRIPT'
#!/bin/bash
printf 'nameserver 2001:4860:4860::8888\nnameserver 2001:4860:4860::8844\nnameserver 2606:4700:4700::1111\nnameserver 2606:4700:4700::1001\noptions timeout:2 attempts:1\n' > /etc/resolv.conf
SCRIPT
        chmod +x /usr/local/bin/fix-resolv-conf.sh

        (crontab -l 2>/dev/null | grep -v fix-resolv-conf; echo "@reboot /usr/local/bin/fix-resolv-conf.sh") | crontab -
        echo "    已添加 @reboot cron 任务。"
    fi

    # 6. 验证
    echo ">>> [6/6] 测试 DNS 解析（google.com）..."
    if ping -6 -c 2 google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ IPv6 解析成功！${NC}"
        ping -6 -c 2 google.com | head -3
    elif ping -c 2 google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 解析成功（走 IPv6 DNS 查询 A 记录）：${NC}"
        ping -c 2 google.com | head -3
    else
        echo -e "${RED}⚠️  解析失败，IPv6 DNS 可能不可达。${NC}"
        echo -e "${YELLOW}    排查：ping6 2001:4860.4860::8888${NC}"
    fi

    echo ""
    echo "=== 当前 /etc/resolv.conf ==="
    cat /etc/resolv.conf
    echo ""
    echo "=== 锁定状态 ==="
    lsattr /etc/resolv.conf 2>/dev/null | grep -i "i" && echo "已锁定" || echo "未锁定（已用 cron 兜底）"
    echo ""
    echo -e "${GREEN}✅ 配置完成！${NC}"
}

HOST_LOWER=$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')
if [[ "$HOST_LOWER" == *woiden* ]] || [[ "$HOST_LOWER" == *hax* ]]; then
    configure_static
else
    echo -e "${RED}无法识别主机类型。${NC}"
    exit 1
fi
