-- 追更中心：串行检查书架各书目录变化，快照进本地资料库。
-- 首轮只建基线；失败/空响应保留上次快照，不清数据。
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local Content = require("fanqie.content")
local Async = require("fanqie.async")
local Log = require("fanqie.logger")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state

local M = {}

--- 检查一本书的目录变化（同步，子进程内调用）。
-- @return table|nil 更新状态（library.update_state 口径）
function M.check_book(plugin, book)
    local book_id = book.book_id or book.bookId
    if not book_id then return nil end
    local b = { book_id = book_id }
    local ok, chapters = pcall(Content.fetch_catalog, plugin.client, b)
    if not ok or type(chapters) ~= "table" or #chapters == 0 then
        -- 诊断：区分「抛错」与「空目录」，记录真实错误（截断防刷屏）
        local why = not ok and ("err: " .. tostring(chapters):sub(1, 120))
            or ("empty: got " .. type(chapters) .. " len " .. tostring(type(chapters) == "table" and #chapters or -1))
        if Log and Log.warn then
            Log.warn("update_center: catalog failed for " .. tostring(book_id) .. " - " .. why)
        end
        return nil
    end
    plugin.library:catalog_observation(book_id, chapters, book.status)
    return plugin.library:update_state(book_id, #chapters)
end

--- 串行检查整个书架。UI 线程只轮询，不阻塞。
-- @param books table 书架记录列表
-- @param on_done function(ok, results) results: book_id -> update_state
function M.refresh(plugin, books, on_done)
    if not (plugin.library and books and #books > 0) then
        if on_done then on_done(false, {}) end
        return
    end
    local updates = plugin.settings:get("updates", {})
    if updates.enabled == false then
        if on_done then on_done(false, {}) end
        return
    end
    local results = {}
    local UIManager = require("ui/uimanager")
    local function process_next(i)
        if i > #books then
            if on_done then on_done(true, results) end
            return
        end
        local book = books[i]
        Async.run(function()
            return M.check_book(plugin, book)
        end, function(ok, result)
            if ok and type(result) == "table" then
                results[tostring(book.book_id or book.bookId)] = result
            end
            UIManager:scheduleIn(0, function() process_next(i + 1) end)
        end, { poll_interval = 0.3, timeout = 60, tag = "update_center" })
    end
    process_next(1)
end

--- 书架徽标：把资料库里的更新状态合并进书架记录（只加字段，不改原字段）。
function M.decorate(books, library)
    if not library then return books end
    for _, book in ipairs(books or {}) do
        local state = library:update_state(book.book_id or book.bookId)
        if state then
            book.update_unread = state.unread_count
            book.update_new = state.new_count
        end
    end
    return books
end

--- 检查间隔是否已到（自动预下载的节流闸门）。
function M.check_due(settings)
    local updates = settings:get("updates", {})
    if updates.enabled == false then return false end
    local interval = tonumber(updates.interval_minutes) or 60
    if interval <= 0 then return false end
    local last = tonumber(updates.last_auto_check_at) or 0
    return (os.time() - last) >= interval * 60
end

--- 通知能力探测：KOReader 版本带 Notification 才返回 true。
function M.notifications_available()
    local ok, Notification = pcall(require, "ui/widget/notification")
    if not ok or type(Notification) ~= "table" then return false end
    -- Notification 是类（模块表），notify 在类表上；用点访问避免把类当实例调用
    return type(Notification.notify) == "function"
end

--- 应用内或系统通知（按用户设置与能力降级）。
-- @return true=已发出（系统）/ false=仅应用内或未发
function M.notify(plugin, text)
    local updates = plugin.settings:get("updates", {})
    if not M.notifications_available() then return false end
    if updates.notifications ~= true then return false end
    local ok, Notification = pcall(require, "ui/widget/notification")
    if not ok then return false end
    pcall(function() Notification:notify(text) end)
    return true
end

--- Wi-Fi 下自动追更：书架打开时调用。只在「已联网 + 间隔已到 + 非离线模式」时
--- 触发一次后台检查；检查发现新章且用户开了 auto_download 才自动下载。
--- 🔴 绝不主动开 Wi-Fi（is_online 探测，不 isConnected-wifi 启用）。
--- 自动检查的候选书：按「最近阅读」优先，最多 auto_limit 本。
--- 🔴 为什么不全库检查：真机实测书架 358 本，逐本 fork 子进程 + 请求耗时约 6 分钟，
---    期间点书架/开书都会被拖住。自动检查只覆盖用户真正在读的书，全量留给
---    用户主动点「检查更新」。
function M.auto_candidates(plugin, books)
    local limit = tonumber(plugin.settings:get("updates", {}).auto_limit) or 20
    if limit <= 0 or limit >= #books then return books end
    local scored = {}
    for i, book in ipairs(books) do
        local record = plugin.library and plugin.library:get(book.book_id or book.bookId)
        local pos = record and record.position
        scored[#scored + 1] = {
            book = book,
            ts = (pos and tonumber(pos.updated_at)) or tonumber(book.read_timestamp) or 0,
            i = i,
        }
    end
    table.sort(scored, function(a, b)
        if a.ts ~= b.ts then return a.ts > b.ts end
        return a.i < b.i
    end)
    local out = {}
    for i = 1, math.min(limit, #scored) do out[i] = scored[i].book end
    return out
end

function M.auto_update(plugin, books)
    if not (plugin.library and books and #books > 0) then return end
    local settings = plugin.settings
    if settings:is_offline_mode() then return end
    if not M.check_due(settings) then return end
    local ok_net, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok_net or not NetworkMgr then return end
    local ok_online, online = pcall(function() return NetworkMgr:isOnline() end)
    if not ok_online or not online then return end
    -- 先记账再跑：检查期间书架又打开一次也不会重复触发
    local updates = settings:get("updates", {})
    updates.last_auto_check_at = os.time()
    settings:set("updates", updates)
    settings:flush()
    local candidates = M.auto_candidates(plugin, books)
    M.refresh(plugin, candidates, function(ok, results)
        if not ok then return end
        local new_books, new_total = 0, 0
        for _, state in pairs(results) do
            if (state.new_count or 0) > 0 then
                new_books = new_books + 1
                new_total = new_total + state.new_count
            end
        end
        if new_total <= 0 then return end
        M.notify(plugin, string.format(_("追更：%d 本书更新了 %d 章"), new_books, new_total))
        if settings:get("updates", {}).auto_download == true then
            M.download_updates(plugin, candidates)
        end
    end)
end

--- 下载全部更新：逐书串行，复用 Download.execute 的节流/跳过/取消。
function M.download_updates(plugin, books)
    local Download = require("fanqie.download")
    local queue = {}
    for _, book in ipairs(books or {}) do
        local state = plugin.library:update_state(book.book_id or book.bookId)
        if state and state.new_count > 0 then queue[#queue + 1] = book end
    end
    if #queue == 0 then
        plugin:showInfo(_("没有需要下载的更新"))
        return
    end
    local function next_book(i)
        if i > #queue then return end
        local book = queue[i]
        local chapters = Content.load_catalog_cache(plugin.settings, book.book_id)
        if not chapters or #chapters == 0 then
            next_book(i + 1)
            return
        end
        local state = plugin.library:update_state(book.book_id)
        local start = math.max(#chapters - (state and state.new_count or 0) + 1, 1)
        Download.execute(plugin, book, chapters, start, #chapters)
    end
    next_book(1)
end

return M
