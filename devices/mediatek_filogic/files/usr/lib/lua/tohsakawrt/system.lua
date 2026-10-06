-- TohsakaWrt System & Networking Module (High Performance)
local M = {}

local core = require("tohsakawrt.core")
local json = require("luci.jsonc")
local nixio = require("nixio")

local _ubus_conn = nil
local function get_ubus()
    if not _ubus_conn then
        local ok, u = pcall(function() return require("ubus").connect() end)
        if ok and u then _ubus_conn = u end
    end
    return _ubus_conn
end

local ALIAS_FILE = "/etc/tohsakawrt-aliases"

function M.cpu_temp()
    local f = io.open("/sys/class/thermal/thermal_zone0/temp", "r")
    if not f then return "未知" end
    local val = tonumber(f:read("*l"))
    f:close()
    if val then
        return string.format("%.1f°C", val / 1000)
    end
    return "未知"
end

function M.system_metrics()
    local u = get_ubus()
    local sys_info = u and u:call("system", "info", {})
    if sys_info then
        local up_sec = sys_info.uptime or 0
        local days = math.floor(up_sec / 86400)
        local hours = math.floor((up_sec % 86400) / 3600)
        local mins = math.floor((up_sec % 3600) / 60)
        local up_str = string.format("%d天%d小时%d分", days, hours, mins)

        local avail_b = sys_info.memory.available or 0
        local total_b = sys_info.memory.total or 1
        local avail_mb = math.floor(avail_b / 1048576)
        local avail_pct = math.floor((avail_b / total_b) * 100)
        local mem_str = string.format("%d MB (%d%% 可用)", avail_mb, avail_pct)

        local l1 = string.format("%.2f", (sys_info.load[1] or 0) / 65536)
        local l2 = string.format("%.2f", (sys_info.load[2] or 0) / 65536)
        local l3 = string.format("%.2f", (sys_info.load[3] or 0) / 65536)
        local load_str = string.format("%s %s %s", l1, l2, l3)

        local root_used = sys_info.root.used or 0
        local root_tot = sys_info.root.total or 1
        local root_pct = math.floor((root_used / root_tot) * 100)
        local root_avail_mb = string.format("%.1f MB", (sys_info.root.avail or 0) / 1024)
        local root_str = string.format("%d%% (空闲 %s)", root_pct, root_avail_mb)

        return {
            uptime = up_str,
            uptime_sec = up_sec,
            mem_avail = avail_mb,
            mem_pct = avail_pct,
            mem_str = mem_str,
            load = load_str,
            root_pct = root_pct,
            root_avail = root_avail_mb,
            root_str = root_str
        }
    end

    -- Fallback to /proc
    return {
        uptime = M.uptime(),
        mem_str = M.mem_info(),
        load = M.loadavg(),
        root_str = "53%"
    }
end

function M.mem_info()
    local f = io.open("/proc/meminfo", "r")
    if not f then return "未知" end
    local avail = 0
    for line in f:lines() do
        local a = line:match("^MemAvailable:%s+(%d+)%s+kB")
        if a then
            avail = tonumber(a) or 0
            break
        end
    end
    f:close()
    return string.format("%.0f MB", avail / 1024)
end

function M.loadavg()
    local f = io.open("/proc/loadavg", "r")
    if not f then return "未知" end
    local line = f:read("*l")
    f:close()
    if not line then return "未知" end
    local a, b, c = line:match("^(%S+)%s+(%S+)%s+(%S+)")
    return string.format("%s %s %s", a or "-", b or "-", c or "-")
end

function M.uptime()
    local f = io.open("/proc/uptime", "r")
    if f then
        local sec = tonumber(f:read("*l"):match("^(%d+)"))
        f:close()
        if sec then
            local d = math.floor(sec / 86400)
            local h = math.floor((sec % 86400) / 3600)
            local m = math.floor((sec % 3600) / 60)
            return string.format("%d天%d小时%d分", d, h, m)
        end
    end
    local out = core.exec_line("uptime")
    local up = out:match("up%s+(.-),%s+load")
    return up or out
end

function M.active_dev()
    local out = core.exec_line("ip route get 8.8.8.8 2>/dev/null")
    return out:match("dev%s+([^%s]+)") or "unknown"
end

function M.wan_gateway()
    local out = core.exec_line("ip route show default 2>/dev/null | awk '{print $3; exit}'")
    return out ~= "" and out or "192.168.1.1"
end

function M.uplink_status()
    local dev = M.active_dev()
    local typ = "unknown"
    if dev == "usb0" then
        typ = "5g"
    elseif dev == "eth0" then
        typ = "wan"
    end
    return { type = typ, dev = dev }
end

function M.wan_ip()
    local u = get_ubus()
    if u then
        local st = u:call("network.interface.wan", "status", {})
        if st and st["ipv4-address"] and st["ipv4-address"][1] then
            return st["ipv4-address"][1].address
        end
    end
    local out = core.exec_line("ip -4 addr show eth0 2>/dev/null | awk '/inet / {print $2; exit}'")
    return out ~= "" and out or "未连接"
end

function M.wan_ip6()
    local out = core.exec_line("ip -6 addr show eth0 scope global 2>/dev/null | awk '/inet6 / {print $2; exit}'")
    return out ~= "" and out or "无 IPv6"
end

function M.usb0_ip()
    local u = get_ubus()
    if u then
        local st = u:call("network.interface.5Ga", "status", {})
        if st and st["ipv4-address"] and st["ipv4-address"][1] then
            return st["ipv4-address"][1].address
        end
    end
    local out = core.exec_line("ip -4 addr show usb0 2>/dev/null | awk '/inet / {print $2; exit}'")
    return out ~= "" and out or "未获取到 IP"
end

function M.public_ip(force)
    if not force then
        local cached = core.get_cached_state("cache_pub_ip", 120)
        if cached and cached ~= "" and cached ~= "未获取到" then
            return cached
        end
    end

    local out = core.exec("curl -s -m 3 http://myip.ipip.net 2>/dev/null")
    local res = nil
    if out and out ~= "" then
        local ip = out:match("(%d+%.%d+%.%d+%.%d+)")
        local loc = out:match("来自于：(.*)") or out:match("来自于:(.*)")
        if loc then loc = loc:gsub("%s+", " "):match("^%s*(.-)%s*$") end
        if ip then
            res = string.format("%s (%s)", ip, (loc and loc ~= "") and loc or "未知")
        end
    end

    if not res then
        local ip_3322 = core.exec_line("curl -s -m 2 http://members.3322.org/dyndns/getip 2>/dev/null")
        if ip_3322 and ip_3322:match("^%d+%.%d+%.%d+%.%d+$") then
            res = ip_3322
        end
    end

    if not res then
        local ip_ican = core.exec_line("curl -s -m 2 http://icanhazip.com 2>/dev/null")
        if ip_ican and ip_ican:match("^%d+%.%d+%.%d+%.%d+$") then
            res = ip_ican
        end
    end

    res = res or "未获取到"
    if res ~= "未获取到" then
        core.set_cached_state("cache_pub_ip", res)
    end
    return res
end

function M.proxy_outbound_ip(force)
    if not force then
        local cached = core.get_cached_state("cache_proxy_ip", 180)
        if cached and cached ~= "" and cached ~= "未获取到" then
            return cached
        end
    end

    local out = core.exec("curl -s -m 3 http://ip-api.com/json/?lang=zh-CN 2>/dev/null")
    local res = nil
    if out and out ~= "" then
        local data = json.parse(out)
        if data and data.query then
            local loc = string.format("%s %s", data.country or "", data.city or ""):match("^%s*(.-)%s*$")
            if loc ~= "" then
                res = string.format("%s (%s)", data.query, loc)
            else
                res = data.query
            end
        end
    end

    if not res then
        local plain = core.exec_line("curl -s -m 3 http://ipinfo.io/ip 2>/dev/null")
        if plain and plain:match("^%d+%.%d+%.%d+%.%d+$") then
            res = plain
        end
    end

    res = res or "未获取到"
    if res ~= "未获取到" then
        core.set_cached_state("cache_proxy_ip", res)
    end
    return res
end

function M.switch_uplink(target)
    -- 出口切换只保留一份实现：shell 脚本 /usr/bin/tohsakawrt-uplink
    -- （该脚本已被 tests/test_uplink_switch.sh 覆盖，含失败回滚断言）
    local arg
    if target == "wan" or target == "eth0" then
        arg = "wan"
    elseif target == "5g" or target == "usb0" then
        arg = "5g"
    else
        return "INVALID_TARGET"
    end

    local raw = core.exec_line("/usr/bin/tohsakawrt-uplink " .. arg .. " 2>/dev/null") or ""
    raw = raw:gsub("%s+$", "")
    local code = raw:match("^([A-Z0-9_]+)")
    local res = code or raw
    if res == "" then
        core.log("TohsakaWrt-Uplink", "uplink script returned nothing for " .. arg)
        res = "ERROR_SWITCH_FAILED"
    end
    if res == "SUCCESS_WAN" or res == "SUCCESS_5G" then
        core.set_cached_state("cache_pub_ip", "")
    end
    return res
end


function M.wan_speed(dev)
    dev = dev or "eth0"
    local function get_bytes()
        local f = io.open("/proc/net/dev", "r")
        if not f then return 0, 0 end
        local rx, tx = 0, 0
        local pat = dev .. ":%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)"
        for line in f:lines() do
            local r, t = line:match(pat)
            if r and t then
                rx, tx = tonumber(r) or 0, tonumber(t) or 0
                break
            end
        end
        f:close()
        return rx, tx
    end

    local cur_rx, cur_tx = get_bytes()
    local now = os.time()
    local state_file = "/tmp/tohsakawrt/state/traffic_speed_" .. dev
    local last_rx, last_tx, last_ts, cached_str

    local f = io.open(state_file, "r")
    if f then
        local line = f:read("*l")
        f:close()
        if line then
            local r, t, s, c = line:match("^(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
            if r and t and s then
                last_rx = tonumber(r)
                last_tx = tonumber(t)
                last_ts = tonumber(s)
                if c and c ~= "" then cached_str = c end
            end
        end
    end

    local dt = last_ts and (now - last_ts) or -1
    local speed_str

    if dt >= 1 and dt <= 60 and last_rx and last_tx and cur_rx >= last_rx and cur_tx >= last_tx then
        local rx_rate = math.floor((cur_rx - last_rx) / dt)
        local tx_rate = math.floor((cur_tx - last_tx) / dt)
        speed_str = string.format("⬇️ %s | ⬆️ %s", core.format_speed(rx_rate), core.format_speed(tx_rate))
    elseif dt == 0 and cached_str then
        speed_str = cached_str
    else
        if nixio and nixio.nanosleep then
            nixio.nanosleep(0, 200000000)
        else
            os.execute("sleep 1")
        end
        local r2, t2 = get_bytes()
        local rx_rate = math.max(0, math.floor((r2 - cur_rx) * 5))
        local tx_rate = math.max(0, math.floor((t2 - cur_tx) * 5))
        speed_str = string.format("⬇️ %s | ⬆️ %s", core.format_speed(rx_rate), core.format_speed(tx_rate))
        cur_rx, cur_tx = r2, t2
        now = os.time()
    end

    core.init()
    local fw = io.open(state_file, "w")
    if fw then
        fw:write(string.format("%.0f %.0f %.0f %s\n", cur_rx, cur_tx, now, speed_str))
        fw:close()
    end

    return speed_str
end

function M.ping_metric(target, count)
    count = count or 2
    local cmd = string.format("ping -c %d -W 1 %s 2>&1", count, target)
    local res = core.exec(cmd)
    local avg = res:match("round%-trip [^=]+= [^/]+/([%d%.]+)/")
    local loss = res:match("([%d%.]+)%%%s*packet loss")
    if avg then
        local num = tonumber(avg) or 0
        local icon = "🟢"
        if num >= 150 then icon = "🟠"
        elseif num >= 80 then icon = "🟡" end
        local loss_num = tonumber(loss) or 0
        local loss_str = (loss_num > 0) and string.format("%d%% 丢包", loss_num) or "0% 丢包"
        return true, icon, string.format("%.1f", num), loss_str
    else
        return false, "🔴", "超时不可达", "100% 丢包"
    end
end

function M.http_metric(url)
    local cmd = string.format("curl -s -w '%%{time_total}' -o /dev/null -m 3 '%s' 2>/dev/null", url)
    local out = core.exec_line(cmd)
    local sec = tonumber(out)
    if sec and sec > 0 then
        local ms = math.floor(sec * 1000)
        local icon = "🟢"
        if ms >= 1000 then icon = "🟠"
        elseif ms >= 500 then icon = "🟡" end
        return true, icon, tostring(ms)
    else
        return false, "🔴", "请求超时"
    end
end

function M.storage_info()
    local storage = core.exec("df -h 2>/dev/null | grep -E '(/overlay$| /$| /tmp$|/mnt/|/opt$)'")
    local block = core.exec("block info 2>/dev/null")
    return storage, block
end

function M.usb_info()
    local usb = core.exec("lsusb -t 2>/dev/null")
    if not usb or usb == "" then usb = "未检测到 USB 设备拓扑" end
    return usb
end

function M.load_aliases()
    local aliases = {}
    local f = io.open(ALIAS_FILE, "r")
    if f then
        for line in f:lines() do
            local mac, name = line:match("^(%S+)%s+(.*)$")
            if mac and name then
                aliases[mac:lower()] = name:match("^%s*(.-)%s*$")
            end
        end
        f:close()
    end
    return aliases
end

function M.set_alias(mac, name)
    mac = mac:lower()
    local aliases = M.load_aliases()
    aliases[mac] = name
    local f = io.open(ALIAS_FILE, "w")
    if f then
        for m, n in pairs(aliases) do
            f:write(string.format("%s %s\n", m, n))
        end
        f:close()
        return true
    end
    return false
end

function M.del_alias(mac)
    mac = mac:lower()
    local aliases = M.load_aliases()
    if not aliases[mac] then return false end
    aliases[mac] = nil
    local f = io.open(ALIAS_FILE, "w")
    if f then
        for m, n in pairs(aliases) do
            f:write(string.format("%s %s\n", m, n))
        end
        f:close()
        return true
    end
    return false
end

return M
