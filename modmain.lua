local _G = GLOBAL
_G.setmetatable(env, { __index = function(_, key) return _G.rawget(_G, key) end })

-- 快速穿越世界：在世界初始化后安装，与启动期索引独立
if GetModConfigData("fast_migration") then
    modimport("main/migration_runtime.lua")
end

-- 启动期索引：分别判断 GetMod 名称索引和文件搜索索引的运行条件
local getmod_enabled = GetModConfigData("getmod_index") == true
local file_enabled = GetModConfigData("file_index_enabled") == true
if not getmod_enabled and not file_enabled then return end

-- 工厂模块在游戏全局环境中执行，不依赖 modimport 的返回值
local function Import(path)
    local chunk = _G.kleiloadlua(MODROOT .. path)
    if _G.type(chunk) ~= "function" then
        _G.error(_G.type(chunk) == "string" and chunk or "无法加载索引模块：" .. path, 0)
    end
    _G.setfenv(chunk, _G)
    return chunk()
end

local getmod, index
if getmod_enabled then
    getmod = Import("main/loading_index_getmod.lua")
end

-- 只有文件搜索索引需要 FFI；探测失败不影响 GetMod 名称索引
if file_enabled then
    local ffi_ok, ffi = _G.pcall(_G.require, "ffi")
    if ffi_ok and ffi and ffi.os == "Windows" then
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

local function restore(state, label)
    if not state then return end
    local ok, reason = _G.pcall(state.Restore, state)
    if not ok then _G.print("[快速加载] " .. label .. "恢复失败：" .. _G.tostring(reason)) end
end

local function stop()
    if stopped then return end
    stopped = true
    -- 分别清理，避免一组恢复失败阻止另一组恢复
    restore(index, "文件索引")
    restore(getmod, "GetMod 索引")
    if _G.KnownModIndex.EndStartupSequence == replacement then
        _G.KnownModIndex.EndStartupSequence = own_end
    end
end

local function done(ok, ...)
    stop()
    if not ok then _G.error((...), 0) end
    return ...
end
replacement = function(...) return done(_G.pcall(old_end, ...)) end

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

local ok, reason = _G.pcall(install)
if not ok then
    stop()
    _G.error(reason, 0)
end
