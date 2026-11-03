-- 优先按索引定位；无可用模组文件时直接尝试本体，仍无结果才完整调用原版搜索。
return function(G, options, supplied_disk, supplied_json)
    local state = {
        enabled = options.enabled, active = false, restored = false, reason = "not_installed",
    }
    local disk, json
    local hooks, upvalues, entries, providers, roots_by_path = {}, {}, {}, {}, {}
    local script_plan, asset_plan, fallback_depth
    local empty_candidates = {}
    fallback_depth = 0
    local native_loadlua = G.kleiloadlua
    local native_exists = G.kleifileexists
    local function normalize(value) return value:gsub("\\", "/"):lower():gsub("/+$", "") end
    local function dotpath(value)
        return value:sub(1, 1) == "." or value:find("/.", 1, true)
    end
    local function keypath(value)
        if type(value) ~= "string" or value == "" then return nil end
        local key = value:gsub("\\", "/"):lower()
        if key:sub(1, 1) == "/" or key:find("//", 1, true) or key:find("[:%z\1-\31]") then return nil end
        if dotpath(key) then return nil end
        return key
    end
    local function hook(target, name, factory)
        local previous = target[name]
        if type(previous) ~= "function" then return false end
        local own = G.rawget(target, name)
        local replacement = factory(previous)
        hooks[#hooks + 1] = { target = target, name = name, previous = own, replacement = replacement }
        target[name] = replacement
        return true
    end
    -- 原版完整搜索期间保留 manifest 拦截；保护调用只负责恢复深度，异常仍原样抛出。
    local function original(fn, ...)
        fallback_depth = fallback_depth + 1
        local function done(ok, ...)
            fallback_depth = fallback_depth - 1
            if not ok then G.error((...), 0) end
            return ...
        end
        return done(G.pcall(fn, ...))
    end
    local function index_file(entry, relative)
        local key = keypath(relative)
        if not key then return end
        entry.files[key] = relative
        local list = providers[key]
        if not list then list = {}; providers[key] = list end
        list[#list + 1] = { entry = entry, relative = relative }
    end
    local function prepare()
        disk = supplied_disk or G.require("loading_index_disk")(G)
        json = supplied_json or G.require("json")
        local cache = { schema = 3, mods = {} }
        local dirty = true
        if not options.rebuild then
            local text = disk:Read("index")
            if text then
                local ok, value = G.pcall(json.decode, text)
                if ok and type(value) == "table" and value.schema == 3 and type(value.mods) == "table" then
                    cache, dirty = value, false
                else
                    G.print("[快速加载] 文件清单损坏或格式已更新，重新扫描。")
                end
            end
        end
        local function prepare_mod(name, mod)
            local version = mod.modinfo and mod.modinfo.version
            -- 无版本的本地目录每轮重新枚举，不把未知版本长期缓存。
            local reusable = type(version) == "string" and version ~= ""
            if not reusable then version = "" end
            local roots, why = disk:Roots(name, G.MODS_ROOT .. name .. "/")
            if not roots then return false, why end
            local root = roots[1]
            local stored = cache.mods[name]
            local list
            if reusable and not options.rebuild and type(stored) == "table"
                and stored.version == version and stored.root == root and type(stored.files) == "table" then
                local valid = true
                for _, relative in ipairs(stored.files) do if not keypath(relative) then valid = false; break end end
                if valid and #stored.files == stored.count then list = stored.files end
            end
            if not list then
                local files, reason = disk:Scan(roots)
                if not files then return false, reason end
                list = {}
                for relative in pairs(files) do list[#list + 1] = relative end
                table.sort(list)
                cache.mods[name] = { version = version, root = root, files = list, count = #list }
                dirty = true
            end
            local entry = { name = name, root = root, files = {} }
            entries[name] = entry
            roots_by_path[normalize(G.MODS_ROOT .. name)] = entry
            roots_by_path[normalize(disk:FullPath(G.MODS_ROOT .. name))] = entry
            roots_by_path[normalize(root)] = entry
            for _, relative in ipairs(list) do index_file(entry, relative) end
            return true
        end
        local seen = {}
        for _, mod in ipairs(G.ModManager.mods) do
            local name = mod.modname
            local workshop = type(name) == "string" and name:match("^workshop%-%d+$")
            if type(name) == "string" and not seen[name] and (workshop or options.local_mods) then
                seen[name] = true
                local success, reason = prepare_mod(name, mod)
                if not success then
                    G.print("[快速加载] 模组 " .. name .. " 保留原版搜索：" .. tostring(reason))
                end
            end
        end
        if dirty then
            local success, reason = disk:Write("index", json.encode(cache))
            if not success then
                G.print("[快速加载] 无法保存文件清单，继续使用当轮内存索引：" .. tostring(reason))
            end
        end
    end

    local function script_paths()
        local path = G.package.path
        if script_plan and script_plan.source == path then return script_plan end
        local plan = { source = path, ranks = {}, unknown = {} }
        local rank = 0
        for template in path:gmatch("[^;]+") do
            rank = rank + 1
            local root = normalize(template):match("^(.*)/scripts/%?%.lua$")
            local entry = root and roots_by_path[root]
            if entry then
                -- 重复条目只保留最早位置，其内容和物理根相同。
                if not plan.ranks[entry] then plan.ranks[entry] = rank end
            else
                local manifest, matches = template:gsub(G.MODS_ROOT .. "([^\\]+)\\scripts\\%?%.lua", "%1", 1)
                plan.unknown[#plan.unknown + 1] = { rank = rank, template = template,
                    manifest = matches == 1 and manifest or nil }
            end
        end

        script_plan = plan
        return plan
    end
    local function asset_paths()
        local paths = G.package.assetpath
        if asset_plan and asset_plan.source == paths and asset_plan.length == #paths then
            local unchanged = true
            -- 验证当前路径表，处理同长度替换、原地重排和字段修改。
            for i, row in ipairs(paths) do
                if asset_plan.rows[i] ~= row or asset_plan.paths[i] ~= row.path or asset_plan.manifests[i] ~= row.manifest then
                    unchanged = false; break
                end
            end
            if unchanged then return asset_plan end
        end
        local plan = { source = paths, length = #paths, ranks = {}, unknown = {}, rows = {}, paths = {}, manifests = {} }
        local rank = 0
        for i = #paths, 1, -1 do
            rank = rank + 1
            local pathdata = paths[i]
            plan.rows[i], plan.paths[i], plan.manifests[i] = pathdata, pathdata.path, pathdata.manifest
            local entry = type(pathdata.path) == "string" and roots_by_path[normalize(pathdata.path)]
            if entry and (not pathdata.manifest or pathdata.manifest == entry.name) then
                if not plan.ranks[entry] then plan.ranks[entry] = rank end
            else
                plan.unknown[#plan.unknown + 1] = { rank = rank, data = pathdata }
            end
        end

        asset_plan = plan
        return plan
    end
    local function candidates(key, plan)
        local list = providers[key]
        if not list then return nil end
        local selected = {}
        for _, item in ipairs(list) do
            local rank = plan.ranks[item.entry]
            if rank and item.entry.files[key] then
                selected[#selected + 1] = { rank = rank, item = item }
            end
        end
        if #selected == 0 then return nil end
        table.sort(selected, function(a, b) return a.rank < b.rank end)
        return selected
    end
    local function compile(entry, relative, logical)
        local text, code = disk:ReadSource(entry.root .. "/" .. relative)
        if not text then
            if code == 2 or code == 3 then
                entry.files[keypath(relative)] = nil
                return nil
            end
            return "Cannot read " .. logical .. ": " .. tostring(code)
        end
        if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
        if text:sub(1, 1) == "#" then text = text:gsub("^[^\n]*", "", 1) end
        local fn, error = G.loadstring(text, "@" .. logical)
        if not fn then return error end
        if G.RequiredFilesForReload then G.RequiredFilesForReload[logical] = G.TheSim:GetFileModificationTime(logical) end
        return fn
    end
    local function logical_resource(entry, relative)
        -- 磁盘路径仅供本模组的 Win32 接口使用；引擎和沙箱 io 使用模组逻辑路径。
        return G.MODS_ROOT:gsub("\\", "/") .. entry.name .. "/" .. relative
    end
    local function resolved_resource(filepath)
        local full = filepath:gsub("\\", "/")
        local base = G.MODS_ROOT:gsub("\\", "/")
        local entry, relative
        if full:sub(1, #base):lower() == base:lower() then
            local name, rest = full:sub(#base + 1):match("^([^/]+)/(.*)$")
            entry, relative = entries[name], rest
        elseif full:match("^%a:/") or full:sub(1, 1) == "/" then
            -- 兼容本轮已有调用方再次传入的已解析绝对路径。
            local lower = full:lower()
            for _, candidate in pairs(entries) do
                local prefix = normalize(candidate.root) .. "/"
                if lower:sub(1, #prefix) == prefix then
                    entry, relative = candidate, full:sub(#prefix + 1)
                    break
                end
            end
        end
        local key = relative and keypath(relative)
        local actual = entry and key and entry.files[key]
        if actual and disk:Exists(entry.root .. "/" .. actual) then
            return logical_resource(entry, actual)
        end
    end
    local function try_script_path(row, relative)
        local template = row.template
        local filename = template:gsub("%?", relative):gsub("\\", "/")

        local result = native_loadlua(filename, row.manifest, "scripts/" .. relative .. ".lua")
        if result then
            if G.RequiredFilesForReload then G.RequiredFilesForReload[filename] = G.TheSim:GetFileModificationTime(filename) end
            return result
        end
    end
    local function try_resource_path(row, relative)
        local data = row.data
        local filename = (data.path .. relative):gsub("\\", "/")

        if native_exists(filename, data.manifest, relative) then
            return filename
        end
    end
    local function search_script(module)
        local relative = module:gsub("[%.\\]", "/")
        local key = keypath("scripts/" .. relative .. ".lua")
        if not key then return nil end
        local plan = script_paths()
        local selected = candidates(key, plan) or empty_candidates
        local unknown = 1
        for _, candidate in ipairs(selected) do
            while plan.unknown[unknown] and plan.unknown[unknown].rank < candidate.rank do
                local result = try_script_path(plan.unknown[unknown], relative)
                if result then return result end
                unknown = unknown + 1
            end
            local item = candidate.item
            local logical = G.MODS_ROOT .. item.entry.name .. "/" .. item.relative
            local result = compile(item.entry, item.relative, logical)
            if result then return result end
        end
        -- 不把“模组无此文件”直接送回全量搜索；跳过已索引模组的无效路径，原生尝试本体。
        -- 未索引路径仍按当前位置探测，避免本体越过本地模组或自定义搜索器。
        while plan.unknown[unknown] do
            local result = try_script_path(plan.unknown[unknown], relative)
            if result then return result end
            unknown = unknown + 1
        end
        return nil
    end
    local function resolve_index(filepath, force, first)
        if type(filepath) ~= "string" then return nil end
        if type(G.IsConsole) == "function" and G.IsConsole() and not force then return nil end
        -- Assets、翻译文件等会把上次解析的路径再次交给解析器；保持结果可重复解析。
        local resolved = resolved_resource(filepath)
        if resolved then return resolved end
        local relative = filepath:gsub("^/", "")
        local key = keypath(relative)
        if not key then return nil end
        local plan = asset_paths()
        local selected = candidates(key, plan) or empty_candidates
        if first and native_exists(first .. relative) then return first .. relative end
        local unknown = 1
        for _, candidate in ipairs(selected) do
            while plan.unknown[unknown] and plan.unknown[unknown].rank < candidate.rank do
                local filename = try_resource_path(plan.unknown[unknown], relative)
                if filename then return filename end
                unknown = unknown + 1
            end
            local item = candidate.item
            local physical = item.entry.root .. "/" .. item.relative
            if disk:Exists(physical) then
                return logical_resource(item.entry, item.relative)
            end
            item.entry.files[key] = nil
        end
        while plan.unknown[unknown] do
            local filename = try_resource_path(plan.unknown[unknown], relative)
            if filename then return filename end
            unknown = unknown + 1
        end
        return nil
    end
    -- 外层包装不能替换三个入口共享的局部搜索器，且会破坏原 memoizedFilePaths。
    -- 只寻找 util.lua 中名为 softresolvefilepath_internal 的已知共享引用；找不到就不改资源逻辑。
    local function hook_resources()
        local debug = G.debug
        if not debug or not debug.getupvalue or not debug.setupvalue then return false end
        local visited, slots, count = {}, {}, 0
        local function visit(fn, depth)
            if type(fn) ~= "function" or visited[fn] or depth > 8 or count > 500 then return end
            visited[fn], count = true, count + 1
            for i = 1, 100 do
                local name, value = debug.getupvalue(fn, i)
                if not name then break end
                if name == "softresolvefilepath_internal" and type(value) == "function" then
                    local info = debug.getinfo(value, "S")
                    local source = info and info.source:gsub("\\", "/")
                    if source and (source == "util.lua" or source:match("[/@]util%.lua$")) then
                        slots[#slots + 1] = { fn = fn, index = i, previous = value }
                    end
                elseif type(value) == "function" then visit(value, depth + 1) end
            end
        end
        visit(G.resolvefilepath, 0)
        visit(G.resolvefilepath_soft, 0)
        visit(G.softresolvefilepath, 0)
        if #slots < 2 then return false end
        local shared = slots[1].previous
        for _, slot in ipairs(slots) do if slot.previous ~= shared then return false end end
        local replacement = function(filepath, force, first)
            if not state.active then return shared(filepath, force, first) end
            local result = resolve_index(filepath, force, first)
            if result then return result end
            return shared(filepath, force, first)
        end
        for _, slot in ipairs(slots) do
            slot.replacement = replacement
            debug.setupvalue(slot.fn, slot.index, replacement)
            upvalues[#upvalues + 1] = slot
        end
        return true
    end
    function state:Install()
        if self.active or self.restored then return end
        if not self.enabled then self.reason = "disabled"; return end
        if G.ModManager.worldgen or (G.TheNet and G.TheNet:IsDedicated()) then self.reason = "unsupported_context"; return end
        prepare()
        self.active, self.reason = true, "installed"
        hook(G.package.loaders, 2, function(previous)
            return function(module, ...)
                if not state.active or type(module) ~= "string" or select("#", ...) > 0 then return previous(module, ...) end
                local result = search_script(module)
                if result then return result end
                return original(previous, module)
            end
        end)
        hook(G, "loadfile", function(previous)
            return function(filename, ...)
                if not state.active or type(filename) ~= "string" or select("#", ...) > 0 then return previous(filename, ...) end
                -- 与当前 main.lua 的 loadfile 名称转换保持一致。
                local module = filename:gsub(".lua", ""):gsub("scripts/", "")
                local result = search_script(module)
                if result then return result end
                return original(previous, filename)
            end
        end)
        hook(G, "kleiloadlua", function(previous)
            return function(filename, ...)
                if not state.active or fallback_depth > 0 or type(filename) ~= "string" or select("#", ...) > 2 then return previous(filename, ...) end
                local root, relative = filename:gsub("\\", "/"):match("^(.-)/scripts/(.+)$")
                local entry = root and roots_by_path[normalize(root)]
                local key = relative and keypath("scripts/" .. relative)
                -- modimport 也可能加载 scripts 之外的入口或辅助文件。
                if not entry then
                    local base = G.MODS_ROOT:gsub("\\", "/")
                    local full = filename:gsub("\\", "/")
                    if full:sub(1, #base) == base then
                        local name, rest = full:sub(#base + 1):match("^([^/]+)/(.*)$")
                        entry, key = entries[name], keypath(rest)
                    end
                end
                local actual = entry and key and entry.files[key]
                if actual then
                    local result = compile(entry, actual, filename)
                    if result then return result end
                end
                return previous(filename, ...)
            end
        end)
        self.resource_hook = hook_resources()
        hook(G.ModManager, "InitializeModMain", function(previous)
            local function done(...) asset_plan = nil; return ... end
            return function(...)
                asset_plan = nil
                return done(previous(...))
            end
        end)
        hook(G, "TranslateStringTable", function(previous)
            return function(...) asset_plan = nil; return previous(...) end
        end)
    end
    function state:Restore()
        if self.restored then return end
        self.active, self.restored = false, true
        for i = #upvalues, 1, -1 do
            local item = upvalues[i]
            local _, current = G.debug.getupvalue(item.fn, item.index)
            if current == item.replacement then G.debug.setupvalue(item.fn, item.index, item.previous) end
        end
        for i = #hooks, 1, -1 do
            local item = hooks[i]
            if G.rawget(item.target, item.name) == item.replacement then item.target[item.name] = item.previous end
        end
        hooks, upvalues, entries, providers, roots_by_path = {}, {}, {}, {}, {}
        script_plan, asset_plan = nil, nil
    end
    return state
end
