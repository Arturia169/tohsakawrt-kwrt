-- TohsakaWrt Telegram Bot Daemon (Pure Lua)
local M = {}

-- 共享零件统一放在 bot_common（模块引用、转义、确认框、计时、eSIM 开关）
local bc = require("tohsakawrt.bot_common")
local net = require("tohsakawrt.bot_net")
local sysm = require("tohsakawrt.bot_sys")
local dirt = require("tohsakawrt.bot_direct")
local modm = require("tohsakawrt.bot_modem")
local esimm = require("tohsakawrt.bot_esim")

-- 兼容：cmd_ping 已搬到 bot_net，但 bot 模块仍保留同名入口（有用例直接调用 bot.cmd_ping）
M.cmd_ping = net.cmd_ping
local core, tg, sys, modem, clash, esim, nixio =
    bc.core, bc.tg, bc.sys, bc.modem, bc.clash, bc.esim, bc.nixio
local html_escape, ask_confirm, now_ms, esim_enabled =
    bc.html_escape, bc.ask_confirm, bc.now_ms, bc.esim_enabled

-- ==================== COMMAND HANDLERS ====================

local function cmd_help()
    local text = [[🤖 <b>Telegram 机器人使用说明</b>

<b>常用监控命令：</b>
/status - 📊 综合运行状态看板 (带网速/外网IP)
/uplink - 🔀 一键平滑切换有线宽带与 5G 出口
/ping - 🩺 双向网络健康度体检 (ICMP + HTTP)
/nodes - 🧭 OpenClash 策略与落地节点
/clients - 👥 当前在线设备列表
/alias - 🏷️ 为未知设备添加中文备注
/wan - 🌐 外网与路由详情 (带公网与代理IP)
/clash - 🧩 OpenClash 核心与端口
/mode - 🔀 一键切换分流模式
/direct_list - 📋 查看 OpenClash 直连白名单
/direct - 🎯 添加域名/IP到直连白名单
/undirect - 🗑️ 从直连白名单移除域名/IP
/temp - 🌡️ CPU 实时温度监控
/uptime - 📡 网络可用性台账（24小时/7天/30天可用率与断网记录）
/log - 🗃️ 网络黑匣子（统一事件时间线：可用性/制式/出口/模组/你的操作）
/why - 🔍 因果关联（断网前发生了什么，最可疑的是什么）
/storage - 💾 存储分区与挂载
/usb - 🔌 USB 设备拓扑
/modem - 📡 5G 模组与射频信号看板 (RM500Q)
/sms [条数] - ✉️ 模组短信息与验证码提取
/modemreload - 🔄 重载 5G 模组
/trend - 📈 5G 信号趋势（最近 60 分钟，含频段跳变统计）
/band - 📻 5G 频段设置（锁定/恢复，带自动回退）
/gnss - 🛰️ GNSS 定位（坐标 / 地图链接 / 开关）
/flow - 📊 流量卡实时用量（剩余 / 已用 / 可用天数）
/direct &lt;域名&gt; - 🔗 加入强制直连（套了优化 CDN、代理反而慢的站点）
/undirect &lt;域名&gt; - 🗑 撤销直连；/direct-list 查看清单
/smart &lt;域名&gt; - 🔎 实测代理 vs 直连哪个快，并给一键建议
/proxy - 🌐 代理与分流面板（直连规则 / 节点分流 / Clash 状态）
/cards - 📇 查看卡内号码
/switch &lt;序号或关键词&gt; - 🔀 切换 eSIM 号码
/download &lt;激活码&gt; [确认码] - 📥 下载并写入新 eSIM Profile
/reboot - ⚡ 重启路由器系统 (带确认闸门)
/poweroff - 🔌 关闭路由器电源 (带确认闸门)

<i>💡 点击下方快捷键盘可直接执行常用指令。</i>]]
    tg.send_msg(text)
end




-- ==================== CALLBACK DISPATCH ====================

-- 一次性闸门：按钮回调会被 Telegram 重发、也会被用户连点，而"重启/关机/删规则"这类
-- 破坏性操作重复执行的代价是不可逆的（关机会直接断网）。所以按"同一条消息 + 同一个动作"
-- 只放行一次；第二次及以后一律忽略。
-- 状态落在 /tmp（tmpfs，重启即清空）：路由器重启后本来就该允许再次操作，不需要持久化。
local function consume_once(msg_id, action)
    local key = string.format("cb_used_%s_%s", tostring(msg_id), tostring(action):gsub("%W", "_"))
    if core.get_state(key, "") == "1" then return false end
    core.set_state(key, "1")
    return true
end

local function handle_callback(cb_id, msg_id, data_str)
    local t0 = now_ms()
    if data_str == "cancel_action" then
        tg.answer_callback(cb_id, "操作已取消")
        -- 必须传第三个参数 false：editMessageText 省略 reply_markup 时旧键盘会保留，
        -- 只改文字的话那条"🔴 确认执行"按钮还留在原地可点，用户以为取消了、再点一下
        -- 操作照样执行（且能反复点）——取消按钮等于形同虚设。
        tg.edit_msg(msg_id, "🛡️ <b>操作已取消</b>\n\n未对系统或服务进行任何修改。", false)

    elseif data_str == "do_clash_restart" then
        -- 破坏性操作：同一条确认消息只认一次（详见 consume_once 注释）
        if not consume_once(msg_id, data_str) then
            tg.answer_callback(cb_id, "该操作已执行过，已忽略")
            return
        end
        tg.answer_callback(cb_id, "正在重启核心...")
        -- 传 false 清空键盘，否则残留的确认按钮会被再点一次、核心被反复重启
        tg.edit_msg(msg_id, "🔄 <b>操作已确认</b>：正在重启 OpenClash 核心，请稍候约 3~5 秒...", false)
        net.cmd_clash_restart(true)

    elseif data_str == "do_modem_reload" then
        -- 破坏性操作：同一条确认消息只认一次（详见 consume_once 注释）
        if not consume_once(msg_id, data_str) then
            tg.answer_callback(cb_id, "该操作已执行过，已忽略")
            return
        end
        tg.answer_callback(cb_id, "正在重载模组...")
        -- 这里不用再传 false：start_esim_job 会把键盘换成"查看结果"，
        -- 确认按钮不会残留，重复点击只可能来自重发，已由上面的闸门挡住
        esimm.start_esim_job("reload", nil, nil, msg_id)

    elseif data_str:find("^do_undirect:") then
        -- 破坏性操作：同一条确认消息只认一次（详见 consume_once 注释）
        if not consume_once(msg_id, data_str) then
            tg.answer_callback(cb_id, "该操作已执行过，已忽略")
            return
        end
        local target = data_str:gsub("^do_undirect:", "")
        tg.answer_callback(cb_id, "正在删除条目...")
        -- 传 false 清空键盘：否则删完按钮还在，连点会反复触发删除
        tg.edit_msg(msg_id, "🗑️ 操作已确认：正在从直连白名单移除 <code>" .. html_escape(target) .. "</code>。", false)
        -- 删除也必须落在新实现（config.yaml 的 TG_DIRECT_RULES 段）：
        -- 旧实现写的是 /etc/openclash/tg_direct_rules.list，那边改了清单里看不到、规则也不生效
        -- cb_id 传 nil：本次回调已经应答过，再答一次只会拿到 "query is invalid" 的失败日志
        sysm.direct_del(target, msg_id, nil)

    elseif data_str == "do_sys_reboot" then
        -- 破坏性操作：同一条确认消息只认一次（详见 consume_once 注释）
        if not consume_once(msg_id, data_str) then
            tg.answer_callback(cb_id, "该操作已执行过，已忽略")
            return
        end
        tg.answer_callback(cb_id, "正在重启路由器...")
        -- 传 false 清空键盘，否则残留按钮可被连点，触发第二次 reboot
        tg.edit_msg(msg_id, "⚡ <b>正在重启路由器系统...</b>\n\n网络即将断开，请等待约 1~2 分钟系统重新上线。", false)
        core.exec("reboot &")

    elseif data_str == "do_sys_poweroff" then
        -- 破坏性操作：同一条确认消息只认一次（详见 consume_once 注释）
        if not consume_once(msg_id, data_str) then
            tg.answer_callback(cb_id, "该操作已执行过，已忽略")
            return
        end
        tg.answer_callback(cb_id, "正在关闭路由器...")
        -- 传 false 清空键盘，否则残留按钮可被连点，关机指令会被重复下发
        tg.edit_msg(msg_id, "🔌 <b>正在关闭路由器电源...</b>\n\n系统正在安全关机，网络已停止。再次使用需手动重新通电。", false)
        core.exec("poweroff &")

    elseif data_str == "refresh_cards" then
        if not esim_enabled() then tg.answer_callback(cb_id, "功能已停用"); tg.edit_msg(msg_id, "⚠️ 功能已停用"); return end
        tg.answer_callback(cb_id, "正在刷新号码列表")
        esimm.cmd_cards(msg_id)

    elseif data_str:find("^enable:") then
        if not esim_enabled() then tg.answer_callback(cb_id, "功能已停用"); tg.edit_msg(msg_id, "⚠️ 功能已停用"); return end
        local index = tonumber(data_str:match("^enable:(%d+)$"))
        local profiles, err, detail = esim.list()
        if not profiles then
            local hint = html_escape(esim.list_hint(err, detail))
            tg.answer_callback(cb_id, "读取卡内号码失败")
            tg.edit_msg(msg_id, "⚠️ <b>读取卡内号码失败</b>：" .. hint)
            return
        end
        local profile = index and profiles and profiles[index]
        if not profile then
            tg.answer_callback(cb_id, "号码列表已变化，请刷新后重试")
            esimm.cmd_cards(msg_id)
        elseif profile.profileState == "enabled" then
            tg.answer_callback(cb_id, "该号码本来就是生效中的，未做改动")
            esimm.cmd_cards(msg_id)
        elseif not profile.iccid or not profile.iccid:match("^%d+$") or #profile.iccid < 18 or #profile.iccid > 22 then
            tg.answer_callback(cb_id, "号码数据无效，请刷新列表")
            esimm.cmd_cards(msg_id)
        else
            tg.answer_callback(cb_id, "正在切换号码…")
            esimm.start_esim_job("switch", profile.iccid, profile.profileNickname or profile.serviceProviderName or profile.profileName, msg_id)
        end

    elseif data_str:find("^esim_result:") then
        local id = data_str:match("^esim_result:(%d+)$")
        local result = id and esim.job_result(id)
        if result then
            tg.answer_callback(cb_id, "任务已完成")
            tg.edit_msg(msg_id, result .. "\n\n🕰️ <i>" .. os.date("%Y-%m-%d %H:%M:%S") .. "</i>")
        else
            tg.answer_callback(cb_id, "任务仍在运行")
        end

    elseif data_str:find("^set_uplink:") then
        local target = data_str:gsub("^set_uplink:", "")
        local res = sys.switch_uplink(target)
        local notice, desc
        if res == "SUCCESS_WAN" then
            notice = "已切换为主力有线宽带"
            desc = "🌐 <b>当前主力出口</b>：<code>有线光猫宽带 (eth0)</code>\n⚡ <b>状态</b>：平滑倒换完成，网络连接零中断。"
        elseif res == "SUCCESS_5G" then
            notice = "已切换为主力 5G 模组"
            desc = "📶 <b>当前主力出口</b>：<code>5G 蜂窝模组 (usb0)</code>\n⚡ <b>状态</b>：平滑倒换完成，已进入 5G 模组通道。"
        elseif res == "ALREADY_WAN" then
            notice = "当前已是主力有线出口，无需切换"
            desc = "🌐 <b>当前主力出口</b>：<code>有线光猫宽带 (eth0)</code>\nℹ️ <b>状态</b>：当前已是该出口，无需切换。"
        elseif res == "ALREADY_5G" then
            notice = "当前已是主力 5G 模组，无需切换"
            desc = "📶 <b>当前主力出口</b>：<code>5G 蜂窝模组 (usb0)</code>\nℹ️ <b>状态</b>：当前已是该出口，无需切换。"
        elseif res == "ERROR_5G_NO_IP" then
            notice = "切换失败：5G 模组未获取到 IP"
            desc = "⚠️ <b>切换失败</b>：5G 模组 (usb0) 当前未获取到有效 IP，无法作为主力出口。"
        else
            notice = "切换失败：路由校验未通过，已回滚"
            desc = "⚠️ <b>切换失败</b>：仍停留在原出口，请稍后重试。诊断返回值：<code>" .. html_escape(res) .. "</code>"
        end

        tg.answer_callback(cb_id, notice)

        local inline_kb = {
            {
                { text = "🌐 切换至：有线宽带", callback_data = "set_uplink:wan" },
                { text = "📶 切换至：5G模组", callback_data = "set_uplink:5g" }
            },
            {
                { text = "📊 返回系统看板", callback_data = "refresh_status" }
            }
        }
        local now = os.date("%Y-%m-%d %H:%M:%S")
        local new_text = string.format([[🔀 <b>网络主力出口切换</b>

━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━
👇 点击下方按钮可再次倒换：

🕰️ <i>%s</i>]], desc, now)

        tg.edit_msg(msg_id, new_text, inline_kb)

    elseif data_str == "open_uplink_menu" then
        local text, kb = net.build_uplink_menu()
        if tg.answer_and_edit(cb_id, "🔀 正在打开出口切换菜单...", msg_id, text, kb) == nil then
            tg.send_msg(text, kb)
        end

    elseif data_str == "refresh_status" then
        local text, kb = sysm.build_status_card()
        if tg.answer_and_edit(cb_id, "🔄 正在刷新看板...", msg_id, text, kb) == nil then
            tg.send_msg(text, kb)
        end

    elseif data_str == "uptime" then
        sysm.cmd_uptime(msg_id, cb_id)

    elseif data_str:find("^event_log:") then
        -- "event_log:12" → 12 小时；sub(11) 跳过前缀
        sysm.cmd_event_log(data_str:sub(11), msg_id, cb_id)

    elseif data_str:find("^event_why:") then
        sysm.cmd_event_correlate(data_str:sub(11), msg_id, cb_id)

    elseif data_str == "refresh_direct" then
        -- 旧实现读的是 /etc/openclash/tg_direct_rules.list，跟 /direct 写入的 config.yaml
        -- 是两份数据；这个"刷新"按钮在老消息上还留着，点下去必须也读新实现，否则用户看到的是过期清单
        sysm.cmd_direct_list(msg_id, cb_id)

    elseif data_str == "gnss_show" then
        modm.cmd_gnss(msg_id, cb_id)
    elseif data_str == "gnss_start" or data_str == "gnss_stop" then
        modm.gnss_action(data_str == "gnss_start" and "start" or "stop", msg_id, cb_id)
    elseif data_str == "band_menu" then
        modm.cmd_band_menu(msg_id, cb_id)
    elseif data_str:match("^band_confirm:") then
        modm.band_confirm(data_str:sub(14), msg_id, cb_id)
    elseif data_str:match("^do_band:") then
        modm.band_lock(data_str:sub(9), msg_id, cb_id)
    elseif data_str == "band_restore" then
        modm.band_restore(msg_id, cb_id)
    elseif data_str == "clash_status" then
        net.cmd_clash(msg_id, cb_id)
    elseif data_str == "nodes_menu" then
        net.cmd_nodes(nil, msg_id, cb_id)
    elseif data_str == "proxy_menu" then
        net.cmd_proxy_menu(msg_id, cb_id)
    elseif data_str == "direct_list" then
        sysm.cmd_direct_list(msg_id, cb_id)
    elseif data_str:match("^direct_add_do:") then
        sysm.direct_add(data_str:sub(15), msg_id, cb_id)
    elseif data_str:match("^direct_del:") then
        sysm.direct_del(data_str:sub(12), msg_id, cb_id)
    elseif data_str == "flowcard_now" then
        sysm.cmd_flowcard(msg_id, cb_id)
    elseif data_str == "signal_trend" then
        modm.cmd_signal_trend(msg_id, cb_id)
    elseif data_str == "signal_long" then
        modm.cmd_signal_long(msg_id, cb_id)
    elseif data_str == "refresh_modem" then
        modm.cmd_modem(msg_id, cb_id)

    elseif data_str == "show_sms" or data_str == "refresh_sms" then
        modm.cmd_sms(3, msg_id, cb_id)

    elseif data_str == "re_ping" then
        tg.answer_callback(cb_id, "🩺 正在重新测试网络质量，请稍候约2秒...")
        net.cmd_ping()

    elseif data_str == "test_nodes" then
        tg.answer_callback(cb_id, "⚡ 正在测速分流节点...")
        net.cmd_nodes("test", msg_id, cb_id)

    elseif data_str == "restart_clash" then
        tg.answer_callback(cb_id, "请确认是否重启核心")
        ask_confirm("重启 OpenClash 核心", "Mihomo 核心守护进程", "短暂断流 3~5 秒，核心自动重载并重新接管分流", "do_clash_restart")

    elseif data_str:find("^set_mode:") then
        local mode = data_str:gsub("^set_mode:", "")
        -- 先校验再渲染：非法模式由 clash.set_mode 白名单拒绝，绝不落到 shell
        local applied, err = clash.set_mode(mode)
        if not applied then
            core.log("TohsakaWrt-Clash", "拒绝非法的代理模式: " .. tostring(mode))
            tg.answer_callback(cb_id, "❌ 无效的代理模式，已拒绝")
            return
        end
        local mode_name = applied
        if mode == "rule" then mode_name = "规则分流 (Rule)"
        elseif mode == "global" then mode_name = "全局代理 (Global)"
        elseif mode == "direct" then mode_name = "全局直连 (Direct)" end

        tg.answer_callback(cb_id, "已切换为: " .. mode_name)

        local inline_kb = {
            {
                { text = "📐 规则分流", callback_data = "set_mode:rule" },
                { text = "🌐 全局代理", callback_data = "set_mode:global" },
                { text = "⚡ 全局直连", callback_data = "set_mode:direct" }
            }
        }
        local new_text = string.format([[✅ <b>OpenClash 模式切换成功</b>

━━━━━━━━━━━━━━━━━━
🔀 <b>当前模式</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
👇 点击可再次切换：

🕰️ <i>%s</i>]], html_escape(mode_name), os.date("%Y-%m-%d %H:%M:%S"))

        tg.edit_msg(msg_id, new_text, inline_kb)
    end

    core.log("Tohsaka-Bot", string.format("Callback %s 用时 %.1f 秒", tostring(data_str), (now_ms() - t0) / 1000))
end

-- ==================== COMMAND DISPATCH ====================

local function handle_command(text)
    text = text:match("^%s*(.-)%s*$")
    if not text or text == "" then return end

    local log_text = text:gsub("%d+", function(value)
        if (#value >= 18 and #value <= 22) or #value == 32 then return "[masked-number]" end
        return value
    end)
    core.log("Tohsaka-Bot", "Command: " .. log_text)
    local t_cmd0 = now_ms()

    local cmd, arg
    if text:sub(1, 1) == "/" then
        cmd, arg = text:match("^(%S+)%s*(.*)$")
        cmd = (cmd or ""):gsub("@.*$", ""):lower()
    else
        cmd = text
        arg = ""
    end

    local full = text

    if cmd == "/modemreload" or cmd == "/mreload" or full:find("重载模组") or cmd == "/reload" or full:find("重载") then
        if not esim_enabled() then
            tg.send_msg("⚠️ 功能已停用")
        else
            ask_confirm("重载 5G 模组", "RM500Q-GL 蜂窝模组", "模组将重新执行射频软复位，期间蜂窝连接将中断约 60~90 秒", "do_modem_reload")
        end
    elseif cmd == "/cards" or cmd == "/sim" or full:find("卡内号码") or full:find("号码清单") then
        esimm.cmd_cards()
    elseif cmd == "/download" or cmd == "/写卡" or full:find("下载写卡") or full:find("写卡") then
        local raw = arg or ""
        if raw == "" and full:find("写卡") then raw = full:gsub("^.-写卡%s*", "") end
        local ac, confirm = raw:match("^(%S+)%s*(.*)$")
        if not ac or ac == "" then
            tg.send_msg("📥 <b>下载写入 eSIM Profile</b>\n\n使用方式：\n<code>/download &lt;激活码LPA:...&gt; [确认码]</code>\n\n<i>示例：</i>\n<code>/download LPA:1$smdp.io$ABCDEF123456</code>")
        else
            esimm.start_esim_job("download", ac, "新Profile", nil, confirm)
        end
    elseif cmd == "/switch" or full:find("切换号码") then
        local selector = arg or ""
        if cmd ~= "/switch" then selector = full:gsub("^.-切换号码", "") end
        esimm.switch_profile(selector)
    elseif cmd == "/start" or cmd == "/help" or cmd == "/menu" or full:find("帮助") then
        cmd_help()
    elseif cmd == "/status" or (full:find("状态") and not full:find("模组") and not full:find("5G") and not full:find("5g")) or full:find("看板") then
        sysm.cmd_status()
    elseif cmd == "/uplink" or cmd == "/switch_wan" or full:find("出口") or full:find("切网") or full:find("换网") or full:find("切5G") or full:find("切5g") then
        net.cmd_uplink()
    elseif cmd == "/ping" or cmd == "/check" or cmd == "/test" or full:find("体检") or full:find("双向") or full:find("测速") then
        net.cmd_ping()
    elseif cmd == "/mode" or full:find("分流模式") or (full:find("模式") and not full:find("模组")) then
        net.cmd_mode(arg)
    elseif cmd == "/nodes" or full:find("节点") or full:find("分流") then
        net.cmd_nodes(arg)
    elseif cmd == "/wan" or full:find("外网") or full:find("路由") then
        net.cmd_wan()
    elseif cmd == "/temp" or full:find("温度") then
        sysm.cmd_temp()
    elseif cmd == "/uptime" or full:find("可用性") or full:find("可用率") then
        sysm.cmd_uptime()
    elseif cmd == "/log" or full:find("黑匣子") or full:find("事件线") then
        -- /log 12 或 /log 12小时 或 说"黑匣子 12 小时"
        local h = tonumber(full:match("^/log%s+(%d+)")) or tonumber(full:match("(%d+)%s*小时"))
        sysm.cmd_event_log(h)
    elseif cmd == "/why" or full:find("找原因") or full:find("为什么") then
        -- 因果关联：回答"为什么卡了/断了"
        local h = tonumber(full:match("^/why%s+(%d+)")) or tonumber(full:match("(%d+)%s*小时"))
        sysm.cmd_event_correlate(h)
    elseif cmd == "/proxy" or full:find("代理面板") or full:find("代理设置") then
        net.cmd_proxy_menu()
    elseif cmd == "/smart" or cmd == "/direct-test" then
        local d = full:match("^/%S+%s+([%w%.%-]+)")
        if d then sysm.direct_smart(d) else sysm.cmd_direct_list() end
    elseif cmd == "/direct" or cmd == "/bypass" or cmd == "/undirect" or cmd == "/direct-list" or cmd == "/directlist"
        or cmd == "/direct_list" or full:find("直连清单") or full:find("强制直连") then
        -- 直连相关入口全部收口到新实现（/usr/bin/tohsakawrt-clash-direct，数据在 config.yaml 的 TG_DIRECT_RULES 段）。
        -- /bypass 与 /direct_list 原先落在下面的旧实现分支上，和这里的 /direct 读写的是两个文件，
        -- 后果是"刚加的规则清单里看不到、撤销了也不生效"（运行中的 Clash 里两条都还在），所以合并到这一支。
        local d = full:match("^/%S+%s+([%w%.%-]+)")
        if cmd == "/undirect" and d then
            sysm.direct_del(d)
        elseif (cmd == "/direct" or cmd == "/bypass" or cmd == "/direct_list") and d then
            sysm.direct_add(d)
        else
            sysm.cmd_direct_list()
        end
    elseif cmd == "/flow" or cmd == "/data" or full:find("查流量") or full:find("流量卡") then
        sysm.cmd_flowcard()
    elseif cmd == "/gnss" or cmd == "/gps" or full:find("定位") or full:find("GPS") then
        modm.cmd_gnss()
    elseif cmd == "/band" or cmd == "/bands" or full:find("频段") then
        local list = full:match("^/band%s+([0-9:]+)") or full:match("^/bands%s+([0-9:]+)")
        if list then modm.band_confirm(list) else modm.cmd_band_menu() end
    elseif cmd == "/trend" or cmd == "/signal" or full:find("信号") then
        -- 说"长趋势/多天趋势"时直接给多天视图，否则给近 60 分钟视图
        if full:find("长趋势") or full:find("多天") or full:find("趋势7") then
            modm.cmd_signal_long()
        else
            modm.cmd_signal_trend()
        end
    elseif cmd == "/modem" or full:find("5G") or full:find("5g") or full:find("模组") then
        modm.cmd_modem()
    elseif cmd == "/sms" or cmd == "/msg" or full:find("短信") or full:find("验证码") then
        local count = tonumber(arg:match("(%d+)")) or 3
        modm.cmd_sms(count)
    elseif full:find("删直连") then
        -- 中文口令不以 "/" 开头，handle_command 只对 "/" 开头的文本解析 arg，
        -- 所以目标必须自己从整句里抠（原先直接把恒为空串的 arg 传下去，这个入口实际只能打印用法）
        local target = full:match("删直连%s*([%w%.%-]+)")
        if target then
            -- 保留"先确认再删"：撤销直连会让该站点重新走代理，属于用户可感知的改动
            ask_confirm("删除直连白名单", target, "目标将不再享受免代理直连待遇，重新受 OpenClash 分流规则控制", "do_undirect:" .. target)
        else
            sysm.cmd_direct_list()
        end
    elseif full:find("白名单") or full:find("直连") then
        -- 纯中文触发词不带目标，直接给清单（清单上每条都有 🗑 撤销按钮）；
        -- 带目标的入口是 /direct、/direct_list 与"删直连 &lt;域名&gt;"，已在上面的分支统一处理
        sysm.cmd_direct_list()
    elseif cmd == "/clients" or cmd == "/devices" or full:find("设备") or full:find("客户端") then
        sysm.cmd_clients()
    elseif cmd == "/alias" or full:find("备注") then
        dirt.cmd_alias(arg)
    elseif cmd == "/reboot" or full:find("重启系统") or full:find("重启路由器") then
        ask_confirm("重启路由器系统", "TohsakaWrt 宿主机", "全家网络将中断约 1~2 分钟，直到路由器重新启动完成", "do_sys_reboot")
    elseif cmd == "/poweroff" or cmd == "/shutdown" or full:find("关闭路由器") or full:find("路由器关机") then
        ask_confirm("关闭路由器电源", "TohsakaWrt 宿主机", "路由器将完全关机并停止所有网络服务，再次开启需手动拔插电源", "do_sys_poweroff")
    elseif cmd == "/clash_restart" or full:find("重启核心") then
        net.cmd_clash_restart()
    elseif cmd == "/clash" or full:find("核心") then
        net.cmd_clash()
    elseif cmd == "/storage" or full:find("存储") then
        sysm.cmd_storage()
    elseif cmd == "/usb" or full:find("USB") or full:find("usb") then
        sysm.cmd_usb()
    else
        local safe = full:gsub("%d+", function(value)
            if (#value >= 18 and #value <= 22) or #value == 32 then return value:sub(1, 6) .. "…" .. value:sub(-4) end
            return value
        end):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        tg.send_msg(string.format("⚠️ <b>未识别的命令</b>：<code>%s</code>\n\n发送 /help 或点击下方键盘查看可用命令。", safe))
    end

    core.log("Tohsaka-Bot", string.format("Command %s 用时 %.1f 秒", tostring(cmd), (now_ms() - t_cmd0) / 1000))
end

-- ==================== MAIN EVENT LOOP ====================

function M.run()
    core.log("Tohsaka-Bot", "Starting TohsakaWrt Telegram Bot Daemon (Lua Engine)...")
    local enabled = core.get_uci("tohsakawrt-tgbot", "main", "enabled", "0")
    local token = core.get_uci("tohsakawrt-tgbot", "main", "token", "")
    local chat_id = core.get_uci("tohsakawrt-tgbot", "main", "chat_id", "")
    local user_id = core.get_uci("tohsakawrt-tgbot", "main", "user_id", "")
    -- 发送者身份闸门：配置了 user_id 则严格校验；未配置时只接受私聊（私聊里 chat_id 即用户 ID）。
    local function sender_allowed(from_id, chat_key, chat_type, configured_user)
        if configured_user ~= nil and configured_user ~= "" then
            return from_id ~= nil and tostring(from_id) == tostring(configured_user)
        end
        if chat_type == "private" then
            return from_id ~= nil and tostring(from_id) == tostring(chat_key)
        end
        return false
    end
    if enabled ~= "1" or token == "" or chat_id == "" then
        core.log("Tohsaka-Bot", "Bot disabled or unconfigured in UCI. Exiting.")
        return
    end

    -- 启动时清一次过期 eSIM 任务文件（不依赖是否有人建任务）
    pcall(esimm.cleanup_jobs)

    local offset = tonumber(core.get_state("offset", "0")) or 0

    -- Synchronize offset on startup to avoid backlog
    local init = tg.get_updates(-1, 0)
    if init and init.result and #init.result > 0 then
        offset = (init.result[#init.result].update_id or 0) + 1
        core.set_state("offset", tostring(offset))
    end

    local loop_count = 0
    local fail_count = 0
    local last_sms_check = 0
    while true do
        loop_count = loop_count + 1
        if loop_count % 20 == 0 then
            collectgarbage("step", 50)
        end

        -- 后台短信静默巡检与新消息推送（轻量级 7ms 检测，发现新消息秒推 TG）
        local now_ts = os.time()
        if (now_ts - last_sms_check) >= 12 then
            last_sms_check = now_ts
            local ok_sms, new_sms = pcall(function()
                return modem.sms_poll_new and modem.sms_poll_new()
            end)
            if ok_sms and new_sms and #new_sms > 0 then
                for _, sm in ipairs(new_sms) do
                    local code_part = ""
                    if sm.code then
                        code_part = string.format("\n🔐 <b>提取验证码</b>：<code>%s</code> <i>(单按直接复制)</i>", html_escape(sm.code))
                    end
                    local content = html_escape(sm.content):gsub("^%s+", ""):gsub("%s+$", "")
                    local push_text = string.format([[📬 <b>收到新短信通知！</b>

━━━━━━━━━━━━━━━━━━
🏢 <b>发件人</b>：<code>%s</code>
⏰ <b>接收时间</b>：<code>%s</code>%s
━━━━━━━━━━━━━━━━━━
💬 <b>短信内容</b>：
%s
━━━━━━━━━━━━━━━━━━
<i>来源：移远 RM500Q-GL 5G 模组</i>]],
                        html_escape(sm.sender),
                        html_escape(sm.timestamp),
                        code_part,
                        content
                    )
                    local kb = {
                        {
                            { text = "✉️ 短信列表", callback_data = "refresh_sms" },
                            { text = "📡 模组状态", callback_data = "refresh_modem" }
                        }
                    }
                    tg.send_msg(push_text, kb)
                end
            end
        end

        local res = tg.get_updates(offset, 8)
        if res and res.result then
            fail_count = 0
            for _, u in ipairs(res.result) do
                local uid = u.update_id
                if uid then
                    -- 内存游标先推进（避免同一条被重复拉取），但落盘放到处理完成之后：
                    -- 处理中重启会重新收到这条指令，而不是永久丢掉它
                    offset = uid + 1
                end

                if u.callback_query then
                    local cq = u.callback_query
                    local cq_chat = cq.message and cq.message.chat
                    local source_chat_id = cq_chat and cq_chat.id
                    local cq_from_id = cq.from and cq.from.id
                    if not source_chat_id or tostring(source_chat_id) ~= tostring(chat_id)
                        or not sender_allowed(cq_from_id, chat_id, cq_chat and cq_chat.type, user_id) then
                        core.log("Tohsaka-Bot", "Rejected update from unauthorized chat")
                    else
                        local cq_id = cq.id
                        local msg_id = cq.message and cq.message.message_id
                        local data_str = cq.data or ""
                        local ok, err = pcall(handle_callback, cq_id, msg_id, data_str)
                        if not ok then
                            core.log("Tohsaka-Bot", "Callback error: " .. tostring(err))
                        end
                    end
                elseif u.message or u.edited_message then
                    local msg = u.message or u.edited_message
                    local source_chat_id = msg and msg.chat and msg.chat.id
                    local source_from_id = msg and msg.from and msg.from.id
                    local source_chat_type = msg and msg.chat and msg.chat.type
                    if not source_chat_id or tostring(source_chat_id) ~= tostring(chat_id)
                        or not sender_allowed(source_from_id, chat_id, source_chat_type, user_id) then
                        core.log("Tohsaka-Bot", "Rejected update from unauthorized chat")
                    else
                        if msg and msg.text then
                            tg.send_chat_action("typing")
                            local ok, err = pcall(handle_command, msg.text)
                            if not ok then
                                core.log("Tohsaka-Bot", "Command error: " .. tostring(err))
                            end
                        end
                    end
                end

                if uid then
                    core.set_state("offset", tostring(offset))
                end
            end
        else
            fail_count = fail_count + 1
            if fail_count > 3 then
                os.execute("sleep 1")
            end
        end
    end
end

return M
