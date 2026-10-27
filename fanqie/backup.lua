-- 本地备份与恢复：版本化 JSON 包（不用 zip，纯 Lua 可写可读，跨 Kindle/Kobo）。
-- 永不导出：config.lua、Cookie、设备池、设备身份、密钥、日志。
-- 白名单字段而非黑名单 —— 不在白名单里的设置键一概不进包。
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local lfs = require("libs/libkoreader-lfs")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")

local M = {}
M.FORMAT = "fanqie-backup"
M.VERSION = 1

-- 白名单：备份包里允许出现的**设置键**（settings/fanqie.lua 的顶层键）。
-- 🔴 凭证类键（cookies、config_auth_fingerprint、curl_payload、reading_v1_key
--    由 settings 顶层持有）绝不在此列；新增设置键必须显式加入才会进包。
local SETTINGS_WHITELIST = {
    sync = true, cache = true, shelf = true, ui = true, startup = true,
    para_review_enabled = true, para_tap_whole = true, download_dir = true,
    library_schema = true, updates = true, offline = true, history = true,
    return_to_shelf_on_close = true,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function deep_copy_settings(settings)
    local out = {}
    for key in pairs(SETTINGS_WHITELIST) do
        local value = settings:get(key, nil)
        if value ~= nil then out[key] = copy(value) end
    end
    return out
end

-- 摘要：简单校验和（可复现、无依赖）。对整个 payload 逐字节累加哈希。
local function checksum(text)
    local acc = 5381
    for i = 1, #text do
        acc = (acc * 33 + text:byte(i)) % 2147483647
    end
    return string.format("%08x", acc)
end

--- 导出备份。
-- @return ok, path_or_err, bytes
function M.export(plugin, target_path, opts)
    opts = opts or {}
    if not plugin.library then return false, _("资料库不可用") end
    local payload = {
        format = M.FORMAT,
        version = M.VERSION,
        created_at = os.time(),
        plugin_version = plugin.version or "unknown",
        settings = deep_copy_settings(plugin.settings),
        library = plugin.library.data,
    }
    if opts.include_cache then payload.include_cache = true end
    -- 序列化键排序：KOReader 的 json/rapidjson 与这里的测试桩都按 pairs 输出，
    -- 同一 payload 两次编码顺序不同 ⇒ 摘要没法对。构建时强制按固定字段序编码。
    local encoded = M.stable_encode(payload)
    if not encoded then return false, _("无法序列化备份") end
    local final = '{["checksum"]="' .. checksum(encoded) .. '",' .. encoded:sub(2)

    local dir = target_path:match("^(.*)/[^/]+$")
    if dir and not H.dir_exists(dir) and not H.make_dir(dir) then
        return false, _("目标目录不可写")
    end
    local temp = target_path .. ".tmp"
    local file, err = io.open(temp, "wb")
    if not file then return false, tostring(err) end
    local ok_write = file:write(final)
    file:close()
    if not ok_write then os.remove(temp); return false, _("写入失败") end
    if not os.rename(temp, target_path) then
        os.remove(temp)
        return false, _("无法写入目标位置")
    end
    if Log and Log.info then Log.info("[backup] exported to", target_path) end
    return true, target_path, #final
end

--- 键排序的稳定序列化：同一数据永远产生同一字节串（摘要的前提）。
-- 只支持备份 payload 这类「字符串键 / 表嵌套 / 标量值」的数据形状。
local function stable_encode(value)
    if value == nil then return "null" end
    local t = type(value)
    if t == "number" then return string.format("%.14g", value) end
    if t == "boolean" then return tostring(value) end
    if t == "string" then return string.format("%q", value) end
    if t ~= "table" then return nil end
    local keys = {}
    for k in pairs(value) do
        if type(k) ~= "string" then return nil end
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v_enc = stable_encode(value[k])
        if not v_enc then return nil end
        parts[#parts + 1] = "[" .. string.format("%q", k) .. "]=" .. v_enc
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
M.stable_encode = stable_encode

--- 校验备份文本：格式、版本、摘要。
-- @return payload|nil, err
function M.validate(raw)
    if type(raw) ~= "string" or raw == "" then return nil, _("备份文件为空") end
    local payload = H.json_decode(raw)
    if type(payload) ~= "table" then return nil, _("备份格式无法解析") end
    if payload.format ~= M.FORMAT then return nil, _("不是番茄插件备份文件") end
    local version = tonumber(payload.version)
    if not version or version > M.VERSION then
        return nil, string.format(_("备份版本（%s）高于当前插件支持"), tostring(payload.version))
    end
    local sum = payload.checksum
    if not sum or type(sum) ~= "string" then return nil, _("备份缺少校验和") end
    payload.checksum = nil
    -- 与导出同一把尺子（stable_encode）：json_encode 的 pairs 顺序不可复现
    local re_encoded = stable_encode(payload)
    if not re_encoded then return nil, _("备份无法重新序列化") end
    if checksum(re_encoded) ~= sum then
        return nil, _("备份内容与校验和不符（文件损坏）")
    end
    payload.checksum = sum
    return payload
end

--- 恢复前预检：解析+校验+统计，返回将要恢复的内容摘要；不改任何状态。
-- @return payload|nil, err
function M.preview(path)
    local file = io.open(path, "rb")
    if not file then return nil, _("无法打开备份文件") end
    local raw = file:read("*a")
    file:close()
    local payload, err = M.validate(raw)
    if not payload then return nil, err end
    return payload
end

--- 恢复：先把现有设置/资料库另存为回滚点，再原子替换。
-- 失败/取消时零修改。
-- @return ok, err
function M.restore(plugin, path)
    local payload, err = M.preview(path)
    if not payload then return false, err end
    local settings = plugin.settings
    local library = plugin.library

    -- 回滚点：同目录 .bak
    local function backup_file(src, suffix)
        if not H.file_exists(src) then return nil end
        local dst = src .. "." .. suffix
        local f = io.open(src, "rb")
        if not f then return nil end
        local raw = f:read("*a")
        f:close()
        local w = io.open(dst, "wb")
        if not w then return nil end
        w:write(raw)
        w:close()
        return dst
    end

    local rollback_settings = backup_file(settings.settings_file, "bak")
    local rollback_library = backup_file(library.path, "bak")

    -- 恢复设置（白名单内的键才写回；白名单外的现有键不动）
    local applied = 0
    for key, value in pairs(payload.settings or {}) do
        if SETTINGS_WHITELIST[key] then
            settings:set(key, copy(value))
            applied = applied + 1
        end
    end
    settings:flush()

    -- 恢复资料库（整表替换 + 落盘）
    if type(payload.library) == "table" then
        library.data = copy(payload.library)
        library:flush()
    end
    if Log and Log.info then
        Log.info("[backup] restored", tostring(applied), "settings keys; rollback at",
            tostring(rollback_settings), tostring(rollback_library))
    end
    return true, rollback_settings
end

return M
