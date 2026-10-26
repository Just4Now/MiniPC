#include "../vl_utf8_stream.h"
#include <cassert>
#include <codecvt>
#include <locale>
#include <iostream>
#include <string>

static std::string Checked(const std::string& text)
{
    std::wstring_convert<std::codecvt_utf8<char32_t>, char32_t> codec;
    codec.from_bytes(text);
    assert(codec.converted() == text.size());
    return text;
}

int main()
{
    const std::string text = "A\xC2\xA3\xE7\x8C\xAB\xF0\x9F\x90\xB1Z";
    for (size_t first = 0; first <= text.size(); ++first) {
        for (size_t second = first; second <= text.size(); ++second) {
            qwenvl::Utf8Stream stream;
            std::string output = Checked(stream.Append(text.substr(0, first)));
            output += Checked(stream.Append(text.substr(first, second - first)));
            output += Checked(stream.Append(text.substr(second)));
            output += stream.Finish();
            assert(output == text);
        }
    }
    qwenvl::Utf8Stream stream;
    std::string output;
    for (const char byte : text) output += Checked(stream.Append(std::string(1, byte)));
    assert(output + stream.Finish() == text);
    assert(stream.Append("\xE7\x8C").empty());
    assert(stream.Finish() == "\xEF\xBF\xBD");
    assert(stream.Append("ok") == "ok");
    assert(stream.Append("\xF0\x9F").empty());
    stream.Reset();
    assert(stream.Append("next") == "next");
    assert(stream.Finish().empty());
    for (const std::string bad : {"\xC0\xAF", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xFF"}) {
        assert(stream.Append(bad).find("\xEF\xBF\xBD") != std::string::npos);
    }
    assert(stream.Append("\xE7").empty());
    assert(stream.Append("A") == "\xEF\xBF\xBD" "A");
    std::cout << "PASS: VL UTF-8 every split, bytewise callbacks, invalid bytes, final tail and request reset\n";
}
