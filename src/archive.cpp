#include "io.hpp"
#include <algorithm>
#include <set>
#include <map>
#include <cstring>
#include <memory>
#ifndef _WIN32
#include <openssl/evp.h>
#include <sys/stat.h>
#include <cerrno>
#endif

namespace backup {
namespace {
constexpr char MAGIC[]="SBKRAW01";
constexpr char MAGIC_POSIX[]="SBKRAW02";
#ifdef _WIN32
struct Entry { fs::path relative; bool directory; uint64_t time,size; DWORD attributes; uint8_t kind=0; uint32_t mode=0,uid=0,gid=0; std::string link; };
uint64_t ticks(FILETIME t){return (uint64_t(t.dwHighDateTime)<<32)|t.dwLowDateTime;}
Entry metadata(const fs::path& absolute,const fs::path& relative) {
    WIN32_FILE_ATTRIBUTE_DATA a{};require(GetFileAttributesExW(absolute.c_str(),GetFileExInfoStandard,&a),"无法读取文件属性："+absolute.u8string());
    require(!(a.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DEVICE)),"不支持链接或特殊文件："+absolute.u8string());
    return {relative,bool(a.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY),ticks(a.ftLastWriteTime),(uint64_t(a.nFileSizeHigh)<<32)|a.nFileSizeLow,a.dwFileAttributes&FILE_ATTRIBUTE_READONLY};
}
std::wstring folded(const fs::path& p) {
    auto s=p.lexically_normal().generic_wstring();if(s.empty())return s;
    int n=LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_LOWERCASE,s.data(),(int)s.size(),nullptr,0,nullptr,nullptr,0);
    require(n>0,"路径大小写规范化失败");std::wstring out(n,0);LCMapStringEx(LOCALE_NAME_INVARIANT,LCMAP_LOWERCASE,s.data(),(int)s.size(),&out[0],n,nullptr,nullptr,0);return out;
}
#else
constexpr uint32_t FILE_ATTRIBUTE_READONLY=1;
struct Entry { fs::path relative; bool directory; uint64_t time,size; uint32_t attributes; uint8_t kind=0; uint32_t mode=0,uid=0,gid=0; std::string link; uint64_t device=0,inode=0; bool multiple=false; };
Entry metadata(const fs::path& absolute,const fs::path& relative) {
    struct stat info{};
    require(lstat(absolute.c_str(),&info)==0,"无法读取文件属性："+absolute.u8string());
    require(S_ISDIR(info.st_mode)||S_ISREG(info.st_mode)||S_ISLNK(info.st_mode)||S_ISFIFO(info.st_mode),"不支持链接或特殊文件："+absolute.u8string());
    require(info.st_mtim.tv_sec>=-11644473600LL,"时间超出归档范围");
    uint64_t ticks=(info.st_mtim.tv_sec+11644473600LL)*10000000ULL+info.st_mtim.tv_nsec/100;
    Entry result{relative,bool(S_ISDIR(info.st_mode)),ticks,uint64_t(info.st_size),(info.st_mode&S_IWUSR)?0u:1u};
    result.mode=info.st_mode&0777;result.uid=info.st_uid;result.gid=info.st_gid;
    result.device=info.st_dev;result.inode=info.st_ino;result.multiple=S_ISREG(info.st_mode)&&info.st_nlink>1;
    if(S_ISLNK(info.st_mode)){result.kind=2;result.link=fs::read_symlink(absolute).generic_u8string();}
    if(S_ISFIFO(info.st_mode))result.kind=3;
    return result;
}
std::wstring folded(const fs::path& p) {
    auto name=wide(p.lexically_normal().generic_u8string());
    for(auto& ch:name)ch=std::towlower(ch);
    return name;
}
#endif
bool within(const fs::path& p,const fs::path& parent) {auto a=folded(p),b=folded(parent);return a==b || (a.size()>b.size()&&a.compare(0,b.size(),b)==0&&(b.back()==L'/'||a[b.size()]==L'/'));}
Bytes digest(const fs::path& p,uint64_t n) {
#ifdef _WIN32
    BCRYPT_ALG_HANDLE alg=nullptr;BCRYPT_HASH_HANDLE hash=nullptr;Bytes object;
    struct Guard {BCRYPT_ALG_HANDLE& a;BCRYPT_HASH_HANDLE& h;~Guard(){if(h)BCryptDestroyHash(h);if(a)BCryptCloseAlgorithmProvider(a,0);}}guard{alg,hash};
    require(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0,"无法初始化 SHA-256");
    ULONG size=0,got=0;require(BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,(PUCHAR)&size,sizeof(size),&got,0)>=0,"无法创建校验对象");object.resize(size);
    require(BCryptCreateHash(alg,&hash,object.data(),size,nullptr,0,0)>=0,"无法创建 SHA-256");
    std::ifstream in(p,std::ios::binary);require(bool(in),"无法读取校验文件");Bytes b(BLOCK);
    while(n) {auto count=(size_t)std::min<uint64_t>(n,b.size());read_bytes(in,b.data(),count);require(BCryptHashData(hash,b.data(),(ULONG)count,0)>=0,"校验计算失败");n-=count;}
    Bytes out(32);require(BCryptFinishHash(hash,out.data(),32,0)>=0,"校验计算失败");BCryptDestroyHash(hash);hash=nullptr;return out;
#else
    std::unique_ptr<EVP_MD_CTX,decltype(&EVP_MD_CTX_free)> ctx(EVP_MD_CTX_new(),EVP_MD_CTX_free);
    require(ctx&&EVP_DigestInit_ex(ctx.get(),EVP_sha256(),nullptr)==1,"无法初始化 SHA-256");
    std::ifstream in(p,std::ios::binary);require(bool(in),"无法读取校验文件");
    Bytes buffer(BLOCK);
    while(n){
        auto count=std::min<uint64_t>(n,buffer.size());
        read_bytes(in,buffer.data(),count);
        require(EVP_DigestUpdate(ctx.get(),buffer.data(),count)==1,"校验计算失败");
        n-=count;
    }
    Bytes out(32);
    require(EVP_DigestFinal_ex(ctx.get(),out.data(),nullptr)==1,"校验计算失败");
    return out;
#endif
}
void verify(const fs::path& p) {
    uint64_t size=fs::file_size(p);require(size>=32+8+1+4+4,"备份文件过短");auto actual=digest(p,size-32);std::ifstream in(p,std::ios::binary);in.seekg((std::streamoff)(size-32));Bytes stored(32);read_bytes(in,stored.data(),32);require(actual==stored,"备份完整性校验失败，文件可能损坏");
}
#ifdef _WIN32
void set_metadata(const fs::path& p,const Entry& e,bool =false) {
    HANDLE h=CreateFileW(p.c_str(),FILE_WRITE_ATTRIBUTES,FILE_SHARE_READ,nullptr,OPEN_EXISTING,e.directory?FILE_FLAG_BACKUP_SEMANTICS:FILE_ATTRIBUTE_NORMAL,nullptr);
    require(h!=INVALID_HANDLE_VALUE,"无法恢复修改时间："+p.u8string());FILETIME ft{DWORD(e.time),DWORD(e.time>>32)};BOOL ok=SetFileTime(h,nullptr,nullptr,&ft);CloseHandle(h);require(ok,"恢复修改时间失败："+p.u8string());
    require(SetFileAttributesW(p.c_str(),e.attributes?e.attributes:FILE_ATTRIBUTE_NORMAL),"无法恢复只读属性："+p.u8string());
}
struct ReadLock {
    HANDLE h;
    explicit ReadLock(const fs::path& p):h(CreateFileW(p.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,nullptr)){require(h!=INVALID_HANDLE_VALUE,"文件正在写入或无法读取："+p.u8string());}
    ~ReadLock(){CloseHandle(h);}
    Bytes read(uint32_t n){Bytes b(n);DWORD got=0;require(ReadFile(h,b.data(),n,&got,nullptr)&&got==n,"源文件读取失败或内容已变化");return b;}
};
#else
void set_metadata(const fs::path& p,const Entry& e,bool posix=false) {
    if(posix) {
        struct stat existing{};
        require(lstat(p.c_str(),&existing)==0,"无法读取还原文件的属主");
        if(existing.st_uid!=e.uid || existing.st_gid!=e.gid)
            require(lchown(p.c_str(),e.uid,e.gid)==0,"无法恢复属主或属组："+p.u8string());
        if(e.kind!=2)require(chmod(p.c_str(),e.mode)==0,"无法恢复权限："+p.u8string());
    }
    timespec times[2]{{0,UTIME_OMIT},{static_cast<time_t>(e.time/10000000)-11644473600LL,static_cast<long>(e.time%10000000)*100}};
    require(utimensat(AT_FDCWD,p.c_str(),times,AT_SYMLINK_NOFOLLOW)==0,"恢复修改时间失败");
    if(!posix&&e.attributes&&!e.directory) fs::permissions(p,fs::perms::owner_write|fs::perms::group_write|fs::perms::others_write,fs::perm_options::remove);
}
struct ReadLock {
    int fd;
    explicit ReadLock(const fs::path& p):fd(open(p.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)){
        require(fd>=0,"无法打开文件："+p.u8string());
        struct stat info{};
        if(fstat(fd,&info)!=0||!S_ISREG(info.st_mode)){close(fd);throw Error("仅支持普通文件");}
    }
    ~ReadLock(){close(fd);}
    Bytes read(uint32_t n){
        Bytes bytes(n);
        size_t offset=0;
        while(offset<n){
            auto got=::read(fd,bytes.data()+offset,n-offset);
            if(got<0&&errno==EINTR)continue;
            require(got>0,"源文件读取失败或内容已变化");
            offset+=got;
        }
        return bytes;
    }
};
#endif
bool make_private_directory(const fs::path& path) {
#ifdef _WIN32
    return fs::create_directory(path);
#else
    return mkdir(path.c_str(),0700)==0;
#endif
}
Result read_archive(const fs::path& archive,const fs::path* destination,const std::string& password,Callback cb) {
    auto absolute=fs::absolute(archive).lexically_normal();safe_path(absolute);require(fs::is_regular_file(absolute),"备份文件不存在");
    ReadLock archive_lock(absolute);
    fs::path temp_parent=destination?fs::absolute(*destination).lexically_normal():fs::temp_directory_path();safe_path(temp_parent);require(fs::is_directory(temp_parent),"目标文件夹不存在");
    Cleanup plain;fs::path input=absolute;bool enc=encrypted(input);
    if(cb)cb({enc?"验证密码与解密":"校验备份",0,0,0});
    if(enc){plain.path=unique_path(temp_parent,L".plain");exclusive_file(plain.path);decrypt_file(absolute,plain.path,password);input=plain.path;}
    verify(input);
    std::ifstream in(input,std::ios::binary);char magic[8];read_bytes(in,magic,8);bool posix=memcmp(magic,MAGIC_POSIX,8)==0;require(posix||memcmp(magic,MAGIC,8)==0,"不是本项目支持的备份格式");
#ifdef _WIN32
    require(!posix||!destination,"Linux 归档请在 Linux 下还原以保留链接和权限");
#endif
    auto mode=get<uint8_t>(in);require(mode<=1,"不支持的压缩方式");auto root=get_string(in);validate_relative(root);require(root.find('/')==std::string::npos,"根目录名称无效");auto count=get<uint32_t>(in);require(count>0&&count<=1000000,"归档条目数量无效");
    Result result;result.path=absolute;result.root=root;result.compression=mode;result.encryption=enc;result.archive_bytes=fs::file_size(absolute);
    fs::path final,staging;Cleanup cleanup;
    if(destination){final=temp_parent/fs::u8path(root);safe_path(final);require(!fs::exists(final),"目标已存在同名目录，请另选还原位置："+final.u8string());staging=unique_path(temp_parent,L".restore");require(make_private_directory(staging),"无法建立还原临时目录");cleanup.path=staging;}
    std::set<std::wstring> seen,dirnames,regular;std::vector<Entry> directories;bool first=true;
    for(uint32_t j=0;j<count;++j) {
        auto type=get<uint8_t>(in);require(type<=(posix?4:1),"归档条目类型无效");auto s=get_string(in);if(first){require(s=="."&&type==1,"归档缺少根目录");}else validate_relative(s);
        fs::path rel=s=="."?fs::path():fs::u8path(s);auto key=folded(rel);require(seen.insert(key).second,"归档存在重复路径");
        if(!rel.empty())require(dirnames.count(folded(rel.parent_path()))>0,"归档父目录缺失、文件目录冲突或顺序错误");
        Entry e{rel,type==1,get<uint64_t>(in),0,get<uint32_t>(in)};require(e.time<=2650467743999999999ULL && (e.attributes&~FILE_ATTRIBUTE_READONLY)==0,"归档元数据无效");e.size=get<uint64_t>(in);require(!e.directory||e.size==0,"目录大小字段无效");
        if(posix){
            e.kind=type;e.mode=get<uint32_t>(in);e.uid=get<uint32_t>(in);e.gid=get<uint32_t>(in);
            require(e.mode<=0777,"权限字段无效");
            if(type==2||type==4){e.link=get_string(in);validate_relative(e.link);}
            if(type>=2)require(e.size==0,"特殊文件数据长度无效");
        }
        fs::path target=staging/rel;
        if(type>=2){
            if(type==4)require(regular.count(folded(fs::u8path(e.link)))>0,"硬链接目标不是此前的普通文件");
#ifndef _WIN32
            if(destination){
                if(type==2)fs::create_symlink(fs::u8path(e.link),target);
                else if(type==3)require(mkfifo(target.c_str(),0600)==0,"无法还原命名管道");
                else fs::create_hard_link(staging/fs::u8path(e.link),target);
                if(type!=4)set_metadata(target,e,posix);
            }
#endif
            ++result.files;
            first=false;
            continue;
        }
        if(e.directory) {
            ++result.directories;dirnames.insert(key);directories.push_back(e);if(destination&&!rel.empty())require(fs::create_directory(target),"无法建立还原目录");
        }else {
            require(j>0,"根条目必须是目录");
            std::ofstream out;if(destination){out.open(target,std::ios::binary|std::ios::trunc);require(bool(out),"无法创建还原文件："+target.u8string());}
            uint64_t remaining=e.size;
            while(remaining) {
                auto raw=get<uint32_t>(in),stored=get<uint32_t>(in),crc=get<uint32_t>(in);require(raw>0&&raw<=BLOCK&&raw<=remaining&&stored>0&&stored<=BLOCK+1025,"归档数据块长度无效");
                Bytes b(stored);read_bytes(in,b.data(),b.size());Bytes data;
                if(mode)data=decompress(b,raw);else{require(stored==raw,"未压缩块长度错误");data=std::move(b);}
                require(crc32(data)==crc,"文件数据块校验失败");if(destination)write_bytes(out,data.data(),data.size());remaining-=raw;
                require(result.bytes<=UINT64_MAX-raw,"归档总大小溢出");result.bytes+=raw;if(cb)cb({destination?"还原文件":"检查文件",result.files,result.bytes,0});
            }
            if(destination){finish(out);set_metadata(target,e,posix);}regular.insert(key);++result.files;
        }
        first=false;
    }
    require((uint64_t)in.tellg()==fs::file_size(input)-32,"归档含多余或缺失数据");in.close();
    if(destination) {for(auto it=directories.rbegin();it!=directories.rend();++it)set_metadata(staging/it->relative,*it,posix);safe_path(final);require(publish_path(staging,final),"提交还原目录失败，可能已存在同名目录");cleanup.path.clear();result.path=final;}
    if(cb)cb({"完成",result.files,result.bytes,result.bytes});return result;
}
}
Result create(const fs::path& source,const fs::path& archive,const Options& opt,Callback cb) {
    opt.filters.validate();if(!opt.password.empty())require(wide(opt.password).size()>=8,"加密密码至少需要 8 个字符");
    auto src=fs::absolute(source).lexically_normal(),dst=fs::absolute(archive).lexically_normal();safe_path(src);safe_path(dst);
    require(fs::is_directory(src),"源文件夹不存在");require(fs::is_directory(dst.parent_path()),"备份保存文件夹不存在");
    // Resolve existing parents so short (8.3) aliases cannot bypass containment checks.
    src=fs::canonical(src);dst=fs::canonical(dst.parent_path())/dst.filename();
    require(!src.filename().empty()&&src!=src.root_path(),"请选择非磁盘根目录的源文件夹");require(!within(dst,src),"备份保存位置不能位于源目录中");require(!fs::exists(dst),"备份文件已存在，请更换文件名");auto root=src.filename().u8string();validate_relative(root);
    std::vector<Entry> entries;auto rootmeta=metadata(src,{});rootmeta.size=0;entries.push_back(rootmeta);uint64_t total=0;
    if(cb)cb({"扫描目录",0,0,0});
    for(auto& item:fs::recursive_directory_iterator(src)) {
        auto rel=item.path().lexically_relative(src);validate_relative(rel.generic_u8string());auto e=metadata(item.path(),rel);
        if(e.kind){e.size=0;if(e.kind==2)validate_relative(e.link);}
        if(e.directory || opt.filters.matches(rel,e.size,e.time)) {if(e.directory)e.size=0;else{require(total<=UINT64_MAX-e.size,"文件总大小溢出");total+=e.size;}entries.push_back(e);}
        require(entries.size()<=1000000,"文件与目录数量超过首版上限（100万）");
    }
    std::sort(entries.begin()+1,entries.end(),[](const Entry& a,const Entry& b){return folded(a.relative)<folded(b.relative);});
    Cleanup raw{unique_path(dst.parent_path(),L".raw")};exclusive_file(raw.path);std::ofstream out(raw.path,std::ios::binary|std::ios::trunc);require(bool(out),"无法写入备份文件");
#ifdef _WIN32
    constexpr bool posix=false;
#else
    constexpr bool posix=true;
    std::map<std::pair<uint64_t,uint64_t>,std::string> hardlinks;
#endif
    write_bytes(out,posix?MAGIC_POSIX:MAGIC,8);put<uint8_t>(out,opt.compression?1:0);put_string(out,root);put<uint32_t>(out,(uint32_t)entries.size());
    Result result;result.path=dst;result.root=root;result.compression=opt.compression;result.encryption=!opt.password.empty();
    for(auto& e:entries) {
        safe_path(e.kind==2?(src/e.relative).parent_path():src/e.relative);auto now=metadata(src/e.relative,e.relative);require(now.directory==e.directory && now.time==e.time && now.kind==e.kind && now.link==e.link && (e.directory||e.kind||now.size==e.size),"扫描后源文件已变化，请重试："+e.relative.u8string());
#ifndef _WIN32
        if(e.multiple){
            auto [previous,added]=hardlinks.emplace(std::make_pair(e.device,e.inode),e.relative.generic_u8string());
            if(!added){e.kind=4;e.link=previous->second;e.size=0;}
        }
#endif
        put<uint8_t>(out,e.directory?1:e.kind);put_string(out,e.relative.empty()?".":e.relative.generic_u8string());put<uint64_t>(out,e.time);put<uint32_t>(out,e.attributes);put<uint64_t>(out,e.size);
        if(posix){
            put<uint32_t>(out,e.mode);put<uint32_t>(out,e.uid);put<uint32_t>(out,e.gid);
            if(e.kind==2||e.kind==4)put_string(out,e.link);
        }
        if(e.directory){++result.directories;continue;}
        if(e.kind){++result.files;continue;}
        ReadLock input(src/e.relative);now=metadata(src/e.relative,e.relative);require(now.size==e.size&&now.time==e.time,"打开前源文件已变化");uint64_t remaining=e.size;
        while(remaining) {auto n=(uint32_t)std::min<uint64_t>(remaining,BLOCK);auto b=input.read(n);auto stored=opt.compression?compress(b):b;put<uint32_t>(out,n);put<uint32_t>(out,(uint32_t)stored.size());put<uint32_t>(out,crc32(b));write_bytes(out,stored.data(),stored.size());remaining-=n;result.bytes+=n;if(cb)cb({"创建备份",result.files,result.bytes,total});}
        now=metadata(src/e.relative,e.relative);require(now.size==e.size&&now.time==e.time,"读取期间源文件已变化");
        ++result.files;if(cb)cb({"创建备份",result.files,result.bytes,total});
    }
    finish(out);auto hash=digest(raw.path,fs::file_size(raw.path));out.open(raw.path,std::ios::binary|std::ios::app);write_bytes(out,hash.data(),hash.size());finish(out);
    Cleanup sealed;fs::path publish=raw.path;
    if(!opt.password.empty()){if(cb)cb({"加密备份",result.files,result.bytes,total});sealed.path=unique_path(dst.parent_path(),L".sealed");exclusive_file(sealed.path);encrypt_file(raw.path,sealed.path,opt.password);publish=sealed.path;}
    safe_path(dst);require(publish_path(publish,dst),"保存备份失败，请检查权限或同名文件");if(opt.password.empty())raw.path.clear();else sealed.path.clear();result.archive_bytes=fs::file_size(dst);if(cb)cb({"完成",result.files,result.bytes,total});return result;
}
Result restore(const fs::path& a,const fs::path& d,const std::string& p,Callback cb){return read_archive(a,&d,p,cb);}
Result inspect(const fs::path& a,const std::string& p,Callback cb){return read_archive(a,nullptr,p,cb);}
}
