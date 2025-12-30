# onedrive-in-tongxinOS
在统信OS系统中通过rclone安装onedrive

通过rclone安装onedrive

1.在终端运行 bash install.sh；

2.文件夹里的 uninstall.sh 为环境卸载程序；

3.文件夹里的rclone-tray.py为程序本体。

首先脚本会检测有没有安装rclone，没有会提示安装；
然后进行onedrive的配置；
最后自动把所有服务、图标、Python 脚本都安装好，并启动服务。

注意：make_installer.sh是生成文件，没有问题不用管，有问题直接拿着这个找AI解决，通过在终端运行“bash make_installer.sh”会生成其他文件，其他文件才是程序文件。

<img width="244" height="260" alt="界面截图" src="https://github.com/user-attachments/assets/c12040a9-4dad-433d-bb59-dd04a5b7fdb5" />
