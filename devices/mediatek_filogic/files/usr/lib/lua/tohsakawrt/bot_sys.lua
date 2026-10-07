-- TohsakaWrt Bot：系统信息类命令（综合看板 / 温度 / 在线设备 / 存储 / USB）
-- 共享零件来自 bot_common；本模块只放这一类功能。
local bc = require("tohsakawrt.bot_common")
local core, tg, sys, modem, clash, esim, nixio =
    bc.core, bc.tg, bc.sys, bc.modem, bc.clash, bc.esim, bc.nixio
local html_escape = bc.html_escape

local M = {}

local function build_status_card()
    local metrics = sys.system_metrics()
    local temp = sys.cpu_temp()
    local pub_ip = sys.public_ip()
    local uplink = sys.uplink_status()
    local uplink_dev = tostring(uplink.dev or "unknown")
    local cur_ip = (uplink.type == "wan") and sys.wan_ip() or sys.usb0_ip()
    local c_status = clash.status()
    local speed = sys.wan_speed(uplink_dev)
    local now = os.date("%Y-%m-%d %H:%M:%S")

    local safe_pub_ip = pub_ip:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    local temp_icon = "🟢"
    local temp_num = tonumber(temp:match("(%d+%.?%d*)"))
    if temp_num and temp_num >= 70 then temp_icon = "🔴"
    elseif temp_num and temp_num >= 60 then temp_icon = "⚠️" end

    local text = string.format([[📊 <b>综合运行看板</b>

━━━━━━━━━━━━━━━━━━
📟 <b>设备型号</b>：Cudy TR3000 (MT7981B)
⏱️ <b>持续运行</b>：%s
🌡️ <b>核心温度</b>：%s %s
🧠 <b>可用内存</b>：%s
📈 <b>系统负载</b>：%s
💾 <b>存储空间</b>：%s
━━━━━━━━━━━━━━━━━━
🚀 <b>实时速率</b>：%s
🌐 <b>宽带外网</b>：<code>%s</code>
📡 <b>出口网卡</b>：<code>%s (%s)</code>
🚦 <b>网络连通</b>：🟢 正常
🧩 <b>OpenClash</b>：%s (%s)
━━━━━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], html_escape(metrics.uptime), temp_icon, html_escape(temp), html_escape(metrics.mem_str), html_escape(metrics.load), html_escape(metrics.root_str), html_escape(speed), safe_pub_ip, html_escape(uplink_dev), html_escape(cur_ip), c_status.running and "🟢 正常运行" or "🔴 未运行", html_escape(c_status.version), html_escape(now))

    local inline_kb = {
        {
            { text = "🔀 切换主力出口", callback_data = "open_uplink_menu" },
            { text = "🔄 刷新看板", callback_data = "refresh_status" }
        },
        {
            { text = "📈 信号趋势", callback_data = "signal_trend" },
            { text = "📡 模组状态", callback_data = "refresh_modem" }
        },
        {
            { text = "📊 查流量", callback_data = "flowcard_now" }
        }
    }

    return text, inline_kb
end

-- 📊 查流量：复用流量卡脚本的查询与格式化（只打印模式，不写台账、不发通知）
function M.cmd_flowcard(msg_id, cb_id)
    local body = core.exec("FLOWCARD_PRINT_ONLY=1 /usr/bin/tohsakawrt-flowcard-daily 2>/dev/null") or ""
    body = tostring(body):gsub("%s+$", "")
    if body == "" then
        body = "📊 <b>流量卡查询失败</b>\n\n<i>可能是网络不通或接口暂时异常，稍后再试。</i>"
    end
    local kb = {
        {
            { text = "🔄 刷新流量", callback_data = "flowcard_now" },
            { text = "📊 返回看板", callback_data = "refresh_status" }
        }
    }
    if msg_id and cb_id then
        return tg.answer_and_edit(cb_id, "正在查询流量...", msg_id, body, kb)
    end
    if msg_id then return tg.edit_msg(msg_id, body, kb) end
    return tg.send_msg(body, kb)
end

function M.cmd_status(msg_id)
    local text, inline_kb = build_status_card()
    if msg_id then
        return tg.edit_msg(msg_id, text, inline_kb)
    end
    return tg.send_msg(text, inline_kb)
end

function M.cmd_temp()
    local temp = sys.cpu_temp()
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local text = string.format([[🌡️ <b>CPU 实时温度</b>

━━━━━━━━━━━━━━━━━━
🔥 <b>当前核心温度</b>：<code>%s</code>
📊 <b>状态评估</b>：正常 (安全范围 &lt; 75°C)
━━━━━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], html_escape(temp), html_escape(now))
    tg.send_msg(text)
end

function M.cmd_clients()
    local aliases = sys.load_aliases()
    local leases = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            local ts, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac and ip then
                local l_mac = mac:lower()
                local d_name = aliases[l_mac] or ((name == "*" or name == "") and "未知设备" or name)
                d_name = d_name:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
                table.insert(leases, string.format("• <b>%s</b>\n  ├ <b>IP</b>：<code>%s</code>\n  └ <b>MAC</b>：<code>%s</code>", d_name, html_escape(ip), html_escape(mac:upper())))
            end
        end
        f:close()
    end

    local now = os.date("%Y-%m-%d %H:%M:%S")
    local body = (#leases > 0) and table.concat(leases, "\n") or "暂无在线客户端数据"
    local text = string.format([[👥 <b>在线客户端 (%d 台)</b>

━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━
💡 <i>提示：发送 /alias 查看或为未知设备添加中文备注。</i>

🕰️ <i>%s</i>]], #leases, body, now)

    tg.send_msg(text)
end

function M.cmd_storage()
    local storage, block = sys.storage_info()
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local s_text = (storage ~= "") and storage:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") or "未获取到存储空间"
    local b_text = (block ~= "") and block:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") or "未获取到块设备"

    local text = string.format([[💾 <b>存储状态</b>
━━━━━━━━━━━━━━━━━━
💾 <b>分区状态</b>：
<pre><code>%s</code></pre>
📦 <b>块设备</b>：
<pre><code>%s</code></pre>
━━━━━━━━━━━━━━━━━━

🕰️ <i>%s</i>]], s_text, b_text, now)
    tg.send_msg(text)
end

function M.cmd_usb()
    local usb = sys.usb_info():gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local text = string.format([[🔌 <b>USB 拓扑</b>
━━━━━━━━━━━━━━━━━━
🔌 <b>设备信息</b>：
<pre><code>%s</code></pre>
━━━━━━━━━━━━━━━━━━

🕰️ <i>%s</i>]], usb, now)
    tg.send_msg(text)
end


M.build_status_card = build_status_card
return M
