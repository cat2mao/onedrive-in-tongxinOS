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

# 单实例检测
LOCK_FILE_PATH = os.path.join(os.path.expanduser("~/.cache"), "rclone_tray.lock")
try:
    if not os.path.exists(os.path.dirname(LOCK_FILE_PATH)):
        os.makedirs(os.path.dirname(LOCK_FILE_PATH))
    _lock_file = open(LOCK_FILE_PATH, "w")
    fcntl.lockf(_lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
except IOError:
    print("程序已在运行中，退出当前实例。")
    sys.exit(1)

# 常量配置
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

# 工具函数
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

# 动作函数
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

def set_timer_interval(minutes):
    if not os.path.exists(TIMER_FILE):
        send_notification("错误", "找不到 Timer 文件", True); return
    if get_current_interval() == minutes: return
    try:
        with open(TIMER_FILE, 'r') as f: content = f.read()
        new_val = f"OnUnitActiveSec={minutes}m"
        if "OnUnitActiveSec=" in content: new_content = re.sub(r"OnUnitActiveSec=.*", new_val, content)
        elif "[Timer]" in content: new_content = content.replace("[Timer]", f"[Timer]\n{new_val}")
        else: return
        with open(TIMER_FILE, 'w') as f: f.write(new_content)
        subprocess.run(["/usr/bin/systemctl", "--user", "daemon-reload"])
        subprocess.run(["/usr/bin/systemctl", "--user", "restart", TIMER_NAME])
        send_notification("设置成功", f"同步间隔已更新为 {minutes} 分钟")
    except Exception as e:
        send_notification("失败", f"无法写入文件: {e}", True)

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
    if widget.get_active(): set_timer_interval(mins)

# UI 构建
indicator = AppIndicator3.Indicator.new("rclone-onedrive", os.path.join(ICON_DIR, "idle.svg"), AppIndicator3.IndicatorCategory.APPLICATION_STATUS)
indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
menu = Gtk.Menu()

item_status = Gtk.MenuItem(label="状态：初始化中"); item_status.set_sensitive(False); menu.append(item_status)
menu.append(Gtk.SeparatorMenuItem())
item_sync = Gtk.MenuItem(label="立即双向同步"); item_sync.connect("activate", manual_sync); menu.append(item_sync)
item_folder = Gtk.MenuItem(label="打开本地文件夹"); item_folder.connect("activate", lambda _: open_actions("local")); menu.append(item_folder)

item_timer = Gtk.MenuItem(label="⏱️ 设置自动同步间隔"); menu_timer = Gtk.Menu(); item_timer.set_submenu(menu_timer)
intervals = [("10 分钟", 10), ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240)]
curr = get_current_interval(); grp = None
for lbl, m in intervals:
    itm = Gtk.RadioMenuItem(group=grp, label=lbl); 
    if grp is None: grp = itm
    if m == curr: itm.set_active(True)
    itm.connect("toggled", on_interval_toggled, m); menu_timer.append(itm)
menu.append(item_timer)

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
