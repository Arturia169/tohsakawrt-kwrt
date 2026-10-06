-- TohsakaWrt Core Module
local M = {}

local uci = require("uci")
local json = require("luci.jsonc")

local STATE_DIR = "/tmp/tohsakawrt/state"

function M.init()
    os.execute("mkdir -p " .. STATE_DIR .. " 2>/dev/null")
end

local _uci_cursor = nil
local function get_cursor()
    if not _uci_cursor then
        _uci_cursor = uci.cursor()
    end
    return _uci_cursor
end

function M.get_uci(config, section, option, default)
    local ok, c = pcall(get_cursor)
    if not ok or not c then return default end
    local val = c:get(config, section, option)
    if val == nil or val == "" then
        return default
    end
    return val
end

function M.set_uci(config, section, option, value)
    local ok, c = pcall(get_cursor)
    if ok and c then
        c:set(config, section, option, value)
        c:commit(config)
    end
end

function M.get_state(key, default)
    local path = STATE_DIR .. "/" .. key
    local f = io.open(path, "r")
    if not f then return default end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return default end
    return content:match("^%s*(.-)%s*$")
end

function M.set_state(key, value)
    M.init()
    local path = STATE_DIR .. "/" .. key
    local f = io.open(path, "w")
    if f then
        f:write(tostring(value))
        f:close()
    end
end

function M.get_cached_state(key, max_age)
    local path = STATE_DIR .. "/" .. key
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    local ts, val = line:match("^(%d+)%s+(.*)$")
    if ts and val then
        local age = os.time() - tonumber(ts)
        if age >= 0 and age <= max_age then
            return val
        end
    end
    return nil
end

function M.set_cached_state(key, val)
    M.init()
    local path = STATE_DIR .. "/" .. key
    local f = io.open(path, "w")
    if f then
        f:write(string.format("%d %s\n", os.time(), tostring(val)))
        f:close()
    end
end

function M.log(tag, msg)
    local function shell_quote(value)
        return "'" .. tostring(value):gsub("[\n\r\t]", " "):gsub("'", "'\\''") .. "'"
    end
    os.execute(string.format("logger -t %s %s", shell_quote(tag or "TohsakaWrt"), shell_quote(msg)))
end

function M.exec(cmd)
    local p = io.popen(cmd)
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

function M.exec_line(cmd)
    local out = M.exec(cmd)
    for line in out:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            return trimmed
        end
    end
    return ""
end

function M.format_bytes(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1073741824 then
        return string.format("%.2f GB", bytes / 1073741824)
    elseif bytes >= 1048576 then
        return string.format("%.1f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

function M.format_speed(bytes_per_sec)
    bytes_per_sec = tonumber(bytes_per_sec) or 0
    if bytes_per_sec >= 1048576 then
        return string.format("%.2f MB/s", bytes_per_sec / 1048576)
    elseif bytes_per_sec >= 1024 then
        return string.format("%.1f KB/s", bytes_per_sec / 1024)
    else
        return string.format("%d B/s", bytes_per_sec)
    end
end

function M.progress_bar(percent, width)
    width = width or 10
    percent = tonumber(percent) or 0
    if percent < 0 then percent = 0 end
    if percent > 100 then percent = 100 end
    local filled = math.floor((percent / 100) * width + 0.5)
    if filled > width then filled = width end
    local empty = width - filled
    return string.rep("■", filled) .. string.rep("░", empty)
end

M.init()
return M
