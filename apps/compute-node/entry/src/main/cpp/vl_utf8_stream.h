#pragma once
#include <string>

namespace qwenvl {
// SDK token callbacks can split a UTF-8 code point. Keep at most its unfinished
// suffix; every returned string is valid UTF-8 before JSON/NAPI conversion.
class Utf8Stream {
public:
    void Reset() { pending.clear(); }
    std::string Append(const std::string& bytes) { return Decode(bytes, false); }
    std::string Finish() { return Decode("", true); }
private:
    std::string pending;
    std::string Decode(const std::string& bytes, bool final)
    {
        const std::string input = pending + bytes;
        pending.clear();
        std::string output;
        size_t at = 0;
        while (at < input.size()) {
            const auto lead = static_cast<unsigned char>(input[at]);
            size_t need = lead < 0x80 ? 1 :
                (lead >= 0xC2 && lead <= 0xDF ? 2 :
                (lead >= 0xE0 && lead <= 0xEF ? 3 :
                (lead >= 0xF0 && lead <= 0xF4 ? 4 : 0)));
            bool valid = need > 0;
            for (size_t i = 1; valid && i < need && at + i < input.size(); ++i) {
                const auto next = static_cast<unsigned char>(input[at + i]);
                valid = next >= 0x80 && next <= 0xBF;
                if (i == 1) {
                    valid = valid && !(lead == 0xE0 && next < 0xA0) &&
                        !(lead == 0xED && next > 0x9F) &&
                        !(lead == 0xF0 && next < 0x90) &&
                        !(lead == 0xF4 && next > 0x8F);
                }
            }
            if (!valid) {
                output += "\xEF\xBF\xBD";
                ++at;
            } else if (at + need > input.size()) {
                if (final) output += "\xEF\xBF\xBD";
                else pending = input.substr(at);
                break;
            } else {
                output.append(input, at, need);
                at += need;
            }
        }
        return output;
    }
};
} // namespace qwenvl
