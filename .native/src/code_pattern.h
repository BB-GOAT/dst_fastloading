#pragma once
#include <cstddef>
#include <cstdio>
#include <vector>

namespace fastloading {
struct PatternMatch {
    unsigned char* address = nullptr;
    size_t count = 0;
};

class CodePattern {
public:
    explicit CodePattern(const char* text) {
        while (*text) {
            if (*text == ' ') { ++text; continue; }
            unsigned value = 0;
            const bool wildcard = text[0] == '?' && text[1] == '?';
            if (!wildcard && sscanf_s(text, "%2x", &value) != 1) { bytes.clear(); return; }
            bytes.push_back(static_cast<unsigned char>(value));
            mask.push_back(wildcard ? 0 : 255);
            text += 2;
        }
    }

    PatternMatch Find(unsigned char* start, size_t length) const {
        PatternMatch result;
        if (bytes.empty()) return result;
        for (size_t j = 0; j + bytes.size() <= length; ++j) {
            bool matches = true;
            for (size_t k = 0; matches && k < bytes.size(); ++k)
                if (mask[k] && start[j + k] != bytes[k]) matches = false;
            if (matches) { result.address = start + j; ++result.count; }
        }
        return result;
    }

    std::vector<unsigned char> bytes, mask;
};
}
