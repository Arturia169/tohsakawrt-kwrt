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

- 消息超过 4096 字符不分片 → Telegram 拒收、输出静默丢失（`tg.lua` 侧未处理）
- `getUpdates` 不区分 429/401/409，不按 `retry_after` 退避
- offset 在处理消息**之前**提交 → 处理中重启会丢那条指令
- 通知"发了就算完"，但状态已先落盘 → 极端情况下漏报或每分钟重发
- eSIM 任务文件从不清理；`new_job_id` 同秒可能撞号
- UCI 里写的是"宽带优先"，而实机可能靠静态路由跑在 5G 上（用户明确表示不改此项）

## 7. 提交与发布

- 提交信息用中文，说清"改了什么 + 为什么"
- 推送目标：`origin` = `github.com/Arturia169/tohsakawrt-kwrt`，分支 `tohsakawrt`
- 云端构建：`.github/workflows/Openwrt-AutoBuild.yml`（会把 `devices/<target>/files` 打进固件；
  并在构建前跑 `tests/` 的用例，用例不过就中止发布）
- **永远不要把凭据、号码、真实 MAC 写进仓库**
