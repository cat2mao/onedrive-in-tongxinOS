#!/bin/bash
echo "⚠️  正在卸载 OneDrive 托盘程序..."

# 停止服务
systemctl --user stop rclone-onedrive.timer
systemctl --user stop rclone-onedrive.service
systemctl --user disable rclone-onedrive.timer
systemctl --user disable rclone-onedrive.service

# 删除文件
rm -f ~/.local/bin/rclone-tray.py
rm -rf ~/.local/share/icons/rclone
rm -f ~/.config/systemd/user/rclone-onedrive.service
rm -f ~/.config/systemd/user/rclone-onedrive.timer
rm -f ~/.local/share/applications/rclone-onedrive.desktop
rm -f ~/.config/autostart/rclone-onedrive.desktop
rm -f ~/Desktop/rclone-onedrive.desktop
rm -f ~/.cache/rclone-onedrive.status
rm -f ~/.cache/rclone_tray.lock

# 删除日志配置
echo "正在删除日志配置 (需要 sudo)..."
sudo rm -f /etc/logrotate.d/rclone-onedrive

# 重载 Systemd
systemctl --user daemon-reload

echo "✅ 卸载完成。"
