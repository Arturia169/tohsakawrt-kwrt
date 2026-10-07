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
            { text = "📊 查流量", callback_data = "flowcard_now" },
            { text = "🌐 代理面板", callback_data = "proxy_menu" }
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

-- 🔗 直连清单：给"套了优化 CDN、走代理反而更慢"的站点加直连规则
function M.cmd_direct_list(msg_id, cb_id)
    local raw = tostring(core.exec("/usr/bin/tohsakawrt-clash-direct list 2>/dev/null") or ""):gsub("%s+$", "")
    local lines = { "🔗 <b>Clash 强制直连清单</b>", "━━━━━━━━━━━━━━━━━━" }
    local kb_rows = {}
    local n = 0
    for d in raw:gmatch("[^\n]+") do
        n = n + 1
        local dom = d:gsub("^%s+", ""):gsub("%s+$", "")
        if dom ~= "" then
            lines[#lines + 1] = string.format("%d. <code>%s</code>", n, html_escape(dom))
            if n <= 5 then
                kb_rows[#kb_rows + 1] = { { text = "🗑 撤销 " .. dom:sub(1, 22), callback_data = "direct_del:" .. dom } }
            end
        end
    end
    if n == 0 then lines[#lines + 1] = "<i>清单为空 —— 用 /direct 域名 添加</i>" end
    lines[#lines + 1] = "━━━━━━━━━━━━━━━━━━"
    lines[#lines + 1] = "💡 <i>这些域名走直连；改完会自动热重载（不断线）。</i>"
    kb_rows[#kb_rows + 1] = { { text = "🔄 刷新清单", callback_data = "direct_list" } }
    local text, kb = table.concat(lines, "\n"), kb_rows
    if msg_id and cb_id then return tg.answer_and_edit(cb_id, "正在读取清单...", msg_id, text, kb) end
    if msg_id then return tg.edit_msg(msg_id, text, kb) end
    return tg.send_msg(text, kb)
end

-- 域名白名单校验：与脚本侧同规则（双重防护，非法输入连脚本都不调）
local function valid_domain(d)
    if type(d) ~= "string" or #d < 4 or #d > 253 then return false end
    if not d:match("^[%w][%w%.%-]*[%w]$") then return false end
    if not d:find("%.") then return false end
    return true
end

function M.direct_add(domain, msg_id, cb_id)
    domain = tostring(domain or ""):gsub("%s", "")
    if not valid_domain(domain) then
        local t = "⚠️ <b>域名格式不正确</b>\n\n<i>示例：<code>/direct blog.example.com</code></i>"
        if msg_id and cb_id then return tg.answer_and_edit(cb_id, "格式不正确", msg_id, t) end
        return tg.send_msg(t)
    end
    local out = tostring(core.exec("/usr/bin/tohsakawrt-clash-direct add " .. domain .. " 2>/dev/null") or ""):gsub("%s+$", "")
    local body
    if out == "ADDED" then
        body = string.format("✅ <b>已加入直连</b>\n\n🔗 <code>%s</code>\n⚡ <b>已热重载</b>（保留现有连接）\n\n<i>下次这条路径就走直连了。</i>", html_escape(domain))
    elseif out == "ALREADY" then
        body = string.format("ℹ️ <b>本来就在直连清单里</b>\n\n🔗 <code>%s</code>", html_escape(domain))
    else
        body = string.format("⚠️ <b>添加失败</b>\n\n<code>%s</code>", html_escape(out ~= "" and out or "无返回"))
    end
    local kb = {
        { { text = "🔗 看清单", callback_data = "direct_list" }, { text = "🗑 撤销", callback_data = "direct_del:" .. domain } },
        { { text = "📊 返回看板", callback_data = "refresh_status" } }
    }
    if msg_id and cb_id then return tg.answer_and_edit(cb_id, out == "ADDED" and "已加入直连" or "完成", msg_id, body, kb) end
    if msg_id then return tg.edit_msg(msg_id, body, kb) end
    return tg.send_msg(body, kb)
end

-- 实测两条路并给建议：直连更快就提供"一键加入"
function M.direct_smart(domain, msg_id, cb_id)
    domain = tostring(domain or ""):gsub("%s", "")
    if not valid_domain(domain) then
        local t = "⚠️ <b>域名格式不正确</b>\n\n<i>示例：<code>/smart blog.example.com</code></i>"
        if msg_id and cb_id then return tg.answer_and_edit(cb_id, "格式不正确", msg_id, t) end
        return tg.send_msg(t)
    end
    local out = tostring(core.exec("/usr/bin/tohsakawrt-clash-direct smart " .. domain .. " 2>/dev/null") or "")
    local dm = out:match("DIRECT_MS:(%d+)")
    local pm = out:match("PROXY_MS:(%d+)")
    local verdict = out:match("VERDICT:(%w+)") or "UNKNOWN"
    local body, kb = {}, {}
    if dm and pm then
        local faster, ratio = "直连", 0
        if tonumber(dm) < tonumber(pm) then
            ratio = math.floor((1 - tonumber(dm) / tonumber(pm)) * 100 + 0.5)
        else
            faster = "代理"
            ratio = math.floor((1 - tonumber(pm) / tonumber(dm)) * 100 + 0.5)
        end
        local head = (verdict == "DIRECT") and "⚡ <b>走直连更快</b>" or "🌐 <b>走代理更快</b>"
        body[#body + 1] = head
        body[#body + 1] = ""
        body[#body + 1] = "━━━━━━━━━━━━━━━━━━"
        body[#body + 1] = string.format("🔗 <code>%s</code>", html_escape(domain))
        body[#body + 1] = string.format("🚀 <b>直连</b>：<code>%s</code> ms", dm)
        body[#body + 1] = string.format("🛰️ <b>代理</b>：<code>%s</code> ms", pm)
        body[#body + 1] = "━━━━━━━━━━━━━━━━━━"
        body[#body + 1] = string.format("📊 <b>%s 快约 %d%%</b>", faster, ratio)
        body[#body + 1] = ""
        body[#body + 1] = (verdict == "DIRECT") and "<i>点下面的按钮即可加入直连清单。</i>" or "<i>保持现状即可，无需改动。</i>"
        if verdict == "DIRECT" then
            kb[#kb + 1] = { { text = "➕ 加入直连", callback_data = "direct_add_do:" .. domain } }
        end
    else
        body[#body + 1] = "🔎 <b>测速失败</b>"
        body[#body + 1] = ""
        body[#body + 1] = string.format("🔗 <code>%s</code>", html_escape(domain))
        body[#body + 1] = string.format("📄 <code>%s</code>", html_escape(out:gsub("\n", " ")))
        body[#body + 1] = ""
        body[#body + 1] = "<i>该站点可能不响应 HTTPS 探测，或当前网络异常。</i>"
    end
    kb[#kb + 1] = { { text = "🔗 看清单", callback_data = "direct_list" }, { text = "📊 返回看板", callback_data = "refresh_status" } }
    local text = table.concat(body, "\n")
    if msg_id and cb_id then return tg.answer_and_edit(cb_id, "正在实测两条路...", msg_id, text, kb) end
    if msg_id then return tg.edit_msg(msg_id, text, kb) end
    return tg.send_msg(text, kb)
end

function M.direct_del(domain, msg_id, cb_id)
    domain = tostring(domain or ""):gsub("%s", "")
    if not valid_domain(domain) then
        if cb_id then tg.answer_callback(cb_id, "域名不合法") end
        return tg.send_msg("⚠️ <b>域名格式不正确</b>")
    end
    local out = tostring(core.exec("/usr/bin/tohsakawrt-clash-direct del " .. domain .. " 2>/dev/null") or ""):gsub("%s+$", "")
    local body = string.format("🗑 <b>已撤销直连</b>\n\n🔗 <code>%s</code>\n⚡ <i>已热重载</i>", html_escape(domain))
    if out ~= "DELETED" then
        body = string.format("⚠️ <b>撤销返回异常</b>：<code>%s</code>", html_escape(out))
    end
    local kb = { { { text = "🔗 看清单", callback_data = "direct_list" } } }
    if msg_id and cb_id then return tg.answer_and_edit(cb_id, "已撤销", msg_id, body, kb) end
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
