local olua = {}

olua.workpath = ''

function olua.write(path, content)
    local file = io.open(path, 'r')
    if file then
        local flag = file:read("*a") == content
        file:close()
        if flag then
            print("up-to-date:", path)
            return
        end
    end

    print("write:", path)

    file = io.open(path, "w")
    assert(file, path)
    file:write(content)
    file:flush()
    file:close()
end

function olua.stringfy(value)
    if value then
        return '"' .. tostring(value) .. '"'
    else
        return nil
    end
end

function olua.newarray(...)
    local mt = {}
    function mt:push(v)
        self[#self + 1] = v
    end
    function mt:tostring(sep)
        return table.concat(self, sep or '\n')
    end
    return setmetatable({...}, {__index = mt})
end

-- suppress lua check warning
function olua.nowarning()
end

local function lookup(level, key)
    assert(key and #key > 0, key)

    local value

    for i = 1, 256 do
        local k, v = debug.getlocal(level, i)
        if k == key then
            value = v
        elseif not k then
            break
        end
    end

    if value then
        return value
    end

    local info1 = debug.getinfo(level, 'Sn')
    local info2 = debug.getinfo(level + 1, 'Sn')
    if info1.source == info2.source or
        info1.short_src == info2.short_src then
        return lookup(level + 1, key)
    end
end

function olua.format(expr, indent)
    expr = string.gsub(expr, '[\n\r]', '\n')
    expr = string.gsub(expr, '^[\n]*', '') -- trim head '\n'
    expr = string.gsub(expr, '[ \n]*$', '') -- trim tail '\n' or ' '

    local space = string.match(expr, '^[ ]*')
    indent = string.rep(' ', indent or 0)
    expr = string.gsub(expr, '^[ ]*', '')  -- trim head space
    expr = string.gsub(expr, '\n' .. space, '\n' .. indent)
    expr = indent .. expr
    
    local function eval(expr)
        return string.gsub(expr, "([ ]*)(${[%w_.]+})", function (indent, str)
            local key = string.match(str, "[%w_]+")
            local level = 1
            local filePath
            -- search caller file path
            while true do
                local info = debug.getinfo(level, 'S')
                if info then
                    if info.source == "=[C]" then
                        level = level + 1
                    else
                        filePath = filePath or info.source
                        if filePath ~= info.source then
                            break
                        else
                            level = level + 1
                        end
                    end
                else
                    break
                end
            end
            -- search in the functin local value
            local value = lookup(level + 1, key) or _G[key]
            for field in string.gmatch(string.match(str, "[%w_.]+"), '[^.]+') do
                if not value then
                    break
                end
                if field ~= key then
                    value = value[field]
                end
            end
            if value == nil then
                error("value not found for '" .. str .. "'")
            else
                -- indent the value if value has multiline
                if type(value) == 'table' and value.tostring then
                    value = value:tostring()
                end
                value = string.gsub(value, '[\n]*$', '')
                return indent .. string.gsub(tostring(value), '\n', '\n' .. indent)
            end
        end)
    end

    expr = eval(expr)
    while true do
        local s, n = string.gsub(expr, '\n[ ]+\n', '\n\n')
        expr = s
        if n == 0 then
            break
        end
    end

    while true do
        local s, n = string.gsub(expr, '\n\n\n', '\n\n')
        expr = s
        if n == 0 then
            break
        end
    end

    expr = string.gsub(expr, '{\n\n', '{\n')
    expr = string.gsub(expr, '\n\n}', '\n}')
    
    return expr
end

function olua.export(path)
    local module = dofile(path)
    if #module.CLASSES > 0 then
        olua.genHeader(module)
        olua.genSource(module)
    elseif #module.CONVS > 0 then
        olua.genConv(module)
    end
end

return olua