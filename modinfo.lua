name = "快速加载"
version = "1.0.0"
author = "冰冰羊"
description = "提前建立模组文件磁盘索引，无模组提供者时直接尝试索引游戏本体，仍未找到才使用原版完整搜索。需要 Windows LuaJIT 才能使用"
api_version = 10
priority = 1e50 -- 晚于提供 FFI 的 LuaJIT 模组，早于普通内容模组。
dst_compatible = true
all_clients_require_mod = false
client_only_mod = true
server_only_mod = false

configuration_options = {
    {
        name = "file_index_enabled",
        label = "文件搜索索引",
        hover = "通过文件索引加速模组和游戏本体的脚本、资源搜索。",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        default = true,
    },
    {
        name = "index_local_mods",
        label = "索引本地模组",
        hover = "将本地模组也纳入文件索引，按版本号复用清单；手动新增文件后可选择重建。",
        options = {
            { description = "关闭（仅工坊）", data = false },
            { description = "开启（工坊和本地）", data = true },
        },
        default = true,
    },
    {
        name = "rebuild_file_index",
        label = "强制重建文件索引",
        hover = "开启后每次加载均重新扫描。手动新增模组文件后可用，完成重建后请关回。",
        options = {
            { description = "关闭（复用同版本）", data = false },
            { description = "开启（重新扫描）", data = true },
        },
        default = false,
    },
    {
        name = "getmod_index",
        label = "GetMod名称索引",
        hover = "独立于文件索引，只加速PostInit收集期间的模组查询。",
        options = {
            { description = "开启", data = true },
            { description = "关闭", data = false },
        },
        default = true,
    },
}
