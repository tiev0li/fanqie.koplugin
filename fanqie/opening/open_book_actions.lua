-- fanqie/opening/open_book_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local UIManager = require("ui/uimanager")
local Content = require("fanqie.content")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local Patches = require("patches.core")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state
local display_error = Runtime.display_error
local getCachedChapters = Runtime.getCachedChapters

local M = {}

-- ===========================================================================
-- Book opening (from bookshelf or direct)
-- ===========================================================================

-- 用缓存目录进入阅读（离线模式或网络获取失败时的回退路径）
function M:_openBookWithCache(book, cached_chapters)
    if not cached_chapters or #cached_chapters == 0 then return end
    UIManager:scheduleIn(0.1, function()
        getCachedChapters(self, book)
    end)
    -- 从 book.item_id（书架中的上次阅读章节）找起始索引
    local start_index = 1
    if book.item_id then
        local target_item_id = tostring(book.item_id)
        for idx, ch in ipairs(cached_chapters) do
            if tostring(ch.itemId or ch.item_id) == target_item_id then
                start_index = idx
                break
            end
        end
    end
    -- 🔴 本地更靠后的进度压过书架缓存（离线阅读回跳修复）：`book.item_id` 只表示
    --    云端/书架进度（本地从不写），离线读过的章节全在 pending 落盘里 ——
    --    不比一下就会跳回上次联网时的章。与 openBook 有网分支同口径。
    local local_idx = _state.localLatestChapterIndex(book.book_id, #cached_chapters)
    if local_idx and local_idx > start_index then
        start_index = local_idx
    end
    -- 如果上次阅读的章节没有缓存，向后找第一个有缓存的章节
    local chapter_cache = Content.load_cache_index(self.settings, book.book_id)
    if chapter_cache then
        local start_item_id = tostring(cached_chapters[start_index].itemId or cached_chapters[start_index].item_id or "")
        if not chapter_cache[start_item_id] then
            if Log then Log.info("openBook: last read chapter not cached, finding next cached") end
            for idx = start_index, #cached_chapters do
                local item_id = tostring(cached_chapters[idx].itemId or cached_chapters[idx].item_id or "")
                if chapter_cache[item_id] then
                    start_index = idx
                    break
                end
            end
        end
    end
    if Log then Log.info("openBookWithCache: start_index=" .. start_index) end
    if self._pending_position_conflict
            and tostring(self._pending_position_conflict.local_position.book_id) == tostring(book.book_id) then
        local conflict = self._pending_position_conflict
        self._pending_position_conflict = nil
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = string.format(_("本地在第 %s 章，云端在第 %s 章。使用哪一个？"),
                conflict.local_position.chapter_index, conflict.cloud_position.chapter_index),
            ok_text = _("继续本地"), cancel_text = _("使用云端"),
            ok_callback = function() self:openChapter(book, cached_chapters, conflict.local_position.chapter_index) end,
            cancel_callback = function() self:openChapter(book, cached_chapters, conflict.cloud_position.chapter_index) end,
        })
        return
    end
    self:openChapter(book, cached_chapters, start_index)
end

-- 后台静默刷新目录：开书走了缓存快路径后，仍在后台拉一次云端目录与阅读进度，
-- 让新章节与「在 App 上读到更靠后」这两件事不被错过。
-- 失败或拉到空（如 Cookie 过期）一律静默保留旧缓存，不打断阅读。
-- @param old_count number 开书时手里缓存目录的章数（用于提示新增章节）
function M:_refreshCatalogInBackground(book, old_count)
    if self._catalog_refreshing then return end
    self._catalog_refreshing = true
    local client = self.client
    local settings = self.settings
    local book_id = book.book_id
    local pull_progress = settings:get("sync", {}).pull_on_open ~= false

    Async.run(function()
        local b = { book_id = book_id }
        local fetched = Content.fetch_catalog(client, b)
        local progress = nil
        if pull_progress then
            local ok_p, p = pcall(function() return client:fetch_read_progress() end)
            if ok_p then progress = p end
        end
        return { chapters = fetched, progress = progress }
    end, function(ok, result, err)
        self._catalog_refreshing = false
        if not ok or type(result) ~= "table" then
            if Log then Log.warn("catalog bg: refresh failed, keep old cache", tostring(err)) end
            return
        end
        local chapters = result.chapters
        if not chapters or #chapters == 0 then
            if Log then Log.warn("catalog bg: fetched empty chapters, keep old cache") end
            return
        end

        -- 新目录落缓存（不回填 current_chapters，避免阅读中索引错位）
        Content.save_catalog_cache(settings, book_id, chapters)
        _state.setDirectoryCache(book_id, chapters)
        -- 追更中心：开书后台刷新拿到的目录也记一次观察（首轮建基线）
        if self.library then
            pcall(self.library.catalog_observation, self.library, book_id, chapters, book.status)
        end

        -- 🔴 v2.16.21：新章节必须**并进 `current_chapters`**，否则阅读中
        --    「到末页自动下一章」用的还是开书那一刻的旧目录 —— 旧目录末章之后
        --    `chapters[idx + 1]` 是 nil，`navigateToChapter` 直接 return
        --    「章节不存在」，用户看到的就是「点开始阅读后不能自动下载最新一章」。
        --    ⚠️ 合并方式是**按 itemId 追加尾部**，绝不整体替换：
        --    ① 替换会让 `current_chapter_index` 指向错位的章（云端目录顺序可能
        --       与本地缓存不同，甚至中间插入/删除了章节）；
        --    ② 只在「云端目录的前 N 项与本地完全一致」时才认为可以安全追加，
        --       不一致就整段放弃（宁可这次不更新，也不能让正在读的章错位）。
        --    这也是「老书缓存目录短、云端多了新章」这个最常见场景。
        local added = 0
        local cur = _state.current_chapters
        local same_book = false
        if type(cur) == "table" and #cur > 0 then
            -- 🔴 归属必须由**文档路径**反查，不能看 `_state.current_book`：
            --    openBook 一进来就把它换成了新书（后台刷新期间用户可能已经
            --    切到另一本书），拿它判「正在读的是不是这本书」会把别的书的
            --    目录并进来。与 localLatestChapterIndex 同口径。
            local doc_path = _state.current_document_path
            if doc_path and _state.book_id_from_path
                    and tostring(_state.book_id_from_path(doc_path)) == tostring(book_id) then
                same_book = true
            elseif not doc_path and self:isCurrentDocFanqie() then
                same_book = true
            end
        end
        if same_book then
            local prefix_ok = #chapters >= #cur
            if prefix_ok then
                for i = 1, #cur do
                    local a = tostring(cur[i].itemId or cur[i].item_id or "")
                    local b2 = tostring(chapters[i].itemId or chapters[i].item_id or "")
                    if a ~= b2 then prefix_ok = false break end
                end
            end
            if prefix_ok then
                -- ⚠️ 原地追加（cur[i] = ...）是对的：current_chapters 就是
                --    阅读器持有的那张表，必须同一个对象才能让「下一章」看到新章。
                --    E5 用例暴露过一个测试侧的坑：若测试让 cur 指向全局共享的
                --    目录常量，原地追加会把那个常量一起改大 —— 生产代码里
                --    current_chapters 永远是 load_catalog_cache 新建的表，不存在
                --    这个共享问题；回归里则必须按真实时序先过一遍 openChapter。
                for i = #cur + 1, #chapters do
                    cur[i] = chapters[i]
                    added = added + 1
                end
                if added > 0 and Log then
                    Log.info("catalog bg: appended " .. tostring(added)
                        .. " new chapters to current_chapters (now " .. tostring(#cur) .. ")")
                end
            elseif Log then
                Log.info("catalog bg: catalog prefix changed, skip current_chapters merge")
            end
        end

        -- 云端进度比本机更靠后：记到 cloud_ahead，下次开书定位生效
        if result.progress and result.progress.data then
            for _, item in ipairs(result.progress.data) do
                if tostring(item.book_id or item.bookId) == tostring(book_id) then
                    local target_item_id = tostring(item.item_id or item.itemId or "")
                    if target_item_id ~= "" then
                        local cloud_idx = nil
                        for idx, ch in ipairs(chapters) do
                            if tostring(ch.itemId or ch.item_id) == target_item_id then
                                cloud_idx = idx
                                break
                            end
                        end
                        -- skip_cloud=true：别把已有标记算进「本机进度」跟自己比
                        local local_idx = _state.localLatestChapterIndex(book_id, #chapters, true)
                        local record = self.library and self.library:get(book_id)
                        local local_position = record and record.position
                        if not local_position and local_idx then
                            local_position = { book_id = book_id, chapter_index = local_idx,
                                item_id = chapters[local_idx] and chapters[local_idx].itemId }
                        end
                        local cloud_position = require("fanqie.reading_session").cloud_position(
                            book_id, target_item_id, chapters, item, item.read_timestamp)
                        local conflict = require("fanqie.reading_session").conflict(local_position, cloud_position)
                        if conflict and self.settings:get("sync", {}).ask_on_conflict ~= false
                                and not self._pending_position_conflict then
                            self._pending_position_conflict = conflict
                            if self:isCurrentDocFanqie() then
                                self:showInfo(_("发现不同的云端阅读位置，下次进入本书时可以选择"))
                            end
                        elseif cloud_idx and (not local_idx or cloud_idx > local_idx) then
                            _state.markCloudAhead(book_id, cloud_idx)
                        end
                    end
                    break
                end
            end
        end

        -- 新增章节：只提示一次，不弹目录
        local reported = old_count and (#chapters - old_count) or 0
        if reported > 0 and self:isCurrentDocFanqie() then
            self:showInfo(T(_("目录已更新：新增 %1 章"), reported))
        end
    end, { poll_interval = 0.3, timeout = 30, tag = "catalog_bg" })
end

function M:_chooseReadingPosition(book, chapters, start_index, progress, open)
    local Session = require("fanqie.reading_session")
    local cloud
    if progress and progress.data then
        for _, item in ipairs(progress.data) do
            if tostring(item.book_id or item.bookId) == tostring(book.book_id) then
                cloud = Session.cloud_position(book.book_id, item.item_id or item.itemId,
                    chapters, item, item.read_timestamp)
                break
            end
        end
    end
    local record = self.library and self.library:get(book.book_id)
    local conflict = Session.conflict(record and record.position, cloud)
    if not conflict or self.settings:get("sync", {}).ask_on_conflict == false then
        open(start_index)
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    local T = require("ffi/util").template
    local function label(p)
        local title = chapters[p.chapter_index] and chapters[p.chapter_index].title or p.item_id
        return T(_("第 %1 章 %2（%3%%）"), p.chapter_index, title or "",
            math.floor((p.chapter_progress or 0) * 100))
    end
    UIManager:show(ConfirmBox:new{
        text = _("本地和云端阅读位置不同，要继续哪一个？") .. "\n\n"
            .. _("本地：") .. label(conflict.local_position) .. "\n"
            .. _("云端：") .. label(conflict.cloud_position),
        ok_text = _("继续本地"), cancel_text = _("使用云端"),
        ok_callback = function() open(conflict.local_position.chapter_index) end,
        cancel_callback = function() open(conflict.cloud_position.chapter_index) end,
        other_buttons = {{ { text = _("取消"), callback = function() end } }},
    })
end

function M:openBook(book)
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = true
    end
    _state.current_book = book

    -- 先尝试目录缓存（本地 IO，不阻塞）
    local cached_chapters = Content.load_catalog_cache(self.settings, book.book_id)
    local has_cache = cached_chapters and #cached_chapters > 0

    -- 无缓存 + 无网络：提示用户联网
    if not has_cache and not self:checkNetwork() then
        return
    end

    -- 有缓存 + 无网络：离线模式，直接用缓存打开，跳过云端进度同步
    if has_cache and not self:checkNetwork() then
        if Log then Log.info("openBook: offline mode, using cached chapters") end
        self:_openBookWithCache(book, cached_chapters)
        return
    end

    -- 有缓存 + 有网络：缓存快路径 —— 先立即进阅读，后台静默刷新目录。
    -- 旧策略是「有网必等云端目录」，每次开书都要白等一轮网络；
    -- 新章节靠后台刷新写缓存，云端更靠后的进度由 _refreshCatalogInBackground
    -- 记到 cloud_ahead，下次开书定位时生效。
    if has_cache then
        if Log then Log.info("openBook: cache fast path, background refresh") end
        self:_openBookWithCache(book, cached_chapters)
        self:_refreshCatalogInBackground(book, #cached_chapters)
        return
    end

    -- 有网络（无论是否有缓存）：子进程获取目录（缓存未命中时）+ 阅读进度
    self:showBusy(_("正在获取目录..."))
    local client = self.client
    local settings = self.settings
    local book_id = book.book_id
    local pull_progress = settings:get("sync", {}).pull_on_open ~= false

    Async.run(function()
        -- 子进程：始终拉取最新目录（有缓存也刷新，获取新章节）；按设置拉取阅读进度
        local b = { book_id = book_id }
        local fetched = Content.fetch_catalog(client, b)
        local progress = nil
        if pull_progress then
            local ok_p, p = pcall(function() return client:fetch_read_progress() end)
            if ok_p then progress = p end
        end
        -- 多值打包成 table（Async.run work_func 只能返回单值）
        return { chapters = fetched, progress = progress }
    end, function(ok, result, err)
        self:closeBusy()
        if not ok or type(result) ~= "table" then
            -- 获取失败：有缓存则回退到缓存进入阅读
            if has_cache then
                if Log then Log.warn("openBook: fetch failed, fallback to cached chapters") end
                self:_openBookWithCache(book, cached_chapters)
                return
            end
            self:showError(T(_("获取目录失败:\n%1"), display_error(err or result)))
            return
        end

        -- 优先用子进程新拉取的目录，回退到缓存
        local chapters = result.chapters or (has_cache and cached_chapters or nil)
        if not chapters or #chapters == 0 then
            -- 新目录为空（可能 cookie 过期）：有缓存则回退
            if has_cache then
                if Log then Log.warn("openBook: fetched empty chapters, fallback to cache") end
                self:_openBookWithCache(book, cached_chapters)
                return
            end
            self:showInfo(_("未获取到章节"))
            return
        end

        -- 持久化新拉取的目录（缓存命中时不重复写）
        if result.chapters and #result.chapters > 0 then
            Content.save_catalog_cache(settings, book_id, result.chapters)
            _state.setDirectoryCache(book_id, result.chapters)
            if self.library then
                pcall(self.library.catalog_observation, self.library, book_id, result.chapters, book.status)
            end
        end

        UIManager:scheduleIn(0.1, function()
            getCachedChapters(self, book)
        end)

        -- 从云端进度中找到起始章节
        local start_index = 1
        if result.progress and result.progress.data then
            for _, item in ipairs(result.progress.data) do
                if tostring(item.book_id or item.bookId) == tostring(book_id) then
                    local target_item_id = tostring(item.item_id or item.itemId)
                    if target_item_id and target_item_id ~= "" then
                        for idx, ch in ipairs(chapters) do
                            if tostring(ch.itemId or ch.item_id) == target_item_id then
                                start_index = idx
                                break
                            end
                        end
                    end
                    break
                end
            end
        end

        -- 云端进度未命中当前书籍时，回退到 book.item_id（书架中的上次阅读章节）
        if start_index == 1 and book.item_id then
            local target_item_id = tostring(book.item_id)
            for idx, ch in ipairs(chapters) do
                if tostring(ch.itemId or ch.item_id) == target_item_id then
                    start_index = idx
                    break
                end
            end
            if start_index > 1 and Log then
                Log.info("openBook: cloud progress miss, fallback to book.item_id, start_index=" .. start_index)
            end
        end

        -- 🔴 本地更靠后的进度压过云端（离线阅读回跳修复）：离线读到 103 章时
        --    云端/书架缓存还停在 100，只看云端就会跳回 100 章。取 max 两头都不丢 ——
        --    反过来云端更新（比如在 App 上读到 105）时仍是云端赢。
        local local_idx = _state.localLatestChapterIndex(book_id, #chapters)
        if local_idx and local_idx > start_index then
            start_index = local_idx
        end

        if start_index > #chapters then
            start_index = 1
        end

        self:_chooseReadingPosition(book, chapters, start_index, result.progress, function(idx)
            self:openChapter(book, chapters, idx)
        end)
    end, { poll_interval = 0.3, timeout = 60 })
end

return M
