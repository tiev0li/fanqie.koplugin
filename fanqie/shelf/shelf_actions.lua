-- fanqie/shelf/shelf_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local UIManager = require("ui/uimanager")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local CoverCache = require("fanqie.cover_cache")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state

local M = {}

function M:_coverCacheUsable(path)
    if not (H and H.file_exists(path)) then return false end
    if not CoverCache then return true end
    local days = self.settings.get_cover_cache_days and self.settings:get_cover_cache_days()
    return CoverCache.is_fresh(path, days)
end

-- 书架菜单是否**真的还显示在屏幕上**。
-- 🔴 这是「点开始阅读却被弹回书架」的最后一道门：书架的显示会触发一次后台刷新，
--    网络回来时用户可能已经进了阅读器 / 关了书架。此时只要还有 `book_list_menu`
--    引用就重建菜单，等于凭空把书架盖到阅读器上面。
--    以 UIManager 窗口栈为准（`H.widget_shown`），引用本身不可信。
--    `ignore_reader`：阅读器即将关闭（返回书架），它已经被排除在外，
--    此时书架自己就是唯一窗口 —— 仍然算「在屏幕上」。
function M:_shelfMenuVisible(ignore_reader)
    local menu = self.book_list_menu
    if type(menu) ~= "table" then return nil end
    if menu._miu_closed then return nil end
    if H and H.widget_shown then
        if H.widget_shown(menu) then return menu end
        if not ignore_reader then return nil end
        -- 还在阅读器里时菜单不在栈上；「看不见的菜单」不能当可见处理。
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        if not (ok_rui and RUI and RUI.instance) then return nil end
        return menu
    end
    return menu
end

-- 开书架菜单时保证书架底下还有一层**能独立存在的**窗口。
--
-- 🔴 从阅读器「返回书架」后阅读器就关了，书架很容易成为窗口栈里唯一的一项。
--    而 KOReader 在栈空时会直接退出 App（UIManager 主循环里的 `_gated_quit`）：
--      · 点书架右上角 X → 栈空 → **App 退出**；
--      · 点「开始阅读」→ 章节需要下载时先关书架 → 栈空 → 下载回来时进程已没了。
--    垫一层文件管理器就都变成「回到文件管理器 / 下载照常进行」。
--    用户已确认：从返回书架进入后点 X 应该回文件管理器。
--
-- 🔴 判据必须是「栈里还有**能独立存在的**全屏窗口」（文件管理器 / 阅读器），
--    不能是「栈里还有别的窗口」：阅读器的菜单容器（TouchMenu）、InfoMessage
--    之类都随时会被关掉，把它们当垫底等于没垫 —— 实测点 X 依旧退到桌面
--    （logcat 里 `UIManager: No dialogs left to show` → `Stopping KOReader main activity`）。
function M:_ensureShelfBackdrop(reader_closing)
    if not (UIManager and UIManager._window_stack) then return end
    local shown = H and H.widget_shown or function() return false end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local ok_rui, RUI = pcall(require, "apps/reader/readerui")
    -- 阅读器在栈上：关书架会回到阅读器，不会退 App（阅读端菜单「书架」这条）。
    -- reader_closing：调用方马上就要关掉阅读器（「返回书架」），
    -- 此时阅读器**不能**算垫底，必须在它底下真的放一层文件管理器。
    if not reader_closing and ok_rui and RUI and shown(RUI.instance) then return end
    if not ok_fm or not FileManager then return end
    local fm = FileManager.instance
    if fm and shown(fm) then return end
    if fm then
        -- 实例还在、只是不在栈上（从阅读器进来时它已被 onShowingReader 关掉）。
        pcall(function() UIManager:show(fm) end)
        return
    end
    -- showFiles 在同一个 UI tick 内返回，不会先画出文件管理器再画书架。
    pcall(function() FileManager:showFiles() end)
end

function M:showBookList(books, opts)
    opts = opts or {}
    -- refresh = 这次调用来自「后台刷新回来」的异步回调，不是用户主动打开书架。
    -- 🔴 判定「书架不在屏幕上就不建窗口」只能看它：用户打开书架 → 进阅读器 →
    --    刷新回来时，`book_list_menu` 引用可能还在（菜单还没被回收），
    --    凭引用重建就是把书架盖到阅读界面上。
    local from_refresh = opts.refresh == true
    -- 封面缓存每天最多清一次（见 cover_cache.maybe_auto_prune）。放在**建菜单之前**：
    -- 菜单一旦建起来，这一屏的 ImageWidget 就持有具体的封面路径了，那时删文件会画出空白格。
    if CoverCache then
        local ok_prune, prune_result = pcall(CoverCache.maybe_auto_prune,
            self.settings, self:_coverCacheDirs())
        -- 跟本次 TTL 维护同一次扫描，且只在拿到非空完整书架时回收孤儿。
        -- 空/失败结果在 bookshelf.lua 已被挡住，不会走到这里清空目录。
        if ok_prune and type(prune_result) == "table" and #books > 0 then
            pcall(CoverCache.prune_shelf_orphans, self.settings, books)
        end
    end

    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end

    for _, book in ipairs(books) do
        if book.cover then
            -- 命名规则统一交给 cover_cache：新名 <book_id>.jpg，
            -- 找不到时回退旧名 <书名>.jpg（兼容已下载的旧缓存，不强制重下）
            -- 🔴 CoverCache 是 safe_require，可返回 nil（模块装载失败）——
            --    三个直接调用点都必须有退化路径（_verify_batch_b B2 场景守的正是这个）。
            local cover_path
            if CoverCache then
                cover_path = CoverCache.find(self.settings, book, function(path)
                    return self:_coverCacheUsable(path)
                end)
            elseif type(book.title) == "string" and book.title ~= "" then
                cover_path = cover_cache_dir .. "/"
                    .. string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
            end
            -- 过期封面**当没有**处理：下面 _preloadAllCovers 会重下并覆盖同名文件
            if cover_path and self:_coverCacheUsable(cover_path) then
                book.cover_path = cover_path
            end
        end
    end

    local ShelfView = require("fanqie.shelf_view")
    self._shelf_books = books

    -- Wi-Fi 自动追更：间隔已到才触发（update_center.auto_update 内部有节流闸门，
    -- 不联网/离线模式/未到间隔都会静默跳过，绝不主动开 Wi-Fi）。
    pcall(function()
        require("fanqie.update_center").auto_update(self, books)
    end)

    -- ① 书架已经在屏幕上（后台刷新回来 / 原地刷新）：**不要关掉重建**。
    --    关掉再建会：丢掉滚动位置、闪一次全屏、并且把菜单重新压到栈顶
    --    （用户如果在刷新的这一两秒里点了「开始阅读」，书架就会盖住阅读器）。
    --    switchItemTable 保留当前页码，封面链继续按新表工作。
    local existing = self:_shelfMenuVisible()
    if existing then
        self:_cancelCoverLoading()
        local ok_update, err_update = pcall(function()
            ShelfView.update(existing, books)
        end)
        if ok_update then
            _state.active_menu = existing
            self:_preloadAllCovers(books)
            return existing
        end
        if Log and Log.error then
            Log.error("shelf in-place update failed, rebuilding:", tostring(err_update))
        end
    end

    -- ② 书架不在屏幕上（用户已经进阅读器 / 关了书架 / 切到别的界面）：
    --    只更新数据与缓存，绝不在这里新建窗口。
    --    —— 这正是「点阅读，自动返回书架，刷新书架」的根因。
    local in_reader = false
    local ok_rui, RUI = pcall(require, "apps/reader/readerui")
    if ok_rui and RUI and RUI.instance then in_reader = true end
    if from_refresh and (in_reader or self._shelf_dismissed) then
        if Log then Log.info("showBookList: shelf not on screen, data updated only") end
        return nil
    end

    -- ③ 新建（用户主动打开书架 / 书架从未创建过）。
    --    🔴 先清 _shelf_dismissed：这次是**显式要书架**，之前那次关闭不该再挡着。
    --    调用方已经保证「不是一次迟到的后台刷新」（那样会走 ①② 或直接被拦下）。
    self._shelf_dismissed = false
    -- 书架即将成为顶层窗口：先确保底下有文件管理器垫着（见 _ensureShelfBackdrop）。
    pcall(function() self:_ensureShelfBackdrop() end)
    return self:_createShelfMenu(books)
end

-- 书架菜单的创建（含它自己的打开/关闭簿记）。
-- ⚠️ 只从 showBookList 调用。
function M:_createShelfMenu(books)
    local ShelfView = require("fanqie.shelf_view")
    local menu = ShelfView.show{
        title = _("番茄书架"),
        books = books,
        show_covers = true,
        -- 刷新后保留搜索关键字；plugin 供排序/搜索对话框读写 settings
        filter_text = self._shelf_opts and self._shelf_opts.filter_text or nil,
        -- 回到上次停留的页码：「开始阅读 → 返回书架」时不要跳回第 1 页。
        -- 只记住**用户可感知**的页码，切换排序/搜索时由那些流程自行重置。
        -- ⚠️ 页码存在模块状态 `_state.shelf_page`：插件实例每次开书/切章都会重建，
        --    实例字段挺不过「进阅读器 → 返回书架」这一趟（见 state.lua 的说明）。
        page = tonumber(_state.shelf_page) or 1,
        plugin = self,
        on_select = function(book)
            self:_cancelCoverLoading()  -- 进入书籍时停止封面预下载，释放带宽给章节预下载
            self:showBookDetail(book)
        end,
        -- 长按条目：单本书快捷菜单（开始阅读 / 章节目录 / 清空本书缓存），
        -- 不打断「点按 = 打开详情」。README「书架操作」早就承诺了这个菜单。
        on_hold = function(book)
            self:showShelfHoldMenu(book)
        end,
        on_close = function()
            -- 🔴 关掉书架 = 用户不要这本书架了：此后任何后台刷新结果都只更新数据，
            --    不许再把书架弹回来（「点阅读自动回书架」的另一条路径）。
            self._shelf_dismissed = true
            self:_cancelCoverLoading()
            self.book_list_menu = nil
            _state.active_menu = nil
        end,
        on_refresh = function()
            self:showBookshelf({ force_refresh = true })
        end,
        on_page_changed = function(page, first, last, current)
            _state.shelf_page = tonumber(page) or 1
            self:_onShelfPage(current, page, first, last)
        end,
    }
    self.book_list_menu = menu
    -- 把菜单上的 opts 也交给插件保存：排序/搜索原地重刷后，关键字要能被下次刷新继承
    if menu and menu._shelf_opts then
        self._shelf_opts = menu._shelf_opts
    end
    _state.active_menu = menu

    -- 🔴 构造表里的 `page =` **不生效**：Menu:init 无条件执行 `self.page = 1`
    --    （koreader/frontend/ui/widget/menu.lua），随后那次 updateItems 已经按第 1 页
    --    画完了。所以「返回书架停在上次那页」必须在创建后显式 onGotoPage，
    --    与目录 showChapterListing 的做法一致。
    local initial_page = tonumber(_state.shelf_page) or 1
    if menu and initial_page > 1 then
        pcall(function() menu:onGotoPage(initial_page) end)
    end

    -- 后台批量预下载所有未缓存的封面（串行，避免阻塞 UI）
    self:_preloadAllCovers(books)
    return menu
end

function M:_cancelCoverLoading()
    self._cover_generation = (tonumber(self._cover_generation) or 0) + 1
    self._cover_preload_generation = (tonumber(self._cover_preload_generation) or 0) + 1
end

-- ⚠️ 页面封面缓存按**当前显示条目**取书（view.item_table[index]），
-- 不能再用 books[index]：书架支持排序与搜索后，显示顺序与 books 下标会错位，
-- 那样会把封面下到别的书上（甚至越界）。
function M:_onShelfPage(view, page, first, last)
    -- 只取消翻页级的封面下载，不影响 _preloadAllCovers 的全量预下载
    self._cover_generation = (tonumber(self._cover_generation) or 0) + 1
    local generation = self._cover_generation
    self:_cacheShelfPageCovers(view, page, first, last, generation, first)
end

function M:_cacheShelfPageCovers(view, page, first, last, generation, index)
    index = index or first
    if generation ~= self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1) ~= tonumber(page) then
        return
    end
    if index > last then return end

    local entry = view.item_table and view.item_table[index]
    -- 排序/搜索原地重刷后 item_table 会换新表，优先用条目回指的 book
    local book = (entry and entry.book) or (self._shelf_books and self._shelf_books[index])
    local function next_index()
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(view, page, first, last, generation, index + 1)
        end)
    end

    if not book or not book.cover or book.cover == "" then
        next_index()
        return
    end

    if book.cover_path then
        next_index()
        return
    end

    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end
    local cover_path, existing
    if CoverCache then
        cover_path = CoverCache.path(self.settings, book)
        if not cover_path then next_index() return end
        existing = CoverCache.find(self.settings, book, function(path)
            return self:_coverCacheUsable(path)
        end)
    else
        -- CoverCache 不可用：退回旧的书名命名（无 TTL，只查存在性）
        cover_path = cover_cache_dir .. "/"
            .. string.gsub(book.title or "", "[/\\:%*%?\"<>|]", "_") .. ".jpg"
        if self:_coverCacheUsable(cover_path) then existing = cover_path end
    end

    -- 把封面路径回填到当前页 UI（缓存命中与子进程下载完成共用同一段逻辑）
    local function apply_cover(path)
        book.cover_path = path
        local changed = false
        for _, entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id) == tostring(book.book_id or book.bookId) then
                if entry.cover_path ~= path then
                    entry.cover_path = path
                    changed = true
                end
                break
            end
        end
        if changed then
            view._suppress_page_callback = true
            pcall(view.updateItems, view, nil, true)
            view._suppress_page_callback = false
        end
    end

    if existing then
        apply_cover(existing)
        next_index()
        return
    end

    -- 子进程下载封面并写盘，UI 线程零阻塞。
    -- 此前这里是同步的 self.client:get_binary()，翻页时每本书一次阻塞 HTTP + 写盘 → 明显卡顿。
    -- tag 与 _preloadAllCovers 共用 "covers"：页级缓存与全量预下载同属封面链，一并取消。
    local url = book.cover
    local client = self.client
    if not (Async and Async.run) then
        next_index()
        return
    end
    Async.run(function()
        local data = client:get_binary(url)
        local file = io.open(cover_path, "wb")
        if file then
            file:write(data)
            file:close()
            return cover_path
        end
        return nil
    end, function(ok, result, err)
        if generation ~= self._cover_generation or not view or view._miu_closed then return end
        if ok and result then
            apply_cover(result)
        elseif Log then
            Log.debug("page cover download failed:", tostring(book.book_id or book.bookId), tostring(err or result))
        end
        next_index()
    end, { poll_interval = 0.125, timeout = 30, tag = "covers" })
end

-- 后台批量预下载所有未缓存的封面（子进程执行，不阻塞 UI）
-- 使用独立的 _cover_preload_generation，不受翻页取消影响
function M:_preloadAllCovers(books)
    self._cover_preload_generation = (tonumber(self._cover_preload_generation) or 0) + 1
    local generation = self._cover_preload_generation
    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end
    local view = self.book_list_menu
    local client = self.client

    -- 更新 UI 中指定 book_id 的封面路径
    local function update_ui_cover(book_id, cover_path)
        if not view or view._miu_closed then return end
        local changed = false
        for _, entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id) == tostring(book_id) then
                if entry.cover_path ~= cover_path then
                    entry.cover_path = cover_path
                    changed = true
                end
                break
            end
        end
        if changed then
            view._suppress_page_callback = true
            pcall(view.updateItems, view, nil, true)
            view._suppress_page_callback = false
        end
    end

    local function preload_one(idx)
        if generation ~= self._cover_preload_generation then return end
        if not view or view._miu_closed then return end
        if idx > #books then return end

        local book = books[idx]
        if not book or not book.cover or book.cover == "" then
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        -- 已有缓存路径，跳过
        if book.cover_path then
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        local cover_path, existing
        if CoverCache then
            cover_path = CoverCache.path(self.settings, book)
            if not cover_path then
                UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
                return
            end
            existing = CoverCache.find(self.settings, book, function(path)
                return self:_coverCacheUsable(path)
            end)
        else
            -- CoverCache 不可用：退回旧的书名命名（无 TTL，只查存在性）
            cover_path = cover_cache_dir .. "/"
                .. string.gsub(book.title or "", "[/\\:%*%?\"<>|]", "_") .. ".jpg"
            if self:_coverCacheUsable(cover_path) then existing = cover_path end
        end
        local book_id = book.book_id or book.bookId

        -- 文件已存在且未过期，设置路径并更新 UI（过期就往下走重下）
        if existing then
            book.cover_path = existing
            update_ui_cover(book_id, existing)
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        -- 子进程下载封面并写入文件，UI 线程零阻塞
        local url = book.cover
        Async.run(function()
            -- fork 继承 client/settings，子进程内同步下载并写文件
            local data = client:get_binary(url)
            local file = io.open(cover_path, "wb")
            if file then
                file:write(data)
                file:close()
                return { path = cover_path, book_id = tostring(book_id) }
            end
            return nil
        end, function(ok, result, err)
            if generation ~= self._cover_preload_generation then return end
            if ok and result and result.path then
                book.cover_path = result.path
                update_ui_cover(result.book_id, result.path)
            end
            -- 继续下一本（子进程已退出，无残留资源）
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
        end, { poll_interval = 0.125, timeout = 30, tag = "covers" })
    end

    -- 延迟启动，给书架 UI 渲染让出时间
    UIManager:scheduleIn(0.5, function() preload_one(1) end)
end

-- ===========================================================================
-- 书籍详情（书架 / 书城共用）
-- ===========================================================================
-- 🔴 ButtonDialog **没有 `info_text` 字段**（KOREADER 上游事实，见
--    MEMORY-koreader-core「上游组件事实」）：`init()` 只渲染 `self.title`
--    与 `self._added_widgets`，传进去的 `info_text` 被**静默丢弃**
--    ⇒ 以前的书架/书城详情框里其实**一行书目信息都没显示**，用户只看到按钮。
--    所以：短摘要写进 `title`，长内容（简介全文）走「简介」按钮打开的可滚动页面。
--
-- 字段来源（v2.12.0）：书架接口（add_shelf_time/last_operate_time/asterisked）
--   + 详情接口 multidetail（书名/简介/总章数/更新状态/章节摘要）
--   + 阅读进度接口（item_id/index/read_timestamp）
-- 合并与格式化全在 fanqie/book_detail.lua（纯函数），本文件只负责摆按钮。

--- 阅读界面「书籍信息」：显示**当前正在读的这本番茄书**的详情（v2.17.0）。
--
-- 数据的取用按可靠性依次退让，**全程零网络**：
--   1. `_state.current_book` —— 从书架 / 书城打开时是完整记录；
--   2. `getCurrentBook()` —— 文档路径反推的书号（重启后从「最近阅读 /
--      文件管理器」直接打开章节续读时，这是唯一的书号来源）；
--   3. `findCachedBook()` —— 用**本地**书架缓存（内存缓存或 shelf_cache.lua）
--      把书名 / 作者 / 简介 / 进度补齐，和 ensureShelfSnapshot 同源，不发包。
--
-- 🔴 为什么不在第 3 步之后再去联网查一次详情：这个入口在阅读界面的菜单里，
--    菜单项的 callback 一旦阻塞在网络往返上，用户看到的就是「点了没反应」。
--    本地能补多少补多少，补不到就明说。

return M
