# mtproto-autosetup
一键部署 Telegram MTProxy 脚本
一键部署 Telegram MTProxy（无 TLS，使用 4433 端口）


你可以在 Ubuntu 上运行后立即生效、并设置开机自启：
curl -sSL https://raw.githubusercontent.com/guoxpeng/mtproto-autosetup/main/install.sh | bash

你可以使用的命令：
命令                           	说明
systemctl status mtproxy	查看运行状态
systemctl restart mtproxy	重启代理
systemctl enable mtproxy	设置开机自启（脚本已包含）
journalctl -u mtproxy -f	实时查看日志

