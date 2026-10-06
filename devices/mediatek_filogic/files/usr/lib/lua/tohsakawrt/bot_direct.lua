-- TohsakaWrt Bot：直连白名单与设备备注
-- 共享零件来自 bot_common；本模块只放这一类功能。
local bc = require("tohsakawrt.bot_common")
local core, tg, sys, modem, clash, esim, nixio =
    bc.core, bc.tg, bc.sys, bc.modem, bc.clash, bc.esim, bc.nixio
local html_escape, ask_confirm = bc.html_escape, bc.ask_confirm

local M = {}

function M.cmd_direct(arg)
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

function M.cmd_undirect(arg, confirmed)
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

function M.cmd_direct_list(msg_id, cb_id)
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

    if msg_id and cb_id then
        return tg.answer_and_edit(cb_id, "🔄 正在刷新直连白名单...", msg_id, text, inline_kb)
    end
    if msg_id then
        return tg.edit_msg(msg_id, text, inline_kb)
    end
    return tg.send_msg(text, inline_kb)
end

function M.cmd_alias(arg)
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


return M
