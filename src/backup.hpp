#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifdef _WIN32
#include <windows.h>
#endif
#include <filesystem>
#include <functional>
#include <string>
#include <vector>
#include <cstdint>
#include <stdexcept>

namespace backup {
namespace fs = std::filesystem;
using Bytes = std::vector<unsigned char>;
struct Error : std::runtime_error { using std::runtime_error::runtime_error; };
std::string utf8(const std::wstring& s);
std::wstring wide(const std::string& s);
void require(bool ok, const std::string& message);
uint32_t crc32(const Bytes& data);
Bytes compress(const Bytes& data);
Bytes decompress(const Bytes& data, uint32_t expected);
void encrypt_file(const fs::path& source, const fs::path& target, const std::string& password);
void decrypt_file(const fs::path& source, const fs::path& target, const std::string& password);
bool encrypted(const fs::path& path);
void safe_path(const fs::path& path);
void validate_relative(const std::string& path);
uint64_t parse_size(const std::string& text);
uint64_t date_boundary(const std::string& text, bool end);
struct Filters {
    std::string name, path, extensions;
    uint64_t min_size = 0, max_size = UINT64_MAX;
    uint64_t after = 0, before = UINT64_MAX;
    void validate() const;
    bool matches(const fs::path& relative, uint64_t size, uint64_t modified) const;
};
struct Options { Filters filters; bool compression = true; std::string password; };
struct Progress { std::string phase; uint64_t files = 0, bytes = 0, total_bytes = 0; };
using Callback = std::function<void(const Progress&)>;
struct Result {
    fs::path path;
    std::string root;
    uint64_t files = 0, directories = 0, bytes = 0, archive_bytes = 0;
    bool compression = false, encryption = false;
};
Result create(const fs::path& source, const fs::path& archive, const Options& options = {}, Callback progress = {});
Result restore(const fs::path& archive, const fs::path& destination, const std::string& password = "", Callback progress = {});
Result inspect(const fs::path& archive, const std::string& password = "", Callback progress = {});
}
