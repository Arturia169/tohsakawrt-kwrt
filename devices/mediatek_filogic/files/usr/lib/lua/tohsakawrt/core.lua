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
    local tmp = path .. ".tmp"
    local f, open_err = io.open(tmp, "w")
    if not f then return nil, open_err end
    local ok, write_err = f:write(tostring(value))
    local close_ok, close_err = f:close()
    if not ok or close_ok == nil then
        os.remove(tmp)
        return nil, write_err or close_err or "write failed"
    end
    local renamed, rename_err = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return nil, rename_err or "rename failed"
    end
    return true
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
    os.execute(string.format("logger -t %s %s", M.shell_quote(tag or "TohsakaWrt"), M.shell_quote(msg)))
end

-- ==========================================================
-- 有界执行：所有外部命令的唯一出口
-- ==========================================================
-- 背景（本次事故根因之一）：io.popen + read("*a") 在 Lua 层没有任何超时，
-- 而被调用的 shell 命令一旦挂住，read 会永久阻塞。机器人是单线程事件循环，
-- 因此一条挂住的命令就会让它彻底停止响应 —— 连它自己的告警推送通道一起死。
-- 更糟的是 pcall 只能捕获 Lua 错误，无法中断阻塞中的 C 层 read，所以外层兜不住。
--
-- 必须用 -s KILL：默认 SIGTERM 无法终止阻塞在驱动 read 中的子进程，
-- BusyBox timeout 会一直等待它，把阻塞传染给父进程。
-- 实测 timeout -s KILL 能在 2.004 秒内打断阻塞的串口读。
-- 默认 60 秒：实测所有正常调用的真实耗时都 ≤1.2 秒（modem_info.sh 1.176s、
-- sms_tool 0.017s、mmcli 0.034s），因此 60 秒既足以容纳全部正常路径，
-- 又能把"永久挂起"降级为"最多卡 60 秒后自动恢复"。
-- 少数合法耗时可超 60 秒的调用（如 modem-heal 全流程）在调用处显式放宽。
local DEFAULT_EXEC_TIMEOUT = tonumber(os.getenv("TWR_EXEC_TIMEOUT") or "") or 60

local function probe_timeout()
    local f = io.open("/usr/bin/timeout", "r")
    if f then f:close() return true end
    f = io.open("/bin/timeout", "r")
    if f then f:close() return true end
    return false
end

M.HAVE_TIMEOUT = probe_timeout()

function M.shell_quote(value)
    return "'" .. tostring(value):gsub("[\n\r\t]", " "):gsub("'", "'\\''") .. "'"
end

-- 把任意命令字符串包装成有界执行。调用方若要复用，用这个而不是自己拼 popen。
function M.bounded(cmd, timeout)
    cmd = tostring(cmd or "")
    if not M.HAVE_TIMEOUT then
        -- 不静默降级：缺少 timeout 时留痕，否则会退化成无界执行且无人知晓
        os.execute("logger -t TohsakaWrt-Core '警告: timeout 缺失，命令退化为无界执行' 2>/dev/null")
        return cmd
    end
    local t = math.max(1, math.floor(tonumber(timeout) or DEFAULT_EXEC_TIMEOUT))
    return string.format("timeout -s KILL %d sh -c %s", t, M.shell_quote(cmd))
end

function M.exec(cmd, timeout)
    local p = io.popen(M.bounded(cmd, timeout))
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

function M.exec_line(cmd, timeout)
    local out = M.exec(cmd, timeout)
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
    -- 与流量卡日报保持一致：█ 填充 + ░ 空白（原先用的是 ■，全项目没有第二个调用者）
    return string.rep("█", filled) .. string.rep("░", empty)
end

M.init()
return M
