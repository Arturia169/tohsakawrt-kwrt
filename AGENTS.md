# 给 AI / 维护者的开工须知

本仓库是 **Cudy TR3000 路由器上运行的 TohsakaWrt 管理套件的源码仓**。
维护方式：由 AI 协助修改 → 在实机上验证 → 回写本仓库 → 提交推送。

## 0. 三条最容易犯的错（先看这个）

1. **权威副本只有一个**：N100 上的 `/root/workspace/tohsakawrt-kwrt`。
   不要用从别处解包/复制的副本改 —— Windows 解包会**丢可执行位**、**中文文件名变乱码**。
2. **仓库文件 ↔ 设备文件一一对应**：`devices/mediatek_filogic/files/xxx` 对应设备上的 `/xxx`
   （例：`files/usr/bin/tohsakawrt` → `/usr/bin/tohsakawrt`）。改完两边必须一致，并核对 md5。
3. **改行为必须同步改用例**：`tests/` 下的断言**只能加、不能删**。

## 1. 环境与访问

- 设备：`root@192.168.100.1`（N100 上有免密密钥 `~/.ssh/id_ed25519_tr3000`）
- 构建/暂存机：`root@192.168.100.50`
- 设备是 BusyBox 环境：**没有 `timeout`**（除非装过 `coreutils-timeout`）；`flock` **不支持 `-w`**
- 设备上的 AT 通路：`/usr/share/modem/modem_at.sh` → `modem_debug.sh` 的 `at()` → `sms_tool`

## 2. 改动标准流程

```sh
# ① 先备份（在设备上）
f=/usr/bin/tohsakawrt                                  # 换成要改的文件
cp -a "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"

# ② 语法检查（过不了这一关就不要装）
sh  -n "$f"                                            # shell 脚本
lua -e "assert(loadfile('$f'))"                        # Lua 脚本

# ③ 跑仓库测试（在 N100 上）
cd /root/workspace/tohsakawrt-kwrt
for t in tests/*.sh;  do sh  "$t" || echo "FAIL $t"; done
for t in tests/*.lua; do lua "$t" || echo "FAIL $t"; done
# 预期：全部通过；若缺 JSON 模块，test_esim.lua 会打印 SKIP（不算失败）

# ④ 实机验证通过后，才回写仓库、提交、推送
```

## 3. 铁律

- **不许硬编码任何凭据或号码**：机器人 token / chat_id / user_id / Bark key / 流量卡号，
  一律放 `uci tohsakawrt-tgbot.main.*`；仓库里的 `etc/config/tohsakawrt-tgbot` 只能是空模板。
- **一个功能只允许一份实现**：
  - 切换上网线路 → 只有 `usr/bin/tohsakawrt-uplink`（Lua 的 `system.lua:switch_uplink` 只是**委托**它）
  - 模组自愈 → 只有 `usr/bin/tohsakawrt-modem-heal`（命令行的 `modem heal` 只是**委托**它）
  - 发通知 → shell 侧只有 `usr/lib/tohsakawrt/common.sh`；Lua 侧只有 `tg.lua`
- **跟模组说话必须走 `modem_at.sh`**：AT 的硬超时与全局互斥只在 `modem_debug.sh` / `modem_at.sh` 两处，
  不要在别处直接调 `sms_tool`。
- **状态文件都在 `/tmp`**：重启即失忆，不要假设任何状态会持久。
- **出口切换 / 模组复位 / 机器人鉴权**这三块最容易造成"断网"或"把自己锁在机器人外面"，
  动手前必须先说明风险、并保留一键回滚。

## 4. 借来的文件（第三方包提供的覆盖文件，尽量别改）

`usr/share/modem/quectel.sh`、`modem_info.sh`、`modem_debug.sh`、`modem_at.sh`、
`usr/lib/lua/luci/view/modem/modem_info.htm`

它们来自 `luci-app-modem` 包；本仓库里的同路径文件是**覆盖文件**（构建时盖在包上面）。
必须改时，在改动处写明**为什么**（否则日后无法判断能否跟随上游更新）。

## 5. 出事了怎么回滚

```sh
# 设备：用 .bak-<时间戳> 覆盖回去，再重启机器人
cp -a /usr/bin/tohsakawrt.bak-20261007-055707 /usr/bin/tohsakawrt
/etc/init.d/tohsakawrt-tgbot restart

# 仓库：丢弃工作区改动，或回退某次提交
git checkout -- <文件>
git revert <提交>
```

## 6. 已知欠账（不要当成新发现的 bug）

**已于 2026-10-07 修复**（如再遇到，说明改动被回退了，而不是"本来就有的问题"）：
- ~~消息超 4096 字符被整条拒收~~ → `tg.lua` 已自动按行分片，键盘挂最后一片，标签不平衡时降级为纯文本
- ~~429 限流直接失败丢消息~~ → 已按 `retry_after` 退避重试一次；401（令牌无效）/409（多实例冲突）有明确日志
- ~~offset 在处理前落盘、处理中重启丢指令~~ → 已改为**处理完成后**落盘（最多重做一次）
- ~~通知"发了就算完"、状态却先落盘~~ → `send_tg` 已校验 Telegram 回 `ok:true`，失败重试并记日志
- ~~流量卡号硬编码在脚本里~~ → 已改为 `uci tohsakawrt-tgbot.main.flowcard_no`
- ~~机器人单文件 1329 行~~ → 已拆成 1 主 + 6 模块（见第 8 节）

**仍然存在**：
- eSIM 任务文件从不清理；`new_job_id` 同秒可能撞号
- UCI 里写的是"宽带优先"，而实机可能靠静态路由跑在 5G 上（用户明确表示不改此项）
- 按钮交互的耗时已从估算约 3.5 秒降到实测 1.6 秒（看板）/ 3.0 秒（出口菜单）；
  剩余时间主要在"采集数据"（约 1.1~1.8 秒），做后台预热可再省约 1 秒，**暂不做**

## 7. 提交与发布

- 提交信息用中文，说清"改了什么 + 为什么"
- 推送目标：`origin` = `github.com/Arturia169/tohsakawrt-kwrt`，分支 `tohsakawrt`
- 云端构建：`.github/workflows/Openwrt-AutoBuild.yml`（会把 `devices/<target>/files` 打进固件；
  并在构建前跑 `tests/` 的用例，用例不过就中止发布）
- **永远不要把凭据、号码、真实 MAC 写进仓库**

## 8. bot.lua 的模块划分（2026-10-07 拆分完成）

`bot.lua` 原先 1329 行，已按功能拆成 1 个主文件 + 6 个模块。**改功能前先看这张表**：

| 文件 | 放什么 |
|---|---|
| `bot.lua` | 主循环 `M.run`、命令分发器、回调分发器、帮助说明（**只做路由，不放实现**） |
| `bot_common.lua` | 共享零件：模块引用、`html_escape`、`ask_confirm`、`now_ms`、`esim_enabled` |
| `bot_net.lua` | 网络与代理：出口切换、双向体检、节点测试、分流模式、OpenClash 状态/重启、宽带详情 |
| `bot_sys.lua` | 系统信息：综合看板、温度、在线设备、存储、USB |
| `bot_modem.lua` | 模组与短信：模组状态卡、短信列表与验证码 |
| `bot_esim.lua` | 卡内号码与 eSIM 任务（启停用、切换配置） |
| `bot_direct.lua` | 直连白名单与设备备注 |

**规矩**：
- 新增命令时，**实现放进对应的 `bot_*.lua`**（没有合适的就新建一个），分发器里只加一行路由；
- 模块里的命令函数一律写成 `function M.xxx(...)`，分发器用 `模块前缀.xxx(...)` 调用；
- 共享零件统一放 `bot_common`，不要在别的模块里再 require 一遍 core/tg/sys/modem/clash/esim；
- **用例若会清空 `package.loaded`，必须把新模块也加进清理列表**，否则场景之间会复用上一个场景的桩件。
