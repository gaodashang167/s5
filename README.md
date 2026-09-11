# Socks5 一键安装脚本

基于 sing-box 部署带用户名和密码认证的 Socks5 服务，支持 systemd 开机自启及异常自动重启。

## 安装

请使用 root 用户执行：

```bash
PORT=16805 USERNAME=用户名 PASSWORD=密码 bash <(curl -fLsS https://raw.githubusercontent.com/gaodashang167/s5/main/sock5.sh)
```

参数说明：

- `PORT`：监听端口，范围为 1 到 65535
- `USERNAME`：Socks5 用户名
- `PASSWORD`：Socks5 密码

建议使用 `curl -fLsS`，远程地址返回 404 或其他 HTTP 错误时会直接停止，不会把错误页面交给 bash 执行。

## 卸载

```bash
bash <(curl -fLsS https://raw.githubusercontent.com/gaodashang167/s5/main/sock5.sh) uninstall
```

## 服务管理

查看运行状态：

```bash
systemctl status sing-box-socks5.service
```

查看实时日志：

```bash
journalctl -u sing-box-socks5.service -f
```

重启服务：

```bash
systemctl restart sing-box-socks5.service
```

停止服务：

```bash
systemctl stop sing-box-socks5.service
```

启动服务：

```bash
systemctl start sing-box-socks5.service
```

## 配置文件

配置文件位置：

```text
/usr/local/sb/config.json
```

查看配置：

```bash
cat /usr/local/sb/config.json
```

配置文件包含认证密码，请勿公开。

## 测试代理

在服务器本机测试：

```bash
curl --socks5-hostname 127.0.0.1:16805 -U '用户名:密码' https://api.ipify.org
```

把端口、用户名和密码替换为安装时设置的值。正确返回出口 IP 即表示代理可用。

## IPv4 和 IPv6

脚本监听 `::`。是否同时接受 IPv4 连接取决于系统的 `net.ipv6.bindv6only` 设置。

查看当前设置：

```bash
sysctl net.ipv6.bindv6only
```

如果返回 `0`，通常可由同一端口同时接受 IPv4 和 IPv6 连接。如果返回 `1`，该监听通常仅接受 IPv6 连接。

## 防火墙

请在 VPS 防火墙或云平台安全组中放行所设置端口的 TCP 入站流量。

使用 UFW 的示例：

```bash
ufw allow 16805/tcp
```

使用 iptables 的示例：

```bash
iptables -I INPUT -p tcp --dport 16805 -j ACCEPT
```

请将示例端口替换为实际的 `PORT`。

## 文件位置

- sing-box：`/usr/local/sb/sing-box`
- 配置文件：`/usr/local/sb/config.json`
- systemd 服务：`/etc/systemd/system/sing-box-socks5.service`

## 注意事项

- 脚本必须以 root 用户运行。
- 不要直接使用来源不明的脚本地址。
- 安装命令中的仓库地址是 `gaodashang167/s5`，不要使用已经返回 404 的旧地址 `jyucoeng/socks5`。
- 修改配置后，请先执行配置检查，再重启服务：

```bash
/usr/local/sb/sing-box check -c /usr/local/sb/config.json && systemctl restart sing-box-socks5.service
```
