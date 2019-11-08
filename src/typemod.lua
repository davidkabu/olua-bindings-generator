local olua = require "olua"

local function command(func)
    return setmetatable({}, {__call = func})
end

local function createTable()
    local t = {}
    local arr = {}
    local map = {}

    function t:__index(key)
        if type(key) == 'number' then
            return arr[key]
        else
            return map[key]
        end
    end

    function t:__newindex(key, value)
        assert(type(key) == 'string', 'only support string field')
        assert(not map[key], 'field conflict: ' .. key)
        map[key] = value
        arr[#arr + 1] = value
    end

    function t:__pairs()
        return pairs(map)
    end

    function t:__ipairs()
        return ipairs(arr)
    end

    function t:toarray()
        return arr
    end

    return setmetatable(t, t)
end

local function typeconfCommand(cls)
    local CMD = {}

    function CMD.ATTR(name, attrs)
        cls.ATTR[name] = attrs
        return CMD
    end

    function CMD.ALIAS(name, alias)
        cls.ALIAS[name] = {NAME = name, ALIAS = alias}
        return CMD
    end

    function CMD.EXCLUDE(name)
        cls.EXCLUDE[name] = true
        return CMD
    end

    function CMD.FUNC(fn, snippet)
        cls.EXCLUDE[fn] = true
        cls.FUNC[fn] = {FUNC = fn, SNIPPET = snippet}
        return CMD
    end

    function CMD.CALLBACK(cb)
        if not cb.NAME then
            cb.NAME = olua.funcname(cb.FUNCS[1])
            cls.EXCLUDE[cb.NAME] = true
        end
        assert(#cb.NAME > 0, 'no callback function name')
        cls.CALLBACK[cb.NAME] = cb
        return CMD
    end

    function CMD.PROP(name, get, set)
        cls.PROP[name] = {NAME = name, GET = get, SET = set}
        return CMD
    end

    function CMD.VAR(name, snippet)
        local varname = olua.funcname(snippet)
        assert(#varname > 0, 'no variable name')
        cls.EXCLUDE[varname] = true
        cls.VAR[name or varname] = {NAME = name, SNIPPET = snippet}
        return CMD
    end

    function CMD.ENUM(name, value)
        cls.ENUM[name] = {NAME = name, VALUE = value}
        return CMD
    end

    function CMD.INJECT(names, codes)
        names = type(names) == 'string' and {names} or names
        for _, n in ipairs(names) do
            cls.INJECT[n] = {NAME = n, CODES = codes}
        end
        return CMD
    end

    function CMD.__index(_, key)
        return cls[key]
    end

    function CMD.__newindex(_, key, value)
        cls[key] = value
    end

    return setmetatable(CMD, CMD)
end

-- function typemod
return function (name)
    local INDEX = 1
    local module = {
        CLASSES = {},
        CONVS = {},
        EXCLUDE_TYPE = {},
        TYPEDEFS = {},
        NAME = name,
    }

    module.EXCLUDE_TYPE = command(function (_, tn)
        module.EXCLUDE_TYPE[tn] = true
    end)

    function module.EXCLUDE_PASS()
    end

    function module.include(path)
        loadfile(path)(module)
    end

    function module.typeconf(classname)
        local cls = {
            CPPCLS = classname,
            ATTR = createTable(),
            ALIAS = createTable(),
            EXCLUDE = createTable(),
            FUNC = createTable(),
            CALLBACK = createTable(),
            PROP = createTable(),
            VAR = createTable(),
            ENUM = createTable(),
            INJECT = createTable(),
            INDEX = INDEX,
            LUANAME = function (n) return n end,
        }
        INDEX = INDEX + 1
        module.CLASSES[classname] = cls
        return typeconfCommand(cls)
    end

    function module.typeonly(classname)
        local cls = module.typeconf(classname)
        cls.EXCLUDE '*'
        return cls
    end

    function module.typedef(info)
        module.TYPEDEFS[#module.TYPEDEFS + 1] = info
    end

    function module.typeconv(info)
        module.CONVS[#module.CONVS + 1] = {
            CPPCLS = assert(info.CPPCLS),
            VARS = info.VARS,
            DEF = olua.format(assert(info.DEF)),
        }
    end

    return module
end