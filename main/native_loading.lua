-- 工厂只负责原生加载；补丁按进程安装，修改开关或更新 DLL 后须完整退出游戏。
return function(options)
    local ffi, disk = options.ffi, options.disk
    ffi.cdef([[
        void * __stdcall GetModuleHandleW(const void *);
        void * __stdcall LoadLibraryW(const void *);
        void * __stdcall LoadLibraryExW(const void *, void *, uint32_t);
        int __stdcall FreeLibrary(void *);
        void * __stdcall GetProcAddress(void *, const char *);
        uint32_t __stdcall GetTempFileNameW(const void *, const void *, uint32_t, void *);
        int __stdcall CopyFileW(const void *, const void *, int);
        int __stdcall MoveFileExW(const void *, const void *, uint32_t);
        int __stdcall DeleteFileW(const void *);
    ]])
    local K = ffi.load("kernel32")
    local function wide(text)
        local n = K.MultiByteToWideChar(65001, 8, text, #text, nil, 0)
        if n == 0 then error("原生路径不是有效的 UTF-8") end
        local result = ffi.new("uint16_t[?]", n + 1)
        if K.MultiByteToWideChar(65001, 8, text, #text, result, n) ~= n then error("原生路径转换失败") end
        return result
    end
    local function text(buffer, length)
        local n = K.WideCharToMultiByte(65001, 0, buffer, length, nil, 0, nil, nil)
        if n == 0 then error("原生模块路径转换失败") end
        local result = ffi.new("char[?]", n)
        K.WideCharToMultiByte(65001, 0, buffer, length, result, n, nil, nil)
        return ffi.string(result, n)
    end
    local function fail(label)
        error(label .. "，Win32=" .. tonumber(K.GetLastError()))
    end
    local roots, reason = disk:Roots(options.name, options.root)
    if not roots then error("找不到实体模组目录：" .. tostring(reason)) end
    local directory = roots[1] .. "/native"
    local package_path = wide(directory .. "/dst_fastloading_native.dll.pkg")
    local attributes = tonumber(K.GetFileAttributesW(package_path))
    if attributes == 4294967295 or require("bit").band(attributes, 16) ~= 0 then
        error("缺少原生发布包 native/dst_fastloading_native.dll.pkg")
    end
    local runtime = disk:FullPath(directory .. "/dst_fastloading_native.dll")
    local module = K.GetModuleHandleW(wide("dst_fastloading_native.dll"))
    if module ~= nil then
        local buffer = ffi.new("uint16_t[32768]")
        local n = K.GetModuleFileNameW(module, buffer, 32768)
        if n == 0 or n >= 32768 then fail("读取已加载模块路径失败") end
        if disk:FullPath(text(buffer, n)):lower() ~= runtime:lower() then
            error("另一目录已加载同名原生模块，请完整退出游戏")
        end
    else
        local stage = ffi.new("uint16_t[32768]")
        if K.GetTempFileNameW(wide(directory), wide("dfl"), 0, stage) == 0 then fail("创建原生暂存文件失败") end
        local ok, error_text = pcall(function()
            if K.CopyFileW(package_path, stage, 0) == 0 then fail("复制原生发布包失败") end
            -- 只验证 PE 可映射，不运行 DllMain；失败时保留既有运行副本。
            local probe = K.LoadLibraryExW(stage, nil, 0x60)
            if probe == nil then fail("原生发布包损坏") end
            K.FreeLibrary(probe)
            if K.MoveFileExW(stage, wide(runtime), 9) == 0 then fail("替换原生运行副本失败，请退出其他游戏进程后重试") end
        end)
        if not ok then
            K.DeleteFileW(stage)
            error(error_text, 0)
        end
        module = K.LoadLibraryW(wide(runtime))
        if module == nil then fail("加载原生运行副本失败") end
    end
    local function bind(name, signature)
        local address = K.GetProcAddress(module, name)
        if address == nil then error("原生接口不完整：" .. name .. "，请完整退出游戏后更新") end
        return ffi.cast(signature, address)
    end
    local abi = bind("FL_ABI", "unsigned int (*)(void)")
    if abi() ~= 1 then error("原生接口版本不兼容，请完整退出游戏后更新") end
    local start = bind("FL_Start", "unsigned int (*)(const void *, unsigned int)")
    return tonumber(start(wide(directory .. "/fastloading_native.log"), options.flags))
end
