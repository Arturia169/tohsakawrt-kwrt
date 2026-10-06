-- TohsakaWrt Telegram Bot Daemon (Pure Lua)
local M = {}

local core = require("tohsakawrt.core")
local tg = require("tohsakawrt.tg")
local sys = require("tohsakawrt.system")
local modem = require("tohsakawrt.modem")
local clash = require("tohsakawrt.clash")
local esim = require("tohsakawrt.esim")
local nixio_ok, nixio = pcall(require, "nixio")
if not nixio_ok then nixio = nil end

local function html_escape(value)
    local escaped = tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return escaped
end

-- ==================== COMMAND HANDLERS ====================

local function ask_confirm(title, desc, impact, confirm_action)
    local text = string.format([[⚠️ <b>敏感操作确认</b>
━━━━━━━━━━━━━━━━━━
<b>操作项目</b>：<code>%s</code>
<b>操作目标</b>：<code>%s</code>
<b>影响评估</b>：%s

❓ <b>请确认是否真的执行？</b>

🕰️ <i>%s</i>]], html_escape(title), html_escape(desc), html_escape(impact), os.date("%Y-%m-%d %H:%M:%S"))
    local inline_kb = {
        {
            { text = "🔴 确认执行", callback_data = confirm_action },
            { text = "🟢 取消操作", callback_data = "cancel_action" }
        }
    }
    tg.send_msg(text, inline_kb)
end

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
/storage - 💾 存储分区与挂载
/usb - 🔌 USB 设备拓扑
/modem - 📡 5G 模组与射频信号看板 (RM500Q)
/sms [条数] - ✉️ 模组短信息与验证码提取
/modemreload - 🔄 重载 5G 模组
/cards - 📇 查看卡内号码
/switch <序号或关键词> - 🔀 切换 eSIM 号码
/download <激活码> [确认码] - 📥 下载并写入新 eSIM Profile
/reboot - ⚡ 重启路由器系统 (带确认闸门)
/poweroff - 🔌 关闭路由器电源 (带确认闸门)

<i>💡 点击下方快捷键盘可直接执行常用指令。</i>]]
    tg.send_msg(text)
end

local function cmd_status()
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
        }
    }

    tg.send_msg(text, inline_kb)
end

local function cmd_uplink()
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

    tg.send_msg(text, inline_kb)
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

local function cmd_clash_restart(confirmed)
    if not confirmed then
        ask_confirm("重启 OpenClash 核心", "Mihomo 核心守护进程", "短暂断流 3~5 秒，核心自动重载并重新接管分流", "do_clash_restart")
        return
    end
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

local function cmd_temp()
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

local function cmd_modem(msg_id)
    local m = modem.info()
    local usb0 = sys.usb0_ip()
    local port = modem.get_port and modem.get_port() or "/dev/ttyUSB3"
    local has_at = nixio and nixio.fs and nixio.fs.stat(port)
    local modem_status = has_at and "✅ 已连接" or "ℹ️ 未检测到"
    local now = os.date("%Y-%m-%d %H:%M:%S")

    -- 信号强度仪表状态
    local rsrp_line = "未获取"
    if m.rsrp then
        local r = m.rsrp_num or -999
        local r_icon = "🟢"
        local r_eval = "极佳"
        if r <= -110 then r_icon = "🔴"; r_eval = "极差"
        elseif r <= -100 then r_icon = "🟠"; r_eval = "较弱"
        elseif r <= -85 then r_icon = "🟡"; r_eval = "中等"
        elseif r <= -75 then r_icon = "🟢"; r_eval = "良好"
        else r_icon = "🟢"; r_eval = "极佳" end
        rsrp_line = string.format("<code>%s</code> (%s) %s", html_escape(m.rsrp), r_eval, r_icon)
    end

    local sinr_line = "未获取"
    if m.sinr then
        local s = m.sinr_num or -999
        local s_icon = "🟢"
        local s_eval = "极佳"
        if s <= 0 then s_icon = "🔴"; s_eval = "极差"
        elseif s <= 5 then s_icon = "🟠"; s_eval = "较弱"
        elseif s <= 13 then s_icon = "🟡"; s_eval = "良好"
        else s_icon = "🟢"; s_eval = "极佳" end
        sinr_line = string.format("<code>%s</code> (%s) %s", html_escape(m.sinr), s_eval, s_icon)
    end

    local rsrq_line = m.rsrq and string.format("<code>%s</code>", html_escape(m.rsrq)) or "未获取"
    local temp_line = m.temp and string.format("<code>%s</code> 🟢", html_escape(m.temp)) or "未获取"
    local qci_line = m.qci and string.format("<code>5QI %s (标准移动宽带)</code>", html_escape(m.qci)) or "未获取"
    local ambr_line = (m.ambr_dl and m.ambr_ul) and string.format("<code>下行 %s / 上行 %s</code>", html_escape(m.ambr_dl), html_escape(m.ambr_ul)) or "未获取"

    local cell_extra = ""
    if m.pci and m.cell_id then
        cell_extra = string.format("\n📍 <b>小区标识</b>：PCI <code>%s</code> · CellID <code>%s</code>", html_escape(m.pci), html_escape(m.cell_id))
    end

    local text = string.format([[📡 <b>5G 蜂窝模块 (RM500Q-GL)</b>

━━━━━━━━━━━━━━━━━━
📟 <b>硬件状态</b>：%s (<code>%s</code>)
🏢 <b>运营商</b>：<code>%s</code>
📶 <b>网络制式</b>：<code>%s</code>
📻 <b>工作频段</b>：<code>%s</code>
🌡️ <b>模组温度</b>：%s
━━━━━━━━━━━━━━━━━━
📊 <b>信号质量指示</b>：
├ 接收功率 (RSRP)：%s
├ 信号质量 (RSRQ)：%s
└ 信噪比 (SINR)：%s%s
━━━━━━━━━━━━━━━━━━
🚀 <b>网络业务签约</b>：
├ 业务等级：%s
└ 签约速率：%s
━━━━━━━━━━━━━━━━━━
🌐 <b>蜂窝内网</b>：<code>%s</code>
🔌 <b>USB 网卡</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
🕰️ <i>%s</i>]],
        modem_status, html_escape(port),
        html_escape(m.oper),
        html_escape(m.mode),
        html_escape(m.band),
        temp_line,
        rsrp_line,
        rsrq_line,
        sinr_line,
        cell_extra,
        qci_line,
        ambr_line,
        html_escape(m.sim_ip),
        html_escape(usb0),
        html_escape(now)
    )

    local inline_kb = {
        {
            { text = "🔄 刷新状态", callback_data = "refresh_modem" },
            { text = "✉️ 查收短信", callback_data = "show_sms" }
        },
        {
            { text = "📇 卡内号码", callback_data = "refresh_cards" },
            { text = "🔄 重载模组", callback_data = "do_modem_reload" }
        }
    }

    if msg_id then
        tg.edit_msg(msg_id, text, inline_kb)
    else
        tg.send_msg(text, inline_kb)
    end
end

local function cmd_sms(limit, msg_id)
    limit = tonumber(limit) or 3
    if limit > 10 then limit = 10 end
    if limit < 1 then limit = 1 end

    local list = modem.sms_list and modem.sms_list("ME", limit) or {}
    local now = os.date("%Y-%m-%d %H:%M:%S")

    if not list or #list == 0 then
        local text = string.format([[✉️ <b>5G 模组短信收件箱</b>

━━━━━━━━━━━━━━━━━━
📭 <b>当前收件箱为空</b>
<i>未在模组设备存储中检测到有效短消息。</i>
━━━━━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], html_escape(now))

        local inline_kb = {
            {
                { text = "🔄 刷新短信", callback_data = "refresh_sms" },
                { text = "📡 模组状态", callback_data = "refresh_modem" }
            }
        }
        if msg_id then tg.edit_msg(msg_id, text, inline_kb)
        else tg.send_msg(text, inline_kb) end
        return
    end

    local items = {}
    for i, m in ipairs(list) do
        local code_part = ""
        if m.code then
            code_part = string.format("\n🔐 <b>提取验证码</b>：<code>%s</code> <i>(轻按直接复制)</i>", html_escape(m.code))
        end
        local content = html_escape(m.content):gsub("^%s+", ""):gsub("%s+$", "")
        local item = string.format([[📩 <b>#%d 发件人</b>：<code>%s</code>
⏰ <b>时间</b>：<code>%s</code>%s
💬 <b>内容</b>：
%s]],
            i,
            html_escape(m.sender),
            html_escape(m.timestamp),
            code_part,
            content
        )
        table.insert(items, item)
    end

    local text = string.format([[✉️ <b>5G 模组短信收件箱 (最近 %d 条)</b>

━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━
💡 <i>单按代码块可一键复制验证码。</i>

🕰️ <i>%s</i>]],
        #list,
        table.concat(items, "\n━━━━━━━━━━━━━━━━━━\n"),
        html_escape(now)
    )

    local inline_kb = {
        {
            { text = "🔄 刷新短信", callback_data = "refresh_sms" },
            { text = "📡 模组状态", callback_data = "refresh_modem" }
        },
        {
            { text = "📇 卡内号码", callback_data = "refresh_cards" }
        }
    }

    if msg_id then
        tg.edit_msg(msg_id, text, inline_kb)
    else
        tg.send_msg(text, inline_kb)
    end
end

local function cmd_direct(arg)
    arg = arg and arg:match("^%s*(.-)%s*$") or ""
    if arg == "" then
        local text = [[🎯 <b>添加直连白名单</b>

━━━━━━━━━━━━━━━━━━
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

━━━━━━━━━━━━━━━━━━
🎯 <b>目标条目</b>：<code>%s</code>
⚡ <b>生效状态</b>：规则已毫秒级热重载 (Direct)
━━━━━━━━━━━━━━━━━━
<i>如需移除，可发送：<code>/undirect %s</code></i>

🕰️ <i>%s</i>]], html_escape(cleaned), html_escape(cleaned), os.date("%Y-%m-%d %H:%M:%S")))
    elseif res:find("^EXISTS:") then
        local cleaned = res:gsub("^EXISTS:", "")
        tg.send_msg(string.format("ℹ️ <b>条目已在直连白名单中</b>：目标 <code>%s</code> 此前已添加，当前正处于直连状态。", html_escape(cleaned)))
    else
        tg.send_msg("⚠️ <b>添加失败</b>：输入的目标无效或解析为空。")
    end
end

local function cmd_undirect(arg, confirmed)
    arg = arg and arg:match("^%s*(.-)%s*$") or ""
    if arg == "" then
        tg.send_msg("🗑️ <b>移除直连白名单</b>\n\n<b>用法：</b>\n<code>/undirect &lt;序号 或 域名/IP&gt;</code>\n\n示例：<code>/undirect 1</code>")
        return
    end
    if not confirmed then
        ask_confirm("删除直连白名单", arg, "目标将不再享受免代理直连待遇，重新受 OpenClash 分流规则控制", "do_undirect:" .. arg)
        return
    end

    local res = clash.direct_del(arg)
    if res:find("^DELETED:") then
        local cleaned = res:gsub("^DELETED:", "")
        tg.send_msg(string.format("🗑️ 已从直连白名单移除目标 <code>%s</code>，核心配置已同步热重载。", html_escape(cleaned)))
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
        table.insert(lines, string.format("%s <b>%d.</b> <code>%s</code>", icon, i, html_escape(item)))
    end

    local inline_kb = {
        { { text = "🔄 刷新列表", callback_data = "refresh_direct" } }
    }

    local text = string.format([[🎯 <b>OpenClash 直连白名单</b>

━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━
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

local function cmd_alias(arg)
    arg = arg and arg:match("^%s*(.-)%s*$") or ""
    if arg == "" then
        local aliases = sys.load_aliases()
        local lines = {}
        for m, n in pairs(aliases) do
            table.insert(lines, string.format("• <code>%s</code> : <b>%s</b>", html_escape(m:upper()), html_escape(n)))
        end
        local list_body = (#lines > 0) and table.concat(lines, "\n") or "暂无设备备注记录"
        local text = string.format([[🏷️ <b>设备备注管理</b>

━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━
<b>使用说明：</b>
• <b>添加/修改备注</b>：<code>/alias MAC地址 设备名字</code>
  <i>例如：/alias 26:e2:0d:d6:08:d2 客厅电视</i>
• <b>删除备注</b>：<code>/alias del MAC地址</code>

🕰️ <i>%s</i>]], list_body, os.date("%Y-%m-%d %H:%M:%S"))
        tg.send_msg(text)
        return
    end

    local sub_cmd, rest = arg:match("^(%S+)%s*(.*)$")
    sub_cmd = sub_cmd or ""
    if sub_cmd == "del" or sub_cmd == "rm" then
        local target_mac = rest:match("^(%S+)")
        if target_mac and target_mac ~= "" then
            sys.del_alias(target_mac)
            tg.send_msg(string.format("🗑️ 已删除 MAC <code>%s</code> 的设备备注。", html_escape(target_mac:upper())))
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

━━━━━━━━━━━━━━━━━━
🔑 <b>MAC</b>：<code>%s</code>
🏷️ <b>备注</b>：%s
━━━━━━━━━━━━━━━━━━
<i>下次查询在线设备时将直接展示该备注！</i>

🕰️ <i>%s</i>]], html_escape(set_mac:upper()), html_escape(set_name), os.date("%Y-%m-%d %H:%M:%S"))
    tg.send_msg(text)
end

local function cmd_storage()
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

local function cmd_usb()
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

local function esim_enabled()
    return core.get_uci("tohsakawrt-tgbot", "main", "esim_enabled", "1") ~= "0"
end

local function cmd_cards(msg_id)
    if not esim_enabled() then
        if msg_id then tg.edit_msg(msg_id, "⚠️ 功能已停用") else tg.send_msg("⚠️ 功能已停用") end
        return
    end
    local profiles, err, detail = esim.list()
    if not profiles then
        local hint = html_escape(esim.list_hint(err, detail))
        local failure = "⚠️ <b>读取卡内号码失败</b>：" .. hint
        if msg_id then tg.edit_msg(msg_id, failure)
        else tg.send_msg(failure) end
        return
    end
    local text, kb = esim.card_text(profiles)
    text = text:gsub("(电话: <code>)([^\n]*)(</code>)", function(prefix, value, suffix)
        return prefix .. html_escape(value) .. suffix
    end)
    text = text:gsub("⚪", "ℹ️")
    text = text:gsub("电话:", "<b>电话</b>：")
    text = text:gsub("卡号:", "<b>卡号</b>：")
    text = text .. "\n\n🕰️ <i>" .. os.date("%Y-%m-%d %H:%M:%S") .. "</i>"
    if msg_id then tg.edit_msg(msg_id, text, kb) else tg.send_msg(text, kb) end
end

local function new_job_id()
    return tostring(os.time()) .. tostring(math.random(100, 999))
end

local function start_esim_job(kind, target, display_name, message_id, extra_arg)
    if not esim_enabled() then tg.send_msg("⚠️ 功能已停用"); return end
    local id = new_job_id()
    local action = (kind == "reload" and "正在重载 5G 模组…")
        or (kind == "download" and "正在连接服务器下载写卡…")
        or "正在切换号码…"
    local warning = ""
    local main_uplink = (kind == "switch" or kind == "reload") and sys.uplink_status().type == "5g"
    if main_uplink then
        warning = "\n⚠️ 模组当前是主出口，期间会断网约 2 分钟"
    end
    local pending = "⏳ <b>" .. action .. "</b>" .. warning
    local pending_kb = {{ { text = "查看结果", callback_data = "esim_result:" .. id } }}
    if message_id then tg.edit_msg(message_id, pending, pending_kb)
    else tg.send_msg(pending, pending_kb) end
    if not esim.start_job(kind, id, target, display_name, main_uplink, extra_arg, message_id) then
        tg.send_msg("⚠️ 后台任务启动失败，请稍后重试。")
        return
    end
end

local function switch_profile(selector)
    if not esim_enabled() then tg.send_msg("⚠️ 功能已停用"); return end
    local profiles, err, detail = esim.list()
    if not profiles then
        local hint = html_escape(esim.list_hint(err, detail))
        tg.send_msg("⚠️ <b>读取卡内号码失败</b>：" .. hint)
        return
    end
    local profile, err = esim.resolve(profiles, selector)
    if err == "full_iccid" then tg.send_msg("⚠️ 请使用序号、名称或掩码选择号码。"); return end
    if not profile then tg.send_msg("⚠️ 未找到匹配号码，请先查看卡内号码。"); return end
    if profile.profileState == "enabled" then
        tg.send_msg("ℹ️ 该号码本来就是生效中的，未做改动。")
        cmd_cards()
        return
    end
    start_esim_job("switch", profile.iccid, profile.profileNickname or profile.serviceProviderName or profile.profileName)
end

-- ==================== CALLBACK DISPATCH ====================

local function handle_callback(cb_id, msg_id, data_str)
    if data_str == "cancel_action" then
        tg.answer_callback(cb_id, "操作已取消")
        tg.edit_msg(msg_id, "🛡️ <b>操作已取消</b>\n\n未对系统或服务进行任何修改。")

    elseif data_str == "do_clash_restart" then
        tg.answer_callback(cb_id, "正在重启核心...")
        tg.edit_msg(msg_id, "🔄 <b>操作已确认</b>：正在重启 OpenClash 核心，请稍候约 3~5 秒...")
        cmd_clash_restart(true)

    elseif data_str == "do_modem_reload" then
        tg.answer_callback(cb_id, "正在重载模组...")
        start_esim_job("reload", nil, nil, msg_id)

    elseif data_str:find("^do_undirect:") then
        local target = data_str:gsub("^do_undirect:", "")
        tg.answer_callback(cb_id, "正在删除条目...")
        tg.edit_msg(msg_id, "🗑️ 操作已确认：正在从直连白名单移除 <code>" .. html_escape(target) .. "</code>。")
        cmd_undirect(target, true)

    elseif data_str == "do_sys_reboot" then
        tg.answer_callback(cb_id, "正在重启路由器...")
        tg.edit_msg(msg_id, "⚡ <b>正在重启路由器系统...</b>\n\n网络即将断开，请等待约 1~2 分钟系统重新上线。")
        core.exec("reboot &")

    elseif data_str == "do_sys_poweroff" then
        tg.answer_callback(cb_id, "正在关闭路由器...")
        tg.edit_msg(msg_id, "🔌 <b>正在关闭路由器电源...</b>\n\n系统正在安全关机，网络已停止。再次使用需手动重新通电。")
        core.exec("poweroff &")

    elseif data_str == "refresh_cards" then
        if not esim_enabled() then tg.answer_callback(cb_id, "功能已停用"); tg.edit_msg(msg_id, "⚠️ 功能已停用"); return end
        tg.answer_callback(cb_id, "正在刷新号码列表")
        cmd_cards(msg_id)

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
            cmd_cards(msg_id)
        elseif profile.profileState == "enabled" then
            tg.answer_callback(cb_id, "该号码本来就是生效中的，未做改动")
            cmd_cards(msg_id)
        elseif not profile.iccid or not profile.iccid:match("^%d+$") or #profile.iccid < 18 or #profile.iccid > 22 then
            tg.answer_callback(cb_id, "号码数据无效，请刷新列表")
            cmd_cards(msg_id)
        else
            tg.answer_callback(cb_id, "正在切换号码…")
            start_esim_job("switch", profile.iccid, profile.profileNickname or profile.serviceProviderName or profile.profileName, msg_id)
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
        tg.answer_callback(cb_id, "🔀 正在打开出口切换菜单...")
        cmd_uplink()

    elseif data_str == "refresh_status" then
        tg.answer_callback(cb_id, "🔄 正在刷新看板...")
        cmd_status()

    elseif data_str == "refresh_direct" then
        tg.answer_callback(cb_id, "🔄 正在刷新直连白名单...")
        cmd_direct_list()

    elseif data_str == "refresh_modem" then
        tg.answer_callback(cb_id, "正在刷新模组状态...")
        cmd_modem(msg_id)

    elseif data_str == "show_sms" or data_str == "refresh_sms" then
        tg.answer_callback(cb_id, "正在读取最新短信...")
        cmd_sms(3, msg_id)

    elseif data_str == "re_ping" then
        tg.answer_callback(cb_id, "🩺 正在重新测试网络质量，请稍候约2秒...")
        M.cmd_ping()

    elseif data_str == "test_nodes" then
        tg.answer_callback(cb_id, "⚡ 正在测速分流节点...")
        cmd_nodes("test")

    elseif data_str == "restart_clash" then
        tg.answer_callback(cb_id, "请确认是否重启核心")
        ask_confirm("重启 OpenClash 核心", "Mihomo 核心守护进程", "短暂断流 3~5 秒，核心自动重载并重新接管分流", "do_clash_restart")

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

━━━━━━━━━━━━━━━━━━
🔀 <b>当前模式</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
👇 点击可再次切换：

🕰️ <i>%s</i>]], html_escape(mode_name), os.date("%Y-%m-%d %H:%M:%S"))

        tg.edit_msg(msg_id, new_text, inline_kb)
    end
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
        cmd_cards()
    elseif cmd == "/download" or cmd == "/写卡" or full:find("下载写卡") or full:find("写卡") then
        local raw = arg or ""
        if raw == "" and full:find("写卡") then raw = full:gsub("^.-写卡%s*", "") end
        local ac, confirm = raw:match("^(%S+)%s*(.*)$")
        if not ac or ac == "" then
            tg.send_msg("📥 <b>下载写入 eSIM Profile</b>\n\n使用方式：\n<code>/download &lt;激活码LPA:...&gt; [确认码]</code>\n\n<i>示例：</i>\n<code>/download LPA:1$smdp.io$ABCDEF123456</code>")
        else
            start_esim_job("download", ac, "新Profile", nil, confirm)
        end
    elseif cmd == "/switch" or full:find("切换号码") then
        local selector = arg or ""
        if cmd ~= "/switch" then selector = full:gsub("^.-切换号码", "") end
        switch_profile(selector)
    elseif cmd == "/start" or cmd == "/help" or cmd == "/menu" or full:find("帮助") then
        cmd_help()
    elseif cmd == "/status" or (full:find("状态") and not full:find("模组") and not full:find("5G") and not full:find("5g")) or full:find("看板") then
        cmd_status()
    elseif cmd == "/uplink" or cmd == "/switch_wan" or full:find("出口") or full:find("切网") or full:find("换网") or full:find("切5G") or full:find("切5g") then
        cmd_uplink()
    elseif cmd == "/ping" or cmd == "/check" or cmd == "/test" or full:find("体检") or full:find("双向") or full:find("测速") then
        M.cmd_ping()
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
    elseif cmd == "/sms" or cmd == "/msg" or full:find("短信") or full:find("验证码") then
        local count = tonumber(arg:match("(%d+)")) or 3
        cmd_sms(count)
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
    elseif cmd == "/reboot" or full:find("重启系统") or full:find("重启路由器") then
        ask_confirm("重启路由器系统", "TohsakaWrt 宿主机", "全家网络将中断约 1~2 分钟，直到路由器重新启动完成", "do_sys_reboot")
    elseif cmd == "/poweroff" or cmd == "/shutdown" or full:find("关闭路由器") or full:find("路由器关机") then
        ask_confirm("关闭路由器电源", "TohsakaWrt 宿主机", "路由器将完全关机并停止所有网络服务，再次开启需手动拔插电源", "do_sys_poweroff")
    elseif cmd == "/clash_restart" or full:find("重启核心") then
        cmd_clash_restart()
    elseif cmd == "/clash" or full:find("核心") then
        cmd_clash()
    elseif cmd == "/storage" or full:find("存储") then
        cmd_storage()
    elseif cmd == "/usb" or full:find("USB") or full:find("usb") then
        cmd_usb()
    else
        local safe = full:gsub("%d+", function(value)
            if (#value >= 18 and #value <= 22) or #value == 32 then return value:sub(1, 6) .. "…" .. value:sub(-4) end
            return value
        end):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        tg.send_msg(string.format("⚠️ <b>未识别的命令</b>：<code>%s</code>\n\n发送 /help 或点击下方键盘查看可用命令。", safe))
    end
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
                    offset = uid + 1
                    core.set_state("offset", tostring(offset))
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
