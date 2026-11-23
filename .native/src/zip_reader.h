#pragma once
#include <cstddef>
#include <cstdint>

namespace fastloading {
using Read = uint32_t (*)(void*, void*, void*, uint32_t);
using Seek = int32_t (*)(void*, void*, uint32_t, int);
using OriginalRead = int (*)(void*, void*, uint32_t);

// 已核对的引擎私有布局；只有读/关闭函数特征通过后才允许访问。
struct ZipReadInfo {
    void* buffer;
    const uint8_t* next_in;
    uint32_t avail_in, total_in;
    uint8_t* next_out;
    uint32_t avail_out, total_out;
    uint8_t stream_tail[0x38];
    uint32_t position;
    uint8_t middle[0x18];
    uint32_t compressed_left, uncompressed_left;
    uint8_t io_prefix[0x14];
    Read read;
    uint8_t io_middle[0x10];
    Seek seek;
    uint8_t io_tail[0x10];
    void* opaque;
    void* stream;
    int32_t method;
    uint32_t prefix_bytes;
    int32_t raw;
};
static_assert(offsetof(ZipReadInfo, position) == 0x60);
static_assert(offsetof(ZipReadInfo, compressed_left) == 0x7C);
static_assert(offsetof(ZipReadInfo, read) == 0x98);
static_assert(offsetof(ZipReadInfo, seek) == 0xB0);
static_assert(offsetof(ZipReadInfo, raw) == 0xE0);

int ReadEntry(void* file, void* output, uint32_t length, OriginalRead fallback);
}
