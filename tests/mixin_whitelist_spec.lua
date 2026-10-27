-- 防回归：每个动作模块里的 M: 方法都必须挂到插件上。
-- 历史缺陷：新增模块方法忘记加入 main.lua 的 ACTION_MODULES 白名单，
-- 真机上表现为「点了菜单没反应」或「attempt to call method (a nil value)」，
-- 而结构测试因为不认识新方法所以一路绿。
local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local main_src = io.open(root .. "/main.lua", "rb"):read("*a")
local block = main_src:match("local ACTION_MODULES = (.-)\n}\n")
if not block then
    io.stderr:write("FAIL: 找不到 ACTION_MODULES 定义\n")
    os.exit(1)
end
-- 白名单里的所有方法名（字符串字面量）
local whitelist = {}
for name in block:gmatch('"([_%a][_%w]*)"') do whitelist[name] = true end

local modules = {
    "fanqie/chapters/chapter_actions.lua",
    "fanqie/cache/cache_actions.lua",
    "fanqie/opening/open_book_actions.lua",
    "fanqie/reader/reader_actions.lua",
    "fanqie/shelf/shelf_actions.lua",
    "fanqie/menus/menu_actions.lua",
    "fanqie/details/book_detail_actions.lua",
    "fanqie/comments/comment_actions.lua",
    "fanqie/comments/comment_view_actions.lua",
}

local failures = 0
local checked = 0
for _, path in ipairs(modules) do
    local f = io.open(root .. "/" .. path, "rb")
    if f then
        local src = f:read("*a")
        f:close()
        local missing = {}
        for name in src:gmatch("function M:([_%a][_%w]*)") do
            checked = checked + 1
            if not whitelist[name] then missing[#missing + 1] = name end
        end
        if #missing > 0 then
            failures = failures + 1
            io.stderr:write("FAIL: " .. path .. " 有未挂载的方法: "
                .. table.concat(missing, ", ") .. "\n")
        end
    end
end

if failures > 0 then os.exit(1) end
print("Mixin whitelist: OK (" .. checked .. " methods checked)")
