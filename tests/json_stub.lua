-- tests/json_stub.lua —— 极简 JSON 编解码（仅供测试，模拟设备上的 rapidjson 行为）。
-- 只支持备份 payload 用到的形状：对象 / 数组 / 字符串 / 数字 / 布尔 / null。
local M = {}

local function esc(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                      ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
end
M.esc = esc

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

local function encode(v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then return string.format("%.14g", v) end
    if t == "string" then return esc(v) end
    if t ~= "table" then return "null" end
    local parts = {}
    if is_array(v) then
        for i = 1, #v do parts[i] = encode(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, val in pairs(v) do
        parts[#parts + 1] = esc(tostring(k)) .. ":" .. encode(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
M.encode = encode

-- 递归下降解析器
local function decode(str)
    local pos = 1
    local function skip()
        while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local parse_value
    local function parse_string()
        local out = {}
        pos = pos + 1
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(out) end
            if c == "\\" then
                local n = str:sub(pos + 1, pos + 1)
                local map = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\" }
                if n == "u" then
                    out[#out + 1] = "?"; pos = pos + 6
                else
                    out[#out + 1] = map[n] or n; pos = pos + 2
                end
            else
                out[#out + 1] = c; pos = pos + 1
            end
        end
        error("unterminated string")
    end
    local function parse_array()
        pos = pos + 1
        local out = {}
        skip()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return out end
        while true do
            out[#out + 1] = parse_value()
            skip()
            local c = str:sub(pos, pos)
            if c == "," then pos = pos + 1; skip()
            elseif c == "]" then pos = pos + 1; return out
            else error("expected , or ]") end
        end
    end
    local function parse_object()
        pos = pos + 1
        local out = {}
        skip()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return out end
        while true do
            skip()
            local key = parse_string()
            skip()
            if str:sub(pos, pos) ~= ":" then error("expected :") end
            pos = pos + 1
            out[key] = parse_value()
            skip()
            local c = str:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1; return out
            else error("expected , or }") end
        end
    end
    function parse_value()
        skip()
        local c = str:sub(pos, pos)
        if c == "{" then return parse_object() end
        if c == "[" then return parse_array() end
        if c == '"' then return parse_string() end
        local lit = str:match("^(%a+)", pos)
        if lit == "true" then pos = pos + 4; return true end
        if lit == "false" then pos = pos + 5; return false end
        if lit == "null" then pos = pos + 4; return nil end
        local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if num and #num > 0 then pos = pos + #num; return tonumber(num) end
        error("unexpected char at " .. pos .. ": " .. c)
    end
    local ok, value = pcall(parse_value)
    if not ok then return nil end
    return value
end
M.decode = decode

return M
