# onedrive-in-tongxinOS
在统信OS系统中通过rclone安装onedrive

通过rclone安装onedrive

为了解决“个人保管库”报错，改为使用“Rclone combine（联合/组合） 模式”，这个模式下，根目录单个文件不会同步，只会同步根目录下的文件夹。

1. 需要在终端运行bash make_installer.sh，然后在同目录下生成文件夹OneDrive-Tray-Installer，进入到目录下；
2. 在如果存在旧版，需要通过bash uninstall.sh清理掉旧版程序，没有则进行下一步；（运行卸载脚本，清理掉你电脑上旧的脚本、旧的服务文件和可能残留的配置。不用担心，这不会删除你的 rclone.conf 配置，也不会删除你本地 OneDrive 文件夹里的数据。）
3. 安装新的版本在终端运行bash install.sh，会生成桌面图标，弹框需要开机启动的权限；
4. 双击桌面上新生成的 “OneDrive 同步助手” 图标，右键/左键点击托盘图标 -> “高级选项”，选择 “强制重置同步 (--resync)”，强制同步完成，再手动“立即双向同步”。

首先脚本会检测有没有安装rclone，没有会提示安装；
然后进行onedrive的配置；
最后自动把所有服务、图标、Python 脚本都安装好，并启动服务。

注意：make_installer.sh是生成文件，没有问题不用管，有问题直接拿着这个找AI解决，通过在终端运行“bash make_installer.sh”会生成其他文件，其他文件才是程序文件。

<img width="244" height="260" alt="界面截图" src="https://github.com/user-attachments/assets/c12040a9-4dad-433d-bb59-dd04a5b7fdb5" />
