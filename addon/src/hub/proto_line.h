#ifndef _FCITX5_AIINPUT_PROTO_LINE_H_
#define _FCITX5_AIINPUT_PROTO_LINE_H_

#include <string>
#include <vector>

namespace fcitx {

// v1 envelope 行解析（扁平字段提取，本仓不引 JSON 库；见
// lab/spec/protocol.md §2）。后端产出的行由我们自己约定的字段构成，
// 覆盖：method、单值字符串、字符串数组；未知字段忽略。

// 定位 "key": 之后的值起点（容忍冒号后空白——后端若 pretty-print
// 也不能静默丢事件；宽松在查找侧，不在语义侧）
inline size_t jsonValuePos(const std::string &s, const char *key,
                           size_t from = 0) {
    const std::string pat = std::string("\"") + key + "\"";
    auto p = s.find(pat, from);
    if (p == std::string::npos) {
        return std::string::npos;
    }
    p += pat.size();
    while (p < s.size() && (s[p] == ' ' || s[p] == '\t')) {
        ++p;
    }
    if (p >= s.size() || s[p] != ':') {
        return std::string::npos;
    }
    ++p;
    while (p < s.size() && (s[p] == ' ' || s[p] == '\t')) {
        ++p;
    }
    return p;
}

inline std::string envelopeMethod(const std::string &line) {
    auto p = jsonValuePos(line, "method");
    if (p == std::string::npos || p >= line.size() || line[p] != '"') {
        return "";
    }
    ++p;
    auto e = line.find('"', p);
    return e == std::string::npos ? "" : line.substr(p, e - p);
}

// JSON 字符串字面量解码（\" \\ \/ \n \r \t \uXXXX BMP）；后端脚本须
// ensure_ascii=False（CJK 保持原生 UTF-8），\u 只兜底
inline std::string jsonUnescape(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '\\' || i + 1 >= s.size()) {
            out += s[i];
            continue;
        }
        char c = s[++i];
        switch (c) {
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case '"': out += '"'; break;
        case '\\': out += '\\'; break;
        case '/': out += '/'; break;
        case 'u': {
            if (i + 4 >= s.size()) {
                out += 'u';
                break;
            }
            unsigned cp = 0;
            bool ok = true;
            for (int k = 1; k <= 4; ++k) {
                char h = s[i + k];
                cp <<= 4;
                if (h >= '0' && h <= '9') cp |= h - '0';
                else if (h >= 'a' && h <= 'f') cp |= h - 'a' + 10;
                else if (h >= 'A' && h <= 'F') cp |= h - 'A' + 10;
                else { ok = false; break; }
            }
            if (!ok) { out += 'u'; break; }
            i += 4;
            if (cp < 0x80) {
                out += static_cast<char>(cp);
            } else if (cp < 0x800) {
                out += static_cast<char>(0xC0 | (cp >> 6));
                out += static_cast<char>(0x80 | (cp & 0x3F));
            } else {
                out += static_cast<char>(0xE0 | (cp >> 12));
                out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                out += static_cast<char>(0x80 | (cp & 0x3F));
            }
            break;
        }
        default: out += c; break;
        }
    }
    return out;
}

inline std::string jsonStrField(const std::string &s, const char *key) {
    auto p = jsonValuePos(s, key);
    if (p == std::string::npos || p >= s.size() || s[p] != '"') {
        return "";
    }
    ++p;
    std::string raw;
    for (; p < s.size(); ++p) {
        if (s[p] == '\\' && p + 1 < s.size()) {
            raw += s[p];
            raw += s[p + 1];
            ++p;
            continue;
        }
        if (s[p] == '"') {
            return jsonUnescape(raw);
        }
        raw += s[p];
    }
    return jsonUnescape(raw);
}

// "key":["a","b",...] → 元素列表（元素内转义已解码）
inline std::vector<std::string> jsonStrArrayField(const std::string &s,
                                                  const char *key) {
    std::vector<std::string> out;
    auto p = jsonValuePos(s, key);
    if (p == std::string::npos || p >= s.size() || s[p] != '[') {
        return out;
    }
    ++p;
    auto end = s.find(']', p);
    if (end == std::string::npos) {
        return out;
    }
    while (p < end) {
        if (s[p] != '"') {
            ++p;
            continue;
        }
        ++p;
        std::string raw;
        for (; p < end; ++p) {
            if (s[p] == '\\' && p + 1 < end) {
                raw += s[p];
                raw += s[p + 1];
                ++p;
                continue;
            }
            if (s[p] == '"') {
                break;
            }
            raw += s[p];
        }
        out.push_back(jsonUnescape(raw));
        ++p;
    }
    return out;
}

} // namespace fcitx

#endif // _FCITX5_AIINPUT_PROTO_LINE_H_
