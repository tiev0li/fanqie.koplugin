-- main.lua —— 插件主入口与编排层（FanQiePlugin，WidgetContainer 子类）。
--
-- 本文件负责：
--   · 模块加载：全部走 safe_require（可选模块失败只警告不致命；logger 缺失时
--     换 no-op 兜底表，避免二次崩溃）
--   · 插件生命周期：init / onDispatcherRegisterActions / 菜单注册（含 mixin 白名单挂载）
--   · 业务编排：书架/阅读/下载/段评/进度同步等用户动作的处理函数
--
-- 模块分工（细节见各文件头注释）：
--   fanqie/settings.lua   设置存取与默认值（settings/fanqie.lua）
--   fanqie/client.lua     网络客户端，所有 HTTP 唯一出口
--   fanqie/content.lua    章节内容清洗与缓存落盘
--   fanqie/bookshelf.lua  书架数据源（内存主源 + 文件后备）
--   fanqie/store.lua      书城网页接口封装       fanqie/store_ui.lua   书城编排（mixin）
--   fanqie/shelf_view.lua 书架渲染（只渲染）     fanqie/store_view.lua 书城渲染（只渲染）
--   fanqie/comment_view.lua 段评视图             fanqie/book_detail.lua 详情三接口合并
--   fanqie/reading/       官方 App 协议（签名/加密/设备池），从阅读 App 书源移植，尽量原样
--   fanqie/appsource.lua  内置番茄APP源（回退书源 + 搜索/发现）
--   fanqie/updater*.lua   在线更新               fanqie/state.lua       运行时状态
--   patches/core.lua      对 KOReader 本体的运行时补丁
--
-- ⚠️ 本文件较长，函数分区靠注释横幅导航；改菜单结构时先找 addToMainMenu。

local LOG_MODULE = "[FanQie]"

local function safe_require(module_name, required)
    local ok, result = pcall(require, module_name)
    if not ok then
        if required then
            print(LOG_MODULE, "fatal: failed to load required module:", module_name, "-", result)
            return nil, false
        else
            print(LOG_MODULE, "warning: failed to load optional module:", module_name, "-", result)
            return nil, true
        end
    end
    return result, true
end

local WidgetContainer, ok = safe_require("ui/widget/container/widgetcontainer", true)
if not ok then return end

local Dispatcher = safe_require("dispatcher")
local UIManager = safe_require("ui/uimanager")
local InfoMessage = safe_require("ui/widget/infomessage")
local logger = safe_require("logger")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or nil

local Settings = safe_require("fanqie.settings")
local Client = safe_require("fanqie.client")
local H = safe_require("fanqie.helper")
local Content = safe_require("fanqie.content")
local Async = safe_require("fanqie.async")
local Event = safe_require("ui/event")
local Log = safe_require("fanqie.logger")

-- 日志模块加载失败时用 no-op 兜底表，调用点无需逐个 `if Log` 保护。
-- 历史上有 22 处直接 `Log.xxx(...)`（未加 guard），logger 缺失时会二次崩溃拖垮整个插件。
if not Log then
    local function _noop() end
    Log = {
        init = _noop,
        debug = _noop,
        info = _noop,
        warn = _noop,
        error = _noop,
        clear_log = _noop,
        is_debug_enabled = function() return false end,
        get_log_file_path = function() return nil end,
    }
end

local Patches = safe_require("patches.core")

local Bookshelf = safe_require("fanqie.bookshelf")
local StoreUI = safe_require("fanqie.store_ui")
local Info = safe_require("fanqie.info")
local Stats = safe_require("fanqie.stats")
local UpdaterUI = safe_require("fanqie.updater_ui")
local Startup = safe_require("fanqie.startup")

local unpack_args = unpack or table.unpack

local Runtime = require("fanqie.runtime")
local _state = Runtime.state
local display_error = Runtime.display_error
local log_error = Runtime.log_error
local main_source = debug.getinfo(1, "S").source or ""
local main_path = main_source:match("^@(.+)$") or main_source
Runtime.plugin_path = main_path:match("^(.*)/[^/]+$") or "."

local FanQiePlugin = WidgetContainer:extend{
    name = "fanqie",
    is_doc_only = false,
    fullname = "FanQie",
    version = Info and Info.version or "3.0",
}

-- Check if the active ReaderUI document is the fanqie chapter we opened.
-- Prevents event handlers (onEndOfBook, onCloseDocument, etc.) from
-- firing on unrelated documents the user may open afterwards.
--
-- 🔴 v2.16.21：不能只看路径里有没有 `/fanqie/`。默认缓存目录确实是
--    `<koreader>/fanqie/cache`（小写），但**用户改过下载目录**之后就变成任意路径
--    （真机日志里是 `/mnt/us/番茄小说/<book_id>/chapter_xxx.html`），
--    `:lower()` 不会把中文变成 fanqie ⇒ 这里恒假 ⇒ onEndOfBook / 进度上传 /
--    段评等一堆依赖它的分支全部静默失效。改成结构判据（与
--    `state.book_id_from_path` 同口径）：`.../<书号>/chapter_<item_id>.html`。
function FanQiePlugin:isCurrentDocFanqie()
    if not (self.ui and self.ui.document) then return false end
    local doc_path = self.ui.document.file or self.ui.document.path
    if not doc_path or type(doc_path) ~= "string" then return false end
    if doc_path:lower():find('/fanqie/', 1, true) then return true end
    -- 结构判据：父目录像书号 + 文件名像章节（见 patches/core.lua 的 is_fanqie_path）
    local normalized = doc_path:gsub("\\", "/")
    local parent = normalized:match("/([^/]+)/chapter_[^/]+%.html$")
    return parent ~= nil and #parent >= 6 and parent:match("^[%w%._-]+$") ~= nil
end

--- KOReader 的全局阅读设置对象（不存在时返回 nil）。
--
-- `G_reader_settings` 是 KOReader 的全局变量，正常情况下一定存在；但
-- **回归 harness 里没有它**（也拿不到真对象）。所有用到它的地方都必须
-- 走这个取用口，缺了就静默降级 —— 否则一个可选能力会把阅读界面拖崩。
function FanQiePlugin:_readerSettings()
    local ok, rs = pcall(function() return G_reader_settings end)
    if ok and rs and type(rs.readSetting) == "function" then
        return rs
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 「到达文档末尾时的操作」：读番茄章节时改成「什么都不做」（v2.17.0）
-- ---------------------------------------------------------------------------
-- 背景：番茄小说**一章就是一个 html 文件**（`content.lua` 的
-- `chapter_<item_id>.html`），在 KOReader 眼里「读完一章」就等于
-- 「读完一本书」。于是读到最后一页**再往后翻**时（判据在
-- `readerrolling.lua:914/928`：`diff > 0 and old_page == self.current_page`），
-- 会派发 `EndOfBook`，而 `ReaderStatus:onEndOfBook` 按**全局设置**
-- `end_document_action`（默认 `"pop-up"`）弹一个「已到文档末尾」的按钮框。
-- 那个框和本插件自己的「自动下一章」是两套东西，一起出现就是打扰。
--
-- 🔴 为什么是「改设置」而不是「插件抢事件」：
--    `WidgetContainer:propagateEvent` 是**正序**遍历
--    （`widgetcontainer.lua:82` `for _, widget in ipairs(self)`，第一个返回 true 的
--    就把事件截住），而 `ReaderStatus` 在 `readerui.lua:416` 就注册了，插件远在其后
--    ⇒ KOReader 的那个对话框**永远先于**插件的 `onEndOfBook` 执行。想让它不发生，
--    只能让 `ReaderStatus` 自己「什么都不做」。
--
-- ✅ 为什么选 `"nothing"` 这个值最合适：
--    `ReaderStatus:onEndOfBook` 的 if/elseif 链里**没有 `"nothing"` 分支**
--    （`readerstatus.lua:126-166` 只有 pop-up / book_status / next_file /
--    goto_beginning / file_browser / mark_read / …），所以它什么也不做，
--    并且**不返回值**（nil）⇒ 事件继续传播 ⇒ 插件的 `onEndOfBook`
--    （进度置 1.0 + 自动下一章）一切照旧，只是不再有那个框。
--
-- 生效范围：**只覆盖打开番茄章节的这段时间**，离开时还原（见各函数的注释）。
function FanQiePlugin:_muteEndDocumentAction()
    if not self:isCurrentDocFanqie() then return end
    local rs = self:_readerSettings()
    if not rs then return end
    local cur = rs:readSetting("end_document_action")
    if _state.end_document_action_backup == nil then
        -- 只在**第一次**覆盖时记原值：切章会走一遍「还原 → 再覆盖」，
        -- 若每次都记，第二次记下的就是我们自己写的 "nothing"，原值就丢了。
        -- ⚠️ 用 `false` 表示「原本没设过」（KOReader 的默认即「弹窗询问」）——
        --    不能和 nil（= 还没覆盖过）混用，否则永远不会还原。
        -- 🔴 别写成 `(cur == nil) and false or cur`：Lua 的 `and/or` 在中间值为
        --    **false** 时会落到最后一个操作数 ⇒ 表达式退化成 `cur`（= nil），
        --    「原本没设过」又变回「还没覆盖过」，L1b/L5 就是这么红的。
        if cur == nil then
            _state.end_document_action_backup = false
        else
            _state.end_document_action_backup = cur
        end
    end
    if cur ~= "nothing" then
        rs:saveSetting("end_document_action", "nothing")
    end
end

--- 还原「到达文档末尾时的操作」。没覆盖过时是空转。
function FanQiePlugin:_restoreEndDocumentAction()
    local backup = _state.end_document_action_backup
    if backup == nil then return end
    _state.end_document_action_backup = nil
    local rs = self:_readerSettings()
    if not rs then return end
    -- ⚠️ 只还原「仍然是我们写的那个值」的情况：用户在阅读番茄小说的过程中
    --    自己去设置里改过（比如就是想要那个框），那就尊重用户的选择。
    if rs:readSetting("end_document_action") ~= "nothing" then return end
    -- 🔴 同样别写成 `backup == false and nil or backup`：中间值是 nil 时整个
    --    表达式落到最后一项 ⇒ 会把 `false` 写回去（LuaSettings 里就成了一个
    --    真值为 false 的键，而不是「没设过」）。L5 就是这条。
    if backup == false then
        rs:saveSetting("end_document_action", nil)  -- 删键 = 回到 KOReader 默认
    else
        rs:saveSetting("end_document_action", backup)
    end
end

--- KOReader 每次打开文档都会广播 `ReaderReady`（`readerui.lua:517`），
--- 这是「文档已就绪」的统一挂载点：插件自己打开章节（showReaderUI）和
--- 用户从「最近阅读 / 文件管理器」直接打开章节 html 都会经过这里。
--- ⚠️ 返回 nil（不消费事件）：别把 ReaderReady 从别的模块手里截走。
function FanQiePlugin:onReaderReady()
    -- 「文档确实已打开」的权威信号：两条打开路径（插件自己 showReaderUI、
    -- 用户从「最近阅读 / 文件管理器」直接打开章节）都会经过这里。
    -- onCloseDocument 的「要加入书架吗 / 关闭后回书架」靠它区分
    -- 「正在打开途中」与「真的关掉了」。
    _state.document_opened = true
    -- 新文档就绪 ⇒ 「切文档」窗口结束（见 showReaderUI 里的置位说明）。
    -- ⚠️ 只在这里清：ReaderReady 是两条打开路径（插件 showReaderUI / 用户从
    --    文件管理器直接开章节）的唯一共同终点，showReaderUI 返回时新实例还没建出来。
    _state.switching_document = false
    if self:isCurrentDocFanqie() then
        pcall(function() require("fanqie.reading_session").restore(self) end)
    end
    local ok, err = pcall(function() self:_muteEndDocumentAction() end)
    if not ok and Log and Log.error then
        Log.error("mute end_document_action failed:", tostring(err))
    end
    -- 阅读统计按「整本书」合并：番茄每章一个 .html，KOReader 默认会把每章当成
    -- 一本书；这里在 statistics 实例上换成按 book_id 的固定身份（界面标题不变）。
    local ok_stat, stat_res = pcall(Stats.sync, self.ui, self.settings)
    if not ok_stat then
        if Log and Log.warn then Log.warn("stats merge failed:", tostring(stat_res)) end
    elseif type(stat_res) == "table" then
        if Log and Log.info then
            Log.info("[FanQie] 阅读统计按书合并:", tostring(stat_res.title),
                "/", tostring(stat_res.book_id))
        end
        -- 作者兜底：书架接口不返回作者，唯一来源是书籍详情页。
        -- 只在仍是 N/A 时触发一次异步抓取（有缓存则直接回填统计库）。
        if stat_res.authors == "N/A" and stat_res.book_id then
            local ok_bm, BookMeta = pcall(require, "fanqie.book_meta")
            if ok_bm and type(BookMeta) == "table" and BookMeta.ensure then
                pcall(BookMeta.ensure, self.settings, stat_res.book_id)
            end
        end
    end
end


--- 当前正在读的番茄书。
--
-- 优先内存里的 `_state.current_book`；没有时（重启后从「最近阅读 / 文件管理器」
-- 直接打开章节续读）从文档路径反推书号，返回一条**最小记录** `{ book_id = ... }`。
--
-- 🔴 `_state.current_book` 不持久化，只有 openBook / openChapter /
--    showChapterListing 会赋值 ⇒ 这条回退是阅读界面「加入/移出书架」在
--    重启续读场景下唯一的书号来源。返回值只保证有 book_id（toggleStoreShelf
--    也只用 book_id），所以标题缺失时确认框文案会退化成「未知」，这是可接受的。
function FanQiePlugin:getCurrentBook()
    local cached = _state.current_book
    if type(cached) == "table" and cached.book_id then
        return cached
    end
    if not (self.ui and self.ui.document) then return nil end
    local path = self.ui.document.file or self.ui.document.path
    if not path or type(_state.book_id_from_path) ~= "function" then return nil end
    local book_id = _state.book_id_from_path(path)
    if not book_id then return nil end
    -- 反查校验：路径前缀必须正是这本书的缓存目录
    if Content and Content.book_cache_dir then
        local dir = Content.book_cache_dir(self.settings, book_id)
        if not dir or path:sub(1, #dir) ~= dir then return nil end
    end
    return { book_id = book_id }
end

--- 当前这本书「在不在书架」的**同步**判断。
-- @return true=在架 / false=不在架 / nil=未知
-- 🔴 为什么必须同步：菜单项文案由 `Menu.getMenuText` 在每次重绘时同步求值，
--    不可能等一次网络往返。所以判据只能是 `_state` 的书架快照（见 state.lua）。
--    快照缺数据（冷启动、从没读过书架列表）时**不要**退化成联网去查 ——
--    那会把菜单打开拖成一个网络等待。返回 nil，由调用方决定兜底文案。
function FanQiePlugin:isCurrentBookOnShelf()
    if not (_state and type(_state.shelfState) == "function") then return nil end
    local book = self:getCurrentBook()
    if type(book) ~= "table" or not book.book_id then return nil end
    return _state.shelfState(book.book_id)
end

function FanQiePlugin:init()
    self.settings = Settings:new()
    Log.init(self.settings)
    self.client = Client:new(self.settings)
    local Library = require("fanqie.library")
    self.library = Library:new(self.settings)
    self.library:migrate(_state.getPendingProgress())
    self.patches_ok = Patches.verifyPatched()
    -- 尽早安装补丁（含 ReaderLink 段评链接拦截），确保已打开的书也能立即生效
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = Patches.verifyPatched()
    end
    -- 加载持久化的段评开关（必须在加载 config 之前，让 config 不覆盖用户选择）
    if _state.loadReviewState then
        _state.loadReviewState(self.settings)
    end
    self:onDispatcherRegisterActions()
    self:loadConfigFile(true)
    -- 初始页面：配置为番茄书架时，在文件管理器上屏后展示书架
    -- （仅处理冷启动创建的第一个文件管理器实例，见 fanqie/startup.lua）
    if Startup and Startup.maybeShowBookshelf then
        pcall(function() Startup.maybeShowBookshelf(self) end)
    end
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    Log.info("plugin initialized:", "version=", self.version)
    -- 自更新链路永远不能让插件本体变哑：任何抛错都只吞进日志。
    -- UI.startup 内部有进程级去重（KOReader 会为 FileManager / 每个 ReaderUI 各建实例）。
    if UpdaterUI and UpdaterUI.startup then
        pcall(function() UpdaterUI.startup(self) end)
    end
end

function FanQiePlugin:displayError(err)
    return display_error(err)
end

-- mixin 只做「白名单显式拷贝」：main.lua 未定义的模块方法才需要搬进来。
-- 以前用 pairs() 全量拷贝，而 main.lua 在下方又重定义了同名方法 → 模块侧那些实现
-- 永不执行（其中还夹着同步阻塞版），是「改了模块却不生效」的维护陷阱。
-- ⚠️ 模块里新增公共方法，必须在此登记，否则不会被拷贝（reader_navigation.lua 已整体移除）。
local BOOKSHELF_MIXIN = {
    "clearShelfCache", -- 三层清缓存（显示层内存 / client API 短缓存 / 文件）
    "showBookshelf",   -- 书架入口（异步拉取 + 缓存回退 + 后台刷新）
    "get_shelf",       -- 拉取书架列表并归一化（子进程内执行）
    "ensureShelfSnapshot", -- 同步补齐「书架状态快照」（纯本地文件，绝不联网）
    "findCachedBook",  -- 从本地书架缓存按书号取完整记录（阅读端「书籍信息」补全用）
}
if Bookshelf then
    for _, name in ipairs(BOOKSHELF_MIXIN) do
        FanQiePlugin[name] = Bookshelf[name]
    end
end

-- 书城入口的名字一律登记在这里；模块内部辅助函数是 local，不需要登记。
local STORE_MIXIN = {
    "showStore",             -- 书城根菜单（分类浏览 / 排行榜 / 搜索）
    "showStoreBrowser",      -- 分类浏览（男频/女频 → 分类分组 → 分类 → 书籍列表）
    "showStoreRanks",        -- 排行榜（最近更新 / 推荐榜）
    "showStoreSearch",       -- 搜索（输入框 → 结果列表）
    "showStoreBookDetail",   -- 书城书籍详情（加入/移出书架、阅读、目录、下载）
    "toggleStoreShelf",      -- 加入 / 移出书架（异步）
}
if StoreUI then
    for _, name in ipairs(STORE_MIXIN) do
        FanQiePlugin[name] = StoreUI[name]
    end
end

function FanQiePlugin:logInitError(step, err)
    local err_msg = log_error(err)
    if logger and logger.err then
        logger.err(LOG_MODULE, step .. ":", err_msg)
    end
    if Log and Log.error then
        Log.error(step .. ":", err_msg)
    end
    local file = io.open("/mnt/us/koreader/fanqie_init_error.log", "a")
    if file then
        file:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. step .. ": " .. err_msg .. "\n")
        file:close()
    end
end

function FanQiePlugin:ensurePatchesInstalled()
    local Patches = require("patches.core")
    if not Patches.verifyPatched("ReaderToc") then
        Patches.install()
    end
end



function FanQiePlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_fanqie_bookshelf", {
        category = "none",
        event = "ShowFanQieBookshelf",
        title = _("番茄书架"),
        filemanager = true,
        -- 阅读界面也能用：在阅读器里触发时由 onShowFanQieBookshelf 决定行为。
        reader = true,
    })
    Dispatcher:registerAction("return_fanqie_toc", {
        category = "none",
        event = "ShowFanQieToc",
        title = _("返回番茄目录"),
        reader = true,
    })
    -- 阅读时一键回书架。登记成 reader 动作后，用户可以在
    -- 「设置 → 手势管理 / 快捷键」里把它绑到任意手势或按键。
    Dispatcher:registerAction("return_fanqie_bookshelf", {
        category = "none",
        event = "ReturnFanQieBookshelf",
        title = _("返回番茄书架"),
        reader = true,
    })
end

function FanQiePlugin:safeCallback(label, callback)
    local self_ref = self
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            self_ref:closeBusy()
            if logger and logger.err then logger.err(LOG_MODULE, "action failed:", label, log_error(err)) end
            self_ref:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

--- 当前这个插件实例应该注册哪套主菜单？
---
--- KOReader 会为 **FileManager 和 ReaderUI 各建一个插件实例**，两边都会调
--- `addToMainMenu`（见 filemanagermenu.lua / readermenu.lua 的 `setUpdateItemTable`）。
--- 所以这里必须按「谁在调我」分流，而不是只看 `self.ui.document`：
---   * `"filemanager"` ⇒ 通用主菜单（书架 / 书城 / 搜索 / 发现 / 下载管理 / 设置 …）
---   * `"reader"`      ⇒ 阅读菜单（返回书架 / 目录 / 段评 / 重新获取本章节 …）
---   * `nil`           ⇒ 不注册
---
--- 🔴 回归背景：以前写成 `if self.ui.document and isCurrentDocFanqie()`，文件管理器
---    实例的 `self.ui.document` 永远是 nil ⇒ 文件管理器主菜单里永远没有「番茄小说」
---    （书城/书架/设置只能从别处进）。上游 v2.16.23/v2.16.26 同样有此问题。
---
--- ⚠️ 两侧都要确认「自己是不是**当前活动**的 UI」：
---    * 阅读端：`ReaderUI.instance` 在 `onCloseWidget`（`UI:close()` 之后）才清空，
---      而 ReaderUI 关闭前会先 `PluginLoader:finalize()` 丢掉旧实例引用 —— 先后不保证，
---      只判 `self.ui.document` 可能读到「已关闭但 document 还在」的旧实例。
---    * 文件管理器：关掉 FileManager 进阅读后它的实例仍然存活
---      （`FileManager.instance` 在 `onCloseWidget` 里才置 nil），此时若还注册，
---      会把整个通用菜单塞进阅读器菜单里。
---@return string|nil "filemanager" | "reader" | nil
function FanQiePlugin:getMainMenuScope()
    local ui = self.ui
    if not (ui and ui.document) then
        -- 文件管理器实例。`FileManager.instance` 在早期构建期可能还没赋值 ⇒ 按「是我」放行。
        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        if ok_fm and FM and FM.instance and FM.instance ~= ui then return nil end
        return "filemanager"
    end
    local ok_rui, RUI = pcall(require, "apps/reader/readerui")
    if not (ok_rui and RUI and RUI.instance == ui) then return nil end
    if not self:isCurrentDocFanqie() then return nil end
    return "reader"
end

function FanQiePlugin:addToMainMenu(menu_items)
    local scope = self:getMainMenuScope()
    if scope == "filemanager" then
        menu_items.fanqie = {
        text = _("番茄小说"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMainMenuItems()
        end,
        }
        return
    end
    if scope ~= "reader" then return end
    -- 读番茄书时注册阅读菜单（含「加入/移出书架」）。
    -- ⚠️ 这里**不能**再卡 `_state.current_book`：它不持久化，重启后从
    --    「最近阅读 / 文件管理器」直接打开章节续读时是 nil。
    menu_items.fanqie = {
        text = _("番茄小说"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                {
                    -- 放在阅读菜单**第一项**：读番茄书时「回书架」是最高频动作，
                    -- 和「继续读」构成一个来回。
                    text = _("返回书架"),
                    callback = self:safeCallback(_("返回书架"), function()
                        self:returnToBookshelf({ force_refresh = false })
                    end),
                },
                {
                    text = _("书架"),
                    callback = self:safeCallback(_("书架"), function()
                        self:showBookshelf()
                    end),
                },
                {
                    text = _("书城"),
                    callback = self:safeCallback(_("书城"), function()
                        self:showStore()
                    end),
                },
                {
                    -- 阅读界面里「我在读的是什么」的入口（v2.17.0）。
                    -- 判据与「加入/移出书架」「目录」同源：优先内存里的
                    -- _state.current_book，没有就从文档路径反推 + 本地书架缓存补全
                    -- （重启续读场景），全程零网络。详见 showCurrentBookInfo。
                    text = _("书籍信息"),
                    callback = self:safeCallback(_("书籍信息"), function()
                        self:showCurrentBookInfo()
                    end),
                },
                {
                    text = _("阅读统计"),
                    callback = self:safeCallback(_("阅读统计"), function()
                        require("fanqie.library_view").show_reading_stats(self)
                    end),
                },
                {
                    text = _("目录"),
                    callback = self:safeCallback(_("目录"), function()
                        -- onShowFanQieToc 需要 current_book + 章节表（都在内存里）；
                        -- 重启续读时两者皆无，事件发出去没人接 ⇒ 显式提示比静默好。
                        if not (_state.current_book and _state.current_chapters) then
                            self:showInfo(_("请先从书架或书城打开这本书"))
                            return
                        end
                        self.ui:handleEvent(Event:new("ShowFanQieToc"))
                    end),
                },
                {
                    text = _("返回刚才位置"),
                    callback = self:safeCallback(_("返回刚才位置"), function()
                        if not (_state.current_book and _state.current_chapters) then
                            self:showInfo(_("无书籍信息"))
                            return
                        end
                        if not require("fanqie.reading_session").return_back(self) then
                            self:showInfo(_("没有可返回的位置"))
                        end
                    end),
                },
                {
                    text = _("下载"),
                    callback = self:safeCallback(_("下载"), function()
                        local book = _state.current_book
                        if not book then self:showInfo(_("无书籍信息")); return end
                        local chapters = _state.current_chapters
                        if not chapters or #chapters == 0 then
                            -- 子进程获取目录，UI 线程保持响应
                            self:showBusy(_("正在获取目录..."))
                            local client = self.client
                            local book_id = book.book_id
                            Async.run(function()
                                local b = { book_id = book_id }
                                return Content.fetch_catalog(client, b)
                            end, function(ok_cat, result, err)
                                self:closeBusy()
                                if not ok_cat or type(result) ~= "table" or #result == 0 then
                                    self:showInfo(_("获取目录失败"))
                                    return
                                end
                                _state.current_chapters = result
                                local Download = require("fanqie.download")
                                Download.showOptionsDialog(self, book, result,
                                    { current_index = _state.current_chapter_index })
                            end, { poll_interval = 0.3, timeout = 60 })
                            return
                        end
                        local Download = require("fanqie.download")
                        Download.showOptionsDialog(self, book, chapters,
                            { current_index = _state.current_chapter_index })
                    end),
                },
                {
                    -- 阅读界面直接管理当前这本书的书架状态（v2.12.0）。
                    -- 🔴 文案按**实际书架状态**给（v2.16.0）。以前一律写
                    --    「加入/移出书架」，等于把两个方向摆在一起让用户自己猜 ——
                    --    在架的书该显示「移出书架」、不在架的该显示「加入书架」。
                    --    判据是 `_state` 的书架快照（纯内存 O(1)，见 state.lua），
                    --    在 `text_func` 里**同步**求值：koreader 的
                    --    `Menu.getMenuText` 每次 `updateItems` 都会调用它
                    --    ⇒ 菜单一打开，方向就是对的。
                    -- 未知（冷启动且本地没有书架缓存）时乐观显示「加入书架」：
                    --    加入是可逆的，而「移出书架」是破坏性动作 —— 宁可猜前者。
                    --    （点击后 `toggleCurrentBookShelf` 仍会先 shelf_check 复核，
                    --      所以即便猜错也不会做错事，只是文案多一次翻转。）
                    text_func = function()
                        if self:isCurrentBookOnShelf() == true then
                            return _("移出书架")
                        end
                        return _("加入书架")
                    end,
                    callback = self:safeCallback(_("加入/移出书架"), function()
                        self:toggleCurrentBookShelf()
                    end),
                },
                {
                    text = _("设置"),
                    sub_item_table_func = function()
                        return self:getSettingsMenuItems()
                    end,
                },
                {
                    text = _("缓存管理"),
                    sub_item_table_func = function()
                        return self:getCacheMenuItems()
                    end,
                },
                {
                    text = _("在线更新"),
                    sub_item_table_func = function()
                        return self:getUpdateMenuItems()
                    end,
                },
                {
                    text = _("重新获取本章节"),
                    callback = self:safeCallback(_("重新获取本章节"), function()
                        self:reloadCurrentChapter()
                    end),
                },
                {
                    text = _("关于"),
                    callback = self:safeCallback(_("关于"), function()
                        -- cover_cell 构建标记：同主菜单「关于」（见 getMainMenuItems）
                        local ok_cc, CCm = pcall(require, "fanqie.cover_cell")
                        local build_note = (ok_cc and CCm and CCm.BUILD)
                            and T(_("（cover_cell 构建 %1）"), CCm.BUILD) or ""
                        self:showInfo(T(Info and Info.about_template or _("番茄小说插件 v%1"), self.version, self.settings:get_download_dir())
                            .. build_note)
                    end),
                },
            }
        end,
    }
end

-- 按职责拆分的动作模块。显式登记方法名，避免覆盖生命周期或意外引入新接口。

-- 忙碌提示（半透明遮罩 + 白框，无 timeout，必须显式 closeBusy）。
--
-- 🔴 必须幂等：直接 `self._busy_msg = InfoMessage:new{...}` 覆盖引用，
--    上一个 InfoMessage 就**再也没有任何引用能关掉它**——它会永久留在
--    UIManager 栈上（点一下就关得掉，但不点就一直在）。
--    实测症状就是「点了书架，那个『正在刷新书架…』弹窗有时候不消失」：
--    例如缓存先显示 → showBusy#1 → 用户点书 → 详情里的下载又 showBusy#2 →
--    #1 的引用被 #2 覆盖，等 #2 关掉时 #1 早就漏了。
--    所以这里先摘引用、再关旧的。
--
-- 注：旧代码写的 `norefresh = true` 是**无效字段**（InfoMessage 没有这个字段，
--     与之相近的是 no_refresh_on_close）。这里不补上它：busy 关掉时必须重绘，
--     否则白框会留在墨水屏上。
function FanQiePlugin:showBusy(text)
    if self._busy_msg then
        local old = self._busy_msg
        self._busy_msg = nil
        H.close_widget(old)
    end
    self._busy_msg = InfoMessage:new{ text = text }
    UIManager:show(self._busy_msg)
    UIManager:forceRePaint()
end

function FanQiePlugin:closeBusy()
    local msg = self._busy_msg
    self._busy_msg = nil
    if msg then H.close_widget(msg) end
end

function FanQiePlugin:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function FanQiePlugin:showError(text)
    -- 同样：`norefresh = false` 是无效字段（InfoMessage 无此字段），去掉。
    UIManager:show(InfoMessage:new{ text = text })
end

-- 按职责拆分的动作模块。显式登记方法名，避免覆盖生命周期或意外引入新接口。
local ACTION_MODULES = {
    { module = "fanqie.comments.comment_actions", methods = {
        "showParaReviewList",
        "showParaReviewDetail",
        "onFanQieParaReview",
    }},
    { module = "fanqie.comments.comment_view_actions", methods = {
        "_displayParaReviewDetail",
        "_fetchParaReplies",
        "_prefetchParaImages",
        "_readerFontSize",
        "_renderParaReviewView",
        "_renderParaReviewText",
        "showParaReviewReplies",
        "_comment_image_dir",
        "showCommentImage",
    }},
    { module = "fanqie.menus.menu_actions", constants = { "PROGRESS_UPLOAD_PRESETS" }, methods = {
        "getMainMenuItems",
        "getUpdateMenuItems",
        "getProgressUploadIntervalItems",
        "getCoverCacheMenuItems",
        "getSettingsMenuItems",
        "setStartupPage",
        "getSourceMenuItems",
        "getSourceDetailMenuItems",
        "showSourceRateLimitDialog",
        "getLogMenuItems",
        "getPreDownloadMenuItems",
        "setPreDownloadCount",
        "showDownloadDirPicker",
        "loadConfigFile",
        "getPluginPath",
        "checkNetwork",
        "_coverCacheDirs",
        "_shelfCacheBytes",
        "_storeCacheBytes",
        "_commentCacheBytes",
        "_coverCacheUsable",
    }},
    { module = "fanqie.shelf.shelf_actions", methods = {
        "_coverCacheUsable",
        "_shelfMenuVisible",
        "_ensureShelfBackdrop",
        "showBookList",
        "_createShelfMenu",
        "_cancelCoverLoading",
        "_onShelfPage",
        "_cacheShelfPageCovers",
        "_preloadAllCovers",
    }},
    { module = "fanqie.details.book_detail_actions", methods = {
        "showCurrentBookInfo",
        "closeBookDetailPage",
        "showBookDetailPage",
        "buildBookDetailDialog",
        "toggleCurrentBookShelf",
        "_promptAddShelfOnLeave",
        "_closeDetailDialog",
        "showAppSearchDialog",
        "showAppSearchResults",
        "getAppExploreMenuItems",
        "showAppExploreResults",
        "showAppBookList",
        "showBookDetail",
        "showAppBookDetail",
        "showShelfHoldMenu",
        "_startBookDownload",
    }},
    { module = "fanqie.chapters.chapter_actions", methods = {
        "showChapterListing",
        "showJumpToChapter",
        "get_chapters",
        "_downloadHeartbeatPath",
        "navigateToChapter",
        "openChapter",
        "_announceDocSwitchToShell",
        "_retractDocSwitchAnnouncement",
        "showReaderUI",
    }},
    { module = "fanqie.reader.reader_actions", methods = {
        "reloadCurrentChapter",
        "preDownloadChapters",
        "getCurrentPageProgress",
        "_chapterIndexByItemId",
        "_currentDocChapterItemId",
        "syncCurrentProgress",
        "retryPendingProgress",
        "onPageUpdate",
        "onFanQiePrevChapter",
        "onEndOfBook",
        "_finalizeProgressSession",
        "_uploadOnCloseEnabled",
        "_progressUploadInterval",
        "_ensureProgressTimer",
        "_stopProgressTimer",
        "onCloseDocument",
        "_returnToShelfAfterClose",
        "onClose",
        "onCloseWidget",
        "onExit",
        "onShowFanQieToc",
        "onShowFanQieBookshelf",
        "onReturnFanQieBookshelf",
        "returnToBookshelf",
    }},
    { module = "fanqie.cache.cache_actions", methods = {
        "getCacheMenuItems",
        "showDownloadManager",
        "getCacheSizeMB",
        "clearAllCache",
    }},
    { module = "fanqie.opening.open_book_actions", methods = {
        "_openBookWithCache",
        "_refreshCatalogInBackground",
        "openBook",
    }},
}

for _, entry in ipairs(ACTION_MODULES) do
    local actions = safe_require(entry.module, true)
    if actions then
        for _, name in ipairs(entry.methods) do
            FanQiePlugin[name] = actions[name]
        end
        if entry.constants then
            for _, name in ipairs(entry.constants) do
                FanQiePlugin[name] = actions[name]
            end
        end
    end
end

return FanQiePlugin
