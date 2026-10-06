package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local has_cjson, json = pcall(require, "cjson")
if not has_cjson then
    local has_jsonc, mod = pcall(require, "luci.jsonc")
    if not has_jsonc then
        print("SKIP: test_esim.lua 需要一个 JSON 模块（lua-cjson，或实机上的 luci.jsonc）——请在设备上运行")
        return
    end
    json = mod
end
package.preload["luci.jsonc"] = function() return { parse = json.decode or json.parse } end
package.preload["tohsakawrt.core"] = function()
    return {
        init = function() end,
        get_uci = function(config, section, option, default)
            if config == "tohsakawrt-tgbot" and section == "numbers" and option == "n_89860012345678901234" then
                return "+8613800138000"
            end
            return default or ""
        end
    }
end
package.preload["tohsakawrt.modem"] = function() return {} end

local original_popen = io.popen
local profile_list_output = ""
io.popen = function(command)
    local output
    if command:find("profile list", 1, true) then
        output = profile_list_output
    elseif command:find("chip info", 1, true) then
        output = '{"type":"lpa","payload":{"code":0,"data":{"eid":"89049032000000000000000000000001"}}}\n'
    else
        output = ""
    end
    local sent = false
    return {
        read = function(_, mode) sent = true; return output end,
        close = function() return true end
    }
end

local esim = require("tohsakawrt.esim")
profile_list_output = [[{"type":"lpa","payload":{"code":-1,"message":"euicc_init","data":""}}]] .. "\n"
local unavailable, list_err, list_detail = esim.list()
assert(not unavailable and list_err == "lpa_error" and list_detail == "euicc_init",
    "M.list must preserve the LPA error message as its detail")
assert(esim.list_hint(list_err, list_detail):find("不是 eSTK", 1, true),
    "euicc_init must explain that the current card is not eSTK")
profile_list_output = [[{"type":"lpa","payload":{"code":-1,"message":"weird_thing","data":""}}]] .. "\n"
local unknown_profiles, unknown_err, unknown_detail = esim.list()
assert(not unknown_profiles and unknown_err == "lpa_error" and unknown_detail == "weird_thing",
    "unknown LPA errors must retain their detail")
assert(esim.list_hint(unknown_err, unknown_detail):find("稍后重试", 1, true),
    "unknown LPA errors must use the retry hint")
profile_list_output = [[{"type":"lpa","payload":{"code":0,"data":[]}}]] .. "\n"
local empty_profiles = esim.list()
assert(type(empty_profiles) == "table" and #empty_profiles == 0, "successful empty profile list must remain unchanged")
profile_list_output = ""
print("PASS: profile list preserves LPA failure details and selects specific or retry hints")
local iccid1 = "89860012345678901234"
local iccid2 = "89860198765432109876"
local fixture = [[AT backend ready
{"type":"lpa","payload":{"code":99,"message":"noise","data":[]}}
{"type":"lpa","payload":{"code":0,"message":"success","data":[{"iccid":"]] .. iccid1 .. [[","profileNickname":"Home-89869912345678900000","serviceProviderName":"Carrier A","profileState":"enabled"},{"iccid":"]] .. iccid2 .. [[","profileNickname":"Travel","serviceProviderName":"Carrier B","profileState":"disabled"}]}}
]]

local profiles, err = esim.parse_lpa(fixture)
assert(profiles and #profiles == 2, "must parse the final successful LPA JSON line: " .. tostring(err))
local card, keyboard = esim.card_text(profiles)
assert(card:find("898600…1234", 1, true), "must mask ICCID to first six and last four")
assert(card:find("电话: <code>+8613800138000</code>", 1, true), "must render the phone number from the UCI mapping")
assert(card:find("890490…0001", 1, true), "must mask EID to first six and last four")
assert(not card:find(iccid1, 1, true) and not card:find(iccid2, 1, true), "rendered card leaked a full ICCID")
assert(not card:find("89869912345678900000", 1, true), "rendered card leaked an ICCID embedded in a profile name")
assert(not card:find("89049032000000000000000000000001", 1, true), "rendered card leaked full EID")
assert(keyboard[1][1].callback_data == "enable:1" and keyboard[2][1].callback_data == "refresh_cards")
assert(esim.resolve(profiles, "tRaVeL") == profiles[2], "keyword matching must be case-insensitive")
local rejected, reason = esim.resolve(profiles, iccid1)
assert(not rejected and reason == "full_iccid", "full ICCID selector must be rejected")
local rendered_reload = esim.reload_text({ ready = true, cpin = "READY", prefix = "898606", last4 = "5858",
    qnw = '"TDD NR5G","46001","NR5G BAND 78",627264', label = "未注册（不搜索）", elapsed = 126, recovered = true })
assert(rendered_reload:find("📶 <b>网络制式</b>：<code>TDD NR5G</code>", 1, true), "QNWINFO must render network mode as a readable field")
assert(rendered_reload:find("📡 <b>运营商</b>：<code>中国联通</code>", 1, true), "QNWINFO operator code must map to its carrier")
assert(rendered_reload:find("📻 <b>频段</b>：<code>NR5G BAND 78</code>", 1, true), "QNWINFO must render the band as a readable field")
assert(rendered_reload:find("未注册（不搜索）", 1, true), "registration state 0 must have a readable label")
assert(rendered_reload:find("898606…5858", 1, true), "reload result must mask ICCID")

print("PASS: final-line JSON parsing, ICCID/EID masking, keyboard and selector guards")
print("PASS: card text renders the phone number from the UCI mapping")
print("PASS: reload result formatting, QNWINFO parsing, operator mapping and registration label display")

os.execute("mkdir -p /tmp/tohsakawrt/state")
local function write_file(path, value)
    local f = assert(io.open(path, "w")); f:write(value); f:close()
end
local tg_calls = { sends = 0, edits = 0, fail_send = false }
package.loaded["tohsakawrt.tg"] = {
    send_msg = function(text)
        tg_calls.sends = tg_calls.sends + 1
        tg_calls.sent_text = text
        if tg_calls.fail_send then error("stub push failure") end
    end,
    edit_msg = function(message_id, text, keyboard)
        tg_calls.edits = tg_calls.edits + 1
        tg_calls.edit_id, tg_calls.edit_text, tg_calls.edit_keyboard = message_id, text, keyboard
    end
}
io.popen = function()
    return {
        read = function() return '{"type":"lpa","payload":{"code":0,"data":{}}}\n' end,
        close = function() return true end
    }
end
local function worker_case(id, message_id, fail_send, kind, main_uplink)
    tg_calls.sends, tg_calls.edits, tg_calls.fail_send = 0, 0, fail_send
    local base = "/tmp/tohsakawrt/state/esim-job-" .. id
    write_file(base .. ".spec", (kind or "download") .. "\nAC\n测试号码\n" .. (main_uplink or "0") .. "\n\n" .. message_id .. "\n")
    esim.worker(id)
    return base .. ".txt"
end
local result_with_id = worker_case("test-push-with-id", "123", false)
assert(tg_calls.sends == 1, "worker must send exactly one new result message")
assert(tg_calls.edits == 1 and tg_calls.edit_id == "123", "worker must finish the pending card when message_id is set")
assert(tg_calls.edit_text:find("已完成", 1, true) and tg_calls.edit_keyboard == nil, "pending card must be finalized without a keyboard")
assert(tg_calls.sent_text:find("🕰️ <i>", 1, true), "pushed result must include the time footer")
print("PASS: worker pushes exactly once and edits the pending card for a nonempty message_id")
local result_without_id = worker_case("test-push-empty-id", "", false)
assert(tg_calls.sends == 1, "worker without message_id must still send exactly one new result message")
assert(tg_calls.edits == 0, "worker must not edit a pending card when message_id is empty")
print("PASS: worker does not edit a pending card for an empty message_id")
local result_after_push_error = worker_case("test-push-error", "", true)
local f = assert(io.open(result_after_push_error, "r"))
local persisted = f:read("*a"); f:close()
assert(persisted and persisted:find("写卡", 1, true), "push failure must not prevent writing the result file")
print("PASS: result file is written even when the push function throws")

local original_reload_flow = esim.reload_flow
esim.reload_flow = function()
    return { ready = true, cpin = "READY", prefix = "898606", last4 = "5858",
        qnw = '"TDD NR5G","46001","NR5G BAND 78",627264', label = "已注册", elapsed = 80 }
end
worker_case("test-reload-main-uplink", "", false, "reload", "1")
assert(tg_calls.sent_text:find("⚠️ 模组当前是主出口，期间会断网约 2 分钟", 1, true),
    "reload result card must warn when the modem is the main uplink")
print("PASS: reload result warns when main_uplink is 1")
worker_case("test-reload-secondary-uplink", "", false, "reload", "0")
assert(not tg_calls.sent_text:find("⚠️ 模组当前是主出口，期间会断网约 2 分钟", 1, true),
    "reload result card must not warn when the modem is not the main uplink")
print("PASS: reload result omits the warning when main_uplink is 0")
esim.reload_flow = original_reload_flow

io.popen = original_popen
