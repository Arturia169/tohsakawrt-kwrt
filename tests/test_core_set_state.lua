local lua_root
for _, candidate in ipairs({ "devices/mediatek_filogic/files/usr/lib/lua", "files/usr/lib/lua" }) do
    local probe = io.open(candidate .. "/tohsakawrt/core.lua", "r")
    if probe then probe:close(); lua_root = candidate; break end
end
assert(lua_root, "cannot locate tohsakawrt Lua payload")
package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path
package.preload["uci"] = function() return { cursor = function() return {} end } end
package.preload["luci.jsonc"] = function() return {} end

local events, fail_rename = {}, false
local original_open, original_execute = io.open, os.execute
local original_rename, original_remove = os.rename, os.remove
io.open = function(path, mode)
    if path == "/tmp/tohsakawrt/state/key.tmp" and mode == "w" then
        events[#events + 1] = "open:" .. path .. ":" .. mode
        return {
            write = function(_, value) events[#events + 1] = "write:" .. value; return true end,
            close = function() events[#events + 1] = "close"; return true end
        }
    end
    return original_open(path, mode)
end
os.execute = function(command) events[#events + 1] = "execute:" .. command; return 0 end
os.rename = function(src, dst)
    events[#events + 1] = "rename:" .. src .. ":" .. dst
    if fail_rename then return nil, "forced rename failure" end
    return true
end
os.remove = function(path) events[#events + 1] = "remove:" .. path; return true end

local core = require("tohsakawrt.core")
assert(core.set_state("key", "123") == true, "atomic state write should succeed")
assert(events[3] == "open:/tmp/tohsakawrt/state/key.tmp:w", "state must open a sibling temporary file")
assert(events[4] == "write:123" and events[5] == "close", "temporary content must be written and closed before rename")
assert(events[6] == "rename:/tmp/tohsakawrt/state/key.tmp:/tmp/tohsakawrt/state/key", "state replacement must use rename")

events = {}
fail_rename = true
local ok, err = core.set_state("key", "456")
assert(ok == nil and err == "forced rename failure", "rename failure must be returned")
assert(events[#events] == "remove:/tmp/tohsakawrt/state/key.tmp", "failed rename must remove the temporary file")

io.open, os.execute, os.rename, os.remove = original_open, original_execute, original_rename, original_remove
print("PASS: set_state writes a temporary file, renames atomically, and cleans up on failure")
