---@diagnostic disable: lowercase-global
name = "快速加载"
version = "1.3.0"
author = "冰冰羊"
description = [[
使用多种手段提升游戏加载速度
(大部分功能)需要 Windows LuaJIT 才能工作
]]
api_version = 10
priority = 1e50

dst_compatible = true -- 兼容联机版
forge_compatible = true -- 兼容熔炉
gorge_compatible = true -- 兼容暴食
dont_starve_compatible = false -- 不兼容单机版

luajit_compatible = { -- Luajit兼容性标识 https://steamcommunity.com/sharedfiles/filedetails/?id=3444078585 | https://github.com/fesily/DontStarveLuaJIT2
    dep_tailcall = false -- 表示不依赖堆栈深度
}

all_clients_require_mod = false
client_only_mod = true
server_only_mod = false

restart_required = true -- 资源解压加速/资源初始化加速 功能需要关闭游戏才会被卸载

---@param label string|nil 标题
---@param client_config boolean|nil 是否仅显示在客户端设置页面上
---@return table
local function SkipSpace(label, client_config)
    return { name = "",label = label, hover = "", options = { { description = "", data = false }, }, default = false, client = client_config}
end

configuration_options = {
    SkipSpace("Luajit"),
    {
        name = "file_index_enabled",
        label = "文件搜索索引",
        hover = "需要 Windows LuaJIT，通过文件索引加速模组和游戏本体的脚本、资源搜索",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        default = true,
    },
    {
        name = "index_local_mods",
        label = "索引本地模组",
        hover = "将本地模组也纳入文件索引，按版本号复用清单；手动新增文件后可选择重建",
        options = {
            { description = "关闭（仅工坊）", data = false },
            { description = "开启（工坊和本地）", data = true },
        },
        default = true,
    },
    {
        name = "rebuild_file_index",
        label = "强制重建文件索引",
        hover = "开启后每次加载均重新扫描。手动新增模组文件后可用，完成重建后请关回",
        options = {
            { description = "关闭（复用同版本）", data = false },
            { description = "开启（重新扫描）", data = true },
        },
        default = false,
    },
    {
        name = "native_zip",
        label = "资源解压加速",
        hover = "减少读取压缩游戏资源时的解压耗时；需要 Windows x64 LuaJIT，启停后须完整退出游戏",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        default = true,
    },
    {
        name = "native_fill",
        label = "资源初始化加速",
        hover = "加快资源加载时的内存准备，减少逐字节填充耗时；需要 Windows x64 LuaJIT，启停后须完整退出游戏",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        default = true,
    },
    SkipSpace(),
    {
        name = "getmod_index",
        label = "GetMod名称索引",
        hover = "加速PostInit收集期间的模组查询",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        default = true,
    },
    {
        name = "fast_migration",
        label = "快速穿越世界",
        hover = "减少跨世界的等待时间，原版会重建一次LUA虚拟机才连接目标世界，本功能将跳过该步骤",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        default = true,
    },
}
