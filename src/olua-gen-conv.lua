local olua = require "olua-io"

local format = olua.format

local function genConvHeader(module)
    local HEADER = string.upper(module.NAME)
    local DECL_FUNCS = {}

    for _, cv in ipairs(module.CONVS) do
        DECL_FUNCS[#DECL_FUNCS + 1] = "// " .. cv.CPPCLS
        local CPPCLS_PATH = olua.topath(cv.CPPCLS)
        DECL_FUNCS[#DECL_FUNCS + 1] = format([[
            int auto_olua_push_${CPPCLS_PATH}(lua_State *L, const ${cv.CPPCLS} *value);
            void auto_olua_check_${CPPCLS_PATH}(lua_State *L, int idx, ${cv.CPPCLS} *value);
            void auto_olua_opt_${CPPCLS_PATH}(lua_State *L, int idx, ${cv.CPPCLS} *value, const ${cv.CPPCLS} &def);
            bool auto_olua_is_${CPPCLS_PATH}(lua_State *L, int idx);
        ]])
        if cv.FUNC.PACK then
            DECL_FUNCS[#DECL_FUNCS + 1] = format([[
                void auto_olua_pack_${CPPCLS_PATH}(lua_State *L, int idx, ${cv.CPPCLS} *value);
                int auto_olua_unpack_${CPPCLS_PATH}(lua_State *L, const ${cv.CPPCLS} *value);
            ]])
        end
        if cv.FUNC.ISPACK then
            DECL_FUNCS[#DECL_FUNCS + 1] = format([[
                bool auto_olua_ispack_${CPPCLS_PATH}(lua_State *L, int idx);
            ]])
        end
        DECL_FUNCS[#DECL_FUNCS + 1] = ""
        olua.nowarning(CPPCLS_PATH)
    end

    DECL_FUNCS = table.concat(DECL_FUNCS, "\n")

    local HEADER_INCLUDES = module.HEADER_INCLUDES
    local PATH = olua.format '${module.PATH}/lua_${module.NAME}.h'
    olua.write(PATH, format([[
        //
        // AUTO BUILD, DON'T MODIFY!
        //
        #ifndef __AUTO_GEN_LUA_${HEADER}_H__
        #define __AUTO_GEN_LUA_${HEADER}_H__

        ${HEADER_INCLUDES}

        ${DECL_FUNCS}

        #endif
    ]]))
    olua.nowarning(HEADER, HEADER_INCLUDES)
end

local function getinitvalue(ti)
    local v = olua.initialvalue(ti)
    if v == '' then
        if ti.DECLTYPE == 'std::string' then
            v = '""'
        elseif ti.CPPCLS then
            v = ti.CPPCLS .. '()'
        else
            error('unknown type:' .. ti.TYPE.CPPCLS)
        end
    end
    return v
end

local function genPushFunc(cv, write)
    local CPPCLS_PATH = olua.topath(cv.CPPCLS)
    local NUM_ARGS = #cv.PROPS
    local OUT = {PUSH_ARGS = olua.newarray('')}

    for _, pi in ipairs(cv.PROPS) do
        local ARG_NAME = format('value->${pi.VARNAME}')
        olua.genPushExp(pi, ARG_NAME, OUT)
        OUT.PUSH_ARGS:push(format([[olua_setfield(L, -2, "${pi.LUANAME}");]]))
        OUT.PUSH_ARGS:push('')
    end

    write(format([[
        int auto_olua_push_${CPPCLS_PATH}(lua_State *L, const ${cv.CPPCLS} *value)
        {
            if (value) {
                lua_createtable(L, 0, ${NUM_ARGS});
                ${OUT.PUSH_ARGS}
            } else {
                lua_pushnil(L);
            }
            
            return 1;
        }
    ]]))
    write('')
    olua.nowarning(CPPCLS_PATH, NUM_ARGS)
end

local function gen_check_func(cv, write)
    local CPPCLS_PATH = olua.topath(cv.CPPCLS)
    local OUT = {
        DECL_ARGS = olua.newarray(),
        CHECK_ARGS = olua.newarray(),
    }
    for i, pi in ipairs(cv.PROPS) do
        local ARG_NAME = 'arg' .. i
        olua.genDeclExp(pi, ARG_NAME, OUT)
        OUT.CHECK_ARGS:push(format([[olua_getfield(L, idx, "${pi.LUANAME}");]]))
        olua.genCheckExp(pi, ARG_NAME, -1, OUT)
        OUT.CHECK_ARGS:push(format([[
            value->${pi.VARNAME} = (${pi.TYPE.CPPCLS})${ARG_NAME};
            lua_pop(L, 1);
        ]]))
        OUT.CHECK_ARGS:push('')
    end

    write(format([[
        void auto_olua_check_${CPPCLS_PATH}(lua_State *L, int idx, ${cv.CPPCLS} *value)
        {
            if (!value) {
                luaL_error(L, "value is NULL");
            }
            idx = lua_absindex(L, idx);
            luaL_checktype(L, idx, LUA_TTABLE);

            ${OUT.DECL_ARGS}

            ${OUT.CHECK_ARGS}
        }
    ]]))
    write('')
    olua.nowarning(CPPCLS_PATH)
end

local function gen_opt_func(cv, write)
    local CPPCLS_PATH = olua.topath(cv.CPPCLS)
    local OUT = {
        DECL_ARGS = olua.newarray(),
        CHECK_ARGS = olua.newarray(),
    }
    for i, pi in ipairs(cv.PROPS) do
        local ARG_NAME = 'arg' .. i
        local INIT_VALUE = pi.DEFAULT or getinitvalue(pi.TYPE)
        pi = setmetatable({DEFAULT = INIT_VALUE}, {__index = pi})
        olua.genDeclExp(pi, ARG_NAME, OUT)
        OUT.CHECK_ARGS:push(format([[olua_getfield(L, idx, "${pi.LUANAME}");]]))
        olua.genCheckExp(pi, ARG_NAME, -1, OUT)
        OUT.CHECK_ARGS:push(format([[
            value->${pi.VARNAME} = (${pi.TYPE.CPPCLS})${ARG_NAME};
            lua_pop(L, 1);
        ]]))
        OUT.CHECK_ARGS:push('')
    end

    write(format([[
        void auto_olua_opt_${CPPCLS_PATH}(lua_State *L, int idx, ${cv.CPPCLS} *value, const ${cv.CPPCLS} &def)
        {
            if (!value) {
                luaL_error(L, "value is NULL");
            }
            if (olua_isnil(L, idx)) {
                *value = def;
            } else {
                idx = lua_absindex(L, idx);
                luaL_checktype(L, idx, LUA_TTABLE);

                ${OUT.DECL_ARGS}

                ${OUT.CHECK_ARGS}
            }
        }
    ]]))
    write('')
    olua.nowarning(CPPCLS_PATH)
end

local function gen_pack_func(cv, write)
    local CPPCLS_PATH = olua.topath(cv.CPPCLS)
    local ARGS_CHUNK = {}

    for i, pi in ipairs(cv.PROPS) do
        local ARG_N = i - 1
        local OLUA_PACK_VALUE = olua.convfunc(pi.TYPE, 'check')
        OLUA_PACK_VALUE = string.gsub(OLUA_PACK_VALUE, '_check_', '_check')
        ARGS_CHUNK[#ARGS_CHUNK + 1] = format([[
            value->${pi.VARNAME} = (${pi.TYPE.CPPCLS})${OLUA_PACK_VALUE}(L, idx + ${ARG_N});
        ]])
        olua.nowarning(ARG_N)
    end

    ARGS_CHUNK = table.concat(ARGS_CHUNK, "\n")
    write(format([[
        void auto_olua_pack_${CPPCLS_PATH}(lua_State *L, int idx, ${cv.CPPCLS} *value)
        {
            if (!value) {
                luaL_error(L, "value is NULL");
            }
            idx = lua_absindex(L, idx);
            ${ARGS_CHUNK}
        }
    ]]))
    write('')
    olua.nowarning(CPPCLS_PATH)
end

local function genUnpackFunc(cv, write)
    local CPPCLS_PATH = olua.topath(cv.CPPCLS)
    local NUM_ARGS = #cv.PROPS
    local ARGS_CHUNK = {}

    for _, pi in ipairs(cv.PROPS) do
        local OLUA_UNPACK_VALUE = olua.convfunc(pi.TYPE, 'push')
        if olua.ispointee(pi.TYPE) then
            ARGS_CHUNK[#ARGS_CHUNK + 1] = format([[
                ${OLUA_UNPACK_VALUE}(L, value->${pi.VARNAME}, "${pi.TYPE.LUACLS}");
            ]])
        else
            ARGS_CHUNK[#ARGS_CHUNK + 1] = format([[
                ${OLUA_UNPACK_VALUE}(L, (${pi.TYPE.DECLTYPE})value->${pi.VARNAME});
            ]])
        end
        olua.nowarning(OLUA_UNPACK_VALUE)
    end

    ARGS_CHUNK = table.concat(ARGS_CHUNK, "\n")
    write(format([[
        int auto_olua_unpack_${CPPCLS_PATH}(lua_State *L, const ${cv.CPPCLS} *value)
        {
            if (value) {
                ${ARGS_CHUNK}
            } else {
                for (int i = 0; i < ${NUM_ARGS}; i++) {
                    lua_pushnil(L);
                }
            }
            
            return ${NUM_ARGS};
        }
    ]]))
    write('')
    olua.nowarning(CPPCLS_PATH, NUM_ARGS)
end

local function genIsFunc(cv, write)
    local CPPCLS_PATH = olua.topath(cv.CPPCLS)
    local TEST_HAS = {'olua_istable(L, idx)'}
    for _, pi in ipairs(cv.PROPS) do
        if not pi.DEFAULT then
            table.insert(TEST_HAS, 2, format([[
                olua_hasfield(L, idx, "${pi.LUANAME}")
            ]]))
        end
    end
    TEST_HAS = table.concat(TEST_HAS, " && ")
    write(format([[
        bool auto_olua_is_${CPPCLS_PATH}(lua_State *L, int idx)
        {
            return ${TEST_HAS};
        }
    ]]))
    write('')
    olua.nowarning(CPPCLS_PATH)
end

local function genIsPackFunc(cv, write)
    local CPPCLS_PATH = olua.topath(cv.CPPCLS)
    local TEST_TYPE = {}
    for i, pi in ipairs(cv.PROPS) do
        local OLUA_IS_VALUE = olua.convfunc(pi.TYPE, 'is')
        local VIDX = i - 1
        TEST_TYPE[#TEST_TYPE + 1] = format([[
            ${OLUA_IS_VALUE}(L, idx + ${VIDX})
        ]])
        olua.nowarning(OLUA_IS_VALUE, VIDX)
    end
    TEST_TYPE = table.concat(TEST_TYPE, " && ")
    write(format([[
        bool auto_olua_ispack_${CPPCLS_PATH}(lua_State *L, int idx)
        {
            return ${TEST_TYPE};
        }
    ]]))
    write('')
    olua.nowarning(CPPCLS_PATH)
end

local function genFuncs(cv, write)
    genPushFunc(cv, write)
    gen_check_func(cv, write)
    gen_opt_func(cv, write)
    genIsFunc(cv, write)

    if cv.FUNC.PACK then
        gen_pack_func(cv, write)
    end
    if cv.FUNC.UNPACK then
        genUnpackFunc(cv, write)
    end
    if cv.FUNC.ISPACK then
        genIsPackFunc(cv, write)
    end
end

local function genConvSource(module)
    local arr = {}
    local function append(value)
        arr[#arr + 1] = value
    end

    append(format([[
        //
        // AUTO BUILD, DON'T MODIFY!
        //
        ${module.INCLUDES}
    ]]))
    append('')

    for _, cv in ipairs(module.CONVS) do
        genFuncs(cv, append)
    end

    local PATH = olua.format '${module.PATH}/lua_${module.NAME}.cpp'
    olua.write(PATH, table.concat(arr, "\n"))
end

function olua.genConv(module, write)
    if write then
        for _, cv in ipairs(module.CONVS) do
            genFuncs(cv, write)
        end
    else
        genConvHeader(module)
        genConvSource(module)
    end
end