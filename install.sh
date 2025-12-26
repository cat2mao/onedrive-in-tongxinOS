#!/bin/bash

echo "=========================================="
echo "    OneDrive 托盘程序一键安装脚本"
echo "=========================================="

# 1. 检查基础环境
CURRENT_USER=$(whoami)
USER_HOME=$HOME
INSTALL_DIR="$USER_HOME/.local/bin"
ICONS_DIR="$USER_HOME/.local/share/icons/rclone"
SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
APP_DIR="$USER_HOME/.local/share/applications"
DESKTOP_DIR="$USER_HOME/Desktop"

if [ "$EUID" -eq 0 ]; then
  echo "❌ 请不要使用 sudo 运行此脚本，直接运行即可。"
  echo "   脚本内部会在需要时请求 sudo 权限。"
  exit 1
fi

# 2. 检查并自动安装 Rclone
echo "🔍 正在检查 Rclone..."
if ! command -v rclone &> /dev/null; then
    echo "⚠️  未检测到 rclone，正在尝试自动安装..."
    
    # 尝试使用 apt 安装 (统信/Deepin/Ubuntu)
    echo ">>> 正在执行: sudo apt update && sudo apt install rclone"
    sudo apt update && sudo apt install -y rclone
    
    # 如果 apt 安装失败，尝试官方脚本
    if ! command -v rclone &> /dev/null; then
        echo "⚠️  Apt 安装失败或版本过低，尝试使用官方脚本安装..."
        if ! command -v curl &> /dev/null; then sudo apt install -y curl; fi
        curl https://rclone.org/install.sh | sudo bash
    fi
    
    # 最终检查
    if ! command -v rclone &> /dev/null; then
        echo "❌ Rclone 安装失败，请手动安装后重试。"
        exit 1
    fi
    echo "✅ Rclone 安装成功！"
fi

# 3. 检查配置
echo "🔍 正在检查 Rclone 配置..."
# 检查是否存在名为 OneDrive 的配置
if ! rclone listremotes | grep -q "OneDrive:"; then
    echo "⚠️  未检测到名为 'OneDrive' 的远程配置。"
    echo "-----------------------------------------------------"
    echo ">>> 即将进入 Rclone 配置向导 <<<"
    echo "1. 输入 'n' 新建配置"
    echo "2. name 输入: OneDrive (必须完全一致)"
    echo "3. storage 类型搜索 'onedrive' 并选择"
    echo "4. 按提示登录即可"
    echo "-----------------------------------------------------"
    echo "按回车键开始配置..."
    read
    rclone config
    # 再次检查
    if ! rclone listremotes | grep -q "OneDrive:"; then
        echo "❌ 配置未成功或名称错误（必须叫 OneDrive），安装终止。"
        exit 1
    fi
else
    echo "✅ 检测到 OneDrive 配置。"
fi

# 4. 安装依赖
echo "📦 正在安装 Python 依赖..."
sudo apt update
sudo apt install -y python3-gi gir1.2-appindicator3-0.1 gir1.2-gtk-3.0

# 5. 部署文件
echo "📂 正在部署文件..."

# 创建目录
mkdir -p "$INSTALL_DIR"
mkdir -p "$ICONS_DIR"
mkdir -p "$SYSTEMD_DIR"
mkdir -p "$APP_DIR"
mkdir -p "$USER_HOME/.cache"
mkdir -p "$USER_HOME/OneDrive"  # 创建本地同步目录

# 复制 Python 脚本
cp "$(dirname "$0")/rclone-tray.py" "$INSTALL_DIR/rclone-tray.py"
chmod +x "$INSTALL_DIR/rclone-tray.py"

# 生成图标
echo "🎨 生成图标..."
cat > "$ICONS_DIR/idle.svg" <<EOF
<svg width="64" height="64" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#0078D4"/></svg>
EOF
cat > "$ICONS_DIR/syncing.svg" <<EOF
<svg width="64" height="64" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#E3E3E3"/><path d="M32 24v-4l-6 6 6 6v-4c4.4 0 8 3.6 8 8s-3.6 8-8 8-8-3.6-8-8h-4c0 6.6 5.4 12 12 12s12-5.4 12-12-5.4-12-12-12z" fill="#0078D4"/></svg>
EOF
cat > "$ICONS_DIR/failed.svg" <<EOF
<svg width="64" height="64" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#E3E3E3"/><circle cx="48" cy="48" r="14" fill="#D13438"/><path d="M46 40h4v10h-4zm0 12h4v4h-4z" fill="#FFFFFF"/></svg>
EOF
cat > "$ICONS_DIR/offline.svg" <<EOF
<svg width="64" height="64" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#A0A0A0"/><line x1="10" y1="54" x2="54" y2="10" stroke="#FFFFFF" stroke-width="4"/></svg>
EOF

# 生成 Systemd Service
echo "⚙️  配置后台服务..."
cat > "$SYSTEMD_DIR/rclone-onedrive.service" <<EOF
[Unit]
Description=Rclone OneDrive BiSync (10min via timer)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'echo SYNCING > %h/.cache/rclone-onedrive.status'
ExecStart=$(which rclone) bisync "OneDrive:" "%h/OneDrive" --exclude "个人保管库/**" --exclude ".xdg-volume-info" --fast-list --transfers 16 --checkers 16 --multi-thread-streams 8 --tpslimit 10 --stats 2s --log-file %h/.cache/rclone-onedrive.log --log-level INFO
ExecStopPost=/bin/bash -c 'if [ "\$EXIT_STATUS" = "0" ]; then echo "IDLE" > %h/.cache/rclone-onedrive.status; else echo "FAILED" > %h/.cache/rclone-onedrive.status; fi'
TimeoutStartSec=0
RemainAfterExit=no

[Install]
WantedBy=default.target
EOF

# 生成 Systemd Timer
cat > "$SYSTEMD_DIR/rclone-onedrive.timer" <<EOF
[Unit]
Description=Run Rclone OneDrive BiSync every 30 minutes

[Timer]
OnBootSec=5m
OnUnitActiveSec=30m
Unit=rclone-onedrive.service

[Install]
WantedBy=timers.target
EOF

# 生成 Desktop 文件 (开始菜单)
echo "🖥️  创建开始菜单快捷方式..."
cat > "$APP_DIR/rclone-onedrive.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=OneDrive 同步助手
Comment=Rclone OneDrive 托盘管理程序
Exec=$(which python3) $INSTALL_DIR/rclone-tray.py
Icon=$ICONS_DIR/idle.svg
Terminal=false
Categories=Utility;Network;
StartupNotify=false
EOF
chmod +x "$APP_DIR/rclone-onedrive.desktop"

# 生成 Desktop 图标 (用户桌面)
echo "🖥️  创建桌面图标..."
if [ -d "$DESKTOP_DIR" ]; then
    cp "$APP_DIR/rclone-onedrive.desktop" "$DESKTOP_DIR/"
    chmod +x "$DESKTOP_DIR/rclone-onedrive.desktop"
    echo "✅ 桌面图标已创建。"
else
    echo "⚠️  未找到桌面目录 $DESKTOP_DIR，跳过桌面图标创建。"
fi

# 6. 配置日志轮转 (需要 Root)
echo "📜 配置日志自动清理..."
# 创建临时文件
cat > /tmp/rclone-onedrive-logrotate <<EOF
$USER_HOME/.cache/rclone-onedrive.log {
    daily
    rotate 7
    missingok
    notifempty
    copytruncate
    su $CURRENT_USER $CURRENT_USER
}
EOF
sudo mv /tmp/rclone-onedrive-logrotate /etc/logrotate.d/rclone-onedrive
sudo chown root:root /etc/logrotate.d/rclone-onedrive

# 7. 启动服务
echo "🚀 启动服务中..."
systemctl --user daemon-reload
systemctl --user enable --now rclone-onedrive.timer

# 设置开机自启托盘
mkdir -p "$USER_HOME/.config/autostart"
cp "$APP_DIR/rclone-onedrive.desktop" "$USER_HOME/.config/autostart/"

echo "=========================================="
echo "✅ 安装完成！"
echo "1. 后台同步服务已启动。"
echo "2. 桌面已生成 'OneDrive 同步助手' 图标。"
echo "3. 请双击桌面图标启动程序。"
echo "=========================================="
