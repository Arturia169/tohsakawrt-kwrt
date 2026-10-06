-- 静态检查：bot 各模块里的"裸函数调用"必须是已定义的
--
-- 目的：拆分模块时最容易漏掉"从 bot_common 取共享函数"这一步。
--       这类问题语法检查发现不了（未定义全局只在运行到那一行才报错），
--       而现有用例也不一定覆盖到那条命令 —— 2026-10-07 就因此让「📇 卡内号码」坏过一次。
--
-- 归一化顺序很重要：先去字符串（含长字符串）、再去注释、最后抹掉函数名。
-- 否则字符串里的 "(Lua Engine)"、注释里的函数名都会造成误报。

local CANDIDATES = {
    "devices/mediatek_filogic/files/usr/lib/lua/tohsakawrt/",
    "files/usr/lib/lua/tohsakawrt/",
}
local MODULES = {
    "bot.lua", "bot_common.lua", "bot_net.lua", "bot_sys.lua",
    "bot_direct.lua", "bot_modem.lua", "bot_esim.lua",
}

local BUILTIN = {}
for _, n in ipairs({
    "require", "pcall", "xpcall", "print", "type", "tostring", "tonumber", "pairs", "ipairs",
    "next", "select", "error", "assert", "setmetatable", "getmetatable", "rawget", "rawset",
    "unpack", "loadfile", "dofile", "loadstring", "collectgarbage",
    "string", "table", "math", "os", "io", "coroutine", "utf8",
}) do
    BUILTIN[n] = true
end
-- Lua 关键字：后面跟括号时（如 `or (`、`function (`）不是函数调用
for _, n in ipairs({
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}) do
    BUILTIN[n] = true
end

local function read_module(name)
    for _, prefix in ipairs(CANDIDATES) do
        local f = io.open(prefix .. name, "r")
        if f then
            local s = f:read("*a")
            f:close()
            return s
        end
    end
    return nil
end

local function normalize(src)
    local code = src
    code = code:gsub("%-%-%[%[.-%]%]", "")     -- 长注释
    code = code:gsub("%[%[.-%]%]", '""')       -- 长字符串（[[...]]）
    code = code:gsub('"[^"]*"', '""')          -- 普通字符串（不使用 %b，它要求两个不同字符）
    code = code:gsub("'[^']*'", "''")
    local lines = {}
    for line in (code .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line:gsub("%-%-.*$", "")   -- 行注释
    end
    code = table.concat(lines, "\n")
    -- 抹掉函数名（保留 function 关键字，它已在关键字白名单里）
    code = code:gsub("function%s+[%a_][%w_]*%s*%(", "function (")
    return code
end

local checked, problems = 0, {}
for _, name in ipairs(MODULES) do
    local src = read_module(name)
    assert(src, "找不到模块文件: " .. name)
    checked = checked + 1

    -- 必须在归一化之前收集"定义/导入"的名字
    local defined = {}
    for fn in src:gmatch("function%s+([%a_][%w_]*)%s*%(") do defined[fn] = true end
    for list in src:gmatch("local%s+([%a_][%w_,%s]-)%s*=") do
        for n in list:gmatch("([%a_][%w_]*)") do defined[n] = true end
    end

    local code = normalize(src)

    local unknown, names = {}, {}
    for _, fn in code:gmatch("([^%.:%w_])([%a_][%w_]*)%s*%(") do
        if not defined[fn] and not BUILTIN[fn] then unknown[fn] = true end
    end
    for k in pairs(unknown) do names[#names + 1] = k end
    table.sort(names)
    if #names > 0 then
        problems[#problems + 1] = string.format("%s: %s", name, table.concat(names, ", "))
    end
end

-- 一次报出所有模块的问题，避免"修一个才发现下一个"
assert(#problems == 0, "出现未定义的裸函数调用（拆分时漏导入/漏改调用点？）:\n  " ..
    table.concat(problems, "\n  "))

print(string.format("PASS: %d 个 bot 模块均无未定义的裸函数调用（可提前发现漏导入/漏改调用点）", checked))
