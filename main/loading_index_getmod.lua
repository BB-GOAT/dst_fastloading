-- 仅在 PostInit 收集期间使用索引；不缓存回调列表，不改变回调顺序。
return function(G, enabled)
    local rawget, type, pcall = G.rawget, G.type, G.pcall
    local manager = G.ModManager
    local state = {
        enabled = enabled == true, applied = false, restored = false,
        reason = "not_reached",
    }
    local hooks = {}
    local source, rows, names, byname
    local entry_count = 0
    local scope = 0

    -- 每次收集前检查整个有效前缀，处理换表、同长度替换、改名和重排。
    -- ipairs 在第一个 nil 处结束；索引必须遵守相同语义和重复名首次命中顺序。
    local function refresh()

        local mods = manager.mods
        if type(mods) ~= "table" or G.getmetatable(mods) then return false end
        local unchanged = mods == source
        local count = 0
        for i, mod in G.ipairs(mods) do
            if type(mod) ~= "table" then return false end
            local name = rawget(mod, "modname")
            if type(name) ~= "string" then return false end
            count = i
            if unchanged and (rows[i] ~= mod or names[i] ~= name) then unchanged = false end
        end
        if unchanged and count == entry_count then return true end
        source, rows, names, byname = mods, {}, {}, {}
        for i, mod in G.ipairs(mods) do
            local name = rawget(mod, "modname")
            rows[i], names[i] = mod, name
            if not byname[name] then byname[name] = mod end
        end
        entry_count = count
        return true
    end

    local function hook(key, factory)
        local old = manager[key]
        local replacement = factory(old)
        hooks[#hooks + 1] = { key = key, old = old, own = rawget(manager, key) ~= nil,
            replacement = replacement }
        manager[key] = replacement
    end

    function state:Install()
        if self.installed or self.restored or not self.enabled then return end
        for _, key in G.ipairs({ "GetMod", "GetPostInitFns", "GetPostInitData" }) do
            if type(manager[key]) ~= "function" then G.error("GetMod 索引缺少接口：" .. key, 0) end
        end
        -- 已有包装可能改变返回值或执行必要登记，不用名称索引跳过它。
        local debug = G.debug
        local info = debug and debug.getinfo and debug.getinfo(manager.GetMod, "S")
        local source = info and info.source:gsub("\\", "/"):gsub("^@", "")
        if source ~= "scripts/mods.lua" then
            self.reason = "无法确认 GetMod 为原版入口，保留已有实现"
            return
        end
        hook("GetMod", function(previous)
            return function(self, name, ...)
                if state.applied and not state.restored and self == manager and scope > 0 then
                    local mod = byname[name]
                    if mod then
                        return mod
                    end
                end
                -- 未命中不缓存 nil；收集范围之外的查询始终调用原函数。
                return previous(self, name, ...)
            end
        end)
        for _, key in G.ipairs({ "GetPostInitFns", "GetPostInitData" }) do
            hook(key, function(previous)
                local function done(saved_scope, ok, ...)
                    scope = saved_scope
                    if not ok then G.error((...), 0) end
                    return ...
                end
                return function(self, ...)
                    if not state.applied or state.restored or self ~= manager then return previous(self, ...) end
                    local saved_scope = scope
                    -- 原版收集器只读取注册表并生成包装函数，不执行回调。
                    -- 这里验证一次后，在这次同步收集内部使用稳定的名称索引。
                    scope = refresh() and saved_scope + 1 or 0
                    return done(saved_scope, pcall(previous, self, ...))
                end
            end)
        end
        self.installed = true
    end

    function state:Apply()
        if self.applied or self.restored then return end
        if not self.enabled then self.reason = "disabled"; return end
        -- 环境表已经在全部入口执行前建立，可在本模组入口立即启用。
        self:Install()
        if self.installed then self.applied, self.reason = true, "applied" end
    end

    function state:Restore()
        if self.restored then return end
        self.restored = true
        scope = 0
        for i = #hooks, 1, -1 do
            local item = hooks[i]
            if rawget(manager, item.key) == item.replacement then
                if item.own then manager[item.key] = item.old else manager[item.key] = nil end
            end
        end
        -- 其他包装器仍引用本补丁时自动退回原函数，避免残留索引生效。
        source, rows, names, byname = nil, nil, nil, nil
    end
    return state
end
