-- TohsakaWrt 5G Cellular Modem Module
local M = {}

local core = require("tohsakawrt.core")

local AT_PORT = "/dev/ttyUSB2"
local MODEM_AT = "/usr/share/modem/modem_at.sh"

local nixio = require("nixio")

function M.at(cmd, timeout)
    timeout = timeout or 3
    if not nixio.fs.stat(AT_PORT) or not nixio.fs.stat(MODEM_AT) then
        return nil, "Modem AT port or script not found"
    end
    local run_cmd = string.format("sh %s %s '%s' 2>/dev/null", MODEM_AT, AT_PORT, cmd)
    return core.exec(run_cmd)
end

function M.info()
    local cgpaddr = M.at("AT+CGPADDR=1") or ""
    local qnwinfo = M.at("AT+QNWINFO") or ""

    local sim_ip = cgpaddr:match('%+CGPADDR:%s*%d+,%s*"([^",]+)')
    local mode, plmn, band = qnwinfo:match('%+QNWINFO:%s*"([^"]*)","([^"]*)","([^"]*)"')

    local oper = "未知运营商"
    if plmn then
        if plmn == "46001" or plmn == "46006" or plmn == "46009" then
            oper = "中国联通"
        elseif plmn == "46000" or plmn == "46002" or plmn == "46004" or plmn == "46007" or plmn == "46008" then
            oper = "中国移动"
        elseif plmn == "46003" or plmn == "46005" or plmn == "46011" or plmn == "46012" then
            oper = "中国电信"
        elseif plmn == "46015" then
            oper = "中国广电"
        else
            oper = plmn
        end
    end

    return {
        sim_ip = sim_ip or "未获取",
        oper = oper,
        band = band or "未知频段",
        mode = mode or "未知制式"
    }
end

function M.keepalive_and_heal()
    local dev = "usb0"
    local f = io.open("/sys/class/net/" .. dev .. "/operstate", "r")
    if not f then return "NO_INTERFACE" end
    f:close()

    local ip_out = core.exec_line("ip -4 addr show " .. dev .. " 2>/dev/null | awk '/inet / {print $2; exit}'")
    if ip_out == "" then
        core.log("tohsakawrt-modem-heal", "5G usb0 lost IP, triggering ifup 5Ga")
        os.execute("ifup 5Ga 2>/dev/null")
        return "HEAL_NO_IP"
    end

    -- Independent ping via usb0 (protecting hot-standby channel from operator PDP sleep)
    local ret = os.execute("ping -c 1 -W 2 -I " .. dev .. " 223.5.5.5 >/dev/null 2>&1")
    if ret == 0 then
        core.set_state("5g_data_fails", "0")
        return "HEALTHY"
    end

    local fails = tonumber(core.get_state("5g_data_fails", "0")) or 0
    fails = fails + 1
    core.set_state("5g_data_fails", tostring(fails))

    local now = os.time()
    local last_heal = tonumber(core.get_state("5g_data_lastheal", "0")) or 0
    if (now - last_heal) < 60 then
        return "THROTTLED"
    end
    core.set_state("5g_data_lastheal", tostring(now))

    if fails == 1 then
        core.log("tohsakawrt-modem-heal", "5G ping timeout (Stage 1): ifup 5Ga")
        os.execute("ifup 5Ga 2>/dev/null")
        return "HEAL_STAGE_1"
    elseif fails == 2 then
        core.log("tohsakawrt-modem-heal", "5G ping timeout (Stage 2): AT+QNETDEVCTL=1,1,1")
        M.at("AT+QNETDEVCTL=1,1,1")
        os.execute("sleep 2; ifup 5Ga 2>/dev/null")
        return "HEAL_STAGE_2"
    else
        core.log("tohsakawrt-modem-heal", "5G ping timeout (Stage 3): AT+CFUN=0/1 reset")
        M.at("AT+CFUN=0")
        os.execute("sleep 2")
        M.at("AT+CFUN=1")
        os.execute("sleep 3; ifup 5Ga 2>/dev/null")
        
        local tg = require("tohsakawrt.tg")
        tg.send_msg("⚠️ <b>5G 热备链路脱网告警</b>\n\n检测到 5G 模组连续 3 次数据探测超时，已执行射频重注网自愈，请留意模组连接状态。")
        return "HEAL_STAGE_3"
    end
end

return M
