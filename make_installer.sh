#!/bin/bash
# make_installer.sh
# 运行此脚本，将在桌面生成最终的安装包文件夹

# 1. 定义输出目录
INSTALLER_DIR="$HOME/Desktop/OneDrive-Tray-Installer"
mkdir -p "$INSTALLER_DIR/assets"

echo "正在生成安装包到: $INSTALLER_DIR"

# =========================================================
# 2. 写入 Python 主程序 (嵌入支持微调框和打钩状态的最新代码)
# =========================================================
cat > "$INSTALLER_DIR/rclone-tray.py" << 'EOF_PYTHON'
#!/usr/bin/env python3
import gi
import os
import subprocess
import time
import re
import sys
import fcntl

gi.require_version('Gtk', '3.0')
gi.require_version('AppIndicator3', '0.1')

from gi.repository import Gtk, AppIndicator3, GObject

# ================== 单实例检测 ==================
LOCK_FILE_PATH = os.path.join(os.path.expanduser("~/.cache"), "rclone_tray.lock")
try:
    if not os.path.exists(os.path.dirname(LOCK_FILE_PATH)):
        os.makedirs(os.path.dirname(LOCK_FILE_PATH))
    _lock_file = open(LOCK_FILE_PATH, "w")
    fcntl.lockf(_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
except IOError:
    print("程序已在运行中，退出当前实例。")
    sys.exit(1)

# ================== 常量配置 ==================
USER_HOME = os.path.expanduser("~")
ICON_DIR = os.path.join(USER_HOME, ".local/share/icons/rclone")
STATUS_FILE = os.path.join(USER_HOME, ".cache/rclone-onedrive.status")
LOG_FILE = os.path.join(USER_HOME, ".cache/rclone-onedrive.log")
SERVICE_FILE = os.path.join(USER_HOME, ".config/systemd/user/rclone-onedrive.service")
TIMER_FILE = os.path.join(USER_HOME, ".config/systemd/user/rclone-onedrive.timer")
RCLONE_CONF = os.path.join(USER_HOME, ".config/rclone/rclone.conf")
SERVICE_NAME = "rclone-onedrive.service"
TIMER_NAME = "rclone-onedrive.timer"
LOCAL_DIR = os.path.join(USER_HOME, "OneDrive")

last_status_code = "INIT"
# 用于防止初始化菜单时触发回调
is_initializing = True 

# ================== 工具函数 ==================
def read_status():
    if os.path.exists(STATUS_FILE):
        try: return open(STATUS_FILE).read().strip()
        except: return "IDLE"
    return "IDLE"

def network_online():
    try:
        subprocess.check_output(["/usr/bin/systemctl", "is-active", "network-online.target"], stderr=subprocess.DEVNULL)
        return True
    except subprocess.CalledProcessError:
        return False

def send_notification(title, message, urgent=False):
    icon_name = "dialog-error" if urgent else "emblem-default"
    urgency = "critical" if urgent else "normal"
    try: subprocess.Popen(["notify-send", "-i", icon_name, "-u", urgency, title, message])
    except: pass

def last_sync_time():
    if not os.path.exists(LOG_FILE): return "无记录"
    try:
        out = subprocess.check_output(["tail", "-n", "50", LOG_FILE], stderr=subprocess.DEVNULL).decode()
        matches = re.findall(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}).*Bisync successful", out, re.MULTILINE)
        if matches: return matches[-1]
    except: pass
    return "未知"

def syncing_progress():
    if not os.path.exists(LOG_FILE): return None
    try:
        log_tail = subprocess.check_output(["tail", "-n", "15", LOG_FILE], stderr=subprocess.DEVNULL).decode().strip()
        lines = log_tail.splitlines()
        for line in reversed(lines):
            if "Transferred:" in line and "%" in line:
                match = re.search(r"(\d{1,3}%).*?([\d\.]+\s?\w+/s).*?ETA\s?([\w\d]+)", line)
                if match: return f"{match.group(1)} ({match.group(2).replace(' ', '')} - {match.group(3)})"
            if "Checks:" in line:
                match = re.search(r"Checks:\s+(\d+\s?/\s?\d+)", line)
                if match: return f"正在比对差异: {match.group(1).replace(' ', '')}"
    except: pass
    return "正在启动同步..."

# ================== 配置读取函数 ==================
def get_current_interval():
    if not os.path.exists(TIMER_FILE): return 30
    try:
        with open(TIMER_FILE, 'r') as f: content = f.read()
        match = re.search(r"OnUnitActiveSec=(\d+)([mh]?)", content)
        if match:
            val = int(match.group(1))
            return val * 60 if match.group(2) == 'h' else val
    except: pass
    return 30

def get_current_fixed_time():
    """ 读取当前的固定时间设置 """
    if not os.path.exists(TIMER_FILE): return None
    try:
        with open(TIMER_FILE, 'r') as f: content = f.read()
        # 匹配 OnCalendar=*-*-* 17:20:00
        match = re.search(r"OnCalendar=\*-\*-\*\s+(\d{2}:\d{2}):00", content)
        if match:
            return match.group(1)
    except: pass
    return None

# ================== 动作函数 ==================
def manual_sync(_):
    send_notification("OneDrive", "正在启动手动同步...")
    subprocess.Popen(["/usr/bin/systemctl", "--user", "restart", SERVICE_NAME])
    update_ui_immediate()

def action_restart_all(_):
    send_notification("系统", "正在重载配置并重启程序...", False)
    try:
        subprocess.run(["/usr/bin/systemctl", "--user", "daemon-reload"], stderr=subprocess.DEVNULL)
        subprocess.Popen(["/usr/bin/systemctl", "--user", "restart", SERVICE_NAME])
        subprocess.Popen(["/usr/bin/systemctl", "--user", "restart", TIMER_NAME])
        python = sys.executable
        subprocess.Popen([python] + sys.argv)
        Gtk.main_quit()
        sys.exit(0)
    except Exception as e:
        send_notification("错误", f"重启失败: {e}", True)

# --- 间隔同步逻辑 ---
def set_timer_interval(minutes):
    if not os.path.exists(TIMER_FILE):
        send_notification("错误", "找不到 Timer 文件", True); return
    if get_current_interval() == minutes: return
    try:
        with open(TIMER_FILE, 'r') as f: content = f.read()
        new_val = f"OnUnitActiveSec={minutes}m"
        
        if "OnUnitActiveSec=" in content: 
            new_content = re.sub(r"OnUnitActiveSec=.*", new_val, content)
        elif "[Timer]" in content: 
            new_content = content.replace("[Timer]", f"[Timer]\n{new_val}")
        else: return
        
        with open(TIMER_FILE, 'w') as f: f.write(new_content)
        subprocess.run(["/usr/bin/systemctl", "--user", "daemon-reload"])
        subprocess.run(["/usr/bin/systemctl", "--user", "restart", TIMER_NAME])
        send_notification("设置成功", f"间隔已更新为 {minutes} 分钟")
    except Exception as e:
        send_notification("失败", f"无法写入文件: {e}", True)

# --- 固定时间逻辑 (改进版：使用 SpinButton 和 CheckMenuItem) ---
def show_time_picker_dialog(current_time=None):
    """ 弹出带有微调框的时间选择对话框 """
    dialog = Gtk.Dialog(title="设置定时同步", parent=None, flags=0)
    dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OK, Gtk.ResponseType.OK)
    
    # 默认时间
    def_h, def_m = 17, 20
    if current_time:
        try:
            parts = current_time.split(":")
            def_h, def_m = int(parts[0]), int(parts[1])
        except: pass

    box = dialog.get_content_area()
    box.set_spacing(10)
    box.set_border_width(20)
    
    label = Gtk.Label(label="请选择每天同步的时间：")
    box.add(label)
    
    # 创建水平布局放 H : M
    hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
    hbox.set_halign(Gtk.Align.CENTER)
    
    # 小时微调框 (0-23)
    adj_h = Gtk.Adjustment(value=def_h, lower=0, upper=23, step_increment=1, page_increment=1, page_size=0)
    spin_h = Gtk.SpinButton(adjustment=adj_h)
    spin_h.set_numeric(True)
    spin_h.set_wrap(True) # 循环
    hbox.pack_start(spin_h, False, False, 0)
    
    # 冒号
    sep = Gtk.Label(label=" : ")
    hbox.pack_start(sep, False, False, 0)
    
    # 分钟微调框 (0-59)
    adj_m = Gtk.Adjustment(value=def_m, lower=0, upper=59, step_increment=1, page_increment=10, page_size=0)
    spin_m = Gtk.SpinButton(adjustment=adj_m)
    spin_m.set_numeric(True)
    spin_m.set_wrap(True) # 循环
    hbox.pack_start(spin_m, False, False, 0)
    
    box.add(hbox)
    box.show_all()
    
    response = dialog.run()
    
    result = None
    if response == Gtk.ResponseType.OK:
        # 获取整数并格式化为 HH:MM
        h = int(spin_h.get_value())
        m = int(spin_m.get_value())
        result = f"{h:02d}:{m:02d}"
        
    dialog.destroy()
    return result

def on_fixed_time_toggled(widget):
    """ 复选框回调 """
    global is_initializing
    if is_initializing: return

    is_active = widget.get_active()
    
    if is_active:
        # 用户尝试启用 -> 弹出对话框选择时间
        current = get_current_fixed_time()
        time_str = show_time_picker_dialog(current)
        
        if time_str:
            # 用户选好了时间 -> 写入配置
            update_fixed_time_config(time_str)
            widget.set_label(f"每天定时同步 ({time_str})")
        else:
            # 用户点了取消 -> 恢复未勾选状态 (需屏蔽信号防止死循环)
            widget.handler_block_by_func(on_fixed_time_toggled)
            widget.set_active(False)
            widget.handler_unblock_by_func(on_fixed_time_toggled)
            
    else:
        # 用户尝试禁用 -> 直接清除配置
        update_fixed_time_config(None)
        widget.set_label("每天定时同步")


def update_fixed_time_config(time_str):
    if not os.path.exists(TIMER_FILE): return
    
    try:
        with open(TIMER_FILE, 'r') as f: content = f.read()
        
        has_calendar = "OnCalendar=" in content
        
        if time_str:
            # 添加/更新
            new_line = f"OnCalendar=*-*-* {time_str}:00"
            # 确保 Persistent 存在
            if "Persistent=" not in content:
                 if "[Timer]" in content:
                     content = content.replace("[Timer]", f"[Timer]\nPersistent=true")
            
            if has_calendar:
                new_content = re.sub(r"OnCalendar=.*", new_line, content)
            else:
                new_content = content.replace("[Timer]", f"[Timer]\n{new_line}")
            msg = f"已设置每天 {time_str} 同步"
        else:
            # 删除
            if has_calendar:
                new_content = re.sub(r"OnCalendar=.*\n?", "", content)
                msg = "已取消固定时间同步"
            else:
                return 

        with open(TIMER_FILE, 'w') as f: f.write(new_content)
        
        subprocess.run(["/usr/bin/systemctl", "--user", "daemon-reload"])
        subprocess.run(["/usr/bin/systemctl", "--user", "restart", TIMER_NAME])
        send_notification("设置成功", msg)
        
    except Exception as e:
        send_notification("失败", f"配置错误: {e}", True)


def edit_file(filepath):
    if not os.path.exists(filepath): send_notification("错误", f"文件不存在", True); return
    try: subprocess.Popen(["xdg-open", filepath])
    except: 
        try: subprocess.Popen(["deepin-editor", filepath])
        except: send_notification("错误", "无法打开编辑器", True)

def force_resync(_):
    dialog = Gtk.MessageDialog(parent=None, flags=0, message_type=Gtk.MessageType.WARNING, buttons=Gtk.ButtonsType.OK_CANCEL, text="确定要强制重置同步吗？")
    dialog.format_secondary_text("这会执行 --resync，仅在报错 'lock file' 时使用。")
    if dialog.run() == Gtk.ResponseType.OK:
        send_notification("系统", "正在执行强制重置...", True)
        subprocess.Popen(["/usr/bin/rclone", "bisync", "OneDrive:", LOCAL_DIR, "--resync", "--verbose", "--log-file", LOG_FILE])
    dialog.destroy()

def open_actions(action):
    if action == "local": subprocess.Popen(["xdg-open", LOCAL_DIR])
    elif action == "web": subprocess.Popen(["xdg-open", "https://onedrive.live.com"])
    elif action == "log": subprocess.Popen(["xdg-open", LOG_FILE])

def quit_app(_):
    Gtk.main_quit(); sys.exit(0)

def on_interval_toggled(widget, mins):
    # 防止初始化时触发
    if is_initializing: return
    if widget.get_active(): set_timer_interval(mins)

# ================== UI 构建 ==================
indicator = AppIndicator3.Indicator.new("rclone-onedrive", os.path.join(ICON_DIR, "idle.svg"), AppIndicator3.IndicatorCategory.APPLICATION_STATUS)
indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
menu = Gtk.Menu()

item_status = Gtk.MenuItem(label="状态：初始化中"); item_status.set_sensitive(False); menu.append(item_status)
menu.append(Gtk.SeparatorMenuItem())
item_sync = Gtk.MenuItem(label="立即双向同步"); item_sync.connect("activate", manual_sync); menu.append(item_sync)
item_folder = Gtk.MenuItem(label="打开本地文件夹"); item_folder.connect("activate", lambda _: open_actions("local")); menu.append(item_folder)

# --- 自动同步设置子菜单 ---
item_timer_menu = Gtk.MenuItem(label="⏱️ 自动同步设置"); 
menu_timer_submenu = Gtk.Menu(); 
item_timer_menu.set_submenu(menu_timer_submenu)

# 1. 间隔设置 (单选)
item_label_1 = Gtk.MenuItem(label="--- 间隔频率 ---"); item_label_1.set_sensitive(False); menu_timer_submenu.append(item_label_1)
intervals = [("10 分钟", 10), ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240)]
curr = get_current_interval(); grp = None
for lbl, m in intervals:
    itm = Gtk.RadioMenuItem(group=grp, label=lbl); 
    if grp is None: grp = itm
    if m == curr: itm.set_active(True)
    itm.connect("toggled", on_interval_toggled, m); menu_timer_submenu.append(itm)

menu_timer_submenu.append(Gtk.SeparatorMenuItem())

# 2. 固定时间设置 (复选 + 微调框)
item_label_2 = Gtk.MenuItem(label="--- 每天定时 ---"); item_label_2.set_sensitive(False); menu_timer_submenu.append(item_label_2)

# 读取状态
curr_fixed = get_current_fixed_time() # 返回 "17:20" 或 None

# 创建复选菜单项
if curr_fixed:
    fixed_label = f"每天定时同步 ({curr_fixed})"
    item_fixed = Gtk.CheckMenuItem(label=fixed_label)
    item_fixed.set_active(True)
else:
    fixed_label = "每天定时同步"
    item_fixed = Gtk.CheckMenuItem(label=fixed_label)
    item_fixed.set_active(False)

# 连接信号
item_fixed.connect("toggled", on_fixed_time_toggled)
menu_timer_submenu.append(item_fixed)

menu.append(item_timer_menu)

item_restart = Gtk.MenuItem(label="重启程序与服务 (全量重载)"); item_restart.connect("activate", action_restart_all); menu.append(item_restart)
menu.append(Gtk.SeparatorMenuItem())

item_adv = Gtk.MenuItem(label="高级选项"); menu_adv = Gtk.Menu(); item_adv.set_submenu(menu_adv)
item_res = Gtk.MenuItem(label="强制重置同步 (--resync)"); item_res.connect("activate", force_resync); menu_adv.append(item_res)
menu_adv.append(Gtk.SeparatorMenuItem())
item_edit = Gtk.MenuItem(label="编辑配置文件"); menu_edit = Gtk.Menu(); item_edit.set_submenu(menu_edit)
item_edit_rc = Gtk.MenuItem(label="编辑 Rclone 配置"); item_edit_rc.connect("activate", lambda _: edit_file(RCLONE_CONF)); menu_edit.append(item_edit_rc)
item_edit_sv = Gtk.MenuItem(label="编辑 Service 服务"); item_edit_sv.connect("activate", lambda _: edit_file(SERVICE_FILE)); menu_edit.append(item_edit_sv)
item_edit_tm = Gtk.MenuItem(label="编辑 Timer 定时器"); item_edit_tm.connect("activate", lambda _: edit_file(TIMER_FILE)); menu_edit.append(item_edit_tm)
item_edit_py = Gtk.MenuItem(label="编辑本程序 (Python)"); item_edit_py.connect("activate", lambda _: edit_file(os.path.abspath(__file__))); menu_edit.append(item_edit_py)
menu_adv.append(item_edit); menu_adv.append(Gtk.SeparatorMenuItem())
item_web = Gtk.MenuItem(label="访问 OneDrive 网页版"); item_web.connect("activate", lambda _: open_actions("web")); menu_adv.append(item_web)
menu.append(item_adv)

item_log = Gtk.MenuItem(label="查看运行日志"); item_log.connect("activate", lambda _: open_actions("log")); menu.append(item_log)
item_time = Gtk.MenuItem(label="上次同步：未知"); item_time.set_sensitive(False); menu.append(item_time)
menu.append(Gtk.SeparatorMenuItem())
item_quit = Gtk.MenuItem(label="退出"); item_quit.connect("activate", quit_app); menu.append(item_quit)

# 标记初始化完成，允许信号触发
is_initializing = False

menu.show_all(); indicator.set_menu(menu)

def update_ui_immediate(): update_ui_logic()
def update_ui_logic():
    global last_status_code
    status = read_status()
    if not network_online():
        indicator.set_icon(os.path.join(ICON_DIR, "offline.svg")); indicator.set_title("离线"); item_sync.set_sensitive(False); item_status.set_label("状态：等待网络连接"); return status
    if status == "SYNCING":
        indicator.set_icon(os.path.join(ICON_DIR, "syncing.svg")); item_sync.set_sensitive(False)
        pt = syncing_progress()
        if pt: indicator.set_title(f"同步中: {pt}"); item_status.set_label(f"状态：{pt}")
        else: indicator.set_title("同步中..."); item_status.set_label("状态：正在分析变更...")
    elif status == "FAILED":
        indicator.set_icon(os.path.join(ICON_DIR, "failed.svg")); indicator.set_title("同步失败"); item_sync.set_sensitive(True); item_status.set_label("状态：上次同步失败")
        if last_status_code == "SYNCING": send_notification("OneDrive 同步失败", "请检查日志", True)
    else:
        indicator.set_icon(os.path.join(ICON_DIR, "idle.svg")); indicator.set_title("OneDrive"); item_sync.set_sensitive(True); item_status.set_label("状态：空闲")
        if last_status_code == "SYNCING": send_notification("OneDrive 同步完成", "文件已更新")
    item_time.set_label(f"上次同步：{last_sync_time()}")
    last_status_code = status
    return status

def auto_refresh():
    status = update_ui_logic()
    GObject.timeout_add(1500 if status == "SYNCING" else 10000, auto_refresh)
    return False

auto_refresh()
Gtk.main()
EOF_PYTHON

# =========================================================
# 3. 写入安装脚本 (install.sh) - 保持不变
# =========================================================
cat > "$INSTALLER_DIR/install.sh" << 'EOF_INSTALL'
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
    echo ">>> 正在执行: sudo apt update && sudo apt install rclone"
    sudo apt update && sudo apt install -y rclone
    
    if ! command -v rclone &> /dev/null; then
        echo "⚠️  Apt 安装失败或版本过低，尝试使用官方脚本安装..."
        if ! command -v curl &> /dev/null; then sudo apt install -y curl; fi
        curl https://rclone.org/install.sh | sudo bash
    fi
    
    if ! command -v rclone &> /dev/null; then
        echo "❌ Rclone 安装失败，请手动安装后重试。"
        exit 1
    fi
    echo "✅ Rclone 安装成功！"
fi

# 3. 检查配置
echo "🔍 正在检查 Rclone 配置..."
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

mkdir -p "$INSTALL_DIR"
mkdir -p "$ICONS_DIR"
mkdir -p "$SYSTEMD_DIR"
mkdir -p "$APP_DIR"
mkdir -p "$USER_HOME/.cache"
mkdir -p "$USER_HOME/OneDrive" 

cp "$(dirname "$0")/rclone-tray.py" "$INSTALL_DIR/rclone-tray.py"
chmod +x "$INSTALL_DIR/rclone-tray.py"

echo "🎨 生成图标..."
cat > "$ICONS_DIR/idle.svg" <<EOF
<svg width="64" height="64" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#0078D4"/></svg>
EOF
cat > "$ICONS_DIR/syncing.svg" <<EOF
<svg width="64" height="64" viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#E3E3E3"/><path d="M32 24v-4l-6 6 6 6v-4c4.4 0 8 3.6 8 8s-3.6 8-8 8-8-3.6-8-8h-4c0 6.6 5.4 12 12 12s12-5.4 12-12-5.4-12-12-12z" fill="#0078D4"/></svg>
EOF
cat > "$ICONS_DIR/failed.svg" <<EOF
<svg width="64" height="64" viewBox="0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#E3E3E3"/><circle cx="48" cy="48" r="14" fill="#D13438"/><path d="M46 40h4v10h-4zm0 12h4v4h-4z" fill="#FFFFFF"/></svg>
EOF
cat > "$ICONS_DIR/offline.svg" <<EOF
<svg width="64" height="64" viewBox="0 64 64" xmlns="http://www.w3.org/2000/svg"><path d="M49.6 22.4c0-6.6-5.4-12-12-12-5 0-9.2 3.1-11.1 7.4C25.3 16.6 23.7 16 22 16c-5.5 0-10 4.5-10 10 0 0.8 0.1 1.6 0.3 2.3-5.1 1.4-8.3 6-8.3 11.3 0 6.6 5.4 12 12 12h33.6c6.6 0 12-5.4 12-12 0-6.5-5.2-11.8-11.6-12H49.6z" fill="#A0A0A0"/><line x1="10" y1="54" x2="54" y2="10" stroke="#FFFFFF" stroke-width="4"/></svg>
EOF

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

echo "🖥️  创建桌面图标..."
if [ -d "$DESKTOP_DIR" ]; then
    cp "$APP_DIR/rclone-onedrive.desktop" "$DESKTOP_DIR/"
    chmod +x "$DESKTOP_DIR/rclone-onedrive.desktop"
    echo "✅ 桌面图标已创建。"
else
    echo "⚠️  未找到桌面目录 $DESKTOP_DIR，跳过桌面图标创建。"
fi

echo "📜 配置日志自动清理..."
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

echo "🚀 启动服务中..."
systemctl --user daemon-reload
systemctl --user enable --now rclone-onedrive.timer

mkdir -p "$USER_HOME/.config/autostart"
cp "$APP_DIR/rclone-onedrive.desktop" "$USER_HOME/.config/autostart/"

echo "=========================================="
echo "✅ 安装完成！"
echo "1. 后台同步服务已启动。"
echo "2. 桌面已生成 'OneDrive 同步助手' 图标。"
echo "3. 请双击桌面图标启动程序。"
echo "=========================================="
EOF_INSTALL
chmod +x "$INSTALLER_DIR/install.sh"

# =========================================================
# 4. 写入卸载脚本 (uninstall.sh)
# =========================================================
cat > "$INSTALLER_DIR/uninstall.sh" << 'EOF_UNINSTALL'
#!/bin/bash
echo "⚠️  正在卸载 OneDrive 托盘程序..."

systemctl --user stop rclone-onedrive.timer
systemctl --user stop rclone-onedrive.service
systemctl --user disable rclone-onedrive.timer
systemctl --user disable rclone-onedrive.service

rm -f ~/.local/bin/rclone-tray.py
rm -rf ~/.local/share/icons/rclone
rm -f ~/.config/systemd/user/rclone-onedrive.service
rm -f ~/.config/systemd/user/rclone-onedrive.timer
rm -f ~/.local/share/applications/rclone-onedrive.desktop
rm -f ~/.config/autostart/rclone-onedrive.desktop
rm -f ~/Desktop/rclone-onedrive.desktop
rm -f ~/.cache/rclone-onedrive.status
rm -f ~/.cache/rclone_tray.lock

echo "正在删除日志配置 (需要 sudo)..."
sudo rm -f /etc/logrotate.d/rclone-onedrive

systemctl --user daemon-reload

echo "✅ 卸载完成。"
EOF_UNINSTALL
chmod +x "$INSTALLER_DIR/uninstall.sh"

echo "✅ 安装包生成成功！"
echo "位置: $INSTALLER_DIR"
echo "请将该文件夹妥善保存。重装系统后，进入该文件夹运行 ./install.sh 即可。"