-- 静态审查：模块句柄与跨模块调用
--   ① 用到的句柄（X.foo）必须是本文件声明过的 local / 已知模块 / 全局函数，否则运行时必炸
--      （今天的 netm 就是这么坏的：bot.lua 里根本没有 netm 这个 local）
--   ② 跨模块调用 X.foo() 中，若 X 解析到某个模块，则该模块必须导出 foo
--      （今天的 build_status_card 就是这么坏的：bot_sys 里是 local function，没导出）
local ROOT = "devices/mediatek_filogic/files/usr/lib/lua/"
local ALT = "files/usr/lib/lua/"
local function payload(p)
    local h = io.open(ROOT .. p, "r")
    if h then h:close(); return ROOT .. p end
    h = io.open(ALT .. p, "r")
    if h then h:close(); return ALT .. p end
    return nil
end
local function read(p)
    local path = payload(p)
    if not path then return nil end
    local h = io.open(path, "r"); local s = h:read("*a"); h:close(); return s
end

local MODULES = { "bot", "bot_common", "bot_net", "bot_sys", "bot_modem", "bot_esim",
                  "bot_direct", "core", "tg", "system", "modem", "clash", "esim" }
-- 各模块导出的名字
local exports = {}
for _, m in ipairs(MODULES) do
    local s = read("tohsakawrt/" .. m .. ".lua")
    if s then
        local set = {}
        for fn in s:gmatch("function M%.([%w_]+)%s*%(") do set[fn] = true end
        for fn in s:gmatch("M%.([%w_]+)%s*=") do set[fn] = true end
        exports[m] = set
    end
end
-- Lua 内置全局与常见允许的全局
local ALLOW = { string = 1, table = 1, math = 1, os = 1, io = 1, ipairs = 1, pairs = 1,
                type = 1, tostring = 1, tonumber = 1, pcall = 1, require = 1, print = 1,
                unpack = 1, select = 1, error = 1, assert = 1, setmetatable = 1, rawget = 1,
                next = 1, _G = 1, package = 1, bit = 1 }

local problems, handles = {}, 0
local FILES = { "bot.lua", "bot_net.lua", "bot_sys.lua", "bot_modem.lua", "bot_esim.lua", "bot_direct.lua" }
for _, f in ipairs(FILES) do
    local s = read("tohsakawrt/" .. f)
    if s then
        -- 本文件声明过的 local 名
        local locals = {}
        for name in s:gmatch("local%s+([%w_]+)") do locals[name] = true end
        for a in s:gmatch("local%s+[%w_ ,]+=%s*[^%\n]-%.%s*([%w_]+)") do locals[a] = true end
        for list in s:gmatch("local%s+([%w_ ,]+)%s*=") do
            for name in list:gmatch("[%w_]+") do locals[name] = true end
        end
        -- 别名 → 模块
        local alias_mod = {}
        for alias, mod in s:gmatch("local%s+([%w_]+)%s*=%s*require%s*%(%s*\"tohsakawrt%.([%w_]+)\"") do
            alias_mod[alias] = mod
        end
        for alias, mod in s:gmatch("local%s+([%w_]+)%s*=%s*require%s*%(\"tohsakawrt%.([%w_]+)\"") do
            alias_mod[alias] = mod
        end
        -- 逐一体检 X.name( 形式的调用
        for alias, name in s:gmatch("([%w_]+)%.([%w_]+)%s*%(") do
            if not ALLOW[alias] then
                if not locals[alias] then
                    problems[#problems + 1] = string.format("%s: 句柄 '%s' 未声明（%s.%s）", f, alias, alias, name)
                else
                    handles = handles + 1
                    local mod = alias_mod[alias]
                    if mod and exports[mod] and not exports[mod][name] then
                        problems[#problems + 1] = string.format("%s: %s.%s() 但 %s 未导出 %s", f, alias, name, mod, name)
                    end
                end
            end
        end
    end
end

if #problems > 0 then
    for _, p in ipairs(problems) do print("FAIL: " .. p) end
    print(string.format("PASS=0 FAIL=%d", #problems))
    os.exit(1)
end
print(string.format("PASS: 句柄与跨模块调用全部有效（检查了 %d 处调用）", handles))
