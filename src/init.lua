local file = select(2, ...)
local OS = io.popen('uname'):read("*l")
OS = (OS == 'Darwin') and 'osx' or (OS == 'Linux' and 'linux' or 'win32')
local path = string.gsub(file, 'init.lua', '?.lua;')
local cpath = string.gsub(file, 'src/init.lua', 'lib/' .. OS .. '/?.so;')
package.path = path .. package.path
package.cpath = cpath .. package.cpath
print('add lua search path: ' .. path)
print('add lib search path: ' .. cpath)

local olua = require "olua"
olua.workpath = string.gsub(file, 'src/init.lua', '')

local _ipairs = ipairs
function ipairs(t)
    local mt = getmetatable(t)
    return (mt and mt.__ipairs or _ipairs)(t)
end

local _pairs = pairs
function pairs(t)
    local mt = getmetatable(t)
    return (mt and mt.__pairs or _pairs)(t)
end