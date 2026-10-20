-- FanQie APP source (番茄小说 APP 接口) — business layer.
-- Ported from the Legado/阅读 book source "番茄小说(APP)": device
-- registration, signed GET (x-argus/x-ladon), CM mget chapter content,
-- directory, book info, search and explore (rank/tab/home).
--
-- All cryptography lives in fanqie.appcrypto. This module only orchestrates
-- HTTP + JSON. Two dependencies are injected so the module stays testable
-- outside KOReader:
--
--   AppSource.http       = function(opts) -> body(string), code(number), headers(table)
--                          opts = { url, method, headers, body, timeout }
--                          (defaults to a LuaSocket implementation)
--   AppSource.store_get  = function(key) -> string|nil
--   AppSource.store_set  = function(key, value)
--                          (device-pool persistence; defaults to in-memory)
--
-- Usage (inside the plugin, wired up by client.lua):
--   local AppSource = require("fanqie.appsource")
--   local chapters, book_info = AppSource.get_chapter_list(book_id)
--   local text = AppSource.get_content(book_id, item_id)

local AC = require("fanqie.appcrypto")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local byte, sub, concat = string.byte, string.sub, table.concat
local floor = math.floor

local AppSource = {}

-- ===========================================================================
-- Constants (from the original book source)
-- ===========================================================================

local HOST_API = 'https://api5-normal-sinfonlineb.fqnovel.com'
local URL_MGET = 'https://novelfm-hl.snssdk.com/novelfm/playerapi/full/mget/v1/'
local URL_REG = 'https://log.snssdk.com/service/2/device_register/'
local URL_WEB = 'https://fanqienovel.com'
local URL_SEARCH = 'https://api.fanqiesdk.com/api/novel/channel/homepage/search/search/v1/'

local UA_APP = 'com.dragon.read/66732 (Linux; U; Android 10; zh_CN; Pixel 4 XL; Build/QD1A.190821.007;tt-ok/3.12.13.4-tiktok)'
local UA_REG = 'com.dragon.read/65132 (Linux; U; Android 10; zh_CN; MI 12; Build/MMB29M; Cronet/TTNetVersion:9ac8d95c 2024-11-25 QuicVersion:3f326df4 2024-11-14)'
local UA_MGET = 'com.dragon.read'
local UA_SEARCH = 'com.ss.android.article.news/13400 (Linux; U; Android 10; zh_CN; tb8788p1_64_bsp; Build/QQ3A.200805.001)'
local UA_HOME = 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Mobile Safari/537.36'

-- Common query suffix shared by the directory / explore APP APIs.
local BASE_QS = 'ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp&version_code=65132&version_name=6.5.1.32&device_platform=android&os=android&ssmix=a&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&manifest_version_code=65132&resolution=1080*1920&dpi=480&update_version_code=65132&pv_player=65132&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0&host_abi=arm64-v8a&dragon_device_type=phone&compliance_status=0'

local SEARCH_SUF = '&enterfrom_aid=&enter_from=inner_search&app_name=news_article&version_name=7.0.8&app_version=7.0.8&channel=tt_huawei2019_yz&version_code=708&device_platform=android&parent_enterfrom=novel_list&novel_host=&aid=13&scm_version=1.0.0.4112&device_type=25053RT47C&device_brand=Redmi&language=zh&os_api=35&os_version=15&openudid=0123456789abcdef&update_version_code=70899&plugin=0&tma_jssdk_version=1.10.0.0&rom_version=miui__os2.0.209.0.volcnxm'

-- ===========================================================================
-- Small utilities
-- ===========================================================================

-- Seed math.random once (used for alnum/uuid/rv; crypto uses /dev/urandom).
do
    local seed = os.time() + floor((os.clock() or 0) * 1000000)
    math.randomseed(seed)
    math.random(); math.random(); math.random()
end

local function now_ms()
    local ok_sock, sock = pcall(require, "socket")
    if ok_sock and sock and sock.gettime then
        return floor(sock.gettime() * 1000)
    end
    return os.time() * 1000
end

local function now_s()
    return floor(now_ms() / 1000)
end

local ALNUM_CH = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
local function alnum(n)
    local out = {}
    for _ = 1, n do
        local p = math.random(1, #ALNUM_CH)
        out[#out + 1] = sub(ALNUM_CH, p, p)
    end
    return concat(out)
end

local function uuid()
    local rnd = AC.random_bytes(16)
    local b = { byte(rnd, 1, 16) }
    b[7] = (b[7] % 16) + 64      -- version 4
    b[9] = (b[9] % 64) + 128     -- variant 1
    local h = {}
    for i = 1, 16 do h[#h + 1] = string.format("%02x", b[i]) end
    local s = concat(h)
    return sub(s, 1, 8) .. '-' .. sub(s, 9, 12) .. '-' .. sub(s, 13, 16)
        .. '-' .. sub(s, 17, 20) .. '-' .. sub(s, 21, 32)
end

local function url_encode(s)
    s = tostring(s or "")
    return (s:gsub("[^a-zA-Z0-9%-_.~]", function(c)
        return string.format("%%%02X", byte(c))
    end))
end

local function jdecode(s)
    if not ok_json then error("JSON module is not available") end
    if json.decode then return json.decode(s) end
    return json:decode(s)
end

-- ===========================================================================
-- Injected dependencies (with defaults)
-- ===========================================================================

local MEM_STORE = {}

local function store_get(key)
    if AppSource.store_get then return AppSource.store_get(key) end
    return MEM_STORE[key]
end

local function store_set(key, value)
    if AppSource.store_set then return AppSource.store_set(key, value) end
    MEM_STORE[key] = value
end

local function log_info(...)
    if AppSource.logger then AppSource.logger(...) end
end

-- Default HTTP via LuaSocket (same shape as client.lua's Client:request).
local function default_http(opts)
    local _, https = pcall(require, "ssl.https")
    local _, http = pcall(require, "socket.http")
    local ltn12 = require("ltn12")
    local transport = opts.url:match("^https:") and https or http
    if not transport then error("socket.http/ssl.https is not available") end
    local response = {}
    local headers = opts.headers or {}
    if opts.body then headers["Content-Length"] = tostring(#opts.body) end
    local prev_timeout = transport.TIMEOUT
    transport.TIMEOUT = opts.timeout or 20
    local ok, _, code, resp_headers = pcall(transport.request, {
        url = opts.url,
        method = opts.method or (opts.body and "POST" or "GET"),
        headers = headers,
        source = opts.body and ltn12.source.string(opts.body) or nil,
        sink = ltn12.sink.table(response),
    })
    transport.TIMEOUT = prev_timeout
    if not ok then error("http request failed: " .. tostring(code)) end
    return concat(response), tonumber(code), resp_headers or {}
end

local function http(opts)
    local fn = AppSource.http or default_http
    return fn(opts)
end

-- ===========================================================================
-- Device pool (registered devices, persisted as "d,i,o,c|d,i,o,c|...")
-- ===========================================================================

local function get_pool()
    local p = tostring(store_get('fqPool') or "")
    local out = {}
    if p == "" then return out end
    for entry in p:gmatch("[^|]+") do
        -- 按逗号分割且保留空字段。不能用 gmatch("[^,]*")：它会在每个逗号
        -- 处额外产生空匹配，导致 parts[2]（install_id）恒为空串，设备池
        -- 读回后 i 全部丢失，正文 mget 因空 iid 被服务端拒绝。
        local parts = {}
        local pos = 1
        while true do
            local c = string.find(entry, ",", pos, true)
            if not c then
                parts[#parts + 1] = string.sub(entry, pos)
                break
            end
            parts[#parts + 1] = string.sub(entry, pos, c - 1)
            pos = c + 1
        end
        -- 只保留 d/i 齐全的设备：旧版本构建或异常注册可能留下 i（install_id）
        -- 为空的坏条目，这类条目一旦排到 pool[1] 会导致正文 mget 被服务端拒绝。
        if parts[1] and parts[1] ~= "" and parts[2] and parts[2] ~= "" then
            out[#out + 1] = { d = parts[1], i = parts[2], o = parts[3] or "", c = parts[4] or "" }
        end
    end
    return out
end

local function save_pool(pool)
    local a = {}
    for _, d in ipairs(pool) do
        a[#a + 1] = (d.d or "") .. "," .. (d.i or "") .. "," .. (d.o or "") .. "," .. (d.c or "")
    end
    store_set('fqPool', concat(a, "|"))
end

-- Register one fresh device against log.snssdk.com.
-- Returns { d, i, o, c } on success, nil + error message otherwise.
local function register_one()
    local openudid = alnum(16)
    local cdid = uuid()
    local clientudid = uuid()

    -- Registration payload JSON (built by hand to control exact field types).
    local hdr = {
        '"display_name":"\231\149\170\232\140\132\229\176\143\232\175\180"', -- 番茄小说
        '"update_version_code":"65132"',
        '"manifest_version_code":"65132"',
        '"aid":1967',
        '"channel":"xiaomi_1967_64"',
        '"package":"com.dragon.read"',
        '"app_version":"6.5.1.32"',
        '"version_code":"65132"',
        '"sdk_version":"v04.04.05-ov-android"',
        '"sdk_target_version":29',
        '"os":"Android"',
        '"os_version":"10"',
        '"os_api":"29"',
        '"device_model":"MI 12"',
        '"device_brand":"Xiaomi"',
        '"device_manufacturer":"Google"',
        '"device_category":"phone"',
        '"cpu_abi":"arm64-v8a"',
        '"release_build":"' .. uuid() .. '"',
        '"density_dpi":"560"',
        '"display_density":"mdpi"',
        '"resolution":"1440x2392"',
        '"language":"zh"',
        '"mac":"11:22:33:44:55:66"',
        '"timezone":8',
        '"access":"wifi"',
        '"not_request_sender":0',
        '"carrier":"CHINA MOBILE"',
        '"mcc_mnc":"46007"',
        '"rom":"EMUI-' .. alnum(13) .. '"',
        '"rom_version":"' .. alnum(2) .. '"',
        '"sig_hash":"' .. AC.md5_hex(uuid()) .. '"',
        '"openudid":"' .. openudid .. '"',
        '"clientudid":"' .. clientudid .. '"',
        '"sim_serial_number":[]',
        '"region":"CN"',
        '"tz_name":"Asia/Shanghai"',
        '"tz_offset":28800',
        '"sim_region":"cn"',
    }
    local js = '{"magic_tag":"ss_app_log","header":{' .. concat(hdr, ",")
        .. '},"_gen_time":' .. string.format("%.0f", now_ms()) .. '}'

    local post = AC.ttenc(AC.gzip_stored(js))
    local ts = now_s()

    local P = {
        { 'tt_data', 'a' }, { 'os_api', '29' }, { 'device_type', 'MI 12' },
        { 'ssmix', 'a' }, { 'manifest_version_code', '65132' }, { 'dpi', '560' },
        { 'version_name', '6.5.1.32' }, { 'ts', tostring(ts) },
        { 'cpu_support64', 'true' }, { 'app_type', 'normal' }, { 'appTheme', 'light' },
        { 'ac', 'wifi' }, { 'host_abi', 'arm64-v8a' }, { 'update_version_code', '65132' },
        { 'channel', 'xiaomi_1967_64' }, { '_rticket', string.format("%.0f", now_ms()) },
        { 'device_platform', 'android' }, { 'version_code', '65132' }, { 'cdid', cdid },
        { 'os', 'android' }, { 'is_android_pad', '0' }, { 'openudid', openudid },
        { 'package', 'com.dragon.read' }, { 'resolution', '1440*2392' },
        { 'os_version', '10' }, { 'language', 'zh' }, { 'device_brand', 'Xiaomi' },
        { 'need_personal_recommend', '1' }, { 'aid', '1967' }, { 'minor_status', '0' },
        { 'app_name', 'novel' }, { 'mcc_mnc', '46007' },
    }
    table.sort(P, function(a, b) return a[1] < b[1] end)
    local parts = {}
    for _, kv in ipairs(P) do
        parts[#parts + 1] = kv[1] .. '=' .. url_encode(kv[2])
    end
    local url = URL_REG .. '?' .. concat(parts, '&')

    local ok, body, code = pcall(http, {
        url = url,
        method = "POST",
        headers = {
            ['Content-Type'] = 'application/octet-stream;tt-data=a',
            ['Accept-Encoding'] = 'gzip',
            ['User-Agent'] = UA_REG,
            ['Connection'] = 'Keep-Alive',
        },
        body = post,
        timeout = 25,
    })
    if not ok then
        return nil, "设备注册请求异常: " .. tostring(body)
    end
    log_info("[FanQie][appsource] register http " .. tostring(code) .. " len " .. tostring(#(body or "")))
    body = tostring(body or "")
    local dev = body:match('"device_id_str"%s*:%s*"(%d+)"')
    if not dev then
        return nil, "设备注册失败: 响应中无 device_id_str (http " .. tostring(code) .. ")"
    end
    local iid = body:match('"install_id_str"%s*:%s*"(%d+)"') or ""
    return { d = dev, i = iid, o = openudid, c = cdid }
end
AppSource.register_one = register_one

-- Ensure the pool holds at least n devices, registering new ones if needed.
-- Registration failures are tolerated: callers may still use an empty/short
-- pool (the directory API accepts unsigned-device requests with a fake id).
local register_failed_at = nil  -- 上次注册失败的时间(ms)，用于负缓存

local function ensure_pool(n)
    n = n or 2
    local pool = get_pool()
    local need = n - #pool
    -- 注册失败后 60s 内不再重试：否则每次取正文都会白等一次 25s 超时
    if need > 0 and register_failed_at and (now_ms() - register_failed_at) < 60000 then
        return pool
    end
    for _ = 1, need do
        local d, err = register_one()
        if not d then
            register_failed_at = now_ms()
            log_info("[FanQie][appsource] register failed: " .. tostring(err))
            break
        end
        register_failed_at = nil
        pool[#pool + 1] = d
        save_pool(pool)
    end
    return pool
end
AppSource.ensure_pool = ensure_pool

-- Device status for UI display: { count = n, first = device_id|nil }
function AppSource.device_status()
    local pool = get_pool()
    return { count = #pool, first = pool[1] and pool[1].d or nil }
end

-- Clear the persisted pool (forces re-registration on next request).
function AppSource.clear_pool()
    store_set('fqPool', "")
end

-- ===========================================================================
-- Signed APP GET  (FQ_api)
-- ===========================================================================

-- Returns response body string. Errors on transport failure / non-2xx.
local function api_get(path, q, aid, host)
    local pool = ensure_pool(2)
    local dev, iid = '', ''
    if #pool > 0 then
        dev = pool[1].d
        iid = pool[1].i or ''
    else
        -- Registration unavailable: fall back to a placeholder device. The
        -- signature itself is what the gateway checks (verified live).
        dev = '0'
        iid = ''
    end
    local qq = q .. '&iid=' .. iid .. '&device_id=' .. dev
    local url = (host or HOST_API) .. path .. '?' .. qq
    local ts = now_s()
    local h = AC.sign(AC.qs_of(url), '', ts, dev, iid, aid or 1967, math.random(0, 1999999999))
    h['User-Agent'] = UA_APP
    local body, code = http({ url = url, method = "GET", headers = h, timeout = 20 })
    if not code or code < 200 or code >= 300 then
        error("APP 接口请求失败: HTTP " .. tostring(code) .. " path=" .. path)
    end
    return body
end

-- ===========================================================================
-- Directory / book info  (ruleToc + ruleBookInfo)
-- ===========================================================================

-- Fetch raw directory payload. Returns parsed `data` table:
--   { catalog_data = [...], book_info = {...}, ... }
local function fetch_directory(book_id)
    local q = 'book_type=0&item_data_list_md5=&catalog_data_md5=&book_id=' .. url_encode(book_id)
        .. '&book_info_md5=&need_version=true&' .. BASE_QS
    local raw = api_get('/reading/bookapi/directory/all_items/v', q)
    local ok, d = pcall(jdecode, raw)
    if not ok or type(d) ~= "table" then
        error("目录响应解析失败: " .. tostring(sub(tostring(raw), 1, 200)))
    end
    if d.code ~= 0 and d.code ~= nil then
        error("目录接口返回错误: code=" .. tostring(d.code) .. " message=" .. tostring(d.message or ""))
    end
    return d.data or {}
end

-- Returns (chapters, book_info):
--   chapters = array of { name = title, item_id = "..." }
--   book_info = raw book_info table (may be nil)
function AppSource.get_chapter_list(book_id)
    local data = fetch_directory(book_id)
    local cats = data.catalog_data or data.item_data_list or {}
    local chapters = {}
    for i, c in ipairs(cats) do
        chapters[#chapters + 1] = {
            name = tostring(c.catalog_title or c.title or ("第" .. i .. "章")),
            item_id = tostring(c.item_id or c.catalog_id or ""),
        }
    end
    return chapters, data.book_info
end

-- Returns normalized book info:
--   { name, author, kind, intro, coverUrl, book_id, creation_status,
--     last_chapter_update_time, serial_count }
function AppSource.get_book_info(book_id)
    local data = fetch_directory(book_id)
    local bd = data.book_info or {}
    local cats = data.catalog_data or data.item_data_list or {}
    -- 诊断：目录接口的表名偶尔会变（catalog_data / item_data_list / 其它），
    -- 章数为 0 时要能从日志看出「是没这张表」还是「表是空的」。
    if #cats == 0 then
        local keys = {}
        for k in pairs(data) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        log_info("[FanQie][app] 目录接口无章节表 book_id=" .. tostring(book_id)
            .. " data keys=" .. concat(keys, ","))
    end
    return put_status({
        name = tostring(bd.book_name or ""),
        author = tostring(bd.author or ""),
        kind = tostring(bd.category or ""),
        intro = tostring(bd.abstract or bd.book_abstract_v2 or ""),
        coverUrl = tostring(bd.thumb_url or bd.expand_thumb_url or ""),
        book_id = tostring(book_id),
        -- 目录接口一次就把章数给了；有就带上，详情框才能显示「N 章」。
        -- ⚠️ 不能直接写 `... and #cats or nil`：`#cats == 0` 时前段是 false，
        --    整体表达式退成 nil 没错，但 `book_info` 为 nil 时 cats 可能是别的表，
        --    显式写清楚更好读。章数为 0 一律不带（UI 不显示 0 章）。
        serial_count = (type(cats) == "table" and #cats > 0) and #cats or nil,
    }, bd)
end

-- ===========================================================================
-- Chapter content via the CM mget channel  (FQ_cmGet + ruleContent)
-- ===========================================================================

-- Low-level mget. Returns map item_id -> decrypted plaintext.
local function cm_get(book_id, item_ids, dev, iid)
    local key_b64, pk = AC.cm_make_key()
    local ids = {}
    for _, v in ipairs(item_ids) do ids[#ids + 1] = '"' .. tostring(v) .. '"' end
    local body = '{"book_id":"' .. tostring(book_id) .. '","item_ids":['
        .. concat(ids, ",") .. '],"key":"' .. key_b64 .. '"}'
    local url = URL_MGET .. '?aid=3040&app_name=novelapp&channel=0&device_id=' .. dev
        .. '&device_platform=android&device_type=UGFFI55&iid=' .. iid
        .. '&os_version=0&version_code=58932&version_name=5.8.9.32'
    local ts = now_s()
    local stub = AC.md5_hex(body)
    local h = AC.sign(AC.qs_of(url), stub, ts, dev, iid, 3040, math.random(0, 1999999999))
    h['User-Agent'] = UA_MGET
    h['Content-Type'] = 'application/json; charset=utf-8'
    local resp, code = http({ url = url, method = "POST", headers = h, body = body, timeout = 20 })
    if not code or code < 200 or code >= 300 then
        error("正文接口请求失败: HTTP " .. tostring(code))
    end
    local ok, dd = pcall(jdecode, resp)
    if not ok or type(dd) ~= "table" then
        error("正文响应解析失败: " .. tostring(sub(tostring(resp), 1, 200)))
    end
    local infos = (dd.data and dd.data.item_infos) or {}
    local out = {}
    for k, it in pairs(infos) do
        if type(it) == "table" and it.key and it.content then
            local ok_dec, txt = pcall(AC.cm_decrypt, pk, tostring(it.key), tostring(it.content))
            if ok_dec and txt then
                out[k] = txt
            end
        end
    end
    if next(out) == nil then
        -- 诊断日志：响应 200 但没有可解密条目（常见于设备参数异常/服务端错误载荷）
        log_info("[FanQie][appsource] mget 无解密结果: code=" .. tostring(code)
            .. " item_infos=" .. tostring(type(infos))
            .. " resp=" .. sub(tostring(resp), 1, 220))
    end
    return out
end

-- Fetch one chapter's content. Returns the decrypted text; if the plaintext
-- happens to be a JSON envelope, the inner `content` field is returned.
function AppSource.get_content(book_id, item_id)
    local pool = ensure_pool(2)
    if #pool == 0 then
        error("设备池为空，正文接口需要已注册设备（请检查网络后重试）")
    end
    local dev, iid = pool[1].d, pool[1].i or ''
    local res = cm_get(book_id, { item_id }, dev, iid)
    local txt = res[tostring(item_id)]
    if not txt or txt == "" then
        error("正文获取失败，请重试")
    end
    -- Some responses wrap the chapter in a JSON envelope; unwrap if present.
    if txt:match("^%s*{") then
        local ok, d = pcall(jdecode, txt)
        if ok and type(d) == "table" then
            local inner = d.content or (type(d.data) == "table" and d.data.content) or nil
            if type(inner) == "string" and #inner > 0 then
                txt = inner
            end
        end
    end
    return txt
end

-- ===========================================================================
-- Search  (searchUrl + ruleSearch)
-- ===========================================================================

local function strip_em(s)
    s = tostring(s or "")
    s = s:gsub("<em>", ""):gsub("</em>", "")
    return (s:gsub("<", "&lt;"))
end

-- Returns array of { name, author, kind, intro, coverUrl, book_id, bookUrl }
function AppSource.search(keyword)
    local url = URL_SEARCH .. '?q=' .. url_encode(keyword) .. '&offset=0' .. SEARCH_SUF
    local body, code = http({
        url = url,
        method = "GET",
        headers = { ['User-Agent'] = UA_SEARCH },
        timeout = 20,
    })
    if not code or code < 200 or code >= 300 then
        error("搜索请求失败: HTTP " .. tostring(code))
    end
    local ok, d = pcall(jdecode, body)
    if not ok or type(d) ~= "table" then
        error("搜索响应解析失败")
    end
    local items = (d.data and d.data.ret_data) or {}
    local out = {}
    for _, it in ipairs(items) do
        local bid = tostring(it.book_id or "")
        if bid ~= "" then
            out[#out + 1] = put_status({
                name = strip_em(it.title),
                author = strip_em(it.author),
                kind = strip_em(it.category),
                intro = strip_em(it.abstract),
                coverUrl = tostring(it.thumb_url or ""),
                book_id = bid,
                bookUrl = URL_WEB .. '/page/' .. bid,
            }, it)
        end
    end
    return out
end

-- ===========================================================================
-- Explore  (exploreUrl + ruleExplore: rank / tab / home)
-- ===========================================================================

-- 把 APP 接口的「作品」字段归一成详情框认的键。
-- 🔴 `creation_status` 语义与网页侧一致（0=完结 / 1=连载，实测 2026-10-20：
--    榜单 cell 接口、搜索接口都带这个字段），直接透传到 book.creation_status，
--    详情框才能判出「连载中 / 已完结」—— 以前不透传，详情一律显示「未知」，
--    与列表行自相矛盾。
-- `last_publish_time` 是 unix 秒，作为「最后更新时间」参与「疑似断更」判断。
local function put_status(b, it)
    b.creation_status = tonumber(it.creation_status)
    b.last_chapter_update_time = tonumber(it.last_publish_time)
    -- 章节数：榜单接口给 word_number（字数）而不是章数，不伪造；
    -- 目录接口返回的 book_info 里才有真实章数（见 get_book_info）。
    return b
end

local function norm_book(it, id_key)
    local bid = tostring(it[id_key or 'book_id'] or it.bookId or "")
    if bid == "" then return nil end
    return put_status({
        name = tostring(it.book_name or it.bookName or ""),
        author = tostring(it.author or ""),
        kind = tostring(it.category or ""),
        intro = tostring(it.abstract or ""),
        coverUrl = tostring(it.thumb_url or it.thumbUri or ""),
        book_id = bid,
        bookUrl = URL_WEB .. '/page/' .. bid .. '#' .. bid,
    }, it)
end

-- 排行榜: /reading/bookapi/bookmall/cell/change/v1/
local function rank_books(cat, algo, page)
    local off = ((page or 1) - 1) * 16
    local q = 'cell_id=7098235271900037133&offset=' .. off
        .. '&client_template=2&client_req_type=2&tab_type=2&req_rank_category_id=' .. cat
        .. '&req_rank_algo=' .. (algo or '101') .. '&' .. BASE_QS
    local raw = api_get('/reading/bookapi/bookmall/cell/change/v1/', q)
    local d = jdecode(raw)
    local bd = (d.data and d.data.cell_view and d.data.cell_view.book_data) or {}
    if type(bd) ~= "table" then bd = {} end   -- rapidjson null sentinel (function)
    local out = {}
    for _, it in ipairs(bd) do
        local b = norm_book(it)
        if b then out[#out + 1] = b end
    end
    return out
end

-- 频道 tab: /reading/bookapi/bookmall/tab/v
local function tab_books(tab_type, page)
    local off = ((page or 1) - 1) * 16
    local q = 'tab_type=' .. tab_type .. '&offset=' .. off .. '&client_template=0&' .. BASE_QS
    local raw = api_get('/reading/bookapi/bookmall/tab/v', q)
    local d = jdecode(raw)
    local ti = (d.data and d.data.tab_item) or {}
    if type(ti) ~= "table" then ti = {} end   -- rapidjson null sentinel (function)
    local out, seen = {}, {}
    for _, t in ipairs(ti) do
        local cells = type(t) == "table" and t.cell_data or nil
        if type(cells) ~= "table" then cells = {} end
        for _, cell in ipairs(cells) do
            local bd = type(cell) == "table" and cell.book_data or nil
            if type(bd) ~= "table" then bd = {} end
            for _, it in ipairs(bd) do
                local b = norm_book(it)
                if b and not seen[b.book_id] then
                    seen[b.book_id] = true
                    out[#out + 1] = b
                end
            end
        end
    end
    return out
end

-- Extract the window.__INITIAL_STATE__ JSON object from the web homepage.
local function extract_initial_state(html)
    html = tostring(html or "")
    local i = html:find('window.__INITIAL_STATE__=', 1, true)
    if not i then return nil end
    local st0 = html:find('{', i, true)
    if not st0 then return nil end
    local depth, instr, esc = 0, false, false
    for k = st0, #html do
        local c = sub(html, k, k)
        if instr then
            if esc then esc = false
            elseif c == '\\' then esc = true
            elseif c == '"' then instr = false end
        else
            if c == '"' then instr = true
            elseif c == '{' then depth = depth + 1
            elseif c == '}' then
                depth = depth - 1
                if depth == 0 then
                    local ok, d = pcall(jdecode, sub(html, st0, k))
                    return ok and d or nil
                end
            end
        end
    end
    return nil
end

-- 首页精选: scrape fanqienovel.com home page initial state.
local HOME_GROUPS = { 'weekList', 'editorList', 'updateList', 'newbookList', 'boyList',
    'girlList', 'readRankList', 'newRankList', 'fantasyList', 'topRankList' }

local function home_books()
    -- 🔴 2026-10-20 实测 bug：设备上请求首页返回 HTTP 200 但 body 里没有
    --    `window.__INITIAL_STATE__`（CDN 风控 / 网络劫持会回一个空壳验证页，
    --    字节数远小于正常首页的 ~50KB）。旧代码 `extract_initial_state` 失败时
    --    静默 `return {}`，用户在「首页精选」看到的就是莫名空白/加载失败，
    --    日志里还查不到任何错误。
    --    修复：body 异常时明确 error（带 body 长度和开头摘要，async 管道会把
    --    错误带回 UI 弹窗），并对首包异常做一次重试。
    local body, code
    for attempt = 1, 2 do
        body, code = http({
            url = URL_WEB .. '/',
            method = "GET",
            headers = { ['User-Agent'] = UA_HOME },
            timeout = 20,
        })
        if code and code >= 200 and code < 300
            and type(body) == "string" and #body > 1024
            and body:find('window.__INITIAL_STATE__', 1, true) then
            break
        end
        if attempt == 1 then
            log_info("[首页精选] 首页响应异常（HTTP " .. tostring(code)
                .. ", body=" .. tostring(body and #body or -1) .. " 字节），重试一次")
        end
    end
    if not code or code < 200 or code >= 300 then
        error("首页请求失败: HTTP " .. tostring(code))
    end
    local d = extract_initial_state(body)
    if not d then
        local head = (type(body) == "string" and body:sub(1, 80) or ""):gsub("[%c]", " ")
        error("首页解析失败：响应里没有书籍数据（HTTP " .. tostring(code)
            .. ", body=" .. tostring(body and #body or -1) .. " 字节）。"
            .. "可能是网络劫持/风控，请稍后重试。开头: " .. head)
    end
    local hm = d.home or {}
    local out, seen = {}, {}
    for _, g in ipairs(HOME_GROUPS) do
        -- 🔴 rapidjson 把 JSON null 解码成 sentinel 函数（rapidjson.null），
        --    `hm[g] or {}` 拦不住函数 ⇒ ipairs(函数) 直接炸
        --    （实测 2026-10-20：首页精选 newbookList/boyList 等字段全是 null）。
        --    null 语义 = 这个分组没数据，按空表处理。
        local group = hm[g]
        if type(group) ~= "table" then group = {} end
        for _, it in ipairs(group) do
            local b = norm_book(it, 'bookId')
            if b and not seen[b.book_id] then
                seen[b.book_id] = true
                out[#out + 1] = b
            end
        end
    end
    return out
end

-- Entry point mirroring ruleExplore: url is one of the exploreUrl entries.
--   https://fanqienovel.com?t=rank&cat=<cat>&algo=<algo>
--   https://fanqienovel.com?t=tab&tt=<tab_type>
--   https://fanqienovel.com            (home)
function AppSource.explore(url, page)
    url = tostring(url or "")
    page = tonumber(page) or 1
    if url:match("[?&]t=rank") then
        local cat = url:match("[?&]cat=(%d+)") or '0'
        local algo = url:match("[?&]algo=(%d+)") or '101'
        return rank_books(cat, algo, page)
    end
    local tt = url:match("[?&]tt=(%d+)")
    if url:match("[?&]t=tab") and tt then
        return tab_books(tt, page)
    end
    return home_books()
end

-- Explore catalogue (from the source's exploreUrl), for UI menus.
-- Returns array of sections: { title = "排行榜", items = { {title, url}, ... } }
-- 🔴 这里**不能放 emoji**：菜单由 KOReader 自绘，设备字体（iFlytek 墨水屏）
--    没有 emoji 字形 ⇒ 每个 emoji 都渲染成豆腐块「▯」，整列菜单像乱码。
--    原书源里的 🔥🏆👑 等只是装饰，去掉不影响任何功能。
function AppSource.explore_catalog()
    return {
        { title = "排行榜", items = {
            { title = "推荐榜", url = URL_WEB .. "?t=rank&cat=0&algo=101" },
            { title = "完本榜", url = URL_WEB .. "?t=rank&cat=0&algo=100" },
            { title = "巅峰榜", url = URL_WEB .. "?t=rank&cat=0&algo=200" },
            { title = "口碑榜", url = URL_WEB .. "?t=rank&cat=0&algo=104" },
        } },
        { title = "分类榜", items = {
            { title = "穿越", url = URL_WEB .. "?t=rank&cat=37&algo=101" },
            { title = "系统", url = URL_WEB .. "?t=rank&cat=19&algo=101" },
            { title = "都市", url = URL_WEB .. "?t=rank&cat=1&algo=101" },
            { title = "现代言情", url = URL_WEB .. "?t=rank&cat=3&algo=101" },
            { title = "玄幻", url = URL_WEB .. "?t=rank&cat=7&algo=101" },
            { title = "古代言情", url = URL_WEB .. "?t=rank&cat=5&algo=101" },
            { title = "重生", url = URL_WEB .. "?t=rank&cat=36&algo=101" },
            { title = "架空", url = URL_WEB .. "?t=rank&cat=452&algo=101" },
            { title = "东方玄幻", url = URL_WEB .. "?t=rank&cat=511&algo=101" },
            { title = "打脸", url = URL_WEB .. "?t=rank&cat=522&algo=101" },
            { title = "奇幻仙侠", url = URL_WEB .. "?t=rank&cat=259&algo=101" },
            { title = "都市脑洞", url = URL_WEB .. "?t=rank&cat=262&algo=101" },
            { title = "科幻末世", url = URL_WEB .. "?t=rank&cat=8&algo=101" },
            { title = "玄幻脑洞", url = URL_WEB .. "?t=rank&cat=257&algo=101" },
            { title = "衍生", url = URL_WEB .. "?t=rank&cat=1079&algo=101" },
        } },
        { title = "频道", items = {
            { title = "推荐", url = URL_WEB .. "?t=tab&tt=2" },
            { title = "经典", url = URL_WEB .. "?t=tab&tt=11" },
            { title = "知识", url = URL_WEB .. "?t=tab&tt=12" },
            { title = "短篇", url = URL_WEB .. "?t=tab&tt=103" },
        } },
        { title = "首页", items = {
            { title = "首页精选", url = URL_WEB },
        } },
    }
end

-- Exposed for tests / advanced usage.
AppSource._api_get = api_get
AppSource._cm_get = cm_get
AppSource._get_pool = get_pool
AppSource._save_pool = save_pool
AppSource.HOST_API = HOST_API

return AppSource
