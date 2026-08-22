
---

```markdown
# 🚀 DNS 一键配置脚本

自动为 Linux 服务器（Debian/Ubuntu）配置 IPv6 DNS，根据主机名智能选择最佳方案，支持静态锁定和 systemd-resolved 两种模式。

## ✨ 特性

- **自动识别主机名**：包含 `woiden` → 静态 `resolv.conf` + `chattr +i` 锁定；包含 `hax` → `systemd-resolved` + stub 模式。
- **一键执行**：通过 `curl` 下载并运行，无需手动创建文件。
- **防止覆盖**：静态模式下锁定 `/etc/resolv.conf`，任何进程都无法修改。
- **两种方案可选**：支持通过命令行参数 `--static` 或 `--resolved` 强制指定。
- **自动验证**：执行后自动测试 `google.com` 解析，并输出状态。

## 📦 使用方法

### 快速开始（一键执行）

```bash
curl -sSL https://raw.githubusercontent.com/你的用户名/仓库名/main/setup_dns.sh | sudo bash
```

> 将 URL 中的 `你的用户名/仓库名` 替换为你的 GitHub 实际路径。

### 指定方案

```bash
# 强制使用静态锁定方案
curl -sSL https://.../setup_dns.sh | sudo bash -s -- --static

# 强制使用 systemd-resolved 方案
curl -sSL https://.../setup_dns.sh | sudo bash -s -- --resolved
```

### 先下载后执行（推荐用于审查）

```bash
curl -sSL -o /tmp/setup_dns.sh https://.../setup_dns.sh
chmod +x /tmp/setup_dns.sh
sudo /tmp/setup_dns.sh
```

## 🧩 脚本内容说明

- **静态方案（woiden）**  
  - 停止并禁用 `systemd-resolved`  
  - 写入自定义 IPv6 DNS 到 `/etc/resolv.conf`  
  - 使用 `chattr +i` 锁定文件，防止被覆盖  
  - 测试 `ping -6 google.com`

- **systemd-resolved 方案（hax）**  
  - 启用 `systemd-resolved`  
  - 配置 `/etc/systemd/resolved.conf`  
  - 将 `/etc/resolv.conf` 软链接到 stub 文件  
  - 若 `systemd-networkd` 运行，则自动配置其 DNS

## 📌 配置的 DNS 地址

- 首选：`2001:4860:4860::8888`（Google IPv6）  
- 备选：`2001:4860:4860::8844`（Google IPv6 备用）

如需修改，请编辑脚本开头的 `PRIMARY_DNS` 和 `SECONDARY_DNS` 变量。

## 🛠️ 支持的系统

- Debian 10+ / Ubuntu 18.04+  
- 支持 OpenVZ / LXC 容器（venet0 接口）  
- 需要 `systemd` 和 `bash`

## ⚠️ 注意事项

- **静态方案会锁定文件**：如需修改 DNS，必须先执行 `sudo chattr -i /etc/resolv.conf`，编辑后重新锁定。
- **脚本需要 root 权限**：请使用 `sudo` 或以 root 用户运行。
- **若网络不通**：脚本会提示解析失败，请检查网络连通性或手动排查。
- **云环境（如 AWS、GCP）**：可能存在 `cloud-init` 覆盖 DNS，静态锁定方案可有效抵御。

## 📄 许可证

MIT License – 可自由使用、修改和分发。

## 🤝 贡献

欢迎提交 Issue 或 Pull Request 改进脚本。

---

**Enjoy your fixed DNS!** 🌐
