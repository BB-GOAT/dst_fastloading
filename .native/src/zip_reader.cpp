#include "zip_reader.h"
#include "libdeflate.h"
#include <climits>
#include <limits>
#include <new>
#include <vector>

namespace fastloading {
namespace {
struct Scratch {
    libdeflate_decompressor* decoder = libdeflate_alloc_decompressor();
    std::vector<uint8_t> compressed;
    ~Scratch() { libdeflate_free_decompressor(decoder); }
};
}

int ReadEntry(void* file, void* output, uint32_t length, OriginalRead fallback) {
    if (!file) return fallback(file, output, length);
    auto* info = *reinterpret_cast<ZipReadInfo**>(static_cast<uint8_t*>(file) + 0xC8);
    // 只接管首次完整读取的 DEFLATE 条目；分段、raw、stored 等保留原版。
    if (!info || !info->buffer || !output || !length || info->method != 8 || info->raw
        || info->avail_in || info->total_in || info->total_out
        || !info->compressed_left || info->compressed_left > 64u * 1024u * 1024u
        || !info->uncompressed_left || info->uncompressed_left > INT_MAX
        || length < info->uncompressed_left || !info->seek || !info->read
        || info->position > UINT32_MAX - info->prefix_bytes
        || info->compressed_left > UINT32_MAX - info->position) {
        return fallback(file, output, length);
    }

    const auto compressed = info->compressed_left;
    const auto uncompressed = info->uncompressed_left;
    const auto position = info->position + info->prefix_bytes;
    try {
        thread_local Scratch scratch;
        if (!scratch.decoder) return fallback(file, output, length);
        scratch.compressed.resize(compressed);
        if (info->seek(info->opaque, info->stream, position, 0) == 0
            && info->read(info->opaque, info->stream, scratch.compressed.data(), compressed) == compressed) {
            size_t written = 0;
            if (libdeflate_deflate_decompress(scratch.decoder, scratch.compressed.data(), compressed,
                output, uncompressed, &written) == LIBDEFLATE_SUCCESS && written == uncompressed) {
                // 本机引擎的 minizip 不累计或检查 CRC；保持其读取语义。
                info->position += compressed;
                info->compressed_left = 0;
                info->uncompressed_left = 0;
                info->total_in = compressed;
                info->total_out = uncompressed;
                info->next_in = static_cast<const uint8_t*>(info->buffer);
                info->avail_in = 0;
                info->next_out = static_cast<uint8_t*>(output) + uncompressed;
                info->avail_out = 0;
                return static_cast<int>(uncompressed);
            }
        }
    } catch (const std::bad_alloc&) {
        // 内存不足时不修改 minizip 的逻辑状态，由原版继续处理。
    }
    // 原版首次读取会按 position 重新 seek，可覆盖失败解码写入的输出。
    return fallback(file, output, length);
}
}
