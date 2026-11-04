# macOS 环境陷阱清单（agent 写/改本技能脚本前必读）

本技能在 macOS（bash 3.2 + BSD userland）下开发与执行。以下陷阱全部来自 2026-11-03
发版链路实战（一次验证曾同时踩中多个），新写脚本或改动现有脚本时逐条对照，改完必须
`bash -n` 全量校验 + 真实环境冒烟一次。

## 1. bash 3.2 多字节变量名陷阱（set -u 下致命）

`$var` 紧跟全角字符（如 `$name（说明）`、`$dir：`）时，bash 3.2 在非 UTF-8 locale 下
会把全角字符的字节并入变量名 → `unbound variable`，且报错指不到真正的变量。

- **规则**：所有紧跟非 ASCII 字符的变量一律加花括号：`${var}（说明）`。
- 2026-11-03 一轮修复共 12 处；这是复发率最高的陷阱，视为必检项。

## 2. BSD grep 不支持 `\|` 交替

`grep 'a\|b'` 在 macOS BSD grep 下把 `\|` 当字面量，静默返回 0 行 → "以为查过了"。

- **规则**：用 `grep -e a -e b`，或 `grep -E 'a|b'`。曾致"本地源码缺 SSO 功能"误报。

## 3. pipefail + `cat | grep -q` 竞态（最隐蔽）

`cat *.js | grep -q 'marker'`：grep 匹配到即提前退出 → cat 收 SIGPIPE（退出码 141）→
`set -o pipefail` 把整个管道判失败 → **匹配成功被误判为"缺失"**。

- **规则**：grep 直接吃文件列表 `grep -qs -e 'marker' dir/*.js`，不走 cat 管道。
- 曾致 C1 验证误阻塞 + "SSO 源码缺失"误判。

## 4. tar 发版携带本地 mtime

tar 全量发布把本地文件的 mtime 原样带到云端 → 云端文件的 mtime 是"本地最后一次修改
时间"，**不能证明有人在服务器上直接改过文件**。

- **规则**：判断"云端是否被热修"只用内容对比（`rsync -rcn` 校验和干跑），永远不用 mtime。
- 2026-11-03 曾因 mtime 误判"云端热修"引发一整轮排查。

## 5. stat 语法差异（BSD vs GNU）

- macOS(BSD)：`stat -f %m <path>`
- Linux(GNU)：`stat -c %Y <path>`

跨平台脚本双写并回退：`stat -f %m f 2>/dev/null || stat -c %Y f 2>/dev/null || echo 0`
（见 `scripts/_lock.sh`）。

## 6. zsh 下 EXIT trap 语义不同（函数返回即触发）

zsh 对**函数体内**设置的 `trap ... EXIT` 会在函数返回时立即执行；bash 是进程退出时执行。
后果：锁类脚本（mkdir 占位 + EXIT trap 释放）在 zsh 下刚拿到锁就被释放，互斥失效。

- **规则**：所有 deploy 脚本必须以 bash 运行（`bash scripts/xxx.sh`，shebang 已是 bash）；
  agent 排查时若在交互式 zsh 里手工 source 脚本做实验，结论不可信。

## 7. `set -e` 下非数值字符串做 `-gt` 比较会静默致命退出（2026-11-03 mock 测试抓出）

`[[ "$x" -gt 0 ]]` 当 `$x` 是非数值字符串（如误把 ps 原始行当计数）时不是"条件为假"，
而是**求值错误 → 整个脚本立即退出（连 if 条件都不豁免 errexit）**；若命令还挂着
`2>/dev/null`，错误信息也被吞掉——表现就是"日志戛然而止、退出码可疑"，极难排查。

- **规则**：`-gt/-lt` 比较前必须先做数值守卫：`[[ "$x" =~ ^[0-9]+$ && "$x" -gt 0 ]]`；
  远程命令拿来的值永远不可信（grep -c 返回计数，但管道任何一环变了就可能拿到别的东西）。
- 位置：deploy-backend.sh 健康检查失败甄别的判活比较。

## 8. 历史实伤记录（2026-11-03 C 验证链）

- profiles 上级目录候选循环缺失 → 档案加载失败（技能布局与脚本假设不一致）
- 陷阱 1/2/3 合计 4 处误报/误判
- v3 重写 deploy-backend.sh 时丢失 docker restart 步骤 → "发版成功"假象，验收 405 抓出

**教训**：重写/大改脚本时，逐功能对照旧版清单（尤其"不起眼的"步骤如 restart）；改完
必须 `bash -n` + 真实环境冒烟。守卫机制自身缺失时必须硬阻塞，不允许静默跳过。
