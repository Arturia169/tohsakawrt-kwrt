-- TohsakaWrt Bot：网络与代理相关命令（出口切换 / 节点 / 分流模式 / OpenClash 核心 / 体检 / 宽带详情）
-- 共享零件来自 bot_common；本模块只放"网络与代理"这一类功能。
local bc = require("tohsakawrt.bot_common")
local core, tg, sys, modem, clash, esim, nixio =
    bc.core, bc.tg, bc.sys, bc.modem, bc.clash, bc.esim, bc.nixio
local html_escape, ask_confirm = bc.html_escape, bc.ask_confirm

local M = {}

local function build_uplink_menu()
    local uplink = sys.uplink_status()
    local cur_name = (uplink.type == "wan") and "有线宽带 (eth0)" or ((uplink.type == "5g") and "5G 蜂窝网络 (usb0)" or (tostring(uplink.dev or "unknown") .. " (未知接口)"))
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
        wan_pub_line = string.format("└ <b>公网归属</b>：<code>%s</code> 🟢", html_escape(wan_pub))
        cell_mode_line = string.format("└ <b>制式频段</b>：<code>%s · %s</code> ℹ️", html_escape(m_info.oper), html_escape(m_info.band))
    elseif uplink.type == "5g" then
        if pub_ip ~= "未获取到" then core.set_state("last_5g_pubip", pub_ip) end
        local cell_pub = (pub_ip ~= "未获取到") and pub_ip or core.get_state("last_5g_pubip", "未获取到")
        local wan_last = core.get_state("last_wan_pubip", "备用待命")
        wan_pub_line = string.format("└ <b>上次出口</b>：<code>%s</code> ℹ️", html_escape(wan_last))
        cell_mode_line = string.format("├ <b>制式频段</b>：<code>%s · %s</code>", html_escape(m_info.oper), html_escape(m_info.band))
        cell_pub_line = string.format("\n└ <b>公网归属</b>：<code>%s</code> 🟢", html_escape(cell_pub))
    else
        wan_pub_line = string.format("└ <b>物理内网</b>：<code>%s</code>", html_escape(ip_wan))
        cell_mode_line = string.format("└ <b>蜂窝分配</b>：<code>%s</code>", html_escape(m_info.sim_ip))
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

━━━━━━━━━━━━━━━━━━
%s <b>当前主力出口</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
🌐 <b>有线宽带 (eth0)</b>
├ 物理内网：<code>%s</code> (光猫分配)
%s

📶 <b>5G 模组 (usb0)</b>
├ 虚拟网卡：<code>%s</code> (模组网关)
├ 蜂窝分配：<code>%s</code>
%s%s
━━━━━━━━━━━━━━━━━━
💡 <i>说明：光猫/5G网卡为设备内网IP；公网归属/蜂窝为运营商真实出口。</i>
👇 <b>点击下方按钮平滑倒换主力上网通道：</b>

🕰️ <i>%s</i>]], cur_icon, html_escape(cur_name), html_escape(ip_wan), wan_pub_line, html_escape(ip_5g), html_escape(m_info.sim_ip), cell_mode_line, cell_pub_line, html_escape(now))

    return text, inline_kb
end

function M.cmd_uplink(msg_id)
    local text, inline_kb = build_uplink_menu()
    if msg_id then
        return tg.edit_msg(msg_id, text, inline_kb)
    end
    return tg.send_msg(text, inline_kb)
end

function M.cmd_ping()
    local gw = sys.wan_gateway()
    local p_gw_ok, p_gw_icon, p_gw_ms, p_gw_loss = sys.ping_metric(gw)
    local p_ali_ok, p_ali_icon, p_ali_ms, p_ali_loss = sys.ping_metric("223.5.5.5")
    local p_cf_ok, p_cf_icon, p_cf_ms, p_cf_loss = sys.ping_metric("1.1.1.1")
    local h_direct_ok, h_direct_icon, h_direct_ms = sys.http_metric("http://connectivitycheck.platform.hicloud.com/generate_204")
    local c_delay = clash.proxy_delay("🚀 默认代理")
    local p_node_icon = c_delay and "🟢" or "ℹ️"
    local p_node_ms = c_delay and (tostring(c_delay) .. " ms") or "未测到"
    local h_proxy_ok, h_proxy_icon, h_proxy_ms = sys.http_metric("http://cp.cloudflare.com/generate_204")

    local function metric_display(ok, ms_str)
        return ok and (ms_str .. " ms") or ms_str
    end

    local now = os.date("%Y-%m-%d %H:%M:%S")
    local inline_kb = {
        {
            { text = "🔄 重新体检", callback_data = "re_ping" },
            { text = "⚡ 节点测速", callback_data = "test_nodes" }
        }
    }

    local text = string.format([[🩺 <b>双向网络体检</b>

━━━━━━━━━━━━━━━━━━
<b>一、基础链路 (ICMP 延时与丢包)</b>
🏠 <b>局域网关</b> (<code>%s</code>)：%s <code>%s</code> (%s)
🇨🇳 <b>国内骨干</b> (阿里 DNS)：%s <code>%s</code> (%s)
🌐 <b>境外直连</b> (CF 1.1.1.1)：%s <code>%s</code> (%s)

<b>二、业务连通 (真实响应)</b>
🇨🇳 <b>国内直连</b> (华为 204)：%s <code>%s</code>
🚀 <b>代理节点</b> (核心直测)：%s <code>%s</code> (默认代理)
✈️ <b>跨境连通</b> (端到端往返)：%s <code>%s</code>
━━━━━━━━━━━━━━━━━━
💡 <i>评级：🟢 良好  🟡 一般  🟠 偏高  🔴 不可达</i>
📏 <i>阈值：ICMP 80 / 150 ms · HTTP 500 / 1000 ms</i>

🕰️ <i>%s</i>]], html_escape(gw), p_gw_icon, html_escape(metric_display(p_gw_ok, p_gw_ms)), html_escape(p_gw_loss),
        p_ali_icon, html_escape(metric_display(p_ali_ok, p_ali_ms)), html_escape(p_ali_loss),
        p_cf_icon, html_escape(metric_display(p_cf_ok, p_cf_ms)), html_escape(p_cf_loss),
        h_direct_icon, html_escape(metric_display(h_direct_ok, h_direct_ms)), p_node_icon, html_escape(p_node_ms),
        h_proxy_icon, html_escape(metric_display(h_proxy_ok, h_proxy_ms)), html_escape(now))

    tg.send_msg(text, inline_kb)
end

function M.cmd_nodes(arg)
    if arg == "test" or arg == "测速" then
        tg.send_msg("⚡ <b>正在测速分流节点...</b>\n\n请稍候约 2 秒...")
        clash.test_nodes()
        os.execute("sleep 2")
    end

    local mode = clash.mode()
    local nodes = clash.nodes_info()
    local node_lines = {}
    for _, n in ipairs(nodes) do
        local d_badge = "ℹ️ 未测"
        if n.delay and n.delay ~= "" then
            local d_num = tonumber(n.delay:match("(%d+)"))
            if d_num then
                if d_num < 80 then d_badge = string.format("🟢 %dms", d_num)
                else d_badge = string.format("⚠️ %dms", d_num) end
            else
                d_badge = string.format("⚠️ %s", n.delay)
            end
        end
            table.insert(node_lines, string.format("• <b>%s</b> [%s]\n  ├ <b>策略</b>：<code>%s</code>\n  └ <b>节点</b>：<code>%s</code>", html_escape(n.group), html_escape(d_badge), html_escape(n.now), html_escape(n.real)))
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

━━━━━━━━━━━━━━━━━━
🔀 <b>当前分流模式</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━
💡 <i>提示：点击下方按钮直接测速或重启。</i>

🕰️ <i>%s</i>]], html_escape(mode), body, html_escape(now))

    tg.send_msg(text, inline_kb)
end

function M.cmd_mode(target)
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

━━━━━━━━━━━━━━━━━━
🔀 <b>当前模式</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
👇 <b>点击下方按钮一键切换：</b>

🕰️ <i>%s</i>]], html_escape(mode_desc), os.date("%Y-%m-%d %H:%M:%S"))
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
    tg.send_msg(string.format("✅ OpenClash 模式已切换为 <code>%s</code>。", html_escape(target)))
end

function M.cmd_clash()
    local st = clash.full_status()
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local inline_kb = {
        {
            { text = "🔄 重启 OpenClash", callback_data = "restart_clash" },
            { text = "⚡ 测速节点", callback_data = "test_nodes" }
        }
    }

    local text = string.format([[🧩 <b>OpenClash 运行状态</b>

━━━━━━━━━━━━━━━━━━
⚙️ <b>插件配置</b>：%s
🏃 <b>核心状态</b>：%s
🆔 <b>核心 PID</b>：<code>%s</code>
🔌 <b>监听端口</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
<b>核心版本：</b>
<pre><code>%s</code></pre>

🕰️ <i>%s</i>]], st.enabled and "已启用" or "未启用", st.running and "✅ 正常运行 (Mihomo)" or "🔴 未运行", html_escape(st.pid), html_escape(st.ports), html_escape(st.version), html_escape(now))

    tg.send_msg(text, inline_kb)
end

function M.cmd_clash_restart(confirmed)
    if not confirmed then
        ask_confirm("重启 OpenClash 核心", "Mihomo 核心守护进程", "短暂断流 3~5 秒，核心自动重载并重新接管分流", "do_clash_restart")
        return
    end
    tg.send_msg("🔄 <b>正在平滑重启核心...</b>\n\n预计耗时 3~5 秒，重启后核心会自动重新接管流量。")
    clash.restart()
end

function M.cmd_wan()
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

    local text = string.format([[🌐 <b>WAN 网络详情</b>

━━━━━━━━━━━━━━━━━━
🚦 <b>网络连通</b>：🟢 正常
📡 <b>物理接口</b>：<code>%s</code>
🚪 <b>默认网关</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
🏠 <b>内网 IPv4</b>：<code>%s</code>
🌐 <b>宽带外网</b>：<code>%s</code>
✈️ <b>代理出口</b>：<code>%s</code>
🏠 <b>IPv6 地址</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━

<b>默认路由：</b>
<pre><code>%s</code></pre>

🕰️ <i>%s</i>]], html_escape(dev), html_escape(gw), html_escape(ip), safe_pub_ip, safe_proxy_ip, html_escape(ip6), (routes ~= "" and routes or "无"), html_escape(now))

    tg.send_msg(text)
end


return M
