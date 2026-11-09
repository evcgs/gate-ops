# 过程剧本 · runtime-upgrade（服务器运行时升级）

> 触发词：PHP 升级、运行时升级、语言版本升级、软件包升级、源码重编译。
> 本剧本 v3.5.0 起，源自 2026-11-09 PHP2Shell 三分支源码升级的复盘（教训见下表）。
> **核心认知：服务器运行时升级（PHP/语言/软件包）不是「代码发版」**——它没有 rsync 源码同步、升级是长耗时编译、要备份的是运行时文件而非应用目录。release 剧本的 rsync 预检 / 浏览器 E2E 不适用，须用本剧本的专项闸门。

## 教训 → 闸门对照表（每条都是本次实录）

| 事故 | 闸门 |
|---|---|
| 备份 tar 的是 `RSYNC_DEST`（小目录），真正被改的 php.ini / PHP 二进制没进备份 | **`BACKUP_TARGETS` 按变更对象备份**：显式声明要备份的绝对路径 |
| 编译完才发现版本号不是目标（7.4.34 → 实际 7.4.33） | **`VERSION_CHECK_CMD` + `VERSION_EXPECT` 版本校验**：编译后校验，不一致即 fail |
| 长耗时编译（>120s）把 gateo-apply 的超时打爆 | **长耗时后台运行**：`setsid nohup ... &` 脱离 + 轮询到完成 |
| 升级靠口头授权，没走 planId 确认闸门 | **仍走 plan→confirm→apply**：复用 gate-ops 的确认闸门（custom 模式） |
| rsync 预检对「无代码同步」场景用空目录绕过 | **显式声明无代码同步**：custom 模式 + `CLOUD_APP` 指向专用空目录（语义 = 无 rsync 源），不假装有差异检查 |

## 阶段流程

### 阶段 1 · 目标与影响面锚定（铁律 0 适用）
- 第一行复述：本次升级对象=<运行时/分支> · 目标版本=<X> · 承载站点=<清单> · 依据=用户指定
- 盘点影响面：该运行时承载哪些站点/服务，升级期间是否有瞬断（FPM 重启）

### 阶段 2 · 只读核查升级路径
- 确认升级方式（宝塔 `update` / yum / 源码重编译）+ 当前版本 + configure 参数 + 第三方扩展（SourceGuardian / ZendGuardLoader 等）
- **确认目标版本在源上真实存在**：下载 tarball 后核对内部 `php_version.h`，防镜像标签漂移（本次 7.4.34→7.4.33 的教训）

### 阶段 3 · 备份（按变更对象）
- 档案配置 `BACKUP_TARGETS`（空格分隔绝对路径）：php.ini / FPM 配置 / PHP 二进制 / 扩展目录 / 版本标记
- 走 gate-ops 的备份 → 指纹 → 真实性校验（第 0.5 / 0.6 步）

### 阶段 4 · 升级（长耗时）
- 走 gate-ops custom 模式：`DEPLOY_CUSTOM_CMD` 用 `setsid nohup ... &` 脱离 + 轮询到完成
- 编译期间旧运行时仍在服务（宝塔 update 模式只停最后 `make install` 那几秒）

### 阶段 5 · 版本校验（硬闸门）
- `VERSION_CHECK_CMD` 输出实际版本，`VERSION_EXPECT` 为期望值；不一致即判失败并留痕

### 阶段 6 · 回归验收 + 台账
- 承载站点逐站 `/index.php` 回归（动态入口，不是静态 `/`）+ 探活
- 台账行（records/<项目>.md）：目标 / 结果 / 验收 / 备份 / 健康检查 / agent / 证据 / 备注

## 终点纪律

- 本剧本终点 = **版本校验通过 + 全站回归通过 + 台账行**。
- 升级完 ≠ 自动升下一个分支——下一个分支是新任务，须用户指令。

## 配置契约（新增字段，详见 references/config-schema.md）

| 字段 | 类型 | 说明 |
|---|---|---|
| `BACKUP_TARGETS` | 空格分隔绝对路径 | 备份对象（按变更对象）；设了则覆盖 RSYNC_DEST 备份 |
| `VERSION_CHECK_CMD` | 命令 | 输出实际版本号的命令（如 `php -r 'echo PHP_VERSION;'`） |
| `VERSION_EXPECT` | 字符串 | 期望版本号；与 VERSION_CHECK_CMD 输出不一致则 fail |
