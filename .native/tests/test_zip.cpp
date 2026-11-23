#include "zip_reader.h"
#include "libdeflate.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {
void Check(bool ok) { if (!ok) throw std::runtime_error("ZIP regression failed"); }
struct File { unsigned char padding[0xC8]{}; fastloading::ZipReadInfo* info; };
struct Stream { std::vector<unsigned char> bytes; size_t position = 0; bool short_read = false, bad_seek = false; };
int fallbacks;
int Fallback(void*, void*, uint32_t) { ++fallbacks; return -777; }
int32_t Seek(void*, void* stream, uint32_t position, int) {
    auto& s = *static_cast<Stream*>(stream);
    s.position = position;
    return s.bad_seek ? -1 : 0;
}
uint32_t Read(void*, void* stream, void* output, uint32_t length) {
    auto& s = *static_cast<Stream*>(stream);
    auto count = std::min<size_t>(length, s.position <= s.bytes.size() ? s.bytes.size() - s.position : 0);
    if (s.short_read && count) --count;
    if (count) memcpy(output, s.bytes.data() + s.position, count);
    s.position += count;
    return static_cast<uint32_t>(count);
}
}
int main() {
    auto* compressor = libdeflate_alloc_compressor(6);
    Check(compressor != nullptr);
    unsigned cases = 0;
    for (size_t size : {size_t(1), size_t(257), size_t(16384), size_t(65537), size_t(1048576)}) {
        std::vector<unsigned char> input(size);
        uint32_t seed = 17;
        for (size_t i = 0; i < size; ++i) { seed = seed * 1664525 + 1013904223; input[i] = i % 3 ? 'a' : static_cast<unsigned char>(seed >> 24); }
        Stream stream;
        stream.bytes.resize(libdeflate_deflate_compress_bound(compressor, size));
        size_t compressed = libdeflate_deflate_compress(compressor, input.data(), size, stream.bytes.data(), stream.bytes.size());
        Check(compressed > 0);
        stream.bytes.resize(compressed);
        for (int scenario = 0; scenario < 12; ++scenario) {
            auto bytes = stream.bytes;
            stream.short_read = scenario == 8;
            stream.bad_seek = scenario == 9;
            fastloading::ZipReadInfo info{};
            unsigned char buffer[16384];
            info.buffer = buffer;
            info.compressed_left = static_cast<uint32_t>(compressed);
            info.uncompressed_left = static_cast<uint32_t>(size);
            info.method = 8;
            info.read = Read;
            info.seek = Seek;
            info.stream = &stream;
            File file{};
            file.info = &info;
            std::vector<unsigned char> output(size + 32, 0xAB);
            uint32_t length = static_cast<uint32_t>(size);
            if (scenario == 1) --length;
            if (scenario == 2) info.raw = 1;
            if (scenario == 3) info.method = 0;
            if (scenario == 4) info.total_out = 1;
            if (scenario == 5) info.avail_in = 1;
            if (scenario == 6) info.compressed_left = 64u * 1024u * 1024u + 1;
            if (scenario == 7) info.position = UINT32_MAX;
            if (scenario == 10) { stream.bytes.assign(3, 0xFF); info.compressed_left = 3; }
            if (scenario == 11) length += 31;
            auto before = info;
            fallbacks = 0;
            int result = fastloading::ReadEntry(&file, output.data(), length, Fallback);
            if (scenario == 0 || scenario == 11) {
                Check(result == static_cast<int>(size) && !fallbacks);
                Check(!memcmp(input.data(), output.data(), size));
                Check(info.total_in == compressed && info.total_out == size && !info.compressed_left && !info.uncompressed_left);
                Check(info.next_out == output.data() + size && info.position == compressed);
                Check(std::all_of(output.begin() + size, output.end(), [](unsigned char b) { return b == 0xAB; }));
            } else {
                Check(result == -777 && fallbacks == 1);
                Check(!memcmp(&before, &info, sizeof(info)));
            }
            stream.bytes = bytes;
            ++cases;
        }
    }
    libdeflate_free_compressor(compressor);
    Check(fastloading::ReadEntry(nullptr, nullptr, 0, Fallback) == -777);
    printf("ZIP tests: %u scenarios passed; fallback state and output guards checked.\n", cases + 1);
}
