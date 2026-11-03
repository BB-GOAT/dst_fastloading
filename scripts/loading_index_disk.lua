-- Windows 宽字符文件接口；只枚举文件名，不加载或执行被枚举的脚本。
-- 保护调用仅用于释放文件和枚举句柄，清理后重新抛出异常。
return function(G, options)
    options = options or {}
    local ffi = G.require("ffi")
    if ffi.os ~= "Windows" then error("Windows LuaJIT required") end
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
        "int __stdcall CreateDirectoryW(const void *, void *);",
        "void * __stdcall CreateFileW(const void *, uint32_t, uint32_t, void *, uint32_t, uint32_t, void *);",
        "int __stdcall GetFileSizeEx(void *, void *);",
        "int __stdcall ReadFile(void *, void *, uint32_t, void *, void *);",
        "int __stdcall WriteFile(void *, const void *, uint32_t, void *, void *);",
        "int __stdcall CloseHandle(void *);",
        "int __stdcall MoveFileExW(const void *, const void *, uint32_t);",
        "int __stdcall DeleteFileW(const void *);",
        "uint32_t __stdcall GetCurrentProcessId(void);",
    }
    if not G.rawget(G, "DST_LOADING_INDEX_FFI_DECLARED") then
        for _, declaration in ipairs(declarations) do ffi.cdef(declaration) end
        G.rawset(G, "DST_LOADING_INDEX_FFI_DECLARED", true)
    end
    local K = ffi.load("kernel32")
    local bit = G.require("bit")
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
        local full = api:FullPath(path):gsub("/", "\\")
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
    local function mkdir(path)
        if isdir(path) then return true end
        local parent = path:match("^(.*)/[^/]+$")
        if parent and #parent > 2 and not mkdir(parent) then return false end
        return K.CreateDirectoryW(nativepath(path), nil) ~= 0 or isdir(path)
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
    local cache_dir = assert(options.cache_dir, "cache_dir required")
    api.cache_dir = api:FullPath(cache_dir)
    if not mkdir(api.cache_dir) then error("cache directory unavailable") end

    -- 优先实际 mods 目录，其次 Steam 工坊目录；一个清单对应一个明确的物理根。
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
        local injector = G.rawget(G, "GameInjector")
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
                    -- 当前实现仅覆盖散装工坊目录；含游戏数据包的目录留给原版。
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
            if self:FullPath(directory):lower() == self.cache_dir:lower() then return true end
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
                    -- 点开头的文件不收录，目录不进入，包括 .git、.github 等。
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
    local function cachepath(name)
        assert(name == "index", "invalid cache name")
        return api.cache_dir .. "/index.json"
    end
    function api:Read(name)
        local handle = K.CreateFileW(nativepath(cachepath(name)), 2147483648, 7, nil, 3, 128, nil)
        if handle == INVALID then return nil end
        local ok, result = pcall(function()
            local size = ffi.new("int64_t[1]")
            if K.GetFileSizeEx(handle, size) == 0 then return nil end
            local length = tonumber(size[0])
            if length < 1 or length > 67108864 then return nil end
            local buffer, read = ffi.new("uint8_t[?]", length), ffi.new("uint32_t[1]")
            if K.ReadFile(handle, buffer, length, read, nil) == 0 or read[0] ~= length then return nil end
            return ffi.string(buffer, length)
        end)
        K.CloseHandle(handle)
        if not ok then error(result, 0) end
        return result
    end
    function api:Write(name, text)
        local path = cachepath(name)
        local temporary = path .. "." .. tonumber(K.GetCurrentProcessId()) .. ".tmp"
        local handle = K.CreateFileW(nativepath(temporary), 1073741824, 0, nil, 2, 128, nil)
        if handle == INVALID then return false end
        local ok, success = pcall(function()
            local written = ffi.new("uint32_t[1]")
            return K.WriteFile(handle, text, #text, written, nil) ~= 0 and written[0] == #text
        end)
        K.CloseHandle(handle)
        if ok and success and K.MoveFileExW(nativepath(temporary), nativepath(path), 9) ~= 0 then return true end
        K.DeleteFileW(nativepath(temporary))
        if not ok then error(success, 0) end
        return false
    end
    function api:Delete(name)
        return K.DeleteFileW(nativepath(cachepath(name))) ~= 0
    end
    function api:Exists(path)
        local value = attributes(path)
        return value and bit.band(value, 16) == 0 or false
    end
    function api:ReadSource(path)
        local handle = K.CreateFileW(nativepath(path), 2147483648, 7, nil, 3, 128, nil)
        if handle == INVALID then return nil, tonumber(K.GetLastError()) end
        local ok, result, code = pcall(function()
            local size = ffi.new("int64_t[1]")
            if K.GetFileSizeEx(handle, size) == 0 then return nil, tonumber(K.GetLastError()) end
            local length = tonumber(size[0])
            if length < 0 or length > 67108864 then return nil, "script_size_limit" end
            local buffer, read = ffi.new("uint8_t[?]", math.max(1, length)), ffi.new("uint32_t[1]")
            if K.ReadFile(handle, buffer, length, read, nil) == 0 then return nil, tonumber(K.GetLastError()) end
            if read[0] ~= length then return nil, "short_read" end
            return ffi.string(buffer, length)
        end)
        K.CloseHandle(handle)
        if not ok then error(result, 0) end
        return result, code
    end
    return api
end
