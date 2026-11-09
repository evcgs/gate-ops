# deploy-guard · 部署入口收口（002 / P1 影子模式）

> 版本：v0.1 · 2026-11-06（2026-11-07 更新状态）
> 状态：**脚本已实现并通过本地自测；尚未部署到任何服务器**。`authorized_keys`、凭据文件、profile、001 面板与主 UI 均未改动。
>
> **2026-11-07 本地闭环批次**：dsh 插件 `lib/core.js` 已加入 T-14/T-15 窗口编排（`index.js` 零改动），**默认关闭**，需显式配置 `windowEnabled` + ssh 目标才生效。本地闭环 `local-loop.mjs` `12/0` ×2、001 自测 `37/0`、面板 E2E `10/0` ×2、门禁 `24/6` 不劣化。详见 `~/user-home/Desktop/gate-ops/deploy-guard/verification-20261107.md`。
>
> 两处仍未收口：① 目标服务器不在可达网络（T-12 暂停，见 §3.1）；② ~~本机 macOS OpenSSH 无法作真实 SSH 假目标，SSH 协议层未验证~~ —— **2026-11-08 该缺口已补齐**：在另一台可连的 Linux 主机上以「追加 1 行 + 原 4 行不动 + 跑完精确还原」跑通 L-00~L-14（`15/0` ×2），服务器回到接线前状态。详见 `deploy-guard/verification-20261108.md` 与 `remote-e2e.mjs`。**该机不是 002 目标机**（无 `project-compose` 站点），本次仅为可摘除的协议层验证，**不是 T-12 生产接线**。G-1 旧共用 key 旁路未解决，**不得切 `enforce`、不得宣称物理收口**。
> 上位文档：`~/user-home/Desktop/gate-ops/deploy-guard/` 下 `constitution.md` / `spec.md` / `clarify-20261106.md` / `plan.md` / `quality.md` / `tasks.md`。

---

## 1. 文件与位置

| 文件 | 位置 | 作用 |
|---|---|---|
| `gateo-window-open.sh` | 真源 `scripts/` | 复用 `_approval.sh::gateo_load_plan` 校验计划，签发 HMAC 窗口凭证 |
| `gateo-window-close.sh` | 真源 `scripts/` | 签发短时效关窗凭证（供 `finally` 调用） |
| `gateo-window-selftest.sh` | 真源 `scripts/` | 纯本地行为自测，临时目录 + 临时密钥 |
| `deploy-guard.sh` | 真源 `scripts/`（源）→ 服务器 `~/.gateops/`（部署） | forced command 入口，窗口校验 + 留痕 + 原样 exec |
| 本文 | 真源 `integrations/deploy-guard/` | 安装、切换、应急、摘除、口径登记 |

现有 14 个 `.sh` 一行未改；新增文件不撞名。

---

## 2. 前置条件

| 端 | 要求 |
|---|---|
| 本地 | bash 3.2+、`openssl`（HMAC-SHA256）、`ssh-keygen` |
| 服务器 | bash 3.2+、`openssl`、登录用户可写 `~/.gateops/`；**不需要 sudo**（部署脚本全程零 `sudo`） |
| 密钥 | 本地 `~/.gateo/guard.secret` 与服务器 `~/.gateops/guard.secret` **内容一致**，均 0600；不进 git、不进回执 |
| deploy key | 为 `project-compose` 单独生成，公钥追加到 `authorized_keys` 并绑 `command=`；原共用 key 保持不受限，作为应急回滚通道 |

> 两处 `guard.secret` 内容必须逐字节一致。命令替换 `$(cat ...)` 会去掉尾部换行，两端实现一致，不要在文件末尾额外加空行。

---

## 3. 服务器端安装（T-12）

### 3.1 阻塞根因：SSH 入站通道不可达（2026-11-06 20:53 复核）

> **2026-11-07 14:48 状态更新**：用户确认「远程服务器当前访问不了，已不在对应网络中」。本节证据与排查清单**仅作留档**，不再执行任何连接探测；002 服务器端部分暂停，恢复条件与当前交付状态见 `tasks.md §0.3`。

**先前判断已修正**：初判「目标主机对本会话出口不可达」不成立。用户在**自己的外部终端**执行同一脚本，同样在连通性前置处失败。因此这不是 WorkBuddy 会话的网络限制，也不是脚本或凭据问题。

| 证据 | 结果 |
|---|---|
| 用户本机执行 `t12-install.sh` | 同样报「目标服务器 SSH 不可达」，零副作用退出 |
| 目标主机 22 / 80 / 5002 / 8080 / 2222 / 2200 / 22222 / 10022 / 8022 | 全部 filtered/closed（超时，非 refused） |
| 目标主机 443 | **open**，二次确认稳定 |
| `https://report.example.com/` | **HTTP 200**，`server: nginx` |
| DNS `report.example.com` | 解析结果**等于**凭据里的目标主机 |
| 从 `aliyun-web` 主机测目标机 22 | 同样不通（排除「只对跳板放行」） |
| 8 个档案共 3 台目标主机 | **3 台 22 全部不通**；对照 `aliyun-web` 22 通 |
| `~/.ssh/known_hosts` | 有 3 条目标机记录，证明历史上直连成功过 |
| 17:06 发版证据 | `gateo-deploy-output.txt` 记录备份 / 探活 / 发布全部成功，目标 `root@<server>`；**最后一次成功直连在约 3 小时前** |
| 本机公网出口（20:59 用户实测） | `101.71.203.141`；`curl` 走代理与 `--noproxy '*'` 直连**返回同一出口**，路由网关 `192.168.3.1 / en0`，非 utun → 该 IP 就是 SSH 直连源 IP，可用于核对安全组 |
| TUN / 代理分流 | **已排除**：本机虽有 6 个 utun 接口与 loopback HTTP 代理，但到目标机与到可达主机的路由均为 `en0`；`~/.ssh/config` 无 `ProxyCommand` / `ProxyJump`；绑定 en0 源地址复测仍是 22 不通、443 通 |

**判定**：目标主机（及其余两台 gate-ops 目标机）当前**只对外放行 443，SSH 入站整体不可达**；服务仍活着。超时而非 refused，更符合安全组 / 防火墙 DROP，而非 sshd 单纯崩溃。本机侧（代理、TUN、路由、凭据、脚本）已全部排除。影响面**不止 T-12**：整个 gate-ops 发版与回滚链路此刻都不可用。

**最可能的一条根因**：本机宽带重拨导致公网出口 IP 变化，三台服务器安全组的 22 入站白名单仍写旧 IP —— 这能同时解释「三台一起断」「17:06 之前都通」「443 不受影响（通常放行 0.0.0.0/0）」。

优先排查顺序：

1. **云控制台 → ECS → 安全组 → 入方向 22 规则**：核对「授权对象」是否含 `101.71.203.141/32`。不含则加一条临时规则后复测；已含则问题在服务器内部。
2. 服务器内部排查需通过**云控制台 VNC / 远程连接进入实例**（`systemctl` / `ss` / `iptables` 是 Linux 命令，**不能在 Mac 本机终端执行**）：`systemctl status sshd`、`ss -lntp | grep :22`、`iptables -L -n`、`firewall-cmd --list-all`、`fail2ban-client status`。
3. 是否新引入堡垒机 / 跳板，需改用 `ProxyJump` 连接。
4. 核对凭据中的目标 IP 是否已在服务器迁移后失效（DNS 目前仍指向它）。

**SSH 恢复后无需改动任何代码或脚本**：`t12-install.sh` 已做幂等与失败自动回退，直接在可连通的终端重跑同一条命令即可。

脚本已封装如下（连通性不通过时立即退出、零副作用）：

```bash
# 接线（一键，含备份 / 部署 / 验证 / 失败自动回退）
GATEOPS_ASSUME_YES=1 bash ~/user-home/Desktop/gate-ops/deploy-guard/t12-install.sh

# 或：交互式确认（输入 yes）
bash ~/user-home/Desktop/gate-ops/deploy-guard/t12-install.sh

# 一键摘除
bash ~/user-home/Desktop/gate-ops/deploy-guard/t12-install.sh --rollback
```

脚本自行完成 T-01（本地 3 份备份）、T-02（专用 deploy key + `guard.secret`）、T-12（服务器接线），并输出脱敏结果到 `deploy-guard/t12-result-<ts>.txt`。连通性不通过时立即退出且零副作用（已实测预演）。

### 3.2 等价手工步骤（供审阅，脚本已封装）

```bash
# 服务器上，以部署登录用户执行
install -d -m 700 ~/.gateops
install -m 700 /path/to/deploy-guard.sh ~/.gateops/deploy-guard.sh
install -m 600 guard.secret ~/.gateops/guard.secret
printf 'shadow' > ~/.gateops/guard.mode
chmod 600 ~/.gateops/guard.mode

# ~/.ssh/authorized_keys 追加一行（原行一律不动）
command="/home/<user>/.gateops/deploy-guard.sh" ssh-ed25519 AAAA... gateops-project-compose-shadow
```

**注意**：`command=` 内必须写展开后的绝对路径，sshd 不展开 `$HOME`。追加前先备份 `authorized_keys`，并确认原共用 key 仍可登录。

验证：

```bash
ssh -i <原共用key> <server> 'true'                      # 应急通道必须通
ssh -i <新key> <server> '__GATEOPS_STATUS__'            # mode=shadow windowValid=0
ssh -i <新key> <server> 'echo guard-proxy-ok'           # 影子模式原样执行
```

---

## 4. 使用（开窗 → 发版 → 关窗）

```bash
export GATEO_GUARD_SECRET_FILE="$HOME/.gateo/guard.secret"

# 0) 切换 deploy key 后必须重新生成计划（plan D-15：SSH_KEY 进 CONFIG_HASH）
#    precheck → plan → 用户确认 planId

# 1) 签发并开窗
OPEN_TOKEN=$(bash scripts/gateo-window-open.sh \
    "$HOME/.gateo/plans/GTO-xxx.plan" "GTO-xxx")
ssh -i <新key> <server> "__GATEOPS_OPEN__ ${OPEN_TOKEN}"

# 2) 发版（真源脚本原样调用，未改动）
bash scripts/gateo-apply.sh "$HOME/.gateo/plans/GTO-xxx.plan" "GTO-xxx"

# 3) 关窗（T-15 后由 gateops_apply 的 finally 自动执行）
CLOSE_TOKEN=$(bash scripts/gateo-window-close.sh "GTO-xxx")
ssh -i <新key> <server> "__GATEOPS_CLOSE__ ${CLOSE_TOKEN}"

# 状态查询
ssh -i <新key> <server> '__GATEOPS_STATUS__'
```

**为什么控制命令写在客户端命令位置**：`authorized_keys` 的 `command=` 会让 sshd 忽略客户端命令，把它原样放进 `SSH_ORIGINAL_COMMAND`。guard 用固定前缀 `__GATEOPS_OPEN__` / `__GATEOPS_CLOSE__` / `__GATEOPS_STATUS__` 精确分流；其它命令一律视为部署命令，校验窗口后 `exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"`。

---

## 5. 模式切换（P2，须先过 plan §6 门禁）

```bash
printf 'enforce' > ~/.gateops/guard.mode
```

切换前必须逐项通过 G-1~G-6，**尤其 G-1：旧共用 key 仍能不经 guard 部署 project-compose**。旁路未关闭时切强制只是「看起来收口了」，不得据此做治理结论。

退回影子：`printf 'shadow' > ~/.gateops/guard.mode`。

---

## 6. 日志

`~/.gateops/guard.log`，append-only，0600：

```text
ts|planId|nonce|decision|reason|cmdLen|cmdHash12
```

`decision`：`allow` / `deny-would-be`（影子）/ `deny`（强制）。
`reason`：`ok` / `no-valid-window` / `expired` / `bad-signature` / `replay` / `window-unverifiable` / `guard-degraded` / `window-opened` / `window-closed`。

**不写命令原文**；`cmdHash12` 是命令 SHA256 前 12 位，仅用于按 planId 对账，不可逆、不参与判定。日志零 IP / 邮箱 / 绝对路径 / 密钥值。

`~/.gateops/window` 存的是带签名的原始 token（0600），forced 分支每次验签，避免只改窗口文件就伪造窗口。`nonce.used` append-only 防重放。

---

## 7. 应急与一键摘除

应急：原共用 key 不受 `command=` 约束，`rollback.sh` 在窗口关闭/过期时仍可直接执行（铁律 6）。

```text
1) 服务器：删除 authorized_keys 中新追加的那一行（原行不动）
2) 服务器：删除 ~/.gateops/ 全部内容
3) 本地：还原 ~/.gateo/credentials.sh 备份（CRED_<PROJECT>_SSH_KEY 改回原值）
4) 本地：删除 4 个新增脚本、integrations/deploy-guard/、新 deploy key、guard.secret
5) dsh 插件：按 .bak 还原 core.js / index.js（若已执行 T-14/T-15）
6) 复验：001 面板 E2E 10/0、聚合门禁 24/6、gateo-doctor.sh 全 OK
```

真源既有文件、三端软链、001 面板与主 UI 产物不在回退链路上。

---

## 8. 相对 spec / plan 的口径细化登记

| 项 | 细化 | 理由 |
|---|---|---|
| `plan D-04` | forced command 会忽略客户端命令，故控制子命令必须借 `SSH_ORIGINAL_COMMAND` 固定前缀分流。这是**精确前缀匹配**，不做语义解析、不对部署命令做白名单；部署命令仍原样 exec | sshd 行为决定，不这样做无法开窗/关窗/查状态 |
| `spec FR-05` | 「命令类别」实现为 `cmdLen` + `cmdHash12` 不可逆指纹，不记录也不解析命令内容 | 与 D-04「不解析」保持一致，同时满足零敏感词与按 planId 对账 |
| `plan D-07` | 服务器密钥与窗口落用户级 `~/.gateops/`，不写 `/etc/gateops/` | 实测部署脚本零 `sudo`，clarify H-05 的服务器权限未核实 |
| `quality Q-14` | `gateops_apply` 异常路径 `finally` 关窗属 T-15，本批次自测标 SKIP，完整验证待 T-15 | 不假装覆盖 |

---

## 9. 本批次明确未做

1. 未登录服务器、未改 `authorized_keys`、未写 `~/.gateops/`。
2. 未生成真实 deploy key / `guard.secret`，未改 `~/.gateo/credentials.sh`（T-02 / T-13 留到 T-12 授权时一并做，避免产生未接线的悬挂资产）。
3. 未改 dsh 插件、未改 001 交付物、未重启 3080。
4. 未真实发版、未 `git commit`、未发布、未同步桌面快照。
5. 未切 `enforce`；P1 不提供物理收口，不宣称已收口。
