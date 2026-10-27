#!/usr/bin/env luajit
-- tests/free_globals.lua —— 检测各模块中「读了但没定义」的全局标识符。
--
-- 背景：把 main.lua 拆成多模块时，原先文件级的 local（常量、require 出来的
-- 模块表）在搬走后变成了裸全局引用。LuaJIT 编译期不报，只有真跑到那一行
-- 才炸（真机上表现为「展开回复时报 attempt to index global 'Client'」）。
--
-- 做法：loadfile 取字节码，扫描 GETGLOBAL / GLOBAL 绑定，排除：
--   · Lua 标准库与 LuaJIT 内建
--   · KOReader 的全局（G_reader_settings / Screen 等由运行时注入的除外——
--     那些在模块里必须显式取用，所以不排除）
-- 用法：luajit tests/free_globals.lua <插件根目录>
local root = arg[1] or "."
local known = {}
for _, name in ipairs({
    -- Lua 5.1 / LuaJIT
    "assert", "collectgarbage", "dofile", "error", "getfenv", "getmetatable",
    "ipairs", "load", "loadfile", "loadstring", "module", "next", "pairs",
    "pcall", "print", "rawequal", "rawget", "rawset", "require", "select",
    "setfenv", "setmetatable", "tonumber", "tostring", "type", "unpack",
    "xpcall", "_G", "_VERSION", "arg", "jit", "bit", "ffi", "newproxy",
    -- Lua 标准库表
    "io", "os", "math", "string", "table", "coroutine", "debug", "package",
    -- KOReader 运行时注入的全局
    "G_reader_settings", "G_defaults", "Screen",
}) do known[name] = true end

local failures = 0
local checked = 0

local function check(path)
    local chunk, err = loadfile(path)
    if not chunk then
        print(("SYNTAX %s: %s"):format(path, err))
        failures = failures + 1
        return
    end
    checked = checked + 1
    local proto = debug.getinfo(chunk, "S").func
    -- 递归遍历所有 proto：LuaJIT 的 debug.getinfo 只有顶层，用 string.dump
    -- 太绕，这里改用 loadstring + 运行时钩子不可行；直接扫描字节码更可靠。
    local bad = {}
    local listing = io.popen(("luajit -bl %q 2>/dev/null"):format(path))
    if listing then
        for line in listing:lines() do
            local name = line:match('GGET%s+%d+%s+%d+%s+;%s+"([%w_]+)"')
                or line:match('GGET%s+%d+%s+%d+%s+;%s+([%w_]+)')
            if name and not known[name] then
                bad[name] = (bad[name] or 0) + 1
            end
        end
        listing:close()
    end
    local names = {}
    for name, count in pairs(bad) do
        names[#names + 1] = ("%s(×%d)"):format(name, count)
    end
    if #names > 0 then
        table.sort(names)
        print(("FREE  %s: %s"):format(path, table.concat(names, " ")))
        failures = failures + 1
    end
end

local pipe = io.popen(("find %q -name '*.lua' -not -path '*/tests/*' | sort"):format(root))
for path in pipe:lines() do check(path) end
pipe:close()

if failures > 0 then
    print(("\n%d file(s) with free global references"):format(failures))
    os.exit(1)
end
print(("OK: %d files, no undefined global reads"):format(checked))
