# 服务器拓扑模板（复制本文件填写你自己的环境；真实拓扑永不入库）

## 拓扑
- 服务器：`<server>`（多应用共享 / 独享）
- 应用目录：`/www/wwwroot/<app>/`（BUILD_SRC / RSYNC_DEST / BACKUP_DIR）
- 容器与端口：`<container>`（0.0.0.0:<host>→<container>）

## 强隔离铁律（多应用共享服务器时必填）
- 本系统只可触碰：目录 X / 容器 Y / 端口 Z
- 不可触碰的兄弟应用：端口清单（误伤即事故）
- 不改 Nginx 全局配置、不 restart 其他容器

## 凭据
仅存 `~/.gateo/credentials.sh`（变量 `CRED_<PROJECT>_*`），本文件只引变量名。
