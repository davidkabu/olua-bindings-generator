local olua = require "olua"
local clang = require "clang"

local format = olua.format

local cachedClass = {}
local ignoredClass = {}

local M = {}

local logfile = io.open('autobuild/autoconf.log', 'w')

local function log(fmt, ...)
    logfile:write(string.format(fmt, ...))
    logfile:write('\n')
end

setmetatable(ignoredClass, {__gc = function ()
    for cls, flag in pairs(ignoredClass) do
        if flag then
            log("[ignore class] %s", cls)
        end
    end
end})

function M:parse(path)
    print('autoconf => ' .. path)
    self.conf = dofile(path)
    self.classes = {}
    self.typeAlias = {}

    self._file = io.open('autobuild/' .. self:toPath(self.conf.NAME) .. '.lua', 'w')

    local headerPath = 'autobuild/.autoconf.h'
    local header = io.open(headerPath, 'w')
    header:write('#ifndef __AUTOCONF_H__\n')
    header:write('#define __AUTOCONF_H__\n')
    header:write(string.format('#include "%s"\n', "gltypes.h"))
    for _, v in ipairs(self.conf.PARSER.HEADERS) do
        header:write(string.format('#include "%s"\n', v))
    end
    header:write('#endif')
    header:close()

    -- clang_createIndex(int excludeDeclarationsFromPCH, int displayDiagnostics);
    -- local index = clang.createIndex(false, true)
    local index = clang.createIndex(false, false)
    local args = self.conf.PARSER.FLAGS
    args[#args + 1] = '-I/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/include/c++/v1'
    args[#args + 1] = '-I/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/11.0.0/include'
    args[#args + 1] = '-I/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/usr/include'
    args[#args + 1] = '-I' .. olua.workpath .. '/include'
    args[#args + 1] = '-x'
    args[#args + 1] = 'c++'
    args[#args + 1] = '-D__arm64__'
    args[#args + 1] = '-std=c++11'

    local tu = index:parse(headerPath, args)
    self:visit(tu:cursor())
    self:writeLine("-- AUTO BUILD, DON'T MODIFY!")
    self:writeLine('')
    self:writeLine('require "autobuild.%s-types"', self:toPath(self.conf.NAME))
    self:writeLine('')
    self:writeLine('local olua = require "olua"')
    self:writeLine('local typeconv = olua.typeconv')
    self:writeLine('local typecls = olua.typecls')
    self:writeLine('local cls = nil')
    self:writeLine('local M = {}')
    self:writeLine('')
    self:writeLine('olua.nowarning(typeconv, typecls, cls)')
    self:writeLine('')
    self:writeHeader()
    self:writeClass()
    self:writeTypedef()
    self:writeLine('return M')

    os.remove(headerPath)
end

function M:toPath(name)
    return string.gsub(name, '_', '-')
end

function M:write(fmt, ...)
    self._file:write(string.format(fmt, ...))
end

function M:writeLine(fmt, ...)
    self:write(fmt, ...)
    self._file:write('\n')
end

function M:writeRaw(str)
    self._file:write(str)
end

function M:writeHeader()
    self:writeLine('M.NAME = "' .. self.conf.NAME .. '"')
    self:writeLine('M.PATH = "' .. self.conf.PATH .. '"')
    if self.conf.HEADER_INCLUDES then
        self:writeLine('M.HEADER_INCLUDES = [[')
        self:write(self.conf.HEADER_INCLUDES)
        self:writeLine(']]')
    end
    self:writeLine('M.INCLUDES = [[')
    self:write(self.conf.INCLUDES)
    self:writeLine(']]')
    if self.conf.CHUNK then
        self:writeLine('M.CHUNK = [[')
        self:writeRaw(self.conf.CHUNK)
        self:writeLine(']]')
    end
    self:writeLine('')
    if #self.conf.CONVS > 0 then
        self:writeLine('M.CONVS = {')
        for _, v in ipairs(self.conf.CONVS) do
            olua.nowarning(v)
            self:writeLine(format([=[
                typeconv {
                    CPPCLS = '${v.CPPCLS}',
                    DEF = [[
                        ${v.DEF}
                    ]],
                },
            ]=], 4))
        end
        self:writeLine('}')
        self:writeLine('')
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
    writeLine('olua.nowarning(typedef)')
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
        olua.nowarning(CPPCLS_PATH, VARS)
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
    for alias, cppcls in pairs(self.typeAlias) do
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
        olua.nowarning(CPPCLS, LUACLS)
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
        olua.nowarning(CPPCLS, LUACLS)
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

function M:writeClass()
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
    local function shouldExportFunc(supercls, fn)
        if supercls then
            local super = assert(cachedClass[supercls], "not found super class '" .. supercls .. "'")
            if super.INST_FUNCS[fn.PROTOTYPE] or super.CONF.EXCLUDE[fn.NAME] then
                return false
            else
                return shouldExportFunc(super.SUPERCLS, fn)
            end
        else
            return true
        end
    end
    self:writeLine('M.CLASSES = {}')
    self:writeLine('')
    for _, cls in ipairs(self.classes) do
        if cls.KIND == 'EnumAlias' then
            goto continue
        end
        self:writeLine("cls = typecls '%s'", cls.CPPCLS)
        if cls.SUPERCLS then
            self:writeLine('cls.SUPERCLS = "' .. cls.SUPERCLS .. '"')
        end
        if cls.CONF.REG_LUATYPE == false or cls.REG_LUATYPE == false then
            self:writeLine('cls.REG_LUATYPE = false')
        end
        if cls.CONF.DEFIF then
            self:writeLine('cls.DEFIF = "%s"', cls.CONF.DEFIF)
        end
        if cls.CONF.CHUNK then
            self:writeLine('cls.CHUNK = [[')
            self:writeRaw(cls.CONF.CHUNK)
            self:writeLine(']]')
        end
        if cls.KIND == 'Enum' then
            self:writeLine('cls.enums [[')
            for _, value in ipairs(cls.ENUMS) do
                self:writeLine('    ' .. value)
            end
            self:writeLine(']]')
        elseif cls.KIND == 'Class' then
            local props = {}
            local filter = {}
            local function tryAddProp(fn)
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
            if #cls.ENUMS > 0 then
                self:writeLine('cls.enums [[')
                for _, value in ipairs(cls.ENUMS) do
                    self:writeLine('    ' .. value)
                end
                self:writeLine(']]')
            end
            self:writeLine('cls.funcs [[')
            for _, fn in ipairs(cls.FUNCS) do
                if shouldExportFunc(cls.SUPERCLS, fn) then
                    self:writeLine('    ' .. fn.FUNC)
                    tryAddProp(fn)
                end
            end
            for _, cb in ipairs(cls.CONF.CALLBACK) do
                if #cb.FUNCS == 1 and (string.match(cb.FUNCS[1], '%(%) *$')
                    or (string.match(cb.FUNCS[1], '%( *void *%) *$'))) then
                    tryAddProp({
                        NAME = cb.NAME,
                        ARGS = 0,
                    })
                end
            end
            self:writeLine(']]')
            for _, fn in ipairs(cls.VARS) do
                self:writeLine("cls.var('%s', [[%s]])", fn.NAME, fn.SNIPPET)
            end
            self:writeConfEnum(cls)
            self:writeConfFunc(cls)
            self:writeConfVar(cls)
            self:writeConfProp(cls)
            self:writeConfCallback(cls)
            self:writeConfBlock(cls)
            self:writeConfInject(cls)
            self:writeConfAlias(cls)
            if #props > 0 then
                self:writeLine('cls.props [[')
                for _, v in ipairs(props) do
                    self:writeLine('    ' .. v)
                end
                self:writeLine(']]')
            end
        end
        self:writeLine('M.CLASSES[#M.CLASSES + 1] = cls')
        self:writeLine('')

        ::continue::
    end
end

function M:writeConfEnum(cls)
    for _, e in ipairs(cls.CONF.ENUM) do
        self:writeLine("cls.enum('%s', '%s')", e.NAME, e.VALUE)
    end
end

function M:writeConfFunc(cls)
    for _, fn in ipairs(cls.CONF.FUNC) do
        self:writeLine("cls.func('%s', [[%s]])", fn.FUNC, fn.SNIPPET)
    end
end

function M:writeConfVar(cls)
    for _, fn in ipairs(cls.CONF.VAR) do
        self:writeLine("cls.var('%s', [[%s]])", fn.NAME, fn.SNIPPET)
    end
end

function M:writeConfProp(cls)
    for _, p in ipairs(cls.CONF.PROP) do
        if not p.GET then
            self:writeLine("cls.prop('%s')", p.NAME)
        elseif string.find(p.GET, '{') then
            if p.SET then
                self:writeLine("cls.prop('%s', [[\n%s]], [[\n%s]])", p.NAME, p.GET, p.SET)
            else
                self:writeLine("cls.prop('%s', [[\n%s]])", p.NAME, p.GET)
            end
        else
            if p.SET then
                self:writeLine("cls.prop('%s', '%s', '%s')", p.NAME, p.GET, p.SET)
            else
                self:writeLine("cls.prop('%s', '%s')", p.NAME, p.GET)
            end
        end
    end
end

function M:writeConfCallback(cls)
    for _, v in ipairs(cls.CONF.CALLBACK) do
        self:writeLine('cls.callback {')
        self:writeLine('    FUNCS =  {')
        for _, fn in ipairs(v.FUNCS) do
            self:writeLine("        '%s',", fn)
        end
        assert(v.TAG_MAKER, 'no tag maker')
        assert(v.TAG_MODE, 'no tag mode')
        self:writeLine('    },')
        if type(v.TAG_MAKER) == 'string' then
            self:writeLine("    TAG_MAKER = '%s',", v.TAG_MAKER)
        else
            self:writeLine("    TAG_MAKER = {'%s'},", table.concat(v.TAG_MAKER, "', '"))
        end
        if type(v.TAG_MODE) == 'string' then
            self:writeLine("    TAG_MODE = '%s',", v.TAG_MODE)
        else
            self:writeLine("    TAG_MODE = {'%s'},", table.concat(v.TAG_MODE, "', '"))
        end
        if v.TAG_STORE then
            self:writeLine('    TAG_STORE = %s,', v.TAG_STORE)
        end
        if v.CPPFUNC then
            self:writeLine("    CPPFUNC = '%s',", v.CPPFUNC)
            assert(v.NEW, 'no new object block')
            self:writeLine("    NEW = [[\n%s]],", v.NEW)
        end
        self:writeLine("    CALLONCE = %s,", v.CALLONCE == true)
        self:writeLine("    REMOVE = %s,", v.REMOVE == true)
        self:writeLine('}')
    end
end

function M:writeConfBlock(cls)
    if cls.CONF.BLOCK then
        self:writeLine(cls.CONF.BLOCK)
    end
end

function M:writeConfInject(cls)
    for _, v in ipairs(cls.CONF.INJECT) do
        if type(v.NAMES) == 'string' then
            self:writeLine("cls.inject('%s', {", v.NAMES)
        else
            self:writeLine("cls.inject({'%s'}, {", table.concat(v.NAMES, "', '"))
        end
        if v.CODES.BEFORE then
            self:writeLine('    BEFORE = [[\n%s]],', v.CODES.BEFORE)
        end
        if v.CODES.AFTER then
            self:writeLine('    AFTER = [[\n%s]],', v.CODES.AFTER)
        end
        if v.CODES.CALLBACK_BEFORE then
            self:writeLine('    CALLBACK_BEFORE = [[\n%s]],', v.CODES.CALLBACK_BEFORE)
        end
        if v.CODES.CALLBACK_AFTER then
            self:writeLine('    CALLBACK_AFTER = [[\n%s]],', v.CODES.CALLBACK_AFTER)
        end
        self:writeLine('})')
    end
end

function M:writeConfAlias(cls)
    for _, v in ipairs(cls.CONF.ALIAS) do
        self:writeLine("cls.alias('%s', '%s')", v.NAME, v.ALIAS)
    end
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

function M:shouldExcludeType(type, ignoreCallback)
    local name = type:name()
    if ignoreCallback and string.find(name, 'std::function') then
        return true
    end
    local rawname = string.gsub(name, '^const *', '')
    rawname = string.gsub(rawname, ' *&$', '')
    if self.conf.EXCLUDE_TYPE[rawname] then
        return true
    elseif name ~= type:canonical():name() then
        return self:shouldExcludeType(type:canonical(), ignoreCallback)
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
        if self:shouldExcludeType(cur:resultType(), true) then
            return
        end
    end

    for _, c in ipairs(cur:children()) do
        if c:kind() == 'UnexposedAttr' then
            return
        end
    end

    for _, arg in ipairs(cur:arguments()) do
        if self:shouldExcludeType(arg:type(), true) then
            return
        end
    end

    local attr = cls.CONF.ATTR[cur:name()] or {}
    local exps = {}

    exps[#exps + 1] = attr.RET and (attr.RET .. ' ') or nil
    exps[#exps + 1] = cur:isStatic() and 'static ' or nil

    if cur:kind() ~= 'Constructor' then
        local resultType = cur:resultType():name()
        exps[#exps + 1] = resultType
        if not string.find(resultType, '[*&]$') then
            exps[#exps + 1] = ' '
        end
    end

    local optional = false
    exps[#exps + 1] = cur:name() .. '('
    for i, arg in ipairs(cur:arguments()) do
        local type = arg:type():name()
        local ARGN = 'ARG' .. i
        if i > 1 then
            exps[#exps + 1] = ', '
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
    if self.conf.EXCLUDE_PATTERN(cls.CPPCLS, cur:name(), decl) then
        return
    else
        return decl
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

    local type = cur:type():name()
    exps[#exps + 1] = type
    if not string.find(type, '[*&]$') then
        exps[#exps + 1] = ' '
    end

    exps[#exps + 1] = cur:name()

    local decl = table.concat(exps, '')
    if self.conf.EXCLUDE_PATTERN(cls.CPPCLS, cur:name(), decl) then
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
            local func = self:visitMethod(cls, c)
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
    local kind = cur:kind()
    local children = cur:children()
    local shouldExport = self.conf.CLASSES[cur:fullname()]
    if #children == 0 then
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
            local cls = cur:fullname()
            if not self.conf.EXCLUDE_TYPE[cls] and not string.find(cls, '^std::') then
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
        local fullname = cur:fullname()
        if not string.find(fullname, '^std::') then
            self.typeAlias[fullname] = cur:type():canonical():name()
            if shouldExport then
                self:visitEnum(cur)
            end
        end
    else
        for _, c in ipairs(children) do
            self:visit(c)
        end
    end
end

return function (path)
    local inst = setmetatable({}, {__index = M})
    inst:parse(path)
end