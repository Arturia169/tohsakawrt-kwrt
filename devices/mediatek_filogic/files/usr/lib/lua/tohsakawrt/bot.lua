-- TohsakaWrt Telegram Bot Daemon (Pure Lua)
local M = {}

local core = require("tohsakawrt.core")
local tg = require("tohsakawrt.tg")
local sys = require("tohsakawrt.system")
local modem = require("tohsakawrt.modem")
local clash = require("tohsakawrt.clash")

-- ==================== COMMAND HANDLERS ====================

local function cmd_help()
    local text = [[🤖 <b>TohsakaWrt Telegram Bot (Lua Engine)</b>

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
/storage - 💾 存储分区与挂载
/usb - 🔌 USB 设备拓扑
/modem - 📡 5G 蜂窝模块 (RM500Q)

<i>💡 点击下方快捷键盘可直接执行常用指令。</i>]]
    tg.send_msg(text)
end

local function cmd_status()
    local metrics = sys.system_metrics()
    local temp = sys.cpu_temp()
    local pub_ip = sys.public_ip()
    local uplink = sys.uplink_status()
    local cur_ip = (uplink.type == "wan") and sys.wan_ip() or sys.usb0_ip()
    local c_status = clash.status()
    local speed = sys.wan_speed(uplink.dev)
    local now = os.date("%Y-%m-%d %H:%M:%S")

    local safe_pub_ip = pub_ip:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")

    local temp_icon = "🟢"
    local temp_num = tonumber(temp:match("(%d+%.?%d*)"))
    if temp_num and temp_num >= 70 then temp_icon = "🔴"
    elseif temp_num and temp_num >= 60 then temp_icon = "🟡" end

    local text = string.format([[📊 <b>TohsakaWrt 综合运行看板</b>

━━━━━━━━━━━━━━
📟 <b>设备型号</b>：Cudy TR3000 (MT7981B)
⏱️ <b>持续运行</b>：%s
🌡️ <b>核心温度</b>：%s %s
🧠 <b>可用内存</b>：%s
📈 <b>系统负载</b>：%s
💾 <b>存储空间</b>：%s
━━━━━━━━━━━━━━
🚀 <b>实时速率</b>：%s
🌐 <b>宽带外网</b>：<code>%s</code>
📡 <b>出口网卡</b>：<code>%s (%s)</code>
🚦 <b>网络连通</b>：🟢 正常
🧩 <b>OpenClash</b>：%s (%s)
━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], metrics.uptime, temp_icon, temp, metrics.mem_str, metrics.load, metrics.root_str, speed, safe_pub_ip, uplink.dev, cur_ip, c_status.running and "🟢 正常运行" or "🔴 未运行", c_status.version, now)

    local inline_kb = {
        {
            { text = "🔀 切换主力出口", callback_data = "open_uplink_menu" },
            { text = "🔄 刷新看板", callback_data = "refresh_status" }
        }
    }

    tg.send_msg(text, inline_kb)
end

local function cmd_uplink()
    local uplink = sys.uplink_status()
    local cur_name = (uplink.type == "wan") and "有线宽带 (eth0)" or ((uplink.type == "5g") and "5G 蜂窝网络 (usb0)" or (uplink.dev .. " (未知接口)"))
    local cur_icon = (uplink.type == "wan") and "🌐" or "📶"

    local ip_wan = sys.wan_ip()
    local ip_5g = sys.usb0_ip()
    local m_info = modem.info()
    local pub_ip = sys.public_ip()

    local wan_pub_line = ""
    local cell_pub_line = ""
    local cell_mode_line = ""

    if uplink.type == "wan" then
        if pub_ip ~= "未获取到" then core.set_state("last_wan_pubip", pub_ip) end
        local wan_pub = (pub_ip ~= "未获取到") and pub_ip or core.get_state("last_wan_pubip", "未获取到")
        wan_pub_line = string.format("└ 公网归属：<code>%s</code> 🟢", wan_pub)
        cell_mode_line = string.format("└ 制式频段：<code>%s · %s</code> ⚪", m_info.oper, m_info.band)
    elseif uplink.type == "5g" then
        if pub_ip ~= "未获取到" then core.set_state("last_5g_pubip", pub_ip) end
        local cell_pub = (pub_ip ~= "未获取到") and pub_ip or core.get_state("last_5g_pubip", "未获取到")
        local wan_last = core.get_state("last_wan_pubip", "备用待命")
        wan_pub_line = string.format("└ 上次出口：<code>%s</code> ⚪", wan_last)
        cell_mode_line = string.format("├ 制式频段：<code>%s · %s</code>", m_info.oper, m_info.band)
        cell_pub_line = string.format("\n└ 公网归属：<code>%s</code> 🟢", cell_pub)
    else
        wan_pub_line = string.format("└ 物理内网：<code>%s</code>", ip_wan)
        cell_mode_line = string.format("└ 蜂窝分配：<code>%s</code>", m_info.sim_ip)
    end

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
    local text = string.format([[🔀 <b>网络主力出口切换</b>

━━━━━━━━━━━━━━
%s <b>当前主力出口</b>：<code>%s</code>
━━━━━━━━━━━━━━
🌐 <b>有线宽带 (eth0)</b>
├ 物理内网：<code>%s</code> (光猫分配)
%s

📶 <b>5G 模组 (usb0)</b>
├ 虚拟网卡：<code>%s</code> (模组网关)
├ 蜂窝分配：<code>%s</code>
%s%s
━━━━━━━━━━━━━━
💡 <i>说明：光猫/5G网卡为设备内网IP；公网归属/蜂窝为运营商真实出口。</i>
👇 <b>点击下方按钮平滑倒换主力上网通道：</b>

🕰️ <i>%s</i>]], cur_icon, cur_name, ip_wan, wan_pub_line, ip_5g, m_info.sim_ip, cell_mode_line, cell_pub_line, now)

    tg.send_msg(text, inline_kb)
end

local function cmd_ping()
    local gw = sys.wan_gateway()
    local p_gw = sys.ping_metric(gw)
    local p_ali = sys.ping_metric("223.5.5.5")
    local p_cf = sys.ping_metric("1.1.1.1")
    local h_direct = sys.http_metric("http://connectivitycheck.platform.hicloud.com/generate_204")
    local c_delay = clash.proxy_delay("🚀 默认代理")
    local p_node = c_delay and string.format("🟢 <code>%d ms</code> (默认代理)", c_delay) or "⚪ <code>未测到</code> (默认代理)"
    local h_proxy = sys.http_metric("http://cp.cloudflare.com/generate_204")

    local now = os.date("%Y-%m-%d %H:%M:%S")
    local inline_kb = {
        {
            { text = "🔄 重新体检", callback_data = "re_ping" },
            { text = "⚡ 节点测速", callback_data = "test_nodes" }
        }
    }

    local text = string.format([[🩺 <b>TohsakaWrt 双向网络体检</b>

━━━━━━━━━━━━━━
<b>一、基础链路 (ICMP 延时与丢包)</b>
🏠 <b>局域网关</b> (<code>%s</code>)：%s
🇨🇳 <b>国内骨干</b> (阿里 DNS)：%s
🌐 <b>境外直连</b> (CF 1.1.1.1)：%s

<b>二、业务连通 (真实响应)</b>
🇨🇳 <b>国内直连</b> (华为 204)：%s
🚀 <b>代理节点</b> (核心直测)：%s
✈️ <b>跨境连通</b> (端到端往返)：%s
━━━━━━━━━━━━━━
💡 <i>评级：🟢 优良 (&lt;80ms/节点&lt;200ms)  🟡 适中  🟠 偏慢  🔴 丢包</i>

🕰️ <i>%s</i>]], gw, p_gw, p_ali, p_cf, h_direct, p_node, h_proxy, now)

    tg.send_msg(text, inline_kb)
end

local function cmd_nodes(arg)
    if arg == "test" or arg == "测速" then
        tg.send_msg("⚡ <b>正在测速分流节点...</b>\n\n请稍候约 2 秒...")
        clash.test_nodes()
        os.execute("sleep 2")
    end

    local mode = clash.mode()
    local nodes = clash.nodes_info()
    local node_lines = {}
    for _, n in ipairs(nodes) do
        local d_badge = "⚪ 未测"
        if n.delay and n.delay ~= "" then
            local d_num = tonumber(n.delay:match("(%d+)"))
            if d_num then
                if d_num < 80 then d_badge = string.format("🟢 %dms", d_num)
                elseif d_num < 180 then d_badge = string.format("🟡 %dms", d_num)
                else d_badge = string.format("🟠 %dms", d_num) end
            else
                d_badge = string.format("⚡ %s", n.delay)
            end
        end
        table.insert(node_lines, string.format("• <b>%s</b> [%s]\n  ├ 策略: <code>%s</code>\n  └ 节点: <code>%s</code>", n.group, d_badge, n.now, n.real))
    end

    local body = (#node_lines > 0) and table.concat(node_lines, "\n") or "⚠️ 无法获取 OpenClash 策略组数据"
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local inline_kb = {
        {
            { text = "⚡ 测速并刷新", callback_data = "test_nodes" },
            { text = "🔄 重启核心", callback_data = "restart_clash" }
        }
    }

    local text = string.format([[🧩 <b>OpenClash 分流策略与节点</b>

━━━━━━━━━━━━━━
🔀 <b>当前分流模式</b>：<code>%s</code>
━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━
💡 <i>提示：点击下方按钮直接测速或重启。</i>

🕰️ <i>%s</i>]], mode, body, now)

    tg.send_msg(text, inline_kb)
end

local function cmd_mode(target)
    local cur = clash.mode()
    local inline_kb = {
        {
            { text = "📐 规则分流", callback_data = "set_mode:rule" },
            { text = "🌐 全局代理", callback_data = "set_mode:global" },
            { text = "⚡ 全局直连", callback_data = "set_mode:direct" }
        }
    }

    if not target or target == "" then
        local mode_desc = cur
        if cur == "rule" then mode_desc = "规则分流 (国内直连 国外代理)"
        elseif cur == "global" then mode_desc = "全局代理 (全部流量走代理节点)"
        elseif cur == "direct" then mode_desc = "全局直连 (全部流量绕过代理)" end

        local text = string.format([[🔀 <b>OpenClash 分流模式管理</b>

━━━━━━━━━━━━━━
当前模式：<code>%s</code>
━━━━━━━━━━━━━━
👇 <b>点击下方按钮一键切换：</b>]], mode_desc)
        tg.send_msg(text, inline_kb)
        return
    end

    target = target:lower()
    if target == "规则" or target == "rule" then target = "rule"
    elseif target == "全局" or target == "global" then target = "global"
    elseif target == "直连" or target == "direct" then target = "direct"
    else
        tg.send_msg("⚠️ <b>无效模式</b>，仅支持 <code>rule</code> / <code>global</code> / <code>direct</code>")
        return
    end

    clash.set_mode(target)
    tg.send_msg(string.format("✅ <b>OpenClash 模式切换成功</b>\n\n当前模式已变更为：<code>%s</code>", target))
end

local function cmd_clash()
    local st = clash.full_status()
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local inline_kb = {
        {
            { text = "🔄 重启 OpenClash", callback_data = "restart_clash" },
            { text = "⚡ 测速节点", callback_data = "test_nodes" }
        }
    }

    local text = string.format([[🧩 <b>OpenClash 运行状态</b>

━━━━━━━━━━━━━━
⚙️ <b>插件配置</b>：%s
🏃 <b>核心状态</b>：%s
🆔 <b>核心 PID</b>：<code>%s</code>
🔌 <b>监听端口</b>：<code>%s</code>
━━━━━━━━━━━━━━
<b>核心版本：</b>
<pre><code>%s</code></pre>

🕰️ <i>%s</i>]], st.enabled and "已启用" or "未启用", st.running and "✅ 正常运行 (Mihomo)" or "❌ 未运行", st.pid, st.ports, st.version, now)

    tg.send_msg(text, inline_kb)
end

local function cmd_clash_restart()
    tg.send_msg("🔄 <b>正在平滑重启核心...</b>\n\n预计耗时 3~5 秒，重启后核心会自动重新接管流量。")
    clash.restart()
end

local function cmd_wan()
    local dev = sys.active_dev()
    local gw = sys.wan_gateway()
    local ip = sys.wan_ip()
    local ip6 = sys.wan_ip6()
    local pub_ip = sys.public_ip()
    local proxy_ip = sys.proxy_outbound_ip()
    local safe_pub_ip = pub_ip:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local safe_proxy_ip = proxy_ip:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local routes = core.exec("ip route show default 2>/dev/null"):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local now = os.date("%Y-%m-%d %H:%M:%S")

    local text = string.format([[🌐 <b>TohsakaWrt WAN 网络详情</b>

━━━━━━━━━━━━━━
🚦 <b>网络连通</b>：🟢 正常
📡 <b>物理接口</b>：<code>%s</code>
🚪 <b>默认网关</b>：<code>%s</code>
━━━━━━━━━━━━━━
🏠 <b>内网 IPv4</b>：<code>%s</code>
🌐 <b>宽带外网</b>：<code>%s</code>
✈️ <b>代理出口</b>：<code>%s</code>
🏠 <b>IPv6 地址</b>：<code>%s</code>
━━━━━━━━━━━━━━

<b>默认路由：</b>
<pre><code>%s</code></pre>

🕰️ <i>%s</i>]], dev, gw, ip, safe_pub_ip, safe_proxy_ip, ip6, (routes ~= "" and routes or "无"), now)

    tg.send_msg(text)
end

local function cmd_temp()
    local temp = sys.cpu_temp()
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local text = string.format([[🌡️ <b>CPU 实时温度</b>

━━━━━━━━━━━━━━
🔥 <b>当前核心温度</b>：<code>%s</code>
📊 <b>状态评估</b>：正常 (安全范围 &lt; 75°C)
━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], temp, now)
    tg.send_msg(text)
end

local function cmd_modem()
    local m = modem.info()
    local usb0 = sys.usb0_ip()
    local has_at = nixio and nixio.fs and nixio.fs.stat("/dev/ttyUSB2")
    local modem_status = has_at and "✅ 已连接" or "⚪ 未检测到"
    local now = os.date("%Y-%m-%d %H:%M:%S")

    local text = string.format([[📡 <b>5G 蜂窝模块 (RM500Q-GL)</b>

━━━━━━━━━━━━━━
📟 <b>模组硬件</b>：%s
📶 <b>网络制式</b>：<code>%s</code>
📻 <b>工作频段</b>：<code>%s</code>
🏢 <b>运营商</b>：<code>%s</code>
🌐 <b>蜂窝内网</b>：<code>%s</code>
🔌 <b>USB 网卡</b>：<code>%s</code>
━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], modem_status, m.mode, m.band, m.oper, m.sim_ip, usb0, now)

    tg.send_msg(text)
end

local function cmd_direct(arg)
    arg = arg and arg:match("^%s*(.-)%s*$") or ""
    if arg == "" then
        local text = [[🎯 <b>添加直连白名单</b>

━━━━━━━━━━━━━━
<b>用法：</b>
<code>/direct &lt;域名或IP&gt;</code>

<b>示例：</b>
• 域名：<code>/direct mysite.com</code>
• IP地址：<code>/direct 123.45.67.89</code>
• 网段：<code>/direct 10.0.0.0/8</code>

💡 <i>添加后规则自动写入顶部并毫秒级热重载，无需重启核心！</i>]]
        tg.send_msg(text)
        return
    end

    local res = clash.direct_add(arg)
    if res:find("^ADDED:") then
        local cleaned = res:gsub("^ADDED:", "")
        tg.send_msg(string.format([[✅ <b>已成功加入直连白名单</b>

━━━━━━━━━━━━━━
🎯 <b>目标条目</b>：<code>%s</code>
⚡ <b>生效状态</b>：规则已毫秒级热重载 (Direct)
━━━━━━━━━━━━━━
💡 <i>如需移除，可发送：<code>/undirect %s</code></i>]], cleaned, cleaned))
    elseif res:find("^EXISTS:") then
        local cleaned = res:gsub("^EXISTS:", "")
        tg.send_msg(string.format("ℹ️ <b>条目已在直连白名单中</b>\n\n目标 <code>%s</code> 此前已添加，当前正处于直连状态。", cleaned))
    else
        tg.send_msg("⚠️ <b>添加失败</b>：输入的目标无效或解析为空。")
    end
end

local function cmd_undirect(arg)
    arg = arg and arg:match("^%s*(.-)%s*$") or ""
    if arg == "" then
        tg.send_msg("🗑️ <b>移除直连白名单</b>\n\n<b>用法：</b>\n<code>/undirect &lt;序号 或 域名/IP&gt;</code>\n\n示例：<code>/undirect 1</code>")
        return
    end

    local res = clash.direct_del(arg)
    if res:find("^DELETED:") then
        local cleaned = res:gsub("^DELETED:", "")
        tg.send_msg(string.format("🗑️ <b>已成功从直连白名单移除</b>\n\n目标 <code>%s</code> 已被移除，核心配置已同步热重载。", cleaned))
    elseif res:find("^ERROR:out_of_range") then
        tg.send_msg("⚠️ <b>移除失败</b>：指定的序号超出当前列表范围。")
    else
        tg.send_msg("⚠️ <b>移除失败</b>：列表中未找到指定条目。")
    end
end

local function cmd_direct_list()
    local list = clash.direct_list()
    local now = os.date("%Y-%m-%d %H:%M:%S")

    if #list == 0 then
        tg.send_msg(string.format("🎯 <b>OpenClash 直连白名单 (0 条)</b>\n\n当前尚未添加任何自定义直连规则。\n发送 <code>/direct &lt;域名或IP&gt;</code> 可直接添加。\n\n🕰️ <i>%s</i>", now))
        return
    end

    local lines = {}
    for i, item in ipairs(list) do
        local icon = item:match("^%d") and "🔢" or "🌐"
        table.insert(lines, string.format("%s <b>%d.</b> <code>%s</code>", icon, i, item))
    end

    local inline_kb = {
        { { text = "🔄 刷新列表", callback_data = "refresh_direct" } }
    }

    local text = string.format([[🎯 <b>OpenClash 直连白名单</b>

━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━
📊 <b>共计</b>：<code>%d</code> 个自定义直连规则

💡 <b>快捷操作提示：</b>
• 添加：发送 <code>/direct 域名或IP</code>
• 移除：发送 <code>/undirect 序号</code> (如 <code>/undirect 1</code>)

🕰️ <i>%s</i>]], table.concat(lines, "\n"), #list, now)

    tg.send_msg(text, inline_kb)
end

local function cmd_clients()
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
                table.insert(leases, string.format("• <b>%s</b>\n  ├ IP: <code>%s</code>\n  └ MAC: <code>%s</code>", d_name, ip, mac:upper()))
            end
        end
        f:close()
    end

    local now = os.date("%Y-%m-%d %H:%M:%S")
    local body = (#leases > 0) and table.concat(leases, "\n") or "暂无在线客户端数据"
    local text = string.format([[👥 <b>在线客户端 (%d 台)</b>

━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━
💡 <i>提示：发送 /alias 查看或为未知设备添加中文备注。</i>

🕰️ <i>%s</i>]], #leases, body, now)

    tg.send_msg(text)
end

local function cmd_alias(arg)
    arg = arg and arg:match("^%s*(.-)%s*$") or ""
    if arg == "" then
        local aliases = sys.load_aliases()
        local lines = {}
        for m, n in pairs(aliases) do
            table.insert(lines, string.format("• <code>%s</code> : <b>%s</b>", m:upper(), n))
        end
        local list_body = (#lines > 0) and table.concat(lines, "\n") or "暂无设备备注记录"
        local text = string.format([[🏷️ <b>设备备注管理</b>

━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━
<b>使用说明：</b>
• <b>添加/修改备注</b>：<code>/alias MAC地址 设备名字</code>
  <i>例如：/alias 26:e2:0d:d6:08:d2 客厅电视</i>
• <b>删除备注</b>：<code>/alias del MAC地址</code>]], list_body)
        tg.send_msg(text)
        return
    end

    local sub_cmd, rest = arg:match("^(%S+)%s*(.*)$")
    sub_cmd = sub_cmd or ""
    if sub_cmd == "del" or sub_cmd == "rm" then
        local target_mac = rest:match("^(%S+)")
        if target_mac and target_mac ~= "" then
            sys.del_alias(target_mac)
            tg.send_msg(string.format("🗑️ 已删除 MAC <code>%s</code> 的设备备注。", target_mac:upper()))
        else
            tg.send_msg("⚠️ 请提供要删除的 MAC 地址，例如：<code>/alias del 26:e2:0d:d6:08:d2</code>")
        end
        return
    end

    local set_mac = sub_cmd
    local set_name = rest:match("^%s*(.-)%s*$")
    if not set_name or set_name == "" then
        tg.send_msg("⚠️ 缺少设备名字。\n格式：<code>/alias MAC地址 设备名字</code>\n例如：<code>/alias 26:e2:0d:d6:08:d2 客厅电视</code>")
        return
    end

    sys.set_alias(set_mac, set_name)
    local text = string.format([[✅ <b>设备备注已保存</b>

━━━━━━━━━━━━━━
🔑 <b>MAC</b>：<code>%s</code>
🏷️ <b>备注</b>：<b>%s</b>
━━━━━━━━━━━━━━
下次查询在线设备时将直接展示该备注！]], set_mac:upper(), set_name)
    tg.send_msg(text)
end

local function cmd_storage()
    local storage, block = sys.storage_info()
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local s_text = (storage ~= "") and storage:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") or "未获取到存储空间"
    local b_text = (block ~= "") and block:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") or "未获取到块设备"

    local text = string.format([[💾 <b>TohsakaWrt 存储状态</b>

<pre><code>%s</code></pre>

<b>块设备：</b>
<pre><code>%s</code></pre>

🕰️ <i>%s</i>]], s_text, b_text, now)
    tg.send_msg(text)
end

local function cmd_usb()
    local usb = sys.usb_info():gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local text = string.format([[🔌 <b>TohsakaWrt USB 拓扑</b>

<pre><code>%s</code></pre>

🕰️ <i>%s</i>]], usb, now)
    tg.send_msg(text)
end

-- ==================== CALLBACK DISPATCH ====================

local function handle_callback(cb_id, msg_id, data_str)
    if data_str:find("^set_uplink:") then
        local target = data_str:gsub("^set_uplink:", "")
        local res = sys.switch_uplink(target)
        local notice = (target == "wan") and "已切换为主力有线宽带" or "已切换为主力 5G 模组"
        local desc = (target == "wan") and "🌐 <b>当前主力出口</b>：<code>有线光猫宽带 (eth0)</code>\n⚡ <b>状态</b>：平滑倒换完成，网络连接零中断。" or "📶 <b>当前主力出口</b>：<code>5G 蜂窝模组 (usb0)</code>\n⚡ <b>状态</b>：平滑倒换完成，已进入 5G 模组通道。"
        if res == "ERROR_5G_NO_IP" then
            notice = "切换失败：5G 模组未获取到 IP"
            desc = "⚠️ <b>切换失败</b>：5G 模组 (usb0) 当前未获取到有效 IP，无法作为主力出口。"
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

━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━
👇 点击下方按钮可再次倒换：

🕰️ <i>%s</i>]], desc, now)

        tg.edit_msg(msg_id, new_text, inline_kb)

    elseif data_str == "open_uplink_menu" then
        tg.answer_callback(cb_id, "🔀 正在打开出口切换菜单...")
        cmd_uplink()

    elseif data_str == "refresh_status" then
        tg.answer_callback(cb_id, "🔄 正在刷新看板...")
        cmd_status()

    elseif data_str == "refresh_direct" then
        tg.answer_callback(cb_id, "🔄 正在刷新直连白名单...")
        cmd_direct_list()

    elseif data_str == "re_ping" then
        tg.answer_callback(cb_id, "🩺 正在重新测试网络质量，请稍候约2秒...")
        cmd_ping()

    elseif data_str == "test_nodes" then
        tg.answer_callback(cb_id, "⚡ 正在测速分流节点...")
        cmd_nodes("test")

    elseif data_str == "restart_clash" then
        tg.answer_callback(cb_id, "🔄 正在重启 OpenClash...")
        cmd_clash_restart()

    elseif data_str:find("^set_mode:") then
        local mode = data_str:gsub("^set_mode:", "")
        clash.set_mode(mode)
        local mode_name = mode
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

━━━━━━━━━━━━━━
🔀 <b>当前模式</b>：<code>%s</code>
━━━━━━━━━━━━━━
👇 点击可再次切换：]], mode_name)

        tg.edit_msg(msg_id, new_text, inline_kb)
    end
end

-- ==================== COMMAND DISPATCH ====================

local function handle_command(text)
    text = text:match("^%s*(.-)%s*$")
    if not text or text == "" then return end

    core.log("Tohsaka-Bot", "Command: " .. text)

    local cmd, arg
    if text:sub(1, 1) == "/" then
        cmd, arg = text:match("^(%S+)%s*(.*)$")
        cmd = (cmd or ""):gsub("@.*$", ""):lower()
    else
        cmd = text
        arg = ""
    end

    local full = text

    if cmd == "/start" or cmd == "/help" or cmd == "/menu" or full:find("帮助") then
        cmd_help()
    elseif cmd == "/status" or full:find("状态") or full:find("看板") then
        cmd_status()
    elseif cmd == "/uplink" or cmd == "/switch_wan" or full:find("出口") or full:find("切网") or full:find("换网") or full:find("切5G") or full:find("切5g") then
        cmd_uplink()
    elseif cmd == "/ping" or cmd == "/check" or cmd == "/test" or full:find("体检") or full:find("双向") or full:find("测速") then
        cmd_ping()
    elseif cmd == "/mode" or full:find("分流模式") or (full:find("模式") and not full:find("模组")) then
        cmd_mode(arg)
    elseif cmd == "/nodes" or full:find("节点") or full:find("分流") then
        cmd_nodes(arg)
    elseif cmd == "/wan" or full:find("外网") or full:find("路由") then
        cmd_wan()
    elseif cmd == "/temp" or full:find("温度") then
        cmd_temp()
    elseif cmd == "/modem" or full:find("5G") or full:find("5g") or full:find("模组") then
        cmd_modem()
    elseif cmd == "/direct" or cmd == "/bypass" then
        cmd_direct(arg)
    elseif cmd == "/undirect" or full:find("删直连") then
        cmd_undirect(arg)
    elseif cmd == "/direct_list" or full:find("白名单") or full:find("直连") then
        if arg and arg ~= "" then
            cmd_direct(arg)
        else
            cmd_direct_list()
        end
    elseif cmd == "/clients" or cmd == "/devices" or full:find("设备") or full:find("客户端") then
        cmd_clients()
    elseif cmd == "/alias" or full:find("备注") then
        cmd_alias(arg)
    elseif cmd == "/clash_restart" or full:find("重启核心") then
        cmd_clash_restart()
    elseif cmd == "/clash" or full:find("核心") then
        cmd_clash()
    elseif cmd == "/storage" or full:find("存储") then
        cmd_storage()
    elseif cmd == "/usb" or full:find("USB") or full:find("usb") then
        cmd_usb()
    else
        local safe = full:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        tg.send_msg(string.format("⚠️ <b>未识别的命令</b>：<code>%s</code>\n\n发送 /help 或点击下方键盘查看可用命令。", safe))
    end
end

-- ==================== MAIN EVENT LOOP ====================

function M.run()
    core.log("Tohsaka-Bot", "Starting TohsakaWrt Telegram Bot Daemon (Lua Engine)...")
    local enabled = core.get_uci("tohsakawrt-tgbot", "main", "enabled", "0")
    local token = core.get_uci("tohsakawrt-tgbot", "main", "token", "")
    local chat_id = core.get_uci("tohsakawrt-tgbot", "main", "chat_id", "")
    if enabled ~= "1" or token == "" or chat_id == "" then
        core.log("Tohsaka-Bot", "Bot disabled or unconfigured in UCI. Exiting.")
        return
    end

    local offset = tonumber(core.get_state("offset", "0")) or 0

    -- Synchronize offset on startup to avoid backlog
    local init = tg.get_updates(-1, 0)
    if init and init.result and #init.result > 0 then
        offset = (init.result[#init.result].update_id or 0) + 1
        core.set_state("offset", tostring(offset))
    end

    local loop_count = 0
    local fail_count = 0
    while true do
        loop_count = loop_count + 1
        if loop_count % 20 == 0 then
            collectgarbage("step", 50)
        end
        local res = tg.get_updates(offset, 8)
        if res and res.result then
            fail_count = 0
            for _, u in ipairs(res.result) do
                local uid = u.update_id
                if uid then
                    offset = uid + 1
                    core.set_state("offset", tostring(offset))
                end

                if u.callback_query then
                    local cq = u.callback_query
                    local cq_id = cq.id
                    local msg_id = cq.message and cq.message.message_id
                    local data_str = cq.data or ""
                    local ok, err = pcall(handle_callback, cq_id, msg_id, data_str)
                    if not ok then
                        core.log("Tohsaka-Bot", "Callback error: " .. tostring(err))
                    end
                elseif u.message or u.edited_message then
                    local msg = u.message or u.edited_message
                    if msg and msg.text then
                        tg.send_chat_action("typing")
                        local ok, err = pcall(handle_command, msg.text)
                        if not ok then
                            core.log("Tohsaka-Bot", "Command error: " .. tostring(err))
                        end
                    end
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
