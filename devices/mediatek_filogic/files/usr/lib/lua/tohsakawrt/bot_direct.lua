-- TohsakaWrt Bot：设备备注管理
--
-- 注意：本模块原先还有 cmd_direct / cmd_undirect / cmd_direct_list 三个直连白名单函数，
-- 已删除。原因是它们走的是旧实现 /usr/bin/tohsaka-direct，写
-- /etc/openclash/tg_direct_rules.list；而 bot.lua 的 /direct 等入口走新实现
-- /usr/bin/tohsakawrt-clash-direct，写 config.yaml 的 TG_DIRECT_RULES 段。
-- 两套数据实测已分叉（旧文件 1 条、新文件 2 条），且旧文件不被任何配置 include，
-- 统一到新实现后这三个函数已无调用者（bot.lua 里只剩 cmd_alias）。
-- 它们的返回值契约（期望 "ADDED:域名"）也与新实现（返回裸 "ADDED"）不一致，
-- 留着是给将来重新接线的人挖坑，故一并删除。
local bc = require("tohsakawrt.bot_common")
local tg, sys = bc.tg, bc.sys
local html_escape = bc.html_escape

local M = {}

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
  <i>例如：/alias aa:bb:cc:dd:ee:ff 客厅电视</i>
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
            tg.send_msg("⚠️ 请提供要删除的 MAC 地址，例如：<code>/alias del aa:bb:cc:dd:ee:ff</code>")
        end
        return
    end

    local set_mac = sub_cmd
    local set_name = rest:match("^%s*(.-)%s*$")
    if not set_name or set_name == "" then
        tg.send_msg("⚠️ 缺少设备名字。\n格式：<code>/alias MAC地址 设备名字</code>\n例如：<code>/alias aa:bb:cc:dd:ee:ff 客厅电视</code>")
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
