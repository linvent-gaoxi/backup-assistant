#include "backup.hpp"
#include <iostream>
#include <map>
#include <set>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <termios.h>
#include <unistd.h>
#include <clocale>
#endif

using namespace backup;
#ifdef _WIN32
int wmain(int argc,wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);SetConsoleCP(CP_UTF8);
#else
int main(int argc,char** native_args) {
    std::setlocale(LC_ALL,"C.UTF-8");
    std::vector<std::wstring> arguments;
    std::vector<const wchar_t*> pointers;
    try {
        for(int i=0;i<argc;++i)arguments.push_back(wide(native_args[i]));
    }catch(...){std::cerr<<"命令行参数必须为 UTF-8\n";return 1;}
    for(const auto& argument:arguments)pointers.push_back(argument.c_str());
    auto argv=pointers.data();
#endif
    try {
        if(argc<2 || std::wstring(argv[1])==L"--help") {
            std::cout<<"文件备份助手 C++ 1.0\n"
            "backup_cli backup --source <目录> --output <文件.sbackup> [筛选选项] [--no-compress] [--password-stdin]\n"
            "backup_cli restore --archive <文件> --destination <已有目录> [--password-stdin]\n"
            "backup_cli inspect --archive <文件> [--password-stdin]\n"
            "筛选选项：--name <通配符> --path <相对路径通配符> --extensions <txt,pdf>\n"
            "          --min-size <字节> --max-size <字节> --after <YYYY-MM-DD> --before <YYYY-MM-DD>\n"
            "密码通过标准输入读取一行，不接受命令行明文密码。交互式输入隐藏回显。\n";return argc<2?2:0;
        }
        std::string command=utf8(argv[1]);require(command=="backup"||command=="restore"||command=="inspect","未知操作，请使用 --help");
        std::map<std::string,std::wstring> args;std::set<std::string> allowed={"--archive","--destination","--password-stdin"};
        if(command=="backup")allowed={"--source","--output","--name","--path","--extensions","--min-size","--max-size","--after","--before","--no-compress","--password-stdin"};
        if(command=="inspect")allowed={"--archive","--password-stdin"};
        for(int i=2;i<argc;++i) {std::string key=utf8(argv[i]);require(allowed.count(key)>0,"未知或不适用的选项："+key);require(args.count(key)==0,"重复选项："+key);if(key=="--no-compress"||key=="--password-stdin")args[key]=L"1";else{require(i+1<argc,"选项缺少参数："+key);args[key]=argv[++i];}}
        auto need=[&](const std::string& k){require(args.count(k)&&!args[k].empty(),"缺少参数："+k);return fs::u8path(utf8(args[k]));};
        std::string password;
        if(args.count("--password-stdin")) {
#ifdef _WIN32
            HANDLE input=GetStdHandle(STD_INPUT_HANDLE);DWORD mode=0;bool console=GetConsoleMode(input,&mode);
            if(console){std::cerr<<"请输入密码：";SetConsoleMode(input,mode&~ENABLE_ECHO_INPUT);wchar_t buf[1024];DWORD got=0;BOOL ok=ReadConsoleW(input,buf,1023,&got,nullptr);SetConsoleMode(input,mode);std::cerr<<"\n";require(ok,"读取密码失败");std::wstring s(buf,got);while(!s.empty()&&(s.back()==L'\r'||s.back()==L'\n'))s.pop_back();password=utf8(s);SecureZeroMemory(buf,sizeof(buf));}
            else require(bool(std::getline(std::cin,password)),"标准输入没有提供密码");
#else
            termios original{};
            const bool terminal=tcgetattr(STDIN_FILENO,&original)==0;
            if(terminal){
                termios hidden=original;hidden.c_lflag&=~ECHO;
                std::cerr<<"请输入密码：";
                require(tcsetattr(STDIN_FILENO,TCSANOW,&hidden)==0,"无法关闭密码回显");
            }
            const bool ok=bool(std::getline(std::cin,password));
            if(terminal){tcsetattr(STDIN_FILENO,TCSANOW,&original);std::cerr<<"\n";}
            require(ok,"标准输入没有提供密码");
#endif
            require(!password.empty(),"密码不能为空");
        }
        Result r;
        if(command=="backup") {Options o;o.password=password;o.compression=!args.count("--no-compress");o.filters.name=utf8(args["--name"]);o.filters.path=utf8(args["--path"]);o.filters.extensions=utf8(args["--extensions"]);
            if(args.count("--min-size"))o.filters.min_size=parse_size(utf8(args["--min-size"]));if(args.count("--max-size"))o.filters.max_size=parse_size(utf8(args["--max-size"]));if(args.count("--after"))o.filters.after=date_boundary(utf8(args["--after"]),false);if(args.count("--before"))o.filters.before=date_boundary(utf8(args["--before"]),true);
            r=create(need("--source"),need("--output"),o);
        } else if(command=="restore")r=restore(need("--archive"),need("--destination"),password);else r=inspect(need("--archive"),password);
#ifdef _WIN32
        if(!password.empty())SecureZeroMemory(&password[0],password.size());
#endif
        std::cout<<"成功\n位置："<<r.path.u8string()<<"\n原目录："<<r.root<<"\n文件数："<<r.files<<"\n目录数（含根）："<<r.directories<<"\n原始字节："<<r.bytes<<"\n备份字节："<<r.archive_bytes<<"\nHuffman："<<(r.compression?"是":"否")<<"\nAES-256-GCM："<<(r.encryption?"是":"否")<<"\n";return 0;
    }catch(const std::exception& e){std::cerr<<"失败："<<e.what()<<"\n";return 1;}
}
