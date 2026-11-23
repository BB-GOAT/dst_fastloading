// 显式传入 smooth_loading 源码才构建；生产 DLL 不依赖该模组。
#include "font_call_hook.h"
#include "chunked_read.h"
#include "MinHook.h"
#include "zip_reader.h"
#include "libdeflate.h"
#include "code_pattern.h"
#include "zip_patterns.h"
#include <intrin.h>
#include <algorithm>
#include <stdexcept>

namespace {
using ReadFn = fastloading::OriginalRead;
void Check(bool value, const char* text) { if (!value) throw std::runtime_error(text); }
ReadFn engine_trampoline = nullptr, font_original = nullptr;
void* font_return = nullptr;
unsigned accelerated = 0, engine_calls = 0, font_calls = 0, pumps = 0;
bool asset_loading = true;
libdeflate_decompressor* decoder = nullptr;
struct Stream {
    std::vector<unsigned char> compressed, decoded;
    size_t position = 0;
    bool short_bulk_read = false, fail_after_chunk = false;
};
struct File { unsigned char padding[0xC8]{}; fastloading::ZipReadInfo* info; };
int32_t Seek(void*, void* object, uint32_t position, int) {
    static_cast<Stream*>(object)->position = position;
    return 0;
}
uint32_t Read(void*, void* object, void* output, uint32_t length) {
    auto& stream = *static_cast<Stream*>(object);
    auto remaining = stream.position < stream.compressed.size() ? stream.compressed.size() - stream.position : 0;
    auto count = std::min<size_t>(length, remaining);
    if (stream.short_bulk_read && length > 16384 && count) --count;
    memcpy(output, stream.compressed.data() + stream.position, count);
    stream.position += count;
    return static_cast<uint32_t>(count);
}
// 模拟原版的连续分段读取，只用于验证调用链及状态，不用于性能比较。
int EngineRead(void* object, void* output, uint32_t length) {
    ++engine_calls;
    auto& info = *static_cast<File*>(object)->info;
    auto& stream = *static_cast<Stream*>(info.stream);
    if (stream.fail_after_chunk && info.total_out >= 1024 * 1024) return -77;
    if (stream.decoded.empty()) {
        std::vector<unsigned char> input(info.compressed_left);
        Seek(nullptr, &stream, info.position + info.prefix_bytes, 0);
        for (size_t done = 0; done < input.size();) {
            const auto request = static_cast<uint32_t>(std::min<size_t>(16384, input.size() - done));
            const auto got = Read(nullptr, &stream, input.data() + done, request);
            if (got != request) return -88;
            done += got;
        }
        stream.decoded.resize(info.uncompressed_left);
        size_t written = 0;
        if (libdeflate_deflate_decompress(decoder, input.data(), input.size(), stream.decoded.data(),
            stream.decoded.size(), &written) != LIBDEFLATE_SUCCESS || written != stream.decoded.size()) return -99;
        info.position += info.compressed_left;
        info.total_in = info.compressed_left;
        info.compressed_left = 0;
    }
    const auto count = std::min(length, info.uncompressed_left);
    memcpy(output, stream.decoded.data() + info.total_out, count);
    info.total_out += count;
    info.uncompressed_left -= count;
    return static_cast<int>(count);
}
int FastRead(void* object, void* output, uint32_t length) {
    const auto before = engine_calls;
    const auto result = fastloading::ReadEntry(object, output, length, engine_trampoline);
    if (engine_calls == before && result > 0) ++accelerated;
    return result;
}
void Pump() { ++pumps; }
int FontRead(void* object, void* output, unsigned length) {
    ++font_calls;
    Check(_ReturnAddress() == font_return, "font caller identity changed");
    if (!asset_loading || length < 2 * 1024 * 1024) return font_original(object, output, length);
    return ReadInChunks(font_original, Pump, object, output, length);
}
struct Data {
    std::vector<unsigned char> input, output;
    Stream stream;
    fastloading::ZipReadInfo info{};
    File file{};
    unsigned char buffer[16384]{};
    Data(const std::vector<unsigned char>& bytes, const std::vector<unsigned char>& compressed)
        : input(bytes), output(bytes.size() + 32, 0xAB) {
        stream.compressed = compressed;
        info.buffer = buffer;
        info.compressed_left = static_cast<uint32_t>(compressed.size());
        info.uncompressed_left = static_cast<uint32_t>(bytes.size());
        info.method = 8; info.read = Read; info.seek = Seek; info.stream = &stream;
        file.info = &info;
    }
    void Verify() {
        Check(!memcmp(input.data(), output.data(), input.size()), "decoded data differs");
        Check(info.total_out == input.size() && !info.uncompressed_left, "read state differs");
        Check(std::all_of(output.begin() + input.size(), output.end(), [](unsigned char value) { return value == 0xAB; }), "output guard overwritten");
    }
};
struct Fixture {
    unsigned char* memory = nullptr;
    unsigned char* entry = nullptr;
    ReadFn font = nullptr, ordinary = nullptr;
    FontReadTarget target;
    bool fast_installed = false;
    Fixture() {
        memory = static_cast<unsigned char*>(VirtualAlloc(nullptr, 0x5000, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
        Check(memory != nullptr, "fixture allocation failed");
        auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(memory);
        dos->e_magic = IMAGE_DOS_SIGNATURE; dos->e_lfanew = 0x100;
        auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(memory + 0x100);
        nt->Signature = IMAGE_NT_SIGNATURE; nt->FileHeader.NumberOfSections = 1;
        nt->FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER64);
        nt->OptionalHeader.SizeOfImage = 0x5000;
        auto section = IMAGE_FIRST_SECTION(nt);
        memcpy(section->Name, ".text", 5);
        section->VirtualAddress = 0x1000; section->Misc.VirtualSize = 0x3000;
        section->Characteristics = IMAGE_SCN_MEM_EXECUTE | IMAGE_SCN_MEM_READ;
        entry = memory + 0x1800;
        const unsigned char prefix[] = {0x40,0x56,0x48,0x83,0xEC,0x20,0x33,0xF6};
        memcpy(entry, prefix, sizeof(prefix));
        memcpy(entry + 8, "\x48\x83\xC4\x20\x5E", 5);
        AbsoluteJump(entry + 13, reinterpret_cast<void*>(&EngineRead));
        memory[0x1C00] = 0xC3;
        memcpy(memory + 0x4000, "font.tex", 9);
        // 保留生产定位器要求的参数布局、font.tex 引用及紧接 ZIP close 的调用序列。
        const unsigned char caller[] = {
            0x53,0x57,0x48,0x81,0xEC,0xD8,0,0,0,0x48,0x8B,0xF9,
            0x44,0x89,0x84,0x24,0xCC,0,0,0,0x48,0x8B,0xC2,0x90,
            0x48,0x8D,0x15,0,0,0,0,
            0x44,0x8B,0x84,0x24,0xCC,0,0,0,0x48,0x8B,0xCF,0x48,0x8B,0xD0,0x48,0x8B,0xD8,
            0xE8,0,0,0,0,0x48,0x8B,0xCF,0xE8,0,0,0,0,
            0x48,0x81,0xC4,0xD8,0,0,0,0x5F,0x5B,0xC3
        };
        auto code = memory + 0x1100;
        memcpy(code, caller, sizeof(caller));
        Relative(code + 24, 3, 7, memory + 0x4000);
        Relative(code + 48, 1, 5, entry);
        Relative(code + 56, 1, 5, memory + 0x1C00);
        font = reinterpret_cast<ReadFn>(code);
        auto other = memory + 0x1200;
        memcpy(other, "\x48\x83\xEC\x28\xE8\0\0\0\0\x48\x83\xC4\x28\xC3", 14);
        Relative(other + 4, 1, 5, entry);
        ordinary = reinterpret_cast<ReadFn>(other);
        Check(FindFontReadTarget(reinterpret_cast<HMODULE>(memory), target), "font target not found");
        Check(target.read == entry && target.call == code + 48, "wrong font target");
        DWORD old;
        Check(VirtualProtect(memory, 0x5000, PAGE_EXECUTE_READ, &old) != 0, "fixture protection failed");
        FlushInstructionCache(GetCurrentProcess(), memory, 0x5000);
    }
    static void Relative(unsigned char* instruction, size_t offset, size_t size, unsigned char* target) {
        const auto delta = static_cast<int32_t>(target - instruction - size);
        memcpy(instruction + offset, &delta, 4);
    }
    void Fast() {
        Check(MH_CreateHook(entry, reinterpret_cast<void*>(&FastRead), reinterpret_cast<void**>(&engine_trampoline)) == MH_OK, "create ZIP hook failed");
        Check(MH_EnableHook(entry) == MH_OK, "enable ZIP hook failed");
        fast_installed = true;
    }
    void Smooth() {
        FontReadTarget found;
        Check(FindFontReadTarget(reinterpret_cast<HMODULE>(memory), found), "ZIP entry hook prevented font discovery");
        unsigned char before[32]; memcpy(before, entry, sizeof(before));
        font_return = found.returnAddress;
        Check(InstallFontReadHook(found, reinterpret_cast<void*>(&FontRead), reinterpret_cast<void**>(&font_original)), "install font CALL failed");
        Check(font_original == reinterpret_cast<ReadFn>(entry), "font fallback bypasses normal ZIP entry");
        Check(!memcmp(before, entry, sizeof(before)), "font hook changed ZIP entry");
        Check(!InstallFontReadHook(found, reinterpret_cast<void*>(&FontRead), reinterpret_cast<void**>(&font_original)), "duplicate CALL patch accepted");
        Check(font_original == reinterpret_cast<ReadFn>(entry), "failed install changed fallback");
    }
    ~Fixture() {
        if (fast_installed) { MH_DisableHook(entry); MH_RemoveHook(entry); }
        VirtualFree(memory, 0, MEM_RELEASE);
    }
};
void Reset() { accelerated = engine_calls = font_calls = pumps = 0; asset_loading = true; }

void CheckGameImage(const wchar_t* path) {
    // 只在测试进程映射游戏副本，不执行游戏函数、不修改磁盘 EXE 或游戏进程。
    HMODULE image = LoadLibraryExW(path, nullptr, DONT_RESOLVE_DLL_REFERENCES);
    Check(image != nullptr, "game image mapping failed");
    auto base = reinterpret_cast<unsigned char*>(image);
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    auto sections = IMAGE_FIRST_SECTION(nt);
    unsigned char* text = nullptr; size_t size = 0;
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i)
        if (!memcmp(sections[i].Name, ".text", 5)) { text = base + sections[i].VirtualAddress; size = sections[i].Misc.VirtualSize; }
    Check(text != nullptr, "game code section missing");
    const fastloading::CodePattern read(zip_read_pattern), close(zip_close_pattern);
    for (bool zip_first : {false, true}) {
        const auto zip = read.Find(text, size);
        Check(zip.count == 1 && close.Find(text, size).count == 1, "game ZIP signatures not unique");
        FontReadTarget font;
        Check(FindFontReadTarget(image, font) && font.read == zip.address, "game font/ZIP target mismatch");
        unsigned char call_before[5]; memcpy(call_before, font.call, 5);
        auto install_zip = [&] {
            Check(MH_CreateHook(zip.address, reinterpret_cast<void*>(&FastRead), reinterpret_cast<void**>(&engine_trampoline)) == MH_OK, "game ZIP trampoline creation failed");
            Check(MH_EnableHook(zip.address) == MH_OK, "game ZIP trampoline enable failed");
        };
        if (zip_first) install_zip();
        FontReadTarget found;
        Check(FindFontReadTarget(image, found) && found.call == font.call, "game font locator depends on ZIP prologue");
        std::vector<unsigned char> entry_before(zip.address, zip.address + read.bytes.size());
        Check(InstallFontReadHook(found, reinterpret_cast<void*>(&FontRead), reinterpret_cast<void**>(&font_original)), "game font CALL installation failed");
        Check(!memcmp(zip.address, entry_before.data(), entry_before.size()), "game font CALL installation changed ZIP body");
        Check(read.Find(text, size).count == (zip_first ? 0u : 1u), "font CALL changed ZIP signature matching");
        unsigned char call_installed[5]; memcpy(call_installed, font.call, 5);
        if (!zip_first) install_zip();
        Check(!memcmp(font.call, call_installed, 5), "game ZIP hook changed font CALL");
        Check(font_original == reinterpret_cast<ReadFn>(zip.address), "game font fallback bypasses ZIP entry");
        Check(close.Find(text, size).count == 1, "game close signature changed");
        Check(MH_DisableHook(zip.address) == MH_OK && MH_RemoveHook(zip.address) == MH_OK, "game ZIP test cleanup failed");
        DWORD protection = 0, ignored = 0;
        Check(VirtualProtect(font.call, 5, PAGE_EXECUTE_READWRITE, &protection) != 0, "game CALL restore failed");
        memcpy(font.call, call_before, 5);
        VirtualProtect(font.call, 5, protection, &ignored);
        FlushInstructionCache(GetCurrentProcess(), font.call, 5);
        Check(read.Find(text, size).count == 1, "game ZIP code not restored");
        printf("Current game image: %s passed; CALL and ZIP entry are independent.\n", zip_first ? "ZIP then font" : "font then ZIP");
    }
    FreeLibrary(image);
}
}
int wmain(int argc, wchar_t** argv) try {
    decoder = libdeflate_alloc_decompressor(); Check(decoder != nullptr, "decoder allocation failed");
    auto compressor = libdeflate_alloc_compressor(1); Check(compressor != nullptr, "compressor allocation failed");
    std::vector<unsigned char> input(3 * 1024 * 1024 + 17);
    uint32_t seed = 19;
    for (auto& byte : input) { seed = seed * 1664525 + 1013904223; byte = static_cast<unsigned char>(seed >> 24); }
    std::vector<unsigned char> compressed(libdeflate_deflate_compress_bound(compressor, input.size()));
    const auto count = libdeflate_deflate_compress(compressor, input.data(), input.size(), compressed.data(), compressed.size());
    Check(count > 16384, "test data does not exercise bulk reads"); compressed.resize(count);
    libdeflate_free_compressor(compressor);
    Check(MH_Initialize() == MH_OK, "MinHook initialization failed");
    for (int mode = 0; mode < 5; ++mode) {
        Fixture fixture;
        const bool smooth = mode >= 2, fast = mode == 1 || mode >= 3;
        if (mode == 4) { fixture.Fast(); fixture.Smooth(); }
        else { if (smooth) fixture.Smooth(); if (fast) fixture.Fast(); }
        Reset();
        Data ordinary(input, compressed);
        Check(fixture.ordinary(&ordinary.file, ordinary.output.data(), static_cast<uint32_t>(input.size())) == static_cast<int>(input.size()), "ordinary result differs");
        ordinary.Verify();
        Check(!font_calls && !pumps, "ordinary resource entered font hook");
        Check(accelerated == (fast ? 1u : 0u) && engine_calls == (fast ? 0u : 1u), "ordinary acceleration path differs");
        Reset();
        Data font(input, compressed);
        Check(fixture.font(&font.file, font.output.data(), static_cast<uint32_t>(input.size())) == static_cast<int>(input.size()), "font result differs");
        font.Verify();
        Check(font_calls == (smooth ? 1u : 0u) && pumps == (smooth ? 4u : 0u), "font chunking differs");
        Check(accelerated == (fast && !smooth ? 1u : 0u), "font chunk bypassed partial fallback");
        Check(engine_calls == (smooth ? 4u : (fast ? 0u : 1u)), "font fallback count differs");
        if (fast && smooth) {
            Reset(); asset_loading = false;
            Data inactive(input, compressed);
            Check(fixture.font(&inactive.file, inactive.output.data(), static_cast<uint32_t>(input.size())) == static_cast<int>(input.size()), "inactive loading result differs");
            inactive.Verify(); Check(accelerated == 1 && !pumps, "inactive loading failed to use whole-entry path");
            Reset();
            Data recovery(input, compressed); recovery.stream.short_bulk_read = true;
            Check(fixture.ordinary(&recovery.file, recovery.output.data(), static_cast<uint32_t>(input.size())) == static_cast<int>(input.size()), "bulk-read failure did not recover");
            recovery.Verify(); Check(engine_calls == 1 && !accelerated && !font_calls, "bulk-read failure used wrong fallback");
            Reset();
            Data failure(input, compressed); failure.stream.fail_after_chunk = true;
            Check(fixture.font(&failure.file, failure.output.data(), static_cast<uint32_t>(input.size())) == -77, "chunk error was swallowed");
            Check(pumps == 1 && engine_calls == 2 && failure.info.total_out == 1024 * 1024, "chunk error state differs");
            Check(!memcmp(input.data(), failure.output.data(), 1024 * 1024), "completed chunk differs");
            Check(std::all_of(failure.output.begin() + 1024 * 1024, failure.output.end(), [](unsigned char value) { return value == 0xAB; }), "failed chunk changed output");
        }
        printf("Cross-mod hooks: mode=%d passed (0 neither, 1 ZIP only, 2 font only, 3 font then ZIP, 4 ZIP then font).\n", mode);
    }
    if (argc == 2) CheckGameImage(argv[1]);
    Check(MH_Uninitialize() == MH_OK, "MinHook cleanup failed");
    libdeflate_free_decompressor(decoder);
    puts("Production CALL installer + font locator + chunk reader + fast ZIP reader: all integration checks passed.");
    return 0;
} catch (const std::exception& error) { fprintf(stderr, "%s\n", error.what()); return 1; }
