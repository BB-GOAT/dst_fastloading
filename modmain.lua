local G = GLOBAL
G.setmetatable(env, { __index = function(_, key) return G.rawget(G, key) end })
if G.rawget(G, "DST_LOADING_INDEX") then return end

local getmod = G.require("loading_index_getmod")(G, GetModConfigData("getmod_index") == true)
getmod:Apply()
local index = G.require("loading_index")(G, {
    enabled = GetModConfigData("file_index_enabled") == true,
    local_mods = GetModConfigData("index_local_mods") == true,
    rebuild = GetModConfigData("rebuild_file_index") == true,
    modroot = MODROOT,
})
G.rawset(G, "DST_LOADING_INDEX", index)
index:Install()
if index.enabled and not index.active then
    G.print("[模组加载索引] 文件索引未启用：" .. G.tostring(index.reason))
elseif index.active and not index.resource_hook then
    G.print("[模组加载索引] 未定位资源搜索入口，资源保留原版搜索，脚本索引继续使用。")
end
if getmod.enabled and not getmod.applied then
    G.print("[模组加载索引] GetMod 索引未启用：" .. G.tostring(getmod.reason))
end

-- 加载完成后恢复钩子并释放内存索引，磁盘清单留待下次加载复用。
local old_end = G.KnownModIndex.EndStartupSequence
local own_end = G.rawget(G.KnownModIndex, "EndStartupSequence")
local replacement
local stopped = false
local function stop()
    if stopped then return end
    stopped = true
    index:Restore()
    getmod:Restore()
    if G.KnownModIndex.EndStartupSequence == replacement then G.KnownModIndex.EndStartupSequence = own_end end
end
local function done(...) stop(); return ... end
replacement = function(...) return done(old_end(...)) end
G.KnownModIndex.EndStartupSequence = replacement
