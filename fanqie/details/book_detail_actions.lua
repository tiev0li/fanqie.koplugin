-- fanqie/details/book_detail_actions.lua —— 从 main.lua 按原函数边界拆分。
-- 方法名与实现保持原接口；共享依赖集中在 fanqie.runtime。

local function safe_require(name)
    local ok, module = pcall(require, name)
    if not ok then return nil end
    return module
end

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ffiutil = require("ffi/util")
local T = ffiutil.template

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local BookDetail = require("fanqie.book_detail")
local Content = require("fanqie.content")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local Async = require("fanqie.async")
local Store = require("fanqie.store")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state
local display_error = Runtime.display_error
local log_error = Runtime.log_error

local M = {}

function M:showCurrentBookInfo()
    local book = _state.current_book
    if type(book) ~= "table" or not book.book_id then
        local minimal = self:getCurrentBook()
        book = minimal
        if type(minimal) == "table" and minimal.book_id
            and type(self.findCachedBook) == "function" then
            local ok, found = pcall(self.findCachedBook, self, minimal.book_id)
            if ok and type(found) == "table" then
                book = found
            end
        end
    end
    if type(book) ~= "table" or not book.book_id then
        self:showInfo(_("无法确定当前书籍"))
        return
    end
    if not (book.title or book.book_name) then
        -- 本地也补不到（首次打开、书架缓存还没落盘）：把书号说出来，
        -- 好过弹一句干巴巴的「暂无书籍信息」。
        self:showInfo(T(_("暂无书籍信息（书号 %1）"), tostring(book.book_id)))
        return
    end
    self:showBookDetailPage(book, {})
end

--- 关闭「书籍详情」整页（唯一入口，避免连点叠两页）。
function M:closeBookDetailPage()
    local page = self._book_detail_page
    self._book_detail_page = nil
    if page then H.close_widget(page) end
end

--- 打开「书籍详情」整页：简介全文 + 合并出来的全部字段（可滚动）。
---@param book table
---@param opts table|nil { on_read = function|nil }
function M:showBookDetailPage(book, opts)
    opts = opts or {}
    if type(book) ~= "table" then return end
    if not BookDetail then
        self:showInfo(_("书籍详情组件不可用"))
        return
    end
    self:closeBookDetailPage()
    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    for _ in pairs(cached) do cache_count = cache_count + 1 end
    local lines = BookDetail.lines(book, { cache_count = cache_count })
    if #lines == 0 then lines = { _("暂无书籍信息") } end
    local text = table.concat(lines, "\n")

    if not TextViewer then
        self:showInfo(text)
        return
    end
    local buttons = {}
    if opts.on_read then
        buttons[#buttons + 1] = { {
            text = _("开始阅读"),
            callback = function()
                self:closeBookDetailPage()
                opts.on_read()
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("关闭"),
        callback = function() self:closeBookDetailPage() end,
    } }
    local page = TextViewer:new{
        title = tostring(book.title or book.book_name or _("书籍详情")),
        text = text,
        text_type = "book_info",
        justified = false,
        buttons_table = buttons,
        close_callback = function() self._book_detail_page = nil end,
    }
    self._book_detail_page = page
    UIManager:show(page)
end

--- 组装「书籍详情」按钮框（书架 / 书城共用）。
-- ⚠️ 一律走 `title` 显示摘要：`info_text` 是死键（见本节开头）。
--@param book table
--@param opts table {
--         on_shelf  = boolean|nil,  -- true=在书架（给「移出书架」）/ false=不在（给「加入书架」）/ nil=未知（不给书架按钮）
--         on_leave  = function|nil,  -- 「开始阅读 / 章节目录」之前的收尾（书城要顺手关掉书城菜单）
--         cache_ok  = boolean,       -- 是否给「清空本书缓存」（书架记录才有本地缓存概念）
--         now       = number|nil,    -- 注入的「当前时间」（测试用）
--       }
function M:buildBookDetailDialog(book, opts)
    opts = opts or {}
    if type(book) ~= "table" then return nil end
    self:_closeDetailDialog()

    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    for _ in pairs(cached) do cache_count = cache_count + 1 end

    local function leave()
        if opts.on_leave then pcall(opts.on_leave) end
    end

    local rows = {}

    -- 第 1 行：简介（整页）/ 开始阅读
    local row1 = {
        {
            text = _("简介"),
            callback = function()
                self:showBookDetailPage(book, { on_read = function()
                    self:_closeDetailDialog()
                    leave()
                    self:openBook(book)
                end })
            end,
        },
        {
            text = _("开始阅读"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                if _state.active_menu then
                    local menu = _state.active_menu
                    _state.active_menu = nil
                    H.close_widget(menu)
                end
                leave()
                self:openBook(book)
            end,
        },
    }
    rows[#rows + 1] = row1

    -- 第 2 行：章节目录 / 下载
    rows[#rows + 1] = {
        {
            text = _("章节目录"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                if _state.active_menu then
                    local menu = _state.active_menu
                    _state.active_menu = nil
                    H.close_widget(menu)
                end
                leave()
                self:showChapterListing(book)
            end,
        },
        {
            text = _("下载"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                -- 保留 active_menu（书架），后台运行关闭下载进度对话框后可回到书架
                -- 避免 UIManager 无 widget 导致 KOReader 退出
                self:_startBookDownload(book)
            end,
        },
    }

    -- 第 3 行：书架动作（**单颗**：由 shelf_check 判定后只给一个方向）。
    -- delete 是幂等的（不在书架也回成功）⇒ 两颗按钮一起给必然出现
    -- 「点「移出书架」→ 提示已移出书架」这种谎报，见 store_ui 的收敛说明。
    if opts.on_shelf ~= nil and type(self.toggleStoreShelf) == "function" then
        local want_add = (opts.on_shelf ~= true)
        rows[#rows + 1] = { {
            text = want_add and _("加入书架") or _("移出书架"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                self:toggleStoreShelf(book, want_add, opts.on_shelf_changed)
            end,
        } }
    end

    -- 第 4 行：清空缓存（仅书架记录）
    if opts.cache_ok ~= false and cache_count > 0 then
        rows[#rows + 1] = { {
            text = _("清空本书缓存"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("确定清空《%1》的缓存?\n%2 章节将被删除。"),
                        book.title or book.book_name or _("未知"), cache_count),
                    ok_text = _("清空"),
                    cancel_text = _("取消"),
                    ok_callback = function()
                        self.settings:clear_book_cache(book.book_id)
                        self:_closeDetailDialog()
                        UIManager:show(InfoMessage:new{ text = _("缓存已清空") })
                    end,
                })
            end,
        } }
    end

    rows[#rows + 1] = { {
        text = _("关闭"),
        callback = function()
            self:closeBookDetailPage()
            self:_closeDetailDialog()
        end,
    } }

    local ButtonDialog = require("ui/widget/buttondialog")
    local title = BookDetail and BookDetail.summary_title(book, { now = opts.now })
        or tostring(book.title or book.book_name or _("书籍详情"))
    if cache_count > 0 then
        title = title .. T(_(" · 缓存 %1 章"), tostring(cache_count))
    end
    _state.detail_dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(_state.detail_dialog)
    return _state.detail_dialog
end

--- 阅读界面：「加入 / 移出书架」当前这本书。
-- 🔴 必须先 `shelf_check` 再决定方向：`bookshelf/delete` 是**幂等**的
--    （不在书架也回 `{"code":0,"message":"SUCCESS"}`），不问就删会谎报
--    「已移出书架」；不问就加则可能重复加。判据只有一句：
--    `code == 0 and data == 1` = 在书架（39 字节，见 fanqie/fanqie.lua 的
--    shelf_check_url 注释与 .workbuddy/tools/_probe_shelf_check*.py）。
-- 移出是破坏性动作 ⇒ 给一次确认；加入直接做（可逆、无副作用）。
function M:toggleCurrentBookShelf()
    -- 走 getCurrentBook()：内存里没有就从文档路径反推（重启续读场景）。
    local book = self:getCurrentBook()
    if type(book) ~= "table" or not book.book_id then
        self:showInfo(_("无书籍信息"))
        return
    end
    if not (Store and Store.shelf_check) then
        self:showInfo(_("书城组件不可用"))
        return
    end
    if not self:checkNetwork() then return end
    local book_id = tostring(book.book_id)
    local client = self.client

    self:showBusy(_("正在查询书架状态…"))
    Async.run(function()
        -- 括号：Async 只回传第一个返回值，显式丢弃 err（失败时首值是 nil）
        return { on_shelf = (Store.shelf_check(client, book_id)) }
    end, function(ok, res)
        self:closeBusy()
        -- 🔴 不能写 `(ok and type(res) == "table") and res.on_shelf or nil`：
        --    Lua 的 `and/or` 链在**左值求值为 false** 时会掉进 `or nil`
        --    ⇒「不在书架」（on_shelf = false）被读成 nil ⇒ 误报「查询失败」，
        --      于是「加入书架」这条路径**永远走不到**（回归 G4 抓到）。
        --    必须显式判类型，别用 `or` 兜底布尔。store_ui.lua 的同名判断就是这个写法。
        local on_shelf
        if ok and type(res) == "table" and type(res.on_shelf) == "boolean" then
            on_shelf = res.on_shelf
        end
        if type(on_shelf) ~= "boolean" then
            self:showError(_("查询书架状态失败，请检查网络与 Cookie"))
            return
        end
        -- 这次查询就是一份确定结论 ⇒ 写进书架快照：菜单文案下一次打开即正确，
        -- 而且「退出阅读时是否提示加入书架」也就不用再查一遍（见 state.lua）。
        if _state and _state.markShelf then _state.markShelf(book_id, on_shelf) end
        if not on_shelf then
            if type(self.toggleStoreShelf) == "function" then
                self:toggleStoreShelf(book, true)
            else
                self:showInfo(_("书城组件不可用"))
            end
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("《%1》已在书架中，确定要移出吗？"),
                tostring(book.title or book.book_name or _("未知"))),
            ok_text = _("移出"),
            cancel_text = _("取消"),
            ok_callback = function()
                if type(self.toggleStoreShelf) == "function" then
                    self:toggleStoreShelf(book, false)
                end
            end,
        })
    end, {
        poll_interval = 0.3,
        timeout = 30,
        tag = "shelf_state",
        -- 取消后回调不执行：loading 必须在这里自己关
        on_cancel = function() pcall(function() self:closeBusy() end) end,
    })
end

--- 离开这本书时：若它**不在书架**，问一次「是否加入书架」。
--
-- 🔴 三个必须守住的边界（每一条都对应一个会真的踩到的场景）：
--
--    ① **切章也会走到这里**。调用点 `onCloseDocument` 在切章时同样触发
--       （`ReaderUI:doShowReader` 会先 `ReaderUI.instance:onClose()`）。
--       判据是「延后一拍看 `ReaderUI.instance` 是否还在」——
--       切章/换书路径在**同一个同步块**里就把新实例 `UIManager:show` 出去了
--       （中间不 yield），所以 nextTick 回调跑时 instance 已存在；而真退出
--       （onHome / 关闭阅读）走到 `ReaderUI.onCloseWidget`，那里把 instance 置 nil。
--       ⇒ 只有 instance 为 nil 才认为「用户真的离开了这本书」。
--
--    ② **不能每次退出都问**。同一本书读过 5 次被问 5 次谁受得了 ——
--       按书号记「已问过」（`_state.shelf_prompted`）。这是**进程内**节流，
--       刻意不落盘：重启后重问一次的代价，远小于为此多维护一份持久化状态。
--
--    ③ **「未知」不等于「不在架」**。冷启动续读时快照可能还是未知（用户从没读过
--       书架列表）。此时**不能**凭猜测弹「加入书架」—— 在架的书会被问错方向。
--       所以：先同步补一次本地书架缓存（`ensureShelfSnapshot`，零网络），
--       还未知才发一次 `shelf_check`（39 B）；连查都查不到（离线）就静默放弃。
--       **不能确定方向，就不要打扰用户**。
-- @param was_open boolean  进入 onCloseDocument 时文档是否**确实已经打开**。
--   与 `_returnToShelfAfterClose` 同一条门控：「点开始阅读 → 子进程下载章节 →
--   showReaderUI」这段窗口里也会走到 CloseDocument，此时阅读器尚未建立，
--   不能当成「用户离开了这本书」，否则会在开书途中误弹「要加入书架吗」。
function M:_promptAddShelfOnLeave(was_open)
    if was_open ~= true then return end
    local book = self:getCurrentBook()
    if type(book) ~= "table" or not book.book_id then return end
    if not (_state and type(_state.shelfState) == "function") then return end
    local book_id = tostring(book.book_id)
    _state.shelf_prompted = _state.shelf_prompted or {}
    if _state.shelf_prompted[book_id] then return end
    -- 切章 / 换书不是「离开这本书」：用本地 switching_document 标志（见 showReaderUI）。
    if _state.switching_document then
        if Log then Log.info("shelf prompt skipped: chapter switch") end
        return
    end

    local self_ref = self

    local function ask(on_shelf)
        if on_shelf ~= false then return end   -- 在架 / 仍未知 ⇒ 不打扰
        -- 不论用户怎么选都记「问过」：点「不用了」就不该再被问第二次。
        _state.shelf_prompted[book_id] = true
        local title = tostring(book.title or book.book_name or book_id)
        UIManager:show(ConfirmBox:new{
            text = T(_("《%1》还没加入书架，要加入吗？"), title),
            ok_text = _("加入书架"),
            cancel_text = _("不用了"),
            ok_callback = function()
                if type(self_ref.toggleStoreShelf) == "function" then
                    -- 复用书城那条路径：它会 showBusy / 写快照 / 失效书架缓存
                    self_ref:toggleStoreShelf({ book_id = book_id, title = title }, true)
                end
            end,
        })
    end

    -- 「真的离开了阅读」：切章 / 换书时 instance 还在（见边界 ①）。
    -- 🔴 但切章的空窗里 instance 恰好是 nil（旧实例先关、新实例下一拍才建），
    --    所以还要看 switching_document（见 fanqie/state.lua 的说明）。
    --    否则读完一本不在架的书、自动跳到下一章时会被误问「要加入书架吗」。
    local function left_reading()
        if _state.switching_document then return false end
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        if ok_rui and RUI and RUI.instance then return false end
        return true
    end

    -- 未知 ⇒ 先同步补本地缓存（内存 → 文件，绝不联网），能补上就省一次请求。
    if _state.shelfState(book_id) == nil and type(self.ensureShelfSnapshot) == "function" then
        pcall(function() self:ensureShelfSnapshot() end)
    end
    local known = _state.shelfState(book_id)

    if known ~= nil then
        -- 已有确定结论：只等一拍确认「真的离开了阅读」。
        UIManager:nextTick(function()
            if left_reading() then ask(known) end
        end)
        return
    end

    -- 还是未知：等一拍确认离开阅读后，查一次（39 B），查到才问。
    UIManager:nextTick(function()
        if not left_reading() then return end
        if not (Store and Store.shelf_check) then return end
        if not self_ref:checkNetwork() then return end
        local client = self_ref.client
        Async.run(function()
            -- 括号：Async 只回传第一个返回值，显式丢弃 err（失败时首值是 nil）
            return { on_shelf = (Store.shelf_check(client, book_id)) }
        end, function(ok, res)
            local on_shelf
            if ok and type(res) == "table" and type(res.on_shelf) == "boolean" then
                on_shelf = res.on_shelf
                -- 结论写进快照：下次（同一次运行内）就不用再查了
                if _state.markShelf then _state.markShelf(book_id, on_shelf) end
            end
            ask(on_shelf)
        end, {
            poll_interval = 0.3,
            timeout = 15,
            -- 独立 tag：别让切章/关菜单的 cancel_tag 把这次查询掐掉
            tag = "shelf_prompt",
        })
    end)
end

-- 书籍详情对话框的**唯一**关闭入口。
-- 顺序很重要：先把 _state.detail_dialog 置 nil，再关那个对象。
--   · 置 nil 让所有「稍后再收尾」的路径（onClose / onCloseWidget / 菜单关闭回调）
--     都不会再碰它；
--   · H.close_widget 只在它**确实还在 UIManager 栈上**时才真关。
-- 这两点缺一不可：直接 `UIManager:close(已经关过的 dialog)` 会照常派发
-- CloseWidget 事件 → ButtonDialog:onCloseWidget 给自己排一次 flashui 全刷 →
-- 墨水屏上表现成「弹窗凭空闪一下」（而且刷新请求会挂到下一次翻页/切章才爆出来）。
function M:_closeDetailDialog()
    local dialog = _state.detail_dialog
    _state.detail_dialog = nil
    if dialog then H.close_widget(dialog) end
end

-- ===========================================================================
-- 番茄APP 内置源：搜索 / 发现
-- ===========================================================================

function M:showAppSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("搜索番茄书籍"),
        input = "",
        input_hint = _("书名 / 作者"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("搜索"),
                    is_enter_default = true,
                    callback = function()
                        local kw = dialog:getInputText()
                        UIManager:close(dialog)
                        if kw and H.trim(kw) ~= "" then
                            self:showAppSearchResults(H.trim(kw))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M:showAppSearchResults(keyword)
    self:showBusy(_("正在搜索..."))
    local client = self.client
    Async.run(function()
        return client:fanqie_app_search(keyword)
    end, function(ok, books, err)
        self:closeBusy()
        if not ok then
            self:showError(T(_("搜索失败:\n%1"), display_error(err or books)))
            return
        end
        self:showAppBookList(T(_("搜索: %1"), keyword), books)
    end, { delay = 0.1, poll_interval = 0.2, timeout = 30 })
end

-- 发现菜单：榜单 / 分类 / 频道 / 首页（数据来源同阅读 App 书源 exploreUrl）
function M:getAppExploreMenuItems()
    local AppSource = require("fanqie.appsource")
    local items = {}
    for _, section in ipairs(AppSource.explore_catalog()) do
        for _, entry in ipairs(section.items) do
            table.insert(items, {
                text = section.title .. " · " .. entry.title,
                keep_menu_open = false,
                callback = function()
                    self:showAppExploreResults(entry.title, entry.url, 1)
                end,
            })
        end
    end
    return items
end

function M:showAppExploreResults(title, url, page)
    page = page or 1
    self:showBusy(_("正在加载..."))
    local client = self.client
    Async.run(function()
        return client:fanqie_app_explore(url, page)
    end, function(ok, books, err)
        self:closeBusy()
        if not ok then
            self:showError(T(_("加载失败:\n%1"), display_error(err or books)))
            return
        end
        if not books or #books == 0 then
            self:showInfo(_("没有更多书籍"))
            return
        end
        local next_page
        -- 首页精选无分页
        if not tostring(url):match("^https://fanqienovel%.com$") then
            next_page = function()
                self:showAppExploreResults(title, url, page + 1)
            end
        end
        self:showAppBookList(string.format("%s (第%d页)", title, page), books, next_page)
    end, { delay = 0.1, poll_interval = 0.2, timeout = 30 })
end

-- 通用书籍列表（搜索/发现结果共用）。next_page 非 nil 时末尾追加「下一页」。
function M:showAppBookList(title, books, next_page)
    if not books or #books == 0 then
        self:showInfo(_("没有更多书籍"))
        return
    end
    local items = {}
    for _, b in ipairs(books) do
        table.insert(items, {
            text = string.format("%s / %s", b.name or _("未知书名"), b.author or ""),
            callback = function()
                -- 🔴 走 showAppBookDetail 而不是 showBookDetail：
                --    showBookDetail 假设「记录来自书架」（on_shelf=true, 有缓存），
                --    而这里的书来自搜索/发现，绝大多数**不在书架**上。
                --    直接复用它会让每本书都显示「移出书架」（实测 bug）。
                self:showAppBookDetail({
                    book_id = b.book_id,
                    title = b.name,
                    author = b.author,
                    desc = b.intro,
                    cover = b.coverUrl,
                    -- 列表接口自带的字段直接透传，详情框立刻就能判状态
                    -- （0=完结 / 1=连载 / nil=没给），不用额外请求
                    creation_status = b.creation_status,
                    last_chapter_update_time = b.last_chapter_update_time,
                    category = b.kind,
                })
            end,
        })
    end
    if next_page then
        table.insert(items, {
            text = ">> " .. _("下一页"),
            callback = next_page,
        })
    end
    local menu
    menu = Menu:new{
        title = title,
        item_table = items,
        items_per_page = 12,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            if _state.active_menu == menu then
                _state.active_menu = nil
            end
        end,
    }
    _state.active_menu = menu
    UIManager:show(menu)
end

function M:showBookDetail(book)
    if type(book) ~= "table" then return end
    -- 书架记录**本来就来自书架**（fetch_shelf_detail 拉回来的）⇒ 必定在架。
    -- 这里不再打 shelf_check（39 B）：它确实很快，但每点一本书都要闪一次
    -- loading；而唯一会「过期」的场景是「别的设备把它移出了书架」，此时
    -- 「移出书架」本身是幂等的，不会误伤任何东西。
    -- 书城那条路（StoreUI.showStoreBookDetail）才必须查 —— 见那里的收敛说明。
    self:buildBookDetailDialog(book, {
        on_shelf = true,
        cache_ok = true,
    })
end

--- APP 内置源（搜索 / 发现）里的书 → 详情框。
--
-- 与上面 showBookDetail（书架记录）的三点区别：
--   ① 这些书**不一定在书架**上 ⇒ 必须先 `shelf_check` 再决定按钮方向；
--      查不到（离线 / 未登录）就**不给**书架按钮（on_shelf=nil），不猜方向。
--      以前这里直接复用 showBookDetail，`on_shelf=true` 硬编码 ⇒
--      每本没加书架的书都显示「移出书架」（实测 bug，2026-10-20）。
--   ② 没有本地缓存概念 ⇒ cache_ok=false（不给「清空本书缓存」）。
--   ③ 列表接口只给字数（word_number），没有章数 ⇒ 顺手拉一次目录详情补上
--      「N 章」（同一次请求还带回 creation_status / last_publish_time）。
--      拉失败静默降级：列表自带的字段已经够用，详情框不会因此打不开。
function M:showAppBookDetail(book)
    if type(book) ~= "table" or not book.book_id then return end
    if not self:checkNetwork() then return end
    if not (Store and Store.shelf_check) then
        self:showInfo(_("书城组件不可用"))
        return
    end

    local client = self.client
    local book_id = tostring(book.book_id)

    self:showBusy(_("正在获取书籍信息…"))
    Async.run(function()
        local on_shelf
        local ok_s, s = pcall(function() return Store.shelf_check(client, book_id) end)
        if ok_s and type(s) == "boolean" then on_shelf = s end

        local info, info_err
        local ok_i, i = pcall(function() return client:fanqie_app_book_info(book_id) end)
        if ok_i and type(i) == "table" then info = i else info_err = tostring(i) end
        -- 目录详情只是锦上添花（补章数），失败要能查：否则详情框「没有 N 章」
        -- 时无从判断是接口挂了还是这本书本来就没章数。
        if Log and Log.debug then
            Log.debug("[FanQie][app] book_info", book_id,
                info and ("serial=" .. tostring(info.serial_count)
                    .. " cs=" .. tostring(info.creation_status)) or ("失败: " .. tostring(info_err)))
        end

        return { on_shelf = on_shelf, info = info }
    end, function(ok, res)
        self:closeBusy()
        local merged = {}
        for k, v in pairs(book) do merged[k] = v end

        local on_shelf
        if ok and type(res) == "table" then
            if type(res.on_shelf) == "boolean" then on_shelf = res.on_shelf end
            local info = res.info
            if type(info) == "table" then
                -- 只补**缺失**字段：列表接口给的标题/作者/封面是最新展示值，别覆盖
                merged.serial_count = merged.serial_count or info.serial_count
                if merged.creation_status == nil then
                    merged.creation_status = info.creation_status
                end
                if not merged.last_chapter_update_time then
                    merged.last_chapter_update_time = info.last_chapter_update_time
                end
                if not merged.desc or merged.desc == "" then merged.desc = info.intro end
                if not merged.category then merged.category = info.kind end
            end
        end

        self:buildBookDetailDialog(merged, {
            on_shelf = on_shelf,
            cache_ok = false,
        })
    end, { poll_interval = 0.3, timeout = 30 })
end

--- 长按书架条目：单本书快捷菜单（开始阅读 / 章节目录 / 清空本书缓存）。
-- README「书架操作」从早期版本就承诺了「长按书籍：显示操作菜单（开始阅读、
-- 章节目录、清空缓存）」，但代码一直没接 `on_hold` —— 本方法补齐该承诺。
-- 「清空本书缓存」与「书籍详情 → 清空本书缓存」走同一条清理路径
-- （settings.clear_book_cache），区别在入口更快、且无缓存时给明确提示。
function M:showShelfHoldMenu(book)
    if type(book) ~= "table" or not book.book_id then return end
    local title = tostring(book.title or book.book_name or _("未知"))
    local dialog -- 先声明后赋值：下面的闭包要捕获这个 upvalue

    -- 打开别的界面之前必须把本菜单 + 书架菜单都关掉，否则书架叠在阅读界面底下
    --（与「书籍详情 → 开始阅读」同一套收尾；book_list_menu 也要同步置 nil，
    --  否则 on_close 再触发一次会拿到已关闭的菜单）
    local function dismiss_self()
        H.close_widget(dialog)
        if _state.active_menu then
            local menu = _state.active_menu
            _state.active_menu = nil
            H.close_widget(menu)
            if self.book_list_menu == menu then self.book_list_menu = nil end
        end
    end

    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    if type(cached) == "table" then
        for _ in pairs(cached) do cache_count = cache_count + 1 end
    end

    local rows = {}
    rows[#rows + 1] = { {
        text = _("开始阅读"),
        callback = function()
            dismiss_self()
            self:openBook(book)
        end,
    } }
    rows[#rows + 1] = { {
        text = _("章节目录"),
        callback = function()
            dismiss_self()
            self:showChapterListing(book)
        end,
    } }
    rows[#rows + 1] = { {
        text = cache_count > 0
            and T(_("清空本书缓存（%1 章）"), tostring(cache_count))
            or _("清空本书缓存"),
        callback = function()
            if cache_count <= 0 then
                self:showInfo(T(_("《%1》没有本地章节缓存"), title))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("确定清空《%1》的缓存?\n%2 章节将被删除。"), title, tostring(cache_count)),
                ok_text = _("清空"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self.settings:clear_book_cache(book.book_id)
                    self:showInfo(T(_("已清空《%1》的 %2 章缓存"), title, tostring(cache_count)))
                end,
            })
        end,
    } }
    rows[#rows + 1] = { {
        text = _("关闭"),
        callback = function()
            H.close_widget(dialog)
        end,
    } }

    local ButtonDialog = require("ui/widget/buttondialog")
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
end
-- 异步获取目录后打开下载对话框
function M:_startBookDownload(book)
    local self_ref = self
    local book_id = book.book_id
    local Async_mod = Async

    self:showBusy(_("正在获取目录..."))

    local function fetch_and_show()
        if Async_mod and Async_mod.run then
            Async_mod.run(function()
                return self_ref:get_chapters(book_id)
            end, function(ok, chapters, err)
                self_ref:closeBusy()
                if not ok or type(chapters) ~= "table" then
                    if Log then Log.error("fetch chapters failed:", log_error(err or chapters)) end
                    self_ref:showError(T(_("获取目录失败:\n%1"), display_error(err or chapters)))
                    return
                end
                -- 检查已缓存章节数量
                local cached_map = Content.load_cache_index(self_ref.settings, book_id) or {}
                local cached_count = 0
                for _ in pairs(cached_map) do cached_count = cached_count + 1 end
                require("fanqie.download").showOptionsDialog(self_ref, book, chapters, {
                    cached_count = cached_count,
                })
            end, {
                poll_interval = 0.3, timeout = 60,
                tag = "book_detail",
                -- 取消后 on_done 不执行：busy 必须在这里关掉。
                on_cancel = function() self_ref:closeBusy() end,
            })
        else
            local ok, chapters = pcall(function()
                return self_ref:get_chapters(book_id)
            end)
            self:closeBusy()
            if not ok or type(chapters) ~= "table" then
                if Log then Log.error("fetch chapters failed:", log_error(chapters)) end
                self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
                return
            end
            local cached_map = Content.load_cache_index(self.settings, book_id) or {}
            local cached_count = 0
            for _ in pairs(cached_map) do cached_count = cached_count + 1 end
            require("fanqie.download").showOptionsDialog(self, book, chapters, {
                cached_count = cached_count,
            })
        end
    end

    -- 有缓存目录时先显示，后台刷新
    local cached_catalog = Content.load_catalog_cache(self.settings, book_id)
    if cached_catalog and #cached_catalog > 0 then
        fetch_and_show()
    else
        fetch_and_show()
    end
end


return M
