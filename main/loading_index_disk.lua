-- Windows 宽字符文件接口；只枚举文件名，不加载或执行被枚举的脚本
-- 保护调用仅用于释放枚举句柄，清理后重新抛出异常
return function(options)
    options = options or {}
    local ffi = _G.require("ffi")
    local declarations = {
        [[typedef struct { uint32_t attr; uint32_t times[6]; uint32_t sizehigh, sizelow, reserved[2]; uint16_t name[260]; uint16_t alternate[14]; } DST_LOADING_INDEX_FIND_DATA_V1;]],
        "int __stdcall MultiByteToWideChar(unsigned int, uint32_t, const char *, int, void *, int);",
        "int __stdcall WideCharToMultiByte(unsigned int, uint32_t, const void *, int, char *, int, const char *, void *);",
        "uint32_t __stdcall GetFullPathNameW(const void *, uint32_t, void *, void *);",
        "uint32_t __stdcall GetModuleFileNameW(void *, void *, uint32_t);",
        "uint32_t __stdcall GetFileAttributesW(const void *);",
        "void * __stdcall FindFirstFileW(const void *, void *);",
        "int __stdcall FindNextFileW(void *, void *);",
        "int __stdcall FindClose(void *);",
        "uint32_t __stdcall GetLastError(void);",
    }
    if not _G.rawget(_G, "DST_LOADING_INDEX_FFI_DECLARED") then
        for _, declaration in ipairs(declarations) do ffi.cdef(declaration) end
        _G.rawset(_G, "DST_LOADING_INDEX_FFI_DECLARED", true)
    end
    local K = ffi.load("kernel32")
    local bit = _G.require("bit")
    local INVALID = ffi.cast("void *", -1)
    local api = {}
    local function wide(text)
        local n = K.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
        if n == 0 then error("invalid UTF-8 path") end
        local buffer = ffi.new("uint16_t[?]", n + 1)
        if K.MultiByteToWideChar(65001, 8, text, #text, buffer, n) ~= n then error("path conversion failed") end
        return buffer
    end
    local function utf8(buffer, length)
        if not length then
            length = 0
            while buffer[length] ~= 0 do length = length + 1 end
        end
        if length == 0 then return "" end
        local n = K.WideCharToMultiByte(65001, 0, buffer, length, nil, 0, nil, nil)
        if n == 0 then error("UTF-16 conversion failed") end
        local output = ffi.new("char[?]", n)
        if K.WideCharToMultiByte(65001, 0, buffer, length, output, n, nil, nil) ~= n then error("UTF-16 conversion failed") end
        return ffi.string(output, n)
    end
    function api:FullPath(path)
        local buffer = ffi.new("uint16_t[32768]")
        local n = K.GetFullPathNameW(wide(path), 32768, buffer, nil)
        if n == 0 or n >= 32768 then error("full path unavailable") end
        return utf8(buffer, n):gsub("\\", "/"):gsub("/+$", "")
    end
    local function nativepath(path)
        -- 内部已规范化的盘符绝对路径无需再次分配完整路径缓冲区
        local full = path
        if not path:match("^%a:/") or path:find("\\", 1, true)
            or path:find("/.", 1, true) or path:find("//", 1, true) then
            full = api:FullPath(path)
        end
        full = full:gsub("/", "\\")
        if full:sub(1, 2) == "\\\\" then return wide("\\\\?\\UNC\\" .. full:sub(3)) end
        return wide("\\\\?\\" .. full)
    end
    local function attributes(path)
        local value = tonumber(K.GetFileAttributesW(nativepath(path)))
        if value == 4294967295 then return nil, tonumber(K.GetLastError()) end
        return value
    end
    local function isdir(path)
        local value, code = attributes(path)
        if not value then return false, code end
        return bit.band(value, 16) ~= 0
    end
    local function executable()
        local buffer = ffi.new("uint16_t[32768]")
        local n = K.GetModuleFileNameW(nil, buffer, 32768)
        if n == 0 or n >= 32768 then error("executable path unavailable") end
        return utf8(buffer, n):gsub("\\", "/")
    end
    local game_root = options.game_root
    if not game_root then
        local exe = executable()
        if not exe:lower():match("/bin64/dontstarve[^/]*%.exe$") then error("unknown game executable") end
        game_root = exe:match("^(.*)/bin64/[^/]+$")
    end
    game_root = api:FullPath(game_root)

    -- 优先实际 mods 目录，其次 Steam 工坊目录；一个清单对应一个明确的物理根
    function api:Roots(name, logicalroot)
        local id = name:match("^workshop%-(%d+)$")
        local candidates = {
            logicalroot,
            game_root .. "/mods/" .. name,
        }
        if id then
            candidates[#candidates + 1] = game_root .. "/../../workshop/content/322330/" .. id
            candidates[#candidates + 1] = game_root .. "/../../workshop/content/322330/" .. name
        end
        local injector = _G.rawget(_G, "GameInjector")
        if id and injector and type(injector.DS_LUAJIT_get_workshop_dir) == "function" then
            local root = injector.DS_LUAJIT_get_workshop_dir()
            if type(root) == "string" and root ~= "" then
                candidates[#candidates + 1] = root .. "/" .. id
                candidates[#candidates + 1] = root .. "/" .. name
            end
        end
        local seen = {}
        for _, candidate in ipairs(candidates) do
            local full = self:FullPath(candidate)
            if not seen[full:lower()] then
                seen[full:lower()] = true
                local directory, code = isdir(full)
                if directory then
                    if bit.band(attributes(full), 1024) ~= 0 then return nil, "reparse_root" end
                    local info = attributes(full .. "/modinfo.lua")
                    -- 当前实现仅覆盖散装工坊目录；含游戏数据包的目录留给原版
                    if attributes(full .. "/databundles") then return nil, "packed_root" end
                    if info and bit.band(info, 16) == 0 then return { full } end
                elseif code and code ~= 2 and code ~= 3 then
                    return nil, "root_access_error:" .. code
                end
            end
        end
        return nil, "no_physical_root"
    end

    function api:Scan(roots)
        local files, visited = {}, 0
        local function walk(directory, prefix, depth)
            if depth > 128 then return false, "depth_limit" end
            local attr = attributes(directory)
            if not attr or bit.band(attr, 16) == 0 then return false, "directory_disappeared" end
            if bit.band(attr, 1024) ~= 0 then return false, "reparse_directory" end
            local data = ffi.new("DST_LOADING_INDEX_FIND_DATA_V1[1]")
            local handle = K.FindFirstFileW(nativepath(directory .. "/*"), data)
            if handle == INVALID then
                local code = tonumber(K.GetLastError())
                if code == 2 then return true end
                return false, "enumeration_error:" .. code
            end
            local ok, result, reason = pcall(function()
                while true do
                    local name = utf8(data[0].name)
                    -- 点开头的文件不收录，目录不进入，包括 .git、.github 等
                    if name:sub(1, 1) ~= "." then
                        visited = visited + 1
                        if visited > 500000 then return false, "file_limit" end
                        if bit.band(data[0].attr, 1024) ~= 0 then return false, "reparse_entry" end
                        local relative = prefix .. name
                        if bit.band(data[0].attr, 16) ~= 0 then
                            local success, why = walk(directory .. "/" .. name, relative .. "/", depth + 1)
                            if not success then return false, why end
                        else
                            files[relative] = true
                        end
                    end
                    if K.FindNextFileW(handle, data) == 0 then
                        local code = tonumber(K.GetLastError())
                        if code ~= 18 then return false, "enumeration_error:" .. code end
                        return true
                    end
                end
            end)
            K.FindClose(handle)
            if not ok then error(result, 0) end
            return result, reason
        end
        for _, root in ipairs(roots) do
            local success, reason = walk(root, "", 0)
            if not success then return nil, reason end
        end
        return files
    end
    -- 原版 io 将 unsafedata 映射到玩家存档目录，与模组安装位置无关
    local function cachepath(name)
        assert(name == "index", "invalid cache name")
        return "unsafedata/dst_fastloading_file_index.json"
    end
    function api:Read(name)
        local file = _G.io.open(cachepath(name), "r")
        if not file then return nil end
        local text = file:read(67108865)
        local closed = file:close()
        if not closed or not text or #text == 0 or #text > 67108864 then return nil end
        return text
    end
    function api:Write(name, text)
        local file, reason = _G.io.open(cachepath(name), "w")
        if not file then return false, reason end
        local written, write_error = file:write(text)
        local closed, close_error = file:close()
        if not written or not closed then return false, write_error or close_error end
        return true
    end
    function api:Exists(path)
        local value = attributes(path)
        return value and bit.band(value, 16) == 0 or false
    end
    return api
end
