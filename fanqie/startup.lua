-- 初始页面（KOReader 启动页）
-- 功能：「设置 → 初始页面 → 番茄书架」后，KOReader 冷启动时第一个界面直接是番茄书架。
--
-- 实现机制：
--   KOReader 启动时 reader.lua 调用 FileManager:showFiles(home_dir) 创建文件管理器实例，
--   插件实例作为该实例的模块在其 init 期间被创建（Widget:new 会调用 init，见 widget.lua），
--   早于 UIManager:show(file_manager)。
--   因此这里在插件 init 中登记 nextTick 回调：等文件管理器上屏后，再把书架 Menu 压到
--   它上面——与 KOReader 内置 start_with=history/favorites 启动页同一机制，
--   关闭书架即回到文件管理器，不会因窗口栈空而退出 KOReader。
--   进程级标志保证只处理冷启动创建的第一个文件管理器实例；之后再次创建文件管理器
--   （阅读完毕关闭书籍、查看缓存目录等）均按普通文件管理器处理。

local ok_UIManager, UIManager = pcall(require, "ui/uimanager")

local Startup = {}

-- 进程级标志：本进程是否已处理过"初始页面"
local startup_handled = false

-- KOReader 内置"启动时显示"设置（start_with，见 reader.lua）的取值：
-- filemanager / last / history / favorites / folder_shortcuts。
-- 初始页面设为书架时同步写入 fanqie_bookshelf：KOReader 启动分支读到未知取值时
-- 走默认文件管理器分支（不会自动打开上次书籍），行为安全。
-- 同时把用户原本的取值记住，关闭功能时原样恢复，不丢失既有偏好。
local START_WITH_BOOKSHELF = "fanqie_bookshelf"
local START_WITH_DEFAULT = "filemanager"

--- 初始页面是否配置为番茄书架
function Startup.isEnabled(settings)
    if not settings then return false end
    local ok, enabled = pcall(function()
        if settings.isBookshelfStartupEnabled then
            return settings:isBookshelfStartupEnabled()
        end
        return false
    end)
    return ok and enabled == true
end

--- 同步 KOReader 的 start_with 设置
-- 开启：记住用户原本的启动页（last/favorites/history 等），写入 fanqie_bookshelf；
-- 关闭：仅当当前值是插件写入的 fanqie_bookshelf 时，恢复用户原本的启动页。
function Startup.syncKoreaderStartWith(settings)
    if not (G_reader_settings and G_reader_settings.saveSetting) then return end
    local enabled = Startup.isEnabled(settings)
    local current = G_reader_settings:readSetting("start_with")
    if enabled then
        if current ~= START_WITH_BOOKSHELF then
            -- 记住原本的启动页（只记第一次，避免被后续其他改动覆盖）
            if settings and settings.getPrevStartWith and settings.setPrevStartWith then
                local ok_prev, prev = pcall(function() return settings:getPrevStartWith() end)
                if ok_prev and (prev == nil or prev == "") then
                    pcall(function() settings:setPrevStartWith(current or START_WITH_DEFAULT) end)
                end
            end
            G_reader_settings:saveSetting("start_with", START_WITH_BOOKSHELF)
            G_reader_settings:flush()
        end
    elseif current == START_WITH_BOOKSHELF then
        -- 恢复用户原本的启动页；没有记录时回退到 KOReader 默认值
        local restore = nil
        if settings and settings.getPrevStartWith then
            local ok_prev, prev = pcall(function() return settings:getPrevStartWith() end)
            if ok_prev then restore = prev end
        end
        if not restore or restore == "" or restore == START_WITH_BOOKSHELF then
            restore = START_WITH_DEFAULT
        end
        G_reader_settings:saveSetting("start_with", restore)
        G_reader_settings:flush()
        if settings and settings.setPrevStartWith then
            pcall(function() settings:setPrevStartWith(nil) end)
        end
    end
end

--- 原生「初始界面」菜单选中「番茄书架」时的桥接（patches/core.lua 补丁调用）
function Startup.onNativeSelectBookshelf(settings)
    if not settings then return end
    if not Startup.isEnabled(settings) then
        pcall(function() settings:setStartupPage("bookshelf") end)
    end
end

--- 在插件 init 中调用：满足条件时登记"文件管理器上屏后展示书架"的回调
-- @param plugin FanQiePlugin 实例（需有 settings / showBookshelf / ui）
-- @return boolean 是否登记了启动展示
function Startup.maybeShowBookshelf(plugin)
    if startup_handled then return false end
    if not plugin then return false end
    -- 阅读器上下文（ui.document 存在）不处理：初始页面只针对文件管理器
    if plugin.ui and plugin.ui.document then return false end
    if not plugin.showBookshelf then return false end
    if not Startup.isEnabled(plugin.settings) then return false end

    startup_handled = true
    -- 自愈 start_with：全局设置被备份恢复等场景下与插件设置脱节时重新对齐
    Startup.syncKoreaderStartWith(plugin.settings)

    if not (ok_UIManager and UIManager) then return false end
    UIManager:nextTick(function()
        -- nextTick 触发时文件管理器已上屏；异常场景（补丁安装失败等）安全跳过
        local ok, err = pcall(function()
            if plugin.showBookshelf then
                plugin:showBookshelf()
            end
        end)
        if not ok then
            local ok_log, Log = pcall(require, "fanqie.logger")
            if ok_log and Log and Log.error then
                Log.error("[startup] 启动展示书架失败:", tostring(err))
            end
        end
    end)
    return true
end

--- 原生「初始界面」菜单选中其他值时的桥接（patches/core.lua 补丁调用）
-- 用户在原生设置里改选文件浏览器/历史/收藏等时，关闭插件的书架启动页，
-- 避免两边设置不一致（start_with 已被原生菜单改写，这里只需恢复插件侧）。
function Startup.onNativeSelectOther(settings)
    if not settings then return end
    if Startup.isEnabled(settings) then
        pcall(function() settings:setStartupPage("filemanager") end)
    end
end

return Startup
