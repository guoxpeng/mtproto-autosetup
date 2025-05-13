# MTProto Auto Setup

本项目用于一键部署 Telegram MTProxy 代理，端口设为 `4433`，支持开机自启和后台稳定运行。

## 🚀 快速开始

在 Ubuntu 系统中，运行以下命令一键部署 MTProxy：

```bash
curl -sSL https://raw.githubusercontent.com/guoxpeng/mtproto-autosetup/main/install.sh | bash
```

## 📌 部署完成后输出信息

脚本执行完毕后，将会输出如下信息：

```
✅ Telegram MTProxy 部署完成
🔹公网 IP: <你的IP>
🔹端口: 4433
🔹Secret: <自动生成的Secret>

🔗 连接链接：
tg://proxy?server=<你的IP>&port=4433&secret=ee<Secret>
```

## ⚙️ 服务管理命令

```bash
systemctl status mtproxy   # 查看服务状态
systemctl restart mtproxy  # 重启服务
systemctl stop mtproxy     # 停止服务
journalctl -u mtproxy -f   # 查看运行日志
```

## 📄 注意事项

- 默认监听端口为 4433（可自行修改 `install.sh` 脚本）
- 本脚本会自动安装依赖、编译源码、创建服务、配置开机启动
