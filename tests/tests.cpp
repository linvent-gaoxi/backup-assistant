#include "backup.hpp"
#include "io.hpp"
#include <iostream>
#include <random>
#include <chrono>
#include <sstream>
#include <cstring>

using namespace backup;
namespace {
void expect(bool b,const std::string& message="assertion failed"){if(!b)throw std::runtime_error(message);}
template<class F>void fails(F f){bool rejected=false;try{f();}catch(const std::exception&){rejected=true;}expect(rejected,"operation should have been rejected");}
void write(const fs::path& p,const Bytes& b){std::ofstream out(p,std::ios::binary);write_bytes(out,b.data(),b.size());finish(out);}
void write(const fs::path& p,const std::string& s){write(p,Bytes(s.begin(),s.end()));}
Bytes read(const fs::path& p){std::ifstream in(p,std::ios::binary);return Bytes(std::istreambuf_iterator<char>(in),{});}
struct Fixture {
    Cleanup clean;fs::path base,source,archive,dest;
    Fixture(){base=unique_path(fs::temp_directory_path(),L".tests");fs::create_directory(base);clean.path=base;source=base/L"示例资料";dest=base/L"还原位置";archive=base/L"备份.sbackup";fs::create_directory(source);fs::create_directory(dest);}
};
Bytes sha(const Bytes& b){BCRYPT_ALG_HANDLE a=nullptr;BCRYPT_HASH_HANDLE h=nullptr;expect(BCryptOpenAlgorithmProvider(&a,BCRYPT_SHA256_ALGORITHM,nullptr,0)>=0);ULONG n=0,got=0;expect(BCryptGetProperty(a,BCRYPT_OBJECT_LENGTH,(PUCHAR)&n,sizeof(n),&got,0)>=0);Bytes object(n),result(32);expect(BCryptCreateHash(a,&h,object.data(),n,nullptr,0,0)>=0);expect(BCryptHashData(h,(PUCHAR)b.data(),(ULONG)b.size(),0)>=0);expect(BCryptFinishHash(h,result.data(),32,0)>=0);BCryptDestroyHash(h);BCryptCloseAlgorithmProvider(a,0);return result;}
void signed_write(const fs::path& p,const std::string& body){Bytes b(body.begin(),body.end());auto s=sha(b);b.insert(b.end(),s.begin(),s.end());write(p,b);}
std::string malformed(const std::string& relative,int mode=0){std::ostringstream out(std::ios::binary);write_bytes(out,"SBKRAW01",8);put<uint8_t>(out,0);put_string(out,"Root");put<uint32_t>(out,mode==3?3:2);auto entry=[&](int type,const std::string& name){put<uint8_t>(out,(uint8_t)type);put_string(out,name);put<uint64_t>(out,133000000000000000ULL);put<uint32_t>(out,0);put<uint64_t>(out,0);};entry(1,".");entry(mode==2?1:0,relative);if(mode==3)entry(1,relative+"/child");return out.str();}
uint64_t mtime(const fs::path& p){WIN32_FILE_ATTRIBUTE_DATA a{};expect(GetFileAttributesExW(p.c_str(),GetFileExInfoStandard,&a));return uint64_t(a.ftLastWriteTime.dwHighDateTime)<<32|a.ftLastWriteTime.dwLowDateTime;}
void change_time(const fs::path& p,uint64_t time){HANDLE h=CreateFileW(p.c_str(),FILE_WRITE_ATTRIBUTES,FILE_SHARE_READ,nullptr,OPEN_EXISTING,fs::is_directory(p)?FILE_FLAG_BACKUP_SEMANTICS:0,nullptr);expect(h!=INVALID_HANDLE_VALUE);FILETIME t{DWORD(time),DWORD(time>>32)};BOOL ok=SetFileTime(h,nullptr,nullptr,&t);CloseHandle(h);expect(ok);}
}
int wmain(){SetConsoleOutputCP(CP_UTF8);int passed=0,failed=0,skipped=0;auto test=[&](const char* name,auto f){try{f();++passed;std::cout<<"PASS "<<name<<"\n";}catch(const std::exception& e){++failed;std::cout<<"FAIL "<<name<<": "<<e.what()<<"\n";}};
    test("CRC32 standard vector",[]{expect(crc32(Bytes{'1','2','3','4','5','6','7','8','9'})==0xcbf43926u);});
    test("Huffman empty input",[]{Bytes b;expect(decompress(compress(b),0)==b);});
    test("Huffman one symbol",[]{Bytes b(100000,'A');expect(compress(b).size()<b.size());expect(decompress(compress(b),(uint32_t)b.size())==b);});
    test("Huffman all byte values",[]{Bytes b;for(int i=0;i<256;++i)b.push_back((unsigned char)i);expect(decompress(compress(b),256)==b);});
    test("Huffman random raw fallback",[]{std::mt19937 g(42);Bytes b(100000);for(auto& c:b)c=(unsigned char)g();auto c=compress(b);expect(c[0]==0);expect(decompress(c,(uint32_t)b.size())==b);});
    test("Huffman skewed distribution",[]{Bytes b(200000,'x');for(size_t i=0;i<b.size();i+=13)b[i]=(unsigned char)(i%256);expect(decompress(compress(b),(uint32_t)b.size())==b);});
    test("Huffman rejects truncation",[]{auto c=compress(Bytes(50000,'a'));c.pop_back();fails([&]{decompress(c,50000);});});
    test("Huffman rejects invalid mode",[]{fails([]{decompress(Bytes{5},1);});});
    test("Huffman rejects invalid frequency",[]{auto c=compress(Bytes(50000,'a'));c[1]^=1;fails([&]{decompress(c,50000);});});
    test("Size and date validation",[]{expect(parse_size("1024")==1024);fails([]{parse_size("-1");});fails([]{parse_size("1MB");});fails([]{parse_size("18446744073709551616");});fails([]{date_boundary("2026-02-30",false);});expect(date_boundary("2024-02-29",false)<date_boundary("2024-02-29",true));});
    test("Filter filename wildcard",[]{Filters f;f.name="报告?.TXT";expect(f.matches(fs::path(L"报告一.txt"),10,0));expect(!f.matches(fs::path(L"报告十二.txt"),10,0));});
    test("Filter relative path",[]{Filters f;f.path="docs/*.txt";expect(f.matches(fs::path(L"docs/a.txt"),0,0));expect(!f.matches(fs::path(L"other/a.txt"),0,0));});
    test("Filter multiple extensions",[]{Filters f;f.extensions="txt;pdf，docx";expect(f.matches(fs::path(L"a.PDF"),0,0));expect(f.matches(fs::path(L"a.docx"),0,0));expect(!f.matches(fs::path(L"a.png"),0,0));});
    test("Filter size boundaries",[]{Filters f;f.min_size=3;f.max_size=5;expect(f.matches(fs::path(L"a"),3,0)&&f.matches(fs::path(L"a"),5,0));expect(!f.matches(fs::path(L"a"),6,0));});
    test("Filter date boundaries",[]{Filters f;f.after=10;f.before=20;expect(f.matches(fs::path(L"a"),0,10));expect(f.matches(fs::path(L"a"),0,20));expect(!f.matches(fs::path(L"a"),0,21));});
    test("Filter combined AND and invalid ranges",[]{Filters f;f.name="a*";f.extensions="txt";f.min_size=2;expect(f.matches(fs::path(L"abc.txt"),2,0));expect(!f.matches(fs::path(L"abc.pdf"),2,0));f.max_size=1;fails([&]{f.validate();});});
    test("Unicode tree empty file and empty directory",[]{Fixture x;fs::create_directories(x.source/L"中文目录"/L"空目录");write(x.source/L"中文目录"/L"说明.txt",std::string("UTF-8 测试\n"));write(x.source/L"空文件",Bytes{});auto r=create(x.source,x.archive);expect(r.files==2);auto q=restore(x.archive,x.dest);expect(q.files==2&&q.directories==3);expect(read(q.path/L"中文目录"/L"说明.txt")==read(x.source/L"中文目录"/L"说明.txt"));expect(fs::is_directory(q.path/L"中文目录"/L"空目录"));expect(fs::file_size(q.path/L"空文件")==0);});
    test("Cross-block binary exact round trip",[]{Fixture x;std::mt19937 g(10);Bytes b(BLOCK*2+513);for(auto& c:b)c=(unsigned char)g();write(x.source/L"binary.bin",b);create(x.source,x.archive);auto r=restore(x.archive,x.dest);expect(read(r.path/L"binary.bin")==b);});
    test("Uncompressed archive round trip",[]{Fixture x;write(x.source/L"a",std::string("abc"));Options o;o.compression=false;create(x.source,x.archive,o);auto r=restore(x.archive,x.dest);expect(!r.compression&&read(r.path/L"a")==Bytes({'a','b','c'}));});
    test("Empty source directory",[]{Fixture x;auto r=create(x.source,x.archive);expect(r.files==0);expect(restore(x.archive,x.dest).directories==1);});
    test("Five filters integrated",[]{Fixture x;fs::create_directory(x.source/L"docs");write(x.source/L"docs"/L"keep.txt",std::string("hello"));write(x.source/L"docs"/L"drop.pdf",std::string("hello"));Options o;o.filters.path="docs/*";o.filters.name="keep*";o.filters.extensions="txt";o.filters.min_size=5;o.filters.max_size=5;o.filters.after=mtime(x.source/L"docs"/L"keep.txt");o.filters.before=o.filters.after;expect(create(x.source,x.archive,o).files==1);auto r=restore(x.archive,x.dest);expect(fs::exists(r.path/L"docs"/L"keep.txt"));expect(!fs::exists(r.path/L"docs"/L"drop.pdf"));});
    test("Preserve file directory and root timestamps",[]{Fixture x;fs::create_directory(x.source/L"sub");write(x.source/L"sub"/L"a",std::string("a"));auto t=date_boundary("2025-05-06",false);change_time(x.source/L"sub"/L"a",t);change_time(x.source/L"sub",t+10000000);change_time(x.source,t+20000000);create(x.source,x.archive);auto r=restore(x.archive,x.dest);expect(mtime(r.path/L"sub"/L"a")==t);expect(mtime(r.path/L"sub")==t+10000000);expect(mtime(r.path)==t+20000000);});
    test("Preserve read-only attribute",[]{Fixture x;write(x.source/L"a",std::string("abc"));expect(SetFileAttributesW((x.source/L"a").c_str(),FILE_ATTRIBUTE_READONLY));create(x.source,x.archive);auto r=restore(x.archive,x.dest);expect(GetFileAttributesW((r.path/L"a").c_str())&FILE_ATTRIBUTE_READONLY);});
    test("Reject archive inside source",[]{Fixture x;fails([&]{create(x.source,x.source/L"bad.sbackup");});});
    test("Reject existing archive without replacing",[]{Fixture x;write(x.archive,std::string("keep"));fails([&]{create(x.source,x.archive);});expect(read(x.archive)==Bytes({'k','e','e','p'}));});
    test("Reject existing restore directory",[]{Fixture x;write(x.source/L"a",std::string("abc"));create(x.source,x.archive);fs::create_directory(x.dest/x.source.filename());fails([&]{restore(x.archive,x.dest);});expect(fs::is_empty(x.dest/x.source.filename()));});
    test("Reject missing source and destination",[]{Fixture x;fails([&]{create(x.base/L"missing",x.archive);});create(x.source,x.archive);fails([&]{restore(x.archive,x.base/L"missing");});});
    test("Encrypted multi-block correct password",[]{Fixture x;std::mt19937 g(44);Bytes b(BLOCK+71);for(auto& c:b)c=(unsigned char)g();write(x.source/L"a",b);Options o;o.password="课程密码123456";create(x.source,x.archive,o);expect(encrypted(x.archive));auto r=restore(x.archive,x.dest,o.password);expect(r.encryption&&read(r.path/L"a")==b);});
    test("Encrypted wrong and missing password leave no output",[]{Fixture x;write(x.source/L"a",std::string("secret"));Options o;o.password="correct-pass";create(x.source,x.archive,o);fails([&]{restore(x.archive,x.dest,"wrong-pass");});fails([&]{restore(x.archive,x.dest);});expect(fs::is_empty(x.dest));});
    test("Reject short encryption password",[]{Fixture x;Options o;o.password="short";fails([&]{create(x.source,x.archive,o);});expect(!fs::exists(x.archive));});
    test("Encryption randomized for same input",[]{Fixture x;Options o;o.password="12345678";create(x.source,x.archive,o);auto second=x.base/L"second.sbackup";create(x.source,second,o);expect(read(x.archive)!=read(second));});
    test("Encrypted tampering rejected",[]{Fixture x;Options o;o.password="12345678";create(x.source,x.archive,o);auto b=read(x.archive);b[40]^=0x40;write(x.archive,b);fails([&]{restore(x.archive,x.dest,o.password);});expect(fs::is_empty(x.dest));});
    test("Encrypted terminal record truncation rejected",[]{Fixture x;Options o;o.password="12345678";create(x.source,x.archive,o);auto b=read(x.archive);b.resize(b.size()-20);write(x.archive,b);fails([&]{inspect(x.archive,o.password);});});
    test("Encrypted appended data rejected",[]{Fixture x;Options o;o.password="12345678";create(x.source,x.archive,o);auto b=read(x.archive);b.push_back(0);write(x.archive,b);fails([&]{inspect(x.archive,o.password);});});
    test("Inspect validates contents without restore output",[]{Fixture x;write(x.source/L"a",std::string("data"));create(x.source,x.archive);auto r=inspect(x.archive);expect(r.files==1&&r.bytes==4&&fs::is_empty(x.dest));});
    test("Raw checksum rejects data and metadata tampering",[]{Fixture x;write(x.source/L"a",std::string("data"));create(x.source,x.archive);auto b=read(x.archive);b[15]^=1;write(x.archive,b);fails([&]{restore(x.archive,x.dest);});expect(fs::is_empty(x.dest));});
    test("Reject truncated archive",[]{Fixture x;create(x.source,x.archive);auto b=read(x.archive);b.resize(12);write(x.archive,b);fails([&]{inspect(x.archive);});});
    test("Reject path traversal after valid checksum",[]{Fixture x;signed_write(x.archive,malformed("../escape"));fails([&]{restore(x.archive,x.dest);});expect(fs::is_empty(x.dest));expect(!fs::exists(x.base/L"escape"));});
    test("Reject absolute path and alternate stream",[]{Fixture x;for(auto s:{"C:/escape","/escape","a:stream","CON.txt","a./x","a//b"}){signed_write(x.archive,malformed(s));fails([&]{inspect(x.archive);});}});
    test("Reject duplicate root entry",[]{Fixture x;signed_write(x.archive,malformed(".",2));fails([&]{restore(x.archive,x.dest);});expect(fs::is_empty(x.dest));});
    test("Reject file directory conflict",[]{Fixture x;signed_write(x.archive,malformed("a",3));fails([&]{inspect(x.archive);});fails([&]{restore(x.archive,x.dest);});expect(fs::is_empty(x.dest));});
    test("Reject trailing plaintext data with valid checksum",[]{Fixture x;signed_write(x.archive,malformed("a")+"extra");fails([&]{restore(x.archive,x.dest);});expect(fs::is_empty(x.dest));});
    test("Reject locked source file and remove temporary files",[]{Fixture x;write(x.source/L"a",std::string("data"));HANDLE h=CreateFileW((x.source/L"a").c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,OPEN_EXISTING,0,nullptr);expect(h!=INVALID_HANDLE_VALUE);fails([&]{create(x.source,x.archive);});CloseHandle(h);expect(!fs::exists(x.archive));for(auto& e:fs::directory_iterator(x.base))expect(e.path().filename().wstring().find(L".sbackup-")!=0);});
    test("Progress callback records file count and completion",[]{Fixture x;write(x.source/L"a",Bytes(BLOCK+10,'x'));uint64_t bytes=0;bool completed=false;create(x.source,x.archive,{},[&](const Progress& p){expect(p.bytes>=bytes);bytes=p.bytes;if(p.phase=="完成"){completed=true;expect(p.files==1);}});expect(completed&&bytes==BLOCK+10);});
    {
        Fixture x;fs::path link=x.source/L"link";BOOL ok=CreateSymbolicLinkW(link.c_str(),x.dest.c_str(),SYMBOLIC_LINK_FLAG_DIRECTORY|2);
        if(ok){test("Reject source symbolic link",[&]{fails([&]{create(x.source,x.archive);});});fs::remove(link);}else{++skipped;std::cout<<"SKIP symbolic link creation unavailable (Windows privilege/developer mode)\n";}
    }
    test("Performance repetitive 16MiB",[]{Fixture x;Bytes b(16*BLOCK,'A');write(x.source/L"large.txt",b);auto start=std::chrono::steady_clock::now();auto r=create(x.source,x.archive);auto middle=std::chrono::steady_clock::now();auto q=restore(x.archive,x.dest);auto end=std::chrono::steady_clock::now();expect(read(q.path/L"large.txt")==b);std::cout<<"  METRIC large bytes="<<r.bytes<<" archive="<<r.archive_bytes<<" backup_ms="<<std::chrono::duration_cast<std::chrono::milliseconds>(middle-start).count()<<" restore_ms="<<std::chrono::duration_cast<std::chrono::milliseconds>(end-middle).count()<<"\n";});
    test("Performance 1000 small files",[]{Fixture x;for(int i=0;i<1000;++i)write(x.source/(std::to_wstring(i)+L".txt"),std::string(128,'a'));auto start=std::chrono::steady_clock::now();auto r=create(x.source,x.archive);auto middle=std::chrono::steady_clock::now();auto q=restore(x.archive,x.dest);auto end=std::chrono::steady_clock::now();expect(q.files==1000);for(int i=0;i<1000;++i)expect(read(q.path/(std::to_wstring(i)+L".txt"))==Bytes(128,'a'));std::cout<<"  METRIC small files="<<q.files<<" bytes="<<r.bytes<<" archive="<<r.archive_bytes<<" backup_ms="<<std::chrono::duration_cast<std::chrono::milliseconds>(middle-start).count()<<" restore_ms="<<std::chrono::duration_cast<std::chrono::milliseconds>(end-middle).count()<<"\n";});
    std::cout<<"RESULT passed="<<passed<<" failed="<<failed<<" skipped="<<skipped<<"\n";return failed?1:0;
}
