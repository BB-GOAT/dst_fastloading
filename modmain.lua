local _G = GLOBAL
_G.setmetatable(env, { __index = function(_, key) return _G.rawget(_G, key) end })

-- 快速穿越世界：在世界初始化后安装，与启动期索引独立
if GetModConfigData("fast_migration") then
    modimport("main/migration_runtime.lua")
end

-- 工厂模块在游戏全局环境中执行，不依赖 modimport 的返回值
local function Import(path)
    local chunk = _G.kleiloadlua(MODROOT .. path)
    if _G.type(chunk) ~= "function" then
        _G.error(_G.type(chunk) == "string" and chunk or "无法加载索引模块：" .. path, 0)
    end
    _G.setfenv(chunk, _G)
    return chunk()
end

-- 原生加载优化独立于两种索引；不满足平台条件时只跳过原生部分。
local native_flags = (GetModConfigData("native_zip") and 1 or 0)
    + (GetModConfigData("native_fill") and 2 or 0)
if native_flags > 0 then
    if jit and jit.os == "Windows" and jit.arch == "x64" then
        local ffi = _G.require("ffi")
        local disk = Import("main/loading_index_disk.lua")()
        local result = Import("main/native_loading.lua")({
            ffi = ffi, disk = disk, root = MODROOT, name = modname, flags = native_flags,
        })
        _G.print("[快速加载][原生优化] 启用结果：" .. _G.tostring(result)
            .. "；位 1=整块解压，位 2=内存填充；详见 native/fastloading_native.log")
    else
        _G.print("[快速加载][原生优化] 需要 Windows x64 LuaJIT，已跳过原生优化")
    end
end

-- 启动期索引：分别判断 GetMod 名称索引和文件搜索索引的运行条件
local getmod_enabled = GetModConfigData("getmod_index") == true
local file_enabled = GetModConfigData("file_index_enabled") == true
if not getmod_enabled and not file_enabled then return end

local getmod, index
if getmod_enabled then
    getmod = Import("main/loading_index_getmod.lua")
end

-- 只有文件搜索索引需要 FFI；普通 Lua 和非 Windows 环境直接跳过
if file_enabled then
    if jit and jit.os == "Windows" then
        index = Import("main/loading_index.lua")({
            enabled = true,
            local_mods = GetModConfigData("index_local_mods") == true,
            rebuild = GetModConfigData("rebuild_file_index") == true,
            disk_factory = Import("main/loading_index_disk.lua"),
        })
    else
        _G.print("[快速加载] 文件索引需要 Windows LuaJIT 的 FFI 支持，已跳过文件索引")
    end
end
if not getmod and not index then return end

local old_end = _G.KnownModIndex.EndStartupSequence
local own_end = _G.rawget(_G.KnownModIndex, "EndStartupSequence")
local replacement
local stopped = false

local function stop()
    if stopped then return end
    stopped = true
    if _G.KnownModIndex.EndStartupSequence == replacement then
        _G.KnownModIndex.EndStartupSequence = own_end
    end
    if index then index:Restore() end
    if getmod then getmod:Restore() end
end

local function done(ok, ...)
    stop()
    if not ok then _G.error((...), 0) end
    return ...
end
-- 保护调用仅用于出错后撤销临时索引；保留原始堆栈并重新抛出错误
replacement = function(...)
    local args, count = { ... }, _G.select("#", ...)
    return done(_G.xpcall(function()
        return old_end(_G.unpack(args, 1, count))
    end, _G.debug.traceback))
end

local function install()
    _G.KnownModIndex.EndStartupSequence = replacement
    if getmod then
        getmod:Apply()
        if not getmod.applied then
            _G.print("[快速加载] GetMod 索引未启用：" .. _G.tostring(getmod.reason))
        end
    end
    if index then
        index:Install()
        if not index.active then
            _G.print("[快速加载] 文件索引未启用：" .. _G.tostring(index.reason))
        elseif not index.resource_hook then
            _G.print("[快速加载] 未定位资源搜索入口，资源保留原版搜索，脚本索引继续使用")
        end
    end
end

local ok, reason = _G.xpcall(install, _G.debug.traceback)
if not ok then
    stop()
    _G.error(reason, 0)
end
