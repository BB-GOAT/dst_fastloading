local G = GLOBAL
G.setmetatable(env, { __index = function(_, key) return G.rawget(G, key) end })

-- 快速穿越世界
if GetModConfigData("fast_migration") then
    modimport("main/migration_runtime.lua")
end

local function Import(modulename, file_env)
    local f = G.kleiloadlua(modulename)
    if f and type(f) == "function" then
        G.setfenv(f, file_env or env)
        return f()
    end
end

local ffi_ok, ffi = G.pcall(G.require, "ffi")
if not ffi_ok or not ffi or ffi.os ~= "Windows" then G.print("[快速加载] 文件索引需要 Windows LuaJIT 的 FFI 支持，已跳过索引加载") return end

if G.rawget(G, "DST_LOADING_INDEX") then return end

local getmod = Import(MODROOT .. "main/loading_index_getmod.lua", GLOBAL)(G, GetModConfigData("getmod_index") == true)
local index = Import(MODROOT .. "main/loading_index.lua", GLOBAL)(G, {
    enabled = GetModConfigData("file_index_enabled") == true,
    local_mods = GetModConfigData("index_local_mods") == true,
    rebuild = GetModConfigData("rebuild_file_index") == true,
    disk_factory = Import(MODROOT .. "main/loading_index_disk.lua", GLOBAL),
})

local old_end = G.KnownModIndex.EndStartupSequence
local own_end = G.rawget(G.KnownModIndex, "EndStartupSequence")
local replacement
local stopped = false
local function stop()
    if stopped then return end
    stopped = true
    -- 分别清理，避免一组恢复失败阻止另一组恢复。
    local index_ok, index_error = G.pcall(index.Restore, index)
    local getmod_ok, getmod_error = G.pcall(getmod.Restore, getmod)
    if G.KnownModIndex.EndStartupSequence == replacement then G.KnownModIndex.EndStartupSequence = own_end end
    if not index_ok then G.print("[快速加载] 文件索引恢复失败：" .. G.tostring(index_error)) end
    if not getmod_ok then G.print("[快速加载] GetMod 索引恢复失败：" .. G.tostring(getmod_error)) end
end
local function done(ok, ...)
    stop()
    if not ok then G.error((...), 0) end
    return ...
end
replacement = function(...) return done(G.pcall(old_end, ...)) end

local function install()
    G.rawset(G, "DST_LOADING_INDEX", index)
    G.KnownModIndex.EndStartupSequence = replacement
    getmod:Apply()
    index:Install()
    if index.enabled and not index.active then
        G.print("[快速加载] 文件索引未启用：" .. G.tostring(index.reason))
    elseif index.active and not index.resource_hook then
        G.print("[快速加载] 未定位资源搜索入口，资源保留原版搜索，脚本索引继续使用。")
    end
    if getmod.enabled and not getmod.applied then
        G.print("[快速加载] GetMod 索引未启用：" .. G.tostring(getmod.reason))
    end
end
local ok, reason = G.pcall(install)
if not ok then
    stop()
    if G.rawget(G, "DST_LOADING_INDEX") == index then G.rawset(G, "DST_LOADING_INDEX", nil) end
    G.error(reason, 0)
end
