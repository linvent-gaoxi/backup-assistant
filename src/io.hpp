#pragma once
#include "backup.hpp"
#include <fstream>
#include <array>
#ifdef _WIN32
#include <bcrypt.h>
#else
#include <openssl/rand.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <cerrno>
#include <cstdio>
#include <linux/fs.h>
#endif

namespace backup {
constexpr uint32_t BLOCK = 1024*1024;
inline void write_bytes(std::ostream& out,const void* p,size_t n) {out.write((const char*)p,n);require(bool(out),"写入失败，请检查磁盘空间和权限");}
inline void read_bytes(std::istream& in,void* p,size_t n) {in.read((char*)p,n);require(bool(in),"备份文件截断或读取失败");}
template<class T> void put(std::ostream& out,T v) { for(size_t i=0;i<sizeof(T);++i){unsigned char c=(uint64_t(v)>>(8*i))&255;write_bytes(out,&c,1);} }
template<class T> T get(std::istream& in) {uint64_t v=0;for(size_t i=0;i<sizeof(T);++i){unsigned char c;read_bytes(in,&c,1);v|=uint64_t(c)<<(8*i);}return T(v);}
inline void put_string(std::ostream& o,const std::string& s) {put<uint32_t>(o,(uint32_t)s.size());write_bytes(o,s.data(),s.size());}
inline std::string get_string(std::istream& i) {auto n=get<uint32_t>(i);require(n>0 && n<=32760,"归档字符串长度无效");std::string s(n,0);read_bytes(i,&s[0],n);return s;}
#ifdef _WIN32
inline void random_bytes(unsigned char* p,ULONG n) {require(BCryptGenRandom(nullptr,p,n,BCRYPT_USE_SYSTEM_PREFERRED_RNG)>=0,"系统随机数生成失败");}
inline fs::path unique_path(const fs::path& parent,const std::wstring& suffix) {
    unsigned char r[16];random_bytes(r,16);const wchar_t* hex=L"0123456789abcdef";std::wstring s=L".sbackup-";for(auto c:r){s+=hex[c>>4];s+=hex[c&15];}return parent/(s+suffix);
}
struct Cleanup {
    fs::path path;
    ~Cleanup() {if(path.empty())return;std::error_code e;if(fs::is_directory(path,e)){for(fs::recursive_directory_iterator it(path,e),end;it!=end&&!e;it.increment(e))SetFileAttributesW(it->path().c_str(),FILE_ATTRIBUTE_NORMAL);}SetFileAttributesW(path.c_str(),FILE_ATTRIBUTE_NORMAL);fs::remove_all(path,e);}
};
inline void exclusive_file(const fs::path& p) {
    HANDLE h=CreateFileW(p.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);require(h!=INVALID_HANDLE_VALUE,"无法创建临时文件："+p.u8string());CloseHandle(h);
}
inline bool publish_path(const fs::path& from,const fs::path& to) {
    return MoveFileExW(from.c_str(),to.c_str(),MOVEFILE_WRITE_THROUGH);
}
#else
inline void random_bytes(unsigned char* p,int n) {
    require(RAND_bytes(p,n)==1,"系统随机数生成失败");
}
inline fs::path unique_path(const fs::path& parent,const std::wstring& suffix) {
    unsigned char r[16];random_bytes(r,16);
    const char* hex="0123456789abcdef";
    std::string name=".sbackup-";
    for(auto c:r){name+=hex[c>>4];name+=hex[c&15];}
    return parent/(name+utf8(suffix));
}
struct Cleanup {
    fs::path path;
    ~Cleanup(){if(!path.empty()){std::error_code ec;fs::remove_all(path,ec);}}
};
inline void exclusive_file(const fs::path& p) {
    int fd=open(p.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
    require(fd>=0,"无法创建临时文件："+p.u8string());
    close(fd);
}
inline bool publish_path(const fs::path& from,const fs::path& to) {
    if (syscall(SYS_renameat2,AT_FDCWD,from.c_str(),AT_FDCWD,to.c_str(),RENAME_NOREPLACE)==0)
        return true;
    if (errno!=EINVAL && errno!=ENOSYS && errno!=EOPNOTSUPP)
        return false;

    // WSL's Windows-drive mount does not implement RENAME_NOREPLACE.
    // Reserve the name first; plain rename replaces only our empty directory.
    struct stat info{};
    if (lstat(from.c_str(),&info)!=0 || !S_ISDIR(info.st_mode) || mkdir(to.c_str(),0700)!=0)
        return false;
    if (::rename(from.c_str(),to.c_str())==0)
        return true;
    rmdir(to.c_str());
    return false;
}
#endif
inline void finish(std::ofstream& out) {out.flush();require(bool(out),"写入失败，可能磁盘空间不足");out.close();require(!out.fail(),"关闭备份文件失败");}
}
