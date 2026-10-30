#include "backup.hpp"
#include <algorithm>
#include <ctime>
#include <codecvt>
#include <locale>
#include <array>
#include <queue>
#include <sstream>
#include <cwctype>
#include <cmath>
#include <iomanip>

namespace backup {
void require(bool ok, const std::string& msg) { if (!ok) throw Error(msg); }
#ifdef _WIN32
std::string utf8(const std::wstring& s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    require(n > 0, "无效的 Unicode 文本");
    std::string r(n, 0); WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), (int)s.size(), &r[0], n, nullptr, nullptr); return r;
}
std::wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0);
    require(n > 0, "无效的 UTF-8 文本");
    std::wstring r(n, 0); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), &r[0], n); return r;
}
#else
std::string utf8(const std::wstring& s) {
    return std::wstring_convert<std::codecvt_utf8<wchar_t>>{}.to_bytes(s);
}
std::wstring wide(const std::string& s) {
    return std::wstring_convert<std::codecvt_utf8<wchar_t>>{}.from_bytes(s);
}
#endif
uint32_t crc32(const Bytes& b) {
    static const auto table = [] { std::array<uint32_t, 256> a{}; for (uint32_t i=0;i<256;++i) { uint32_t c=i; for(int j=0;j<8;++j)c=(c>>1)^((c&1)?0xedb88320u:0); a[i]=c; } return a; }();
    uint32_t c=~0u; for (auto v:b)c=(c>>8)^table[(c^v)&255]; return ~c;
}
namespace {
struct Node { uint64_t frequency; int left=-1, right=-1, symbol=-1; };
struct Tree {
    std::vector<Node> nodes;
    int root;
    explicit Tree(const std::array<uint32_t,256>& f) {
        auto cmp=[this](int a,int b){ if(nodes[a].frequency!=nodes[b].frequency)return nodes[a].frequency>nodes[b].frequency; return a>b; };
        std::priority_queue<int,std::vector<int>,decltype(cmp)> q(cmp);
        for(int i=0;i<256;++i)if(f[i]) { nodes.push_back({f[i],-1,-1,i}); q.push((int)nodes.size()-1); }
        require(!q.empty(), "Huffman 频率表为空");
        while(q.size()>1) { int a=q.top();q.pop();int b=q.top();q.pop();nodes.push_back({nodes[a].frequency+nodes[b].frequency,a,b,-1});q.push((int)nodes.size()-1); }
        root=q.top();
    }
};
void codes(const Tree& t,int n,std::vector<bool>& p,std::array<std::vector<bool>,256>& out) {
    if(t.nodes[n].symbol>=0) { out[t.nodes[n].symbol]=p;return; }
    p.push_back(false); codes(t,t.nodes[n].left,p,out);p.back()=true;codes(t,t.nodes[n].right,p,out);p.pop_back();
}
bool wildcard(const std::wstring& pat,const std::wstring& s) {
    size_t p=0,i=0,star=std::wstring::npos,last=0;
    while(i<s.size()) {
        if(p<pat.size() && (pat[p]==L'?' || towlower(pat[p])==towlower(s[i]))) {++p;++i;}
        else if(p<pat.size() && pat[p]==L'*') {star=p++;last=i;}
        else if(star!=std::wstring::npos) {p=star+1;i=++last;}
        else return false;
    }
    while(p<pat.size() && pat[p]==L'*')++p; return p==pat.size();
}
}
Bytes compress(const Bytes& b) {
    Bytes raw(1,0);raw.insert(raw.end(),b.begin(),b.end());if(b.empty())return raw;
    std::array<uint32_t,256> f{};for(auto v:b)++f[v];Tree t(f);
    std::array<std::vector<bool>,256> c;std::vector<bool> p;codes(t,t.root,p,c);
    Bytes out(1,1);for(auto v:f)for(int i=0;i<4;++i)out.push_back((v>>(8*i))&255);
    unsigned char v=0;int used=0;
    for(auto ch:b)for(bool bit:c[ch]) { v|=(bit?1:0)<<(7-used);if(++used==8){out.push_back(v);v=0;used=0;} }
    if(used)out.push_back(v); return out.size()<raw.size()?out:raw;
}
Bytes decompress(const Bytes& b,uint32_t expected) {
    require(expected<=1024*1024 && !b.empty(),"压缩块长度无效");
    if(b[0]==0) { require(b.size()==size_t(expected)+1,"原始块长度错误");return Bytes(b.begin()+1,b.end()); }
    require(b[0]==1 && b.size()>=1025,"Huffman 块损坏");
    std::array<uint32_t,256> f{};uint64_t sum=0;
    for(int j=0;j<256;++j) {for(int i=0;i<4;++i)f[j]|=uint32_t(b[1+j*4+i])<<(8*i);sum+=f[j];}
    require(sum==expected && expected>0,"Huffman 频率与长度不符");Tree t(f);Bytes out;out.reserve(expected);uint64_t bit=0;
    for(uint32_t j=0;j<expected;++j) {
        int n=t.root;
        while(t.nodes[n].symbol<0) {require(1025+bit/8<b.size(),"Huffman 数据截断");bool one=(b[1025+bit/8]>>(7-bit%8))&1;++bit;n=one?t.nodes[n].right:t.nodes[n].left;}
        auto ch=(unsigned char)t.nodes[n].symbol;require(f[ch]>0,"Huffman 频率错误");--f[ch];out.push_back(ch);
    }
    require(b.size()==1025+(bit+7)/8,"Huffman 块包含多余数据");
    if(bit%8)require((b.back()&((1u<<(8-bit%8))-1))==0,"Huffman 填充位错误");return out;
}
uint64_t parse_size(const std::string& s) {
    require(!s.empty() && s[0]!='-',"大小必须为非负整数（字节）");size_t n=0;
    try {auto v=std::stoull(s,&n);require(n==s.size() && s.find_first_not_of("0123456789")==std::string::npos,"大小必须为非负整数（字节）");return v;}catch(const Error&){throw;}catch(...){throw Error("大小超出范围");}
}
uint64_t date_boundary(const std::string& s,bool end) {
    require(s.size()==10 && s[4]=='-' && s[7]=='-',"日期格式应为 YYYY-MM-DD");
    for(size_t i=0;i<s.size();++i)if(i!=4 && i!=7)require(s[i]>='0' && s[i]<='9',"日期包含无效字符");
#ifdef _WIN32
    SYSTEMTIME st{};st.wYear=(WORD)std::stoi(s.substr(0,4));st.wMonth=(WORD)std::stoi(s.substr(5,2));st.wDay=(WORD)std::stoi(s.substr(8,2));
    require(st.wYear>=1601 && st.wMonth>=1 && st.wMonth<=12 && st.wDay>=1 && st.wDay<=31,"日期无效");
    if(end){st.wHour=23;st.wMinute=59;st.wSecond=59;st.wMilliseconds=999;}
    SYSTEMTIME utc{};FILETIME ft{};require(TzSpecificLocalTimeToSystemTime(nullptr,&st,&utc) && SystemTimeToFileTime(&utc,&ft),"日期无效");
    SYSTEMTIME round{};require(SystemTimeToTzSpecificLocalTime(nullptr,&utc,&round) && round.wMonth==st.wMonth && round.wDay==st.wDay,"日期无效");
    return (uint64_t(ft.dwHighDateTime)<<32)|ft.dwLowDateTime;
#else
    std::tm local{};
    local.tm_year=std::stoi(s.substr(0,4))-1900;
    local.tm_mon=std::stoi(s.substr(5,2))-1;
    local.tm_mday=std::stoi(s.substr(8,2));
    local.tm_hour=end?23:0;local.tm_min=end?59:0;local.tm_sec=end?59:0;
    local.tm_isdst=-1;
    const auto requested=local;
    auto seconds=mktime(&local);
    require(local.tm_year==requested.tm_year&&local.tm_mon==requested.tm_mon&&local.tm_mday==requested.tm_mday&&seconds>=-11644473600LL,"日期无效");
    return (seconds+11644473600LL)*10000000ULL+(end?9999999:0);
#endif
}
void Filters::validate() const {require(min_size<=max_size,"最小大小不能超过最大大小");require(after<=before,"开始日期不能晚于结束日期");wide(name);wide(path);wide(extensions);}
bool Filters::matches(const fs::path& rel,uint64_t size,uint64_t time)const {
    if(size<min_size || size>max_size || time<after || time>before)return false;
    if(!name.empty() && !wildcard(wide(name),wide(rel.filename().u8string())))return false;
    std::string pathpat=path;std::replace(pathpat.begin(),pathpat.end(),'\\','/');
    if(!path.empty() && !wildcard(wide(pathpat),wide(rel.generic_u8string())))return false;
    if(!extensions.empty()) {
        std::wstring ext=wide(rel.extension().u8string()),list=wide(extensions);for(auto& c:list)if(c==L';'||c==L'，'||c==L'、'||iswspace(c))c=L',';
        std::wstringstream in(list);std::wstring item;bool found=false,has=false;
        while(std::getline(in,item,L','))if(!item.empty()) {has=true;if(item[0]!=L'.' && item!=L"*")item=L"."+item;if(wildcard(item,ext))found=true;}
        if(has && !found)return false;
    }
    return true;
}
void safe_path(const fs::path& p) {
    auto a=fs::absolute(p).lexically_normal();fs::path cur;
#ifdef _WIN32
    for(auto& part:a) {cur/=part;DWORD attr=GetFileAttributesW(cur.c_str());if(attr!=INVALID_FILE_ATTRIBUTES)require(!(attr&FILE_ATTRIBUTE_REPARSE_POINT),"路径包含链接或重解析点："+cur.u8string());}
#else
    for(auto& part:a){
        cur/=part;
        require(!fs::is_symlink(fs::symlink_status(cur)),"路径包含符号链接："+cur.u8string());
    }
#endif
}
void validate_relative(const std::string& s) {
    require(!s.empty() && s.size()<=32760 && s.front()!='/' && s.back()!='/' && s.find('\\')==std::string::npos,"归档相对路径无效");
    wide(s);std::istringstream in(s);std::string part;
    while(std::getline(in,part,'/')) {
        require(!part.empty() && part!="." && part!=".." && part.back()!='.' && part.back()!=' ',"归档路径含非法分量");
        for(unsigned char c:part)require(c>=32 && std::string(":<>\"|?*").find(c)==std::string::npos,"归档路径含非法字符");
        auto base=part.substr(0,part.find('.'));for(auto& c:base)c=(char)toupper((unsigned char)c);
        require(base!="CON" && base!="PRN" && base!="AUX" && base!="NUL" && !(base.size()==4 && (base.substr(0,3)=="COM"||base.substr(0,3)=="LPT") && base[3]>='0' && base[3]<='9'),"归档路径含 Windows 保留名称");
    }
}
}
