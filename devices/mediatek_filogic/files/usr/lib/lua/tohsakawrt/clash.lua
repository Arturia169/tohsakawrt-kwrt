-- TohsakaWrt OpenClash & Whitelist Module (High Performance)
local M = {}

local core = require("tohsakawrt.core")
local json = require("luci.jsonc")

local API_BASE = "http://127.0.0.1:9090"

local function api_get(endpoint, timeout)
    timeout = timeout or 3
    local cmd = string.format("curl -s -m %d '%s%s'", timeout, API_BASE, endpoint)
    local out = core.exec(cmd)
    if not out or out == "" then return nil end
    return json.parse(out)
end

local function api_patch(endpoint, data, timeout)
    timeout = timeout or 3
    local body = json.stringify(data)
    local cmd = string.format("curl -s -m %d -X PATCH -H 'Content-Type: application/json' -d '%s' '%s%s'", timeout, body, API_BASE, endpoint)
    return core.exec(cmd)
end

function M.status()
    local res = api_get("/version", 2)
    if res and res.version then
        return { running = true, version = res.version, core = "Mihomo" }
    end
    local pid = core.exec_line("pidof mihomo 2>/dev/null || pidof clash 2>/dev/null")
    if pid ~= "" then
        return { running = true, version = "API未响应", core = "存活" }
    end
    return { running = false, version = "未运行", core = "已停止" }
end

function M.full_status()
    local pid = core.exec_line("pidof mihomo 2>/dev/null || pidof clash 2>/dev/null")
    local enabled = core.get_uci("openclash", "@openclash[0]", "enable", "0")
    local v_cmd = "/etc/openclash/clash -v 2>/dev/null | head -n1"
    local version = core.exec_line(v_cmd)
    if version == "" then
        local st = M.status()
        version = st.version
    end

    local ports = core.exec_line([=[netstat -tln 2>/dev/null | grep -E ':(7874|7890|7892|7895|9090)[[:space:]]' | awk '{print $4}' | sed 's/.*://' | sort -nu | tr '\n' ' ']=])
    if ports == "" then ports = "未检测到" end

    return {
        enabled = (enabled == "1"),
        running = (pid ~= ""),
        pid = (pid ~= "" and pid or "无"),
        version = version,
        ports = ports
    }
end

function M.mode()
    local res = api_get("/configs", 2)
    if res and res.mode then
        return res.mode
    end
    return "unknown"
end

function M.set_mode(mode)
    api_patch("/configs", { mode = mode }, 3)
    return mode
end

function M.restart()
    core.exec("/etc/init.d/openclash restart >/dev/null 2>&1 &")
end

local function resolve_node(proxies, name, depth)
    depth = depth or 0
    if depth > 5 then return name, "" end
    local p = proxies[name]
    if not p then return name, "" end
    if (p.type == "Selector" or p.type == "URLTest" or p.type == "Fallback") and p.now and p.now ~= name then
        return resolve_node(proxies, p.now, depth + 1)
    end
    local delay_str = ""
    if p.history and #p.history > 0 then
        local d = p.history[#p.history].delay
        if d and d > 0 then delay_str = tostring(d) .. "ms" end
    end
    return name, delay_str
end

function M.nodes_info()
    local data = api_get("/proxies", 3)
    if not data or not data.proxies then
        return {}
    end

    local groups = {"🚀 默认代理", "💎 自建专线", "🍀 Google", "🤖 ChatGPT", "📲 Telegram", "📹 YouTube", "👨🏿‍💻 GitHub"}
    local results = {}
    for _, g in ipairs(groups) do
        local p = data.proxies[g]
        if p then
            local real_name, delay = resolve_node(data.proxies, p.now)
            table.insert(results, {
                group = g,
                now = p.now or "无",
                real = real_name or "无",
                delay = delay
            })
        end
    end
    return results
end

function M.test_nodes()
    core.exec("curl -s -m 4 'http://127.0.0.1:9090/group/%E2%99%BB%EF%B8%8F%20%E9%A6%99%E6%B8%AF%E8%87%AA%E5%8A%A8/delay?url=http%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=2500' >/dev/null 2>&1 &")
    core.exec("curl -s -m 4 'http://127.0.0.1:9090/group/%E2%99%BB%EF%B8%8F%20%E7%BE%8E%E5%9B%BD%E8%87%AA%E5%8A%A8/delay?url=http%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204&timeout=2500' >/dev/null 2>&1 &")
end

function M.proxy_delay(group_name)
    group_name = group_name or "🚀 默认代理"
    -- Check cached history from /proxies first to avoid network stall
    local data = api_get("/proxies", 2)
    if data and data.proxies then
        local p = data.proxies[group_name]
        if p then
            if p.history and #p.history > 0 then
                local d = p.history[#p.history].delay
                if d and d > 0 then return d end
            end
            if p.now and data.proxies[p.now] then
                local real_p = data.proxies[p.now]
                if real_p.history and #real_p.history > 0 then
                    local d = real_p.history[#real_p.history].delay
                    if d and d > 0 then return d end
                end
            end
        end
    end

    -- Fast active probe
    local encoded = string.gsub(group_name, "([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local cmd = string.format("curl -s -m 2 'http://127.0.0.1:9090/proxies/%s/delay?url=http%%3A%%2F%%2Fcp.cloudflare.com%%2Fgenerate_204&timeout=1500'", encoded)
    local raw = core.exec(cmd)
    if raw and raw ~= "" then
        local d = json.parse(raw)
        if d and d.delay and d.delay > 0 then
            return d.delay
        end
    end
    return nil
end

function M.direct_list()
    local f = io.open("/etc/openclash/tg_direct_rules.list", "r")
    if not f then return {} end
    local list = {}
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            table.insert(list, line)
        end
    end
    f:close()
    return list
end

function M.direct_add(target)
    local res = core.exec_line(string.format('/usr/bin/tohsaka-direct add "%s" 2>/dev/null', target))
    return res
end

function M.direct_del(target)
    local res = core.exec_line(string.format('/usr/bin/tohsaka-direct del "%s" 2>/dev/null', target))
    return res
end

return M
