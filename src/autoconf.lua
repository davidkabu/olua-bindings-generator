local olua = require "olua"
local clang = require "clang"

local format = olua.format

local cachedClass = {}
local ignoredClass = {}
local visitedClass = {}

local M = {}

local HEADER_PATH = 'autobuild/.autoconf.h'
local logfile = io.open('autobuild/autoconf.log', 'w')

local function log(fmt, ...)
    logfile:write(string.format(fmt, ...))
    logfile:write('\n')
end

setmetatable(ignoredClass, {__gc = function ()
    os.remove(HEADER_PATH)
    for cls, flag in pairs(ignoredClass) do
        if flag then
            log("[ignore class] %s", cls)
        end
    end
end})

function M:parse(path)
    print('autoconf => ' .. path)
    self.conf = dofile(path)
    self.filename = self:toPath(self.conf.NAME)
    self.classes = {}
    self.aliases = {}

    self:doParse()
    self:checkClass()
    self:writeToFile()
end

function M:checkClass()
    for _, cls in ipairs(self.classes) do
        cachedClass[cls.CPPCLS] = cls
    end
    for name, cls in pairs(self.conf.CLASSES) do
        if cls.NOTCONF then
            cachedClass[cls.CPPCLS] = {
                KIND = 'Class',
                CPPCLS = cls.CPPCLS,
                SUPERCLS = cls.SUPERCLS,
                CONF = cls,
                FUNCS = {},
                VARS = {},
                ENUMS = {},
                INST_FUNCS = {},
            }
            self.classes[#self.classes + 1] = cachedClass[cls.CPPCLS]
        elseif not cachedClass[name] then
            error("class '" .. name .. "' not found")
        end
    end
    for _, cls in ipairs(self.classes) do
        if cls.SUPERCLS then
            assert(cachedClass[cls.SUPERCLS],
                " super class not found: " .. cls.CPPCLS .. ' -> ' .. cls.SUPERCLS)
        end
    end
    table.sort(self.classes, function (a, b)
        return a.CONF.INDEX < b.CONF.INDEX
    end)
end

function M:doParse()
    local header = io.open(HEADER_PATH, 'w')
    header:write(format [[
        #ifndef __AUTOCONF_H__\n
        #define __AUTOCONF_H__\n

        #undef __APPLE__
    ]])
    header:write('\n\n')
    for _, HEADER in ipairs(self.conf.PARSER.HEADERS) do
        header:write(format('#include "${HEADER}"'))
        header:write('\n')
    end
    header:write('#endif')
    header:close()

    local index = clang.createIndex(false, true)
    local args = self.conf.PARSER.FLAGS
    local WORKPATH = olua.workpath
    args[#args + 1] = format('-I${WORKPATH}/include/c++')
    args[#args + 1] = format('-I${WORKPATH}/include/c')
    args[#args + 1] = format('-I${WORKPATH}/include/android-sysroot/')
    args[#args + 1] = format('-I${WORKPATH}/include/android-sysroot/x86_64-linux-android')
    args[#args + 1] = '-x'
    args[#args + 1] = 'c++'
    args[#args + 1] = '-DANDROID'
    args[#args + 1] = '-D__linux__'
    args[#args + 1] = '-std=c++11'

    local tu = index:parse(HEADER_PATH, args)
    self:visit(tu:cursor())
end

function M:createClass()
    local cls = {}
    self.classes[#self.classes + 1] = cls
    return cls
end

function M:visitEnum(cur)
    local cls = self:createClass()
    local cppcls = cur:fullname()
    local conf = self.conf.CLASSES[cppcls]
    cls.CONF = conf
    cls.CPPCLS = cppcls
    cls.ENUMS = {}
    visitedClass[cppcls] = true
    if cur:kind() ~= 'TypeAliasDecl' then
        for _, c in ipairs(cur:children()) do
            local kind = c:kind()
            assert(kind == 'EnumConstantDecl', kind)
            cls.ENUMS[#cls.ENUMS + 1] = c:name()
        end
        cls.KIND = 'Enum'
    else
        cls.KIND = 'EnumAlias'
    end
end

function M:shouldExcludeTypeName(name)
    if self.conf.EXCLUDE_TYPE[name] then
        return true
    elseif string.find(name, '<') then
        name = string.gsub(name, '<.*>', '')
        return self:shouldExcludeTypeName(name)
    end
end

function M:shouldExcludeType(type)
    local name = type:name()
    local rawname = string.gsub(name, '^const *', '')
    rawname = string.gsub(rawname, ' *&$', '')
    if self:shouldExcludeTypeName(rawname) then
        return true
    elseif name ~= type:canonical():name() then
        return self:shouldExcludeType(type:canonical())
    end
end

local DEFAULT_ARG_TYPES = {
    IntegerLiteral = true,
    FloatingLiteral = true,
    ImaginaryLiteral = true,
    StringLiteral = true,
    CharacterLiteral = true,
    CXXBoolLiteralExpr = true,
    CXXNullPtrLiteralExpr = true,
    GNUNullExpr = true,
    DeclRefExpr = true,
}

function M:hasDefaultValue(cur)
    for _, c in ipairs(cur:children()) do
        if DEFAULT_ARG_TYPES[c:kind()] then
            return true
        else
            if self:hasDefaultValue(c) then
                return true
            end
        end
    end
end

function M:visitMethod(cls, cur)
    if cur:kind() == 'Constructor' then
        if cur:access() ~= 'public'  or
            cur:isConvertingConstructor() or
            cur:isCopyConstructor() or
            cur:isMoveConstructor() then
            return
        end
    else
        if cur:access() ~= 'public' and cur:kind() ~= 'FunctionDecl' then
            return
        end
    end

    if cur:kind() ~= 'Constructor' then
        if self:shouldExcludeType(cur:resultType()) then
            return
        end
    end

    for _, c in ipairs(cur:children()) do
        if c:kind() == 'UnexposedAttr' then
            return
        end
    end

    for _, arg in ipairs(cur:arguments()) do
        if self:shouldExcludeType(arg:type()) then
            return
        end
    end

    local fn = cur:name()
    local attr = cls.CONF.ATTR[fn] or {}
    local callback = cls.CONF.CALLBACK[fn] or {}
    local exps = {}

    exps[#exps + 1] = attr.RET and (attr.RET .. ' ') or nil
    exps[#exps + 1] = cur:isStatic() and 'static ' or nil

    local callbackType

    if cur:kind() ~= 'Constructor' then
        local resultType = cur:resultType():name()
        local funcType = self:toFuncType(cur:resultType())
        if funcType then
            callbackType = 'RET'
            resultType = funcType
            if callback.NULLABLE then
                exps[#exps + 1] = '@nullable '
            end
            if callback.LOCAL ~= false then
                exps[#exps + 1] = '@local '
            end
        end
        exps[#exps + 1] = resultType
        if not string.find(resultType, '[*&]$') then
            exps[#exps + 1] = ' '
        end
    end

    local optional = false
    exps[#exps + 1] = fn .. '('
    for i, arg in ipairs(cur:arguments()) do
        local type = arg:type():name()
        local funcType = self:toFuncType(arg:type())
        local ARGN = 'ARG' .. i
        if i > 1 then
            exps[#exps + 1] = ', '
        end
        if funcType then
            callbackType = 'ARG'
            type = funcType
            if callback.NULLABLE then
                exps[#exps + 1] = '@nullable '
            end
            if callback.LOCAL ~= false then
                exps[#exps + 1] = '@local '
            end
        end
        if self:hasDefaultValue(arg) then
            exps[#exps + 1] = '@optional '
            optional = true
        else
            assert(not optional, cls.CPPCLS .. '::' .. cur:displayName())
        end
        exps[#exps + 1] = attr[ARGN] and (attr[ARGN] .. ' ') or nil
        exps[#exps + 1] = type
        if not string.find(type, '[*&]$') then
            exps[#exps + 1] = ' '
        end
        exps[#exps + 1] = arg:name()
    end
    exps[#exps + 1] = ')'

    local decl = table.concat(exps, '')
    if self.conf.EXCLUDE_PASS(cls.CPPCLS, fn, decl) then
        return
    else
        return decl, callbackType
    end
end

function M:toFuncType(type)
    local name = type:name()
    if name:find('std::function') then
        return name
    else
        local rawname = string.gsub(name, "^const *", '')
        rawname = string.gsub(rawname, " *[*&]$", '')
        local alias = self.aliases[rawname]
        if alias and alias:find('std::function') then
            return string.gsub(name, rawname, alias)
        end
    end
end

function M:visitFieldDecl(cls, cur)
    if cur:access() ~= 'public' or cur:type():isConst() then
        return nil
    end

    if self:shouldExcludeType(cur:type()) then
        return
    end

    local exps = {}

    if self:hasDefaultValue(cur) then
        exps[#exps + 1] = '@optional '
    end

    local type = self:toFuncType(cur:type())
    if type then
        exps[#exps + 1] = '@nullable '
        local callback = cls.CONF.CALLBACK[cur:name()] or {}
        callback.NOTEXPORT = true
        if callback.LOCAL ~= false then
            exps[#exps + 1] = '@local '
        end
    else
        type = cur:type():name()
    end
    exps[#exps + 1] = type
    if not string.find(type, '[*&]$') then
        exps[#exps + 1] = ' '
    end

    exps[#exps + 1] = cur:name()

    local decl = table.concat(exps, '')
    if self.conf.EXCLUDE_PASS(cls.CPPCLS, cur:name(), decl) then
        return
    else
        return {NAME = cur:name(), SNIPPET = decl}
    end
end

function M:visitClass(cur)
    local cls = self:createClass()
    local filter = {}
    local cppcls = cur:fullname()
    local conf = self.conf.CLASSES[cppcls]
    cls.CPPCLS = cppcls
    cls.SUPERCLS = conf.SUPERCLS
    cls.CONF = conf
    cls.FUNCS = {}
    cls.VARS = {}
    cls.ENUMS = {}
    cls.KIND = 'Class'
    cls.INST_FUNCS = {}

    visitedClass[cppcls] = true

    if cur:kind() == 'Namespace' then
        cls.REG_LUATYPE = false
    end

    ignoredClass[cppcls] = false

    for _, c in ipairs(cur:children()) do
        local kind = c:kind()
        if kind == 'CXXBaseSpecifier' then
            if not cls.SUPERCLS then
                cls.SUPERCLS = c:type():name()
            end
        elseif kind == 'FieldDecl' then
            if conf.EXCLUDE['*'] or conf.EXCLUDE[c:name()] then
                goto continue
            end
            cls.VARS[#cls.VARS + 1] = self:visitFieldDecl(cls, c)
        elseif kind == 'VarDecl' then
            if conf.EXCLUDE['*'] then
                goto continue
            end
            local children = c:children()
            if c:access() == 'public' and #children > 0 then
                local ck = children[1]:kind()
                if ck == 'IntegerLiteral' then
                    cls.ENUMS[#cls.ENUMS + 1] = c:name()
                end
            end
        elseif kind == 'Constructor' or kind == 'FunctionDecl' or kind == 'CXXMethod' then
            local displayName = c:displayName()
            local fn = c:name()
            if (conf.EXCLUDE['*'] or conf.EXCLUDE[fn] or filter[displayName]) or
                (kind == 'Constructor' and (conf.EXCLUDE['new'] or cur:isAbstract())) then
                goto continue
            end
            local func, callbackType = self:visitMethod(cls, c)
            if func then
                if kind == 'FunctionDecl' then
                    func = 'static ' .. func
                elseif not c:isStatic() then
                    cls.INST_FUNCS[displayName] = cls.CPPCLS
                end
                filter[displayName] = true
                cls.FUNCS[#cls.FUNCS + 1] = {
                    FUNC = func,
                    NAME = fn,
                    ARGS = #c:arguments(),
                    CALLBACK_TYPE = callbackType,
                    PROTOTYPE = displayName,
                }
            end
        else
            self:visit(c)
        end

        ::continue::
    end
end

function M:visit(cur)
    local access = cur:access()
    if access == 'private' or access == 'protected' then
        return
    end

    local kind = cur:kind()
    local children = cur:children()
    local cls = cur:fullname()
    local shouldExport = self.conf.CLASSES[cls] and not visitedClass[cls]
    if #children == 0 or string.find(cls, "^std::") then
        return
    elseif kind == 'Namespace' then
        if shouldExport then
            self:visitClass(cur)
        else
            for _, c in ipairs(children) do
                self:visit(c)
            end
        end
    elseif kind == 'ClassDecl' or kind == 'StructDecl' then
        if shouldExport then
            self:visitClass(cur)
        else
            if not self.conf.EXCLUDE_TYPE[cls] then
                if ignoredClass[cls] == nil then
                    ignoredClass[cls] = true
                end
            end
        end
    elseif kind == 'EnumDecl' then
        if shouldExport then
            self:visitEnum(cur)
        end
    elseif kind == 'TypeAliasDecl' then
        self.aliases[cls] = cur:underlyingType():name()
        if shouldExport then
            self:visitEnum(cur)
        end
    elseif kind == 'TypedefDecl' then
        local c = children[1]
        if not c or c:kind() ~= 'UnexposedAttr' then
            local alias = cur:type():name()
            local name = cur:underlyingType():name()
            self.aliases[alias] = self.aliases[name] or name
        end
    else
        for _, c in ipairs(children) do
            self:visit(c)
        end
    end
end

--
-- wirte data
--
function M:toPath(name)
    return string.gsub(name, '_', '-')
end

function M:writeHeader(append)
    append(format([[
        M.NAME = "${self.conf.NAME}"
        M.PATH = "${self.conf.PATH}"
    ]]))

    if self.conf.HEADER_INCLUDES then
        append(format([=[
            M.HEADER_INCLUDES = [[
            ${self.conf.HEADER_INCLUDES}
            ]]
        ]=]))
    end

    append(format([=[
        M.INCLUDES = [[
        ${self.conf.INCLUDES}
        ]]
    ]=]))

    if self.conf.CHUNK then
        append(format([=[
            M.CHUNK = [[
            ${self.conf.CHUNK}
            ]]
        ]=]))
    end

    append('')

    if #self.conf.CONVS > 0 then
        append('M.CONVS = {')
        for _, CONV in ipairs(self.conf.CONVS) do
            append(format([=[
                typeconv {
                    CPPCLS = '${CONV.CPPCLS}',
                    DEF = [[
                        ${CONV.DEF}
                    ]],
                },
            ]=], 4))
        end
        append('}')
        append('')
    end
end

function M:writeTypedef()
    local file = io.open('autobuild/' .. self:toPath(self.conf.NAME) .. '-types.lua', 'w')
    local classes = {}
    local enums = {}
    local typemap = {}
    local function writeLine(fmt, ...)
        file:write(string.format(fmt, ...))
        file:write('\n')
    end
    writeLine("-- AUTO BUILD, DON'T MODIFY!")
    writeLine('')
    writeLine('local olua = require "olua"')
    writeLine('local typedef = olua.typedef')
    writeLine('')
    for _, td in ipairs(self.conf.TYPEDEFS) do
        local arr = {}
        for k, v in pairs(td) do
            arr[#arr + 1] = {k, v}
        end
        table.sort(arr, function (a, b) return a[1] < b[1] end)
        writeLine("typedef {")
        for _, p in ipairs(arr) do
            if type(p[2]) == 'string' then
                if string.find(p[2], '[\n\r]') then
                    writeLine("    %s = [[\n%s]],", p[1], p[2])
                else
                    writeLine("    %s = '%s',", p[1], p[2])
                end
            else
                writeLine("    %s = %s,", p[1], p[2])
            end
        end
        writeLine("}")
        writeLine("")
    end
    for _, v in ipairs(self.conf.CONVS) do
        local CPPCLS_PATH = string.gsub(v.CPPCLS, '::', '_')
        local VARS = v.VARS or 'nil'
        file:write(format([[
            typedef {
                CPPCLS = '${v.CPPCLS}',
                CONV = 'auto_olua_$$_${CPPCLS_PATH}',
                VARS = ${VARS},
            }
        ]]))
        file:write('\n\n')
    end
    for _, cls in ipairs(self.classes) do
        typemap[cls.CPPCLS] = cls
        if cls.KIND == 'Enum' then
            enums[#enums + 1] = cls.CPPCLS
        elseif cls.KIND == 'Class' then
            classes[#classes + 1] = cls.CPPCLS
        end
    end
    for alias, cppcls in pairs(self.aliases) do
        local cls = typemap[cppcls] or typemap[alias]
        if cls then
            if cls.KIND == 'Class' then
                classes[#classes + 1] = alias
            else
                enums[#enums + 1] = alias
            end
        end
    end
    table.sort(classes)
    table.sort(enums)
    for _, v in ipairs(enums) do
        local CPPCLS = v
        local LUACLS = self.conf.MAKE_LUACLS(v)
        file:write(format([[
            typedef {
                CPPCLS = '${CPPCLS}',
                DECLTYPE = 'lua_Unsigned',
                CONV = 'olua_$$_uint',
                LUACLS = '${LUACLS}',
            }
        ]]))
        file:write('\n\n')
    end
    for _, v in ipairs(classes) do
        local CPPCLS = v
        local LUACLS = self.conf.MAKE_LUACLS(v)
        file:write(format([[
            typedef {
                CPPCLS = '${CPPCLS} *',
                CONV = 'olua_$$_cppobj',
                LUACLS = '${LUACLS}',
            }
        ]]))
        file:write('\n\n')
    end
end

local function isNewFunc(supercls, fn)
    if not supercls then
        return true
    end

    local super = cachedClass[supercls]
    if not super then
        error(format("not found super class '${supercls}'"))
    elseif super.INST_FUNCS[fn.PROTOTYPE] or super.CONF.EXCLUDE[fn.NAME] then
        return false
    else
        return isNewFunc(super.SUPERCLS, fn)
    end
end

local function tryAddProp(fn, filter, props)
    if string.find(fn.NAME, '^get') or string.find(fn.NAME, '^is') then
        local name = string.gsub(fn.NAME, '^%l+', '')
        name = string.gsub(name, '^%u+', function (str)
            if #str > 1 and #str ~= #name then
                if #str == #name - 1 then
                    -- maybe XXXXXs
                    return str:lower()
                else
                    return str:sub(1, #str - 1):lower() .. str:sub(#str)
                end
            else
                return str:lower()
            end
        end)
        if not filter[name] then
            filter[name] = true
            if fn.ARGS == 0 then
                props[#props + 1] = name
            end
        else
            for i, v in ipairs(props) do
                if v == name then
                    table.remove(props, i)
                    break
                end
            end
        end
    end
end

function M:writeClass(append)
    append('M.CLASSES = {}')
    append('')
    for _, cls in ipairs(self.classes) do
        if cls.KIND == 'EnumAlias' then
            goto continue
        end
        append(format("cls = typecls '${cls.CPPCLS}'"))
        if cls.SUPERCLS then
            append(format('cls.SUPERCLS = "${cls.SUPERCLS}"'))
        end
        if cls.CONF.REG_LUATYPE == false or cls.REG_LUATYPE == false then
            append('cls.REG_LUATYPE = false')
        end
        if cls.CONF.DEFIF then
            append(format('cls.DEFIF = "${cls.CONF.DEFIF}"'))
        end
        if cls.CONF.CHUNK then
            append(format([=[
                cls.CHUNK = [[
                ${cls.CONF.CHUNK}
                ]]
            ]=]))
        end
        if cls.KIND == 'Enum' then
            append('cls.enums [[')
            for _, value in ipairs(cls.ENUMS) do
                append('    ' .. value)
            end
            append(']]')
        elseif cls.KIND == 'Class' then
            local props = {}
            local filter = {}
            if #cls.ENUMS > 0 then
                append('cls.enums [[')
                for _, value in ipairs(cls.ENUMS) do
                    append('    ' .. value)
                end
                append(']]')
            end
            append('cls.funcs [[')
            local callbacks = {}
            for _, fn in ipairs(cls.FUNCS) do
                if isNewFunc(cls.SUPERCLS, fn) then
                    if not fn.CALLBACK_TYPE and not cls.CONF.CALLBACK[fn.NAME] then
                        append('    ' .. fn.FUNC)
                        tryAddProp(fn, filter, props)
                    else
                        local arr = callbacks[fn.NAME]
                        if not arr then
                            arr = {}
                            callbacks[#callbacks + 1] = arr
                            callbacks[fn.NAME] = arr
                        end
                        arr[#arr + 1] = fn
                    end
                end
            end
            for _, v in ipairs(callbacks) do
                local FUNCS = {}
                for i, fn in ipairs(v) do
                    FUNCS[i] = fn.FUNC
                end
                local TAG = v[1].NAME:gsub('^set', ''):gsub('^get', '')
                local mode = v[1].CALLBACK_TYPE == 'RET' and 'OLUA_TAG_EQUAL' or 'OLUA_TAG_REPLACE'
                local callback = cls.CONF.CALLBACK[v[1].NAME]
                if callback then
                    callback.FUNCS = FUNCS
                    if not callback.TAG_MAKER then
                        callback.TAG_MAKER = olua.format 'olua_makecallbacktag("${TAG}")'
                    end
                    if not callback.TAG_MODE then
                        callback.TAG_MODE = mode
                    end
                else
                    cls.CONF.CALLBACK[v[1].NAME] = {
                        NAME = v[1].NAME,
                        FUNCS = FUNCS,
                        TAG_MAKER = olua.format 'olua_makecallbacktag("${TAG}")',
                        TAG_MODE = mode,
                    }
                end
            end
            for _, cb in ipairs(cls.CONF.CALLBACK) do
                if not cb.NOTEXPORT then
                    assert(cb.FUNCS, "callback '" .. cb.NAME .. "' not found")
                    if #cb.FUNCS == 1 and (string.match(cb.FUNCS[1], '%(%) *$')
                        or (string.match(cb.FUNCS[1], '%( *void *%) *$'))) then
                        tryAddProp({
                            NAME = cb.NAME,
                            ARGS = 0,
                        }, filter, props)
                    end
                end
            end
            append(']]')
            for _, fn in ipairs(cls.VARS) do
                local LUANAME = cls.CONF.LUANAME(fn.NAME)
                append(format("cls.var('${LUANAME}', [[${fn.SNIPPET}]])"))
            end
            self:writeConfEnum(cls, append)
            self:writeConfFunc(cls, append)
            self:writeConfVar(cls, append)
            self:writeConfProp(cls, append)
            self:writeConfCallback(cls, append)
            self:writeConfBlock(cls, append)
            self:writeConfInject(cls, append)
            self:writeConfAlias(cls, append)
            if #props > 0 then
                append('cls.props [[')
                for _, v in ipairs(props) do
                    append('    ' .. v)
                end
                append(']]')
            end
        end
        append('M.CLASSES[#M.CLASSES + 1] = cls')
        append('')

        ::continue::
    end
end

function M:writeConfEnum(cls, append)
    for _, e in ipairs(cls.CONF.ENUM) do
        append(format("cls.enum('${e.NAME}', '${e.VALUE}')"))
    end
end

function M:writeConfFunc(cls, append)
    for _, fn in ipairs(cls.CONF.FUNC) do
        append(format("cls.func('${fn.FUNC}', [[${fn.SNIPPET}]])"))
    end
end

function M:writeConfVar(cls, append)
    for _, fn in ipairs(cls.CONF.VAR) do
        append(format("cls.var('${fn.NAME}', [[${fn.SNIPPET}]])"))
    end
end

function M:writeConfProp(cls, append)
    for _, p in ipairs(cls.CONF.PROP) do
        if not p.GET then
            append(format("cls.prop('${p.NAME}')"))
        elseif string.find(p.GET, '{') then
            if p.SET then
                append(format("cls.prop('${p.NAME}', [[\n${p.GET}]], [[\n${p.SET}]])"))
            else
                append(format("cls.prop('${p.NAME}', [[\n${p.GET}]])"))
            end
        else
            if p.SET then
                append(format("cls.prop('${p.NAME}', '${p.GET}', '${p.SET}')"))
            else
                append(format("cls.prop('${p.NAME}', '${p.GET}')"))
            end
        end
    end
end

function M:writeConfCallback(cls, append)
    for _, v in ipairs(cls.CONF.CALLBACK) do
        if v.NOTEXPORT then
            goto continue
        end
        local FUNCS = olua.newarray("',\n'", "'", "'"):push(table.unpack(v.FUNCS))
        local TAG_MAKER = olua.newarray("', '", "'", "'")
        local TAG_MODE = olua.newarray("', '", "'", "'")
        local TAG_STORE = v.TAG_STORE or 'nil'
        local CALLONCE = tostring(v.CALLONCE == true)
        local REMOVE = tostring(v.REMOVE == true)
        assert(v.TAG_MAKER, 'no tag maker')
        assert(v.TAG_MODE, 'no tag mode')
        if type(v.TAG_MAKER) == 'string' then
            TAG_MAKER:push(v.TAG_MAKER)
        else
            TAG_MAKER:push(table.unpack(v.TAG_MAKER))
            TAG_MAKER = '{' .. tostring(TAG_MAKER) .. '}'
        end
        if type(v.TAG_MODE) == 'string' then
            TAG_MODE:push(v.TAG_MODE)
        else
            TAG_MODE:push(table.unpack(v.TAG_MODE))
            TAG_MODE = '{' .. tostring(TAG_MODE) .. '}'
        end
        append(format([[
            cls.callback {
                FUNCS =  {
                    ${FUNCS}
                },
                TAG_MAKER = ${TAG_MAKER},
                TAG_MODE = ${TAG_MODE},
                TAG_STORE = ${TAG_STORE},
                CALLONCE = ${CALLONCE},
                REMOVE = ${REMOVE},
        ]]))
        if v.CPPFUNC then
            append(string.format("    CPPFUNC = '%s',", v.CPPFUNC))
            assert(v.NEW, 'no new object block')
            append(string.format("    NEW = [[\n%s]],", v.NEW))
        end
        append('}')
        ::continue::
    end
end

function M:writeConfBlock(cls, append)
    if cls.CONF.BLOCK then
        append(cls.CONF.BLOCK)
    end
end

function M:writeConfInject(cls, append)
    for _, v in ipairs(cls.CONF.INJECT) do
        append(string.format("cls.inject('%s', {", v.NAME))
        if v.CODES.BEFORE then
            append(string.format('    BEFORE = [[\n%s]],', v.CODES.BEFORE))
        end
        if v.CODES.AFTER then
            append(string.format('    AFTER = [[\n%s]],', v.CODES.AFTER))
        end
        if v.CODES.CALLBACK_BEFORE then
            append(string.format('    CALLBACK_BEFORE = [[\n%s]],', v.CODES.CALLBACK_BEFORE))
        end
        if v.CODES.CALLBACK_AFTER then
            append(string.format('    CALLBACK_AFTER = [[\n%s]],', v.CODES.CALLBACK_AFTER))
        end
        append(string.format('})'))
    end
end

function M:writeConfAlias(cls, append)
    for _, v in ipairs(cls.CONF.ALIAS) do
        append(format("cls.alias('${v.NAME}', '${v.ALIAS}')"))
    end
end

function M:writeToFile()
    local file = io.open(format('autobuild/${self.filename}.lua'), 'w')

    local function append(...)
        file:write(...)
        file:write('\n')
    end

    append(format([[
        -- AUTO BUILD, DON'T MODIFY!

        require "autobuild.${self.filename}-types"

        local olua = require "olua"
        local typeconv = olua.typeconv
        local typecls = olua.typecls
        local cls = nil
        local M = {}
    ]]))
    append('')

    self:writeHeader(append)
    self:writeClass(append)
    self:writeTypedef(append)

    append('return M')
end

return function (path)
    local inst = setmetatable({}, {__index = M})
    inst:parse(path)
end