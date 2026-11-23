#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
#include <array>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <vector>
#include "MinHook.h"
#include "zip_reader.h"
#include "zip_patterns.h"
#include "code_pattern.h"

namespace {
std::mutex install_lock;
bool initialized = false;
unsigned active = 0;
unsigned initial_requested = 0;
wchar_t log_path_buffer[32768]{};
fastloading::OriginalRead original_read = nullptr;

void Log(const char* text) {
    if (!log_path_buffer[0]) return;
    FILE* file = nullptr;
    if (_wfopen_s(&file, log_path_buffer, L"a") == 0 && file) {
        fprintf(file, "%s\n", text);
        fclose(file);
    }
}

bool ClientExecutable() {
    wchar_t path[32768];
    DWORD size = GetModuleFileNameW(nullptr, path, 32768);
    if (!size || size >= 32768) return false;
    const wchar_t* name = wcsrchr(path, L'\\');
    return name && _wcsicmp(name + 1, L"dontstarve_steam_x64.exe") == 0;
}

unsigned char* Unique(const unsigned char* bytes, size_t count, const unsigned char* mask = nullptr) {
    auto* base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    auto* section = IMAGE_FIRST_SECTION(nt);
    unsigned char* found = nullptr;
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
        if (memcmp(section[i].Name, ".text", 5)) continue;
        auto* start = base + section[i].VirtualAddress;
        size_t length = section[i].Misc.VirtualSize;
        for (size_t j = 0; j + count <= length; ++j) {
            bool matches = start[j] == bytes[0];
            for (size_t k = 1; matches && k < count; ++k) {
                if ((!mask || mask[k]) && start[j + k] != bytes[k]) matches = false;
            }
            if (matches) {
                if (found) return nullptr;
                found = start + j;
            }
        }
    }
    return found;
}

fastloading::PatternMatch FindPattern(const fastloading::CodePattern& pattern) {
    auto* base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    auto* section = IMAGE_FIRST_SECTION(nt);
    fastloading::PatternMatch result;
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
        if (memcmp(section[i].Name, ".text", 5)) continue;
        auto part = pattern.Find(base + section[i].VirtualAddress, section[i].Misc.VirtualSize);
        if (part.count) result.address = part.address;
        result.count += part.count;
    }
    return result;
}

int HookRead(void* file, void* output, uint32_t length) {
    return fastloading::ReadEntry(file, output, length, original_read);
}

bool InstallZip() {
    // 仅检查相关函数；调用地址通配，无关代码、资源或函数地址变化不要求更新模组。
    // 读/关闭函数特征同时约束私有字段偏移和当前不检查 CRC 的语义。
    const fastloading::CodePattern read_pattern(zip_read_pattern), close_pattern(zip_close_pattern);
    const auto read = FindPattern(read_pattern), close = FindPattern(close_pattern);
    char diagnostic[200];
    sprintf_s(diagnostic, "ZIP signatures: read=%zu, close=%zu.", read.count, close.count);
    Log(diagnostic);
    if (close.count != 1 || read.count != 1) {
        Log("ZIP skipped: read/close implementation changed or signatures are not unique."); return false;
    }
    auto* address = read.address;
    auto status = MH_Initialize();
    if (status != MH_OK && status != MH_ERROR_ALREADY_INITIALIZED) { Log(MH_StatusToString(status)); return false; }
    status = MH_CreateHook(address, reinterpret_cast<void*>(&HookRead), reinterpret_cast<void**>(&original_read));
    if (status != MH_OK) { Log(MH_StatusToString(status)); return false; }
    // MinHook 在发布跳转时暂停其他线程，并维护原函数跳板的指令边界。
    status = MH_EnableHook(address);
    if (status != MH_OK) { MH_RemoveHook(address); Log(MH_StatusToString(status)); return false; }
    Log("ZIP enabled: libdeflate whole-entry path; engine CRC semantics preserved.");
    return true;
}

constexpr unsigned char signature_a[] = {
    0x48,0x8B,0xCB,0x48,0x89,0x5C,0x24,0x20,0x48,0x8B,0xD6,0x48,0x89,0x54,0x24,0x28,
    0x48,0x85,0xC9,0x74,0x19,0x41,0x0F,0xB6,0x45,0x00,0x88,0x02,0x48,0xFF,0xC9,0x48,
    0x89,0x4C,0x24,0x20,0x48,0xFF,0xC2,0x48,0x89,0x54,0x24,0x28,0xEB,0xE2
};
constexpr unsigned char signature_b[] = {
    0x48,0x89,0x44,0x24,0x38,0x48,0x89,0x4C,0x24,0x40,0x0F,0x1F,0x40,0,0x48,0x85,
    0xC0,0x74,0x15,0x44,0x88,0x21,0x48,0xFF,0xC8,0x48,0x89,0x44,0x24,0x38,0x48,0xFF,
    0xC1,0x48,0x89,0x4C,0x24,0x40,0xEB,0xE6
};

struct Patch { unsigned char* address; const unsigned char* before; size_t size; std::array<unsigned char, 46> after; DWORD protection; };

bool InstallFill() {
    // 除内存内容外，也保留原循环的最终寄存器、标志位和栈上计数/指针。
    constexpr unsigned char code_a[] = {
        0x48,0x8B,0xCB,0x48,0x8B,0xD6,0x48,0x85,0xC9,0x74,0x0F,
        0x57,0x48,0x89,0xD7,0x41,0x0F,0xB6,0x45,0x00,0xF3,0xAA,0x48,0x89,0xFA,0x5F,
        0x48,0x89,0x4C,0x24,0x20,0x48,0x89,0x54,0x24,0x28,0x48,0x85,0xC9
    };
    constexpr unsigned char code_b[] = {
        0x48,0x85,0xC0,0x74,0x12,0x57,0x48,0x89,0xCF,0x48,0x89,0xC1,0x44,0x89,0xE0,
        0xF3,0xAA,0x48,0x89,0xF9,0x33,0xC0,0x5F,
        0x48,0x89,0x44,0x24,0x38,0x48,0x89,0x4C,0x24,0x40,0x48,0x85,0xC0
    };
    Patch patches[2] = {
        { Unique(signature_a, sizeof(signature_a)), signature_a, sizeof(signature_a), {}, 0 },
        { Unique(signature_b, sizeof(signature_b)), signature_b, sizeof(signature_b), {}, 0 }
    };
    if (!patches[0].address || !patches[1].address) { Log("Fill skipped: signatures missing or not unique."); return false; }
    for (auto& p : patches) p.after.fill(0x90);
    memcpy(patches[0].after.data(), code_a, sizeof(code_a));
    memcpy(patches[1].after.data(), code_b, sizeof(code_b));

    // 在暂停线程之前准备句柄和全部存储；暂停期间不分配堆内存或写日志。
    std::vector<HANDLE> threads;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return false;
    THREADENTRY32 entry{sizeof(entry)};
    bool ok = true;
    if (!Thread32First(snapshot, &entry)) ok = false;
    else do {
        if (entry.th32OwnerProcessID != GetCurrentProcessId() || entry.th32ThreadID == GetCurrentThreadId()) continue;
        HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, entry.th32ThreadID);
        if (!thread) { ok = false; break; }
        threads.push_back(thread);
    } while (Thread32Next(snapshot, &entry));
    CloseHandle(snapshot);
    size_t suspended = 0;
    for (; ok && suspended < threads.size(); ++suspended) {
        if (SuspendThread(threads[suspended]) == DWORD(-1)) { ok = false; break; }
        CONTEXT context{};
        context.ContextFlags = CONTEXT_CONTROL;
        bool safe = GetThreadContext(threads[suspended], &context) != 0;
        for (const auto& p : patches) {
            auto start = reinterpret_cast<uintptr_t>(p.address);
            if (context.Rip >= start && context.Rip < start + p.size) safe = false;
        }
        if (!safe) { ++suspended; ok = false; break; }
    }
    size_t writable = 0;
    for (; ok && writable < 2; ++writable) {
        auto& p = patches[writable];
        if (memcmp(p.address, p.before, p.size)
            || !VirtualProtect(p.address, p.size, PAGE_EXECUTE_READWRITE, &p.protection)) { ok = false; break; }
    }
    if (ok) {
        for (auto& p : patches) {
            memcpy(p.address, p.after.data(), p.size);
            FlushInstructionCache(GetCurrentProcess(), p.address, p.size);
        }
    }
    for (size_t i = writable; i > 0; --i) {
        DWORD ignored;
        auto& p = patches[i - 1];
        VirtualProtect(p.address, p.size, p.protection, &ignored);
    }
    for (size_t i = suspended; i > 0; --i) ResumeThread(threads[i - 1]);
    for (HANDLE thread : threads) CloseHandle(thread);
    Log(ok ? "Fill enabled: both loops replaced; register/stack outputs preserved." : "Fill skipped: cannot safely publish both patches.");
    return ok;
}
}

extern "C" __declspec(dllexport) unsigned FL_ABI() { return 1; }
extern "C" __declspec(dllexport) unsigned FL_Start(const wchar_t* log_path, unsigned requested) try {
    std::lock_guard<std::mutex> guard(install_lock);
    if (initialized) {
        if (requested != initial_requested) Log("Configuration changed since initialization; fully exit the game to change native options.");
        return active;
    }
    initialized = true;
    initial_requested = requested;
    if (!log_path || wcsncpy_s(log_path_buffer, log_path, _TRUNCATE) != 0) return 0;
    FILE* log_file = nullptr;
    _wfopen_s(&log_file, log_path, L"w");
    bool logging = log_file != nullptr;
    if (log_file) fclose(log_file);
    Log("FastLoading native 1.2; process lifetime; no Lua callbacks.");
    if (!logging || !ClientExecutable()) {
        Log("Unsupported executable name or platform; no engine code modified.");
        return 0;
    }
    HMODULE self;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&FL_Start), &self)) return 0;
    if ((requested & 1) && InstallZip()) active |= 1;
    if ((requested & 2) && InstallFill()) active |= 2;
    return active;
} catch (...) {
    Log("Native initialization failed; installed features remain process-owned.");
    return active;
}
