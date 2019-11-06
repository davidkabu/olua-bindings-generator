local olua = require "olua"

local function command(func)
    return setmetatable({}, {__call = func})
end

local function addcmd(cls)
    cls.ATTR = command(function (_, name, attr)
        cls.ATTR[name] = attr
        return cls
    end)
    cls.ALIAS = command(function (_, name, alias)
        cls.ALIAS[#cls.ALIAS + 1] = {NAME = name, ALIAS = alias}
        return cls
    end)
    cls.EXCLUDE = command(function (_, func)
        cls.EXCLUDE[func] = true
        return cls
    end)
    cls.FUNC = command(function (_, func, snippet)
        cls.EXCLUDE[func] = true
        cls.FUNC[#cls.FUNC + 1] = {FUNC = func, SNIPPET = snippet}
        return cls
    end)
    cls.CALLBACK = command(function (_, opt)
        local func = olua.funcname(opt.FUNCS[1])
        assert(#func > 0, 'no callback function name')
        cls.EXCLUDE[func] = true
        opt.NAME = func
        cls.CALLBACK[#cls.CALLBACK + 1] = opt
        return cls
    end)
    cls.PROP = command(function (_, name, get, set)
        cls.PROP[#cls.PROP + 1] = {NAME = name, GET = get, SET = set}
        return cls
    end)
    cls.VAR = command(function (_, name, snippet)
        local varname = olua.funcname(snippet)
        assert(#varname > 0, 'no variable name')
        cls.EXCLUDE[varname] = true
        cls.VAR[#cls.VAR + 1] = {NAME = name, SNIPPET = snippet}
        return cls
    end)
    cls.ENUM = command(function (_, name, value)
        cls.ENUM[#cls.ENUM + 1] = {NAME = name, VALUE = value}
        return cls
    end)
    cls.INJECT = command(function (_, names, codes)
        cls.INJECT[#cls.INJECT + 1] = {NAMES = names, CODES = codes}
        return cls
    end)
    return cls
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
        EXCLUDE_PASS = function () end,
    }

    module.EXCLUDE_TYPE = command(function (_, tn)
        module.EXCLUDE_TYPE[tn] = true
    end)

    function module.include(path)
        loadfile(path)(module)
    end

    function module.typeconf(classname)
        local cls = {
            CPPCLS = classname,
            INDEX = INDEX,
            LUANAME = function (n) return n end,
        }
        INDEX = INDEX + 1
        module.CLASSES[classname] = cls
        return addcmd(cls)
    end

    function module.typedef(info)
        module.TYPEDEFS[#module.TYPEDEFS + 1] = info
    end

    function module.typeconv(info)
        module.CONVS[#module.CONVS + 1] = {
            CPPCLS = assert(info.CPPCLS),
            VARS = info.VARS,
            DEF = olua.format(assert(info.DEF)),
            FUNC = info.FUNC,
        }
    end

    return module
end