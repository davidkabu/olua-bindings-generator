local olua = require "olua-io"

local format = olua.format

local function genInclude(module, write)
    local CHUNK= module.CHUNK
    write(format([[
        //
        // AUTO BUILD, DON'T MODIFY!
        //
        ${module.INCLUDES}
    ]]))
    write('')
    if CHUNK then
        write(format(CHUNK))
        write('')
    end

    if module.CONVS then
        olua.genConv(module, write)
    end
end

local function genClasses(module, write)
    local function doGenClass(cls)
        cls.LUACLS = olua.toluacls(cls.CPPCLS)
        if cls.DEFIF then
            write(cls.DEFIF)
        end
        olua.genClass(module, cls, write)
        if cls.DEFIF then
            write('#endif')
        end
        write('')
    end

    for _, cls in ipairs(module.CLASSES) do
        if #cls > 0 then
            for _, v in ipairs(cls) do
                doGenClass(v)
            end
        else
            doGenClass(cls)
        end
    end
end

local function genLuaopen(module, write)
    local REQUIRES = {}

    local function doGenOpen(cls)
        local CPPCLS_PATH = olua.topath(cls.CPPCLS)
        if cls.DEFIF then
            REQUIRES[#REQUIRES + 1] = cls.DEFIF
        end
        REQUIRES[#REQUIRES + 1] = format([[
            olua_require(L, "${cls.LUACLS}", luaopen_${CPPCLS_PATH});
        ]])
        if cls.DEFIF then
            REQUIRES[#REQUIRES + 1] = '#endif'
        end
    end

    for _, cls in ipairs(module.CLASSES) do
        if #cls > 0 then
            for _, v in ipairs(cls) do
                doGenOpen(v)
            end
        else
            doGenOpen(cls)
        end
    end

    REQUIRES = table.concat(REQUIRES, "\n")
    write(format([[
        int luaopen_${module.NAME}(lua_State *L)
        {
            ${REQUIRES}
            return 0;
        }
    ]]))
    write('')
end

function olua.genSource(module)
    local arr = {}
    local function append(value)
        value = string.gsub(value, ' *#if', '#if')
        value = string.gsub(value, ' *#endif', '#endif')
        arr[#arr + 1] = value
    end

    genInclude(module, append)
    genClasses(module, append)
    genLuaopen(module, append)

    local PATH = olua.format '${module.PATH}/lua_${module.NAME}.cpp'
    olua.write(PATH, table.concat(arr, "\n"))
end