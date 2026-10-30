#include "backup.hpp"
#include <commctrl.h>
#include <commdlg.h>
#include <shobjidl.h>
#include <thread>
#include <mutex>
#include <atomic>
#include <sstream>
#include <iomanip>
#ifdef _MSC_VER
#pragma comment(linker,"\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")
#endif

using namespace backup;
namespace {
enum {TOGGLE_FILTERS=21,COPY_STATUS=20,NAV_BACKUP=10,NAV_RESTORE,NAV_ABOUT,SOURCE=101,OUTPUT,SOURCE_PICK,OUTPUT_PICK,NAME,PATH_PATTERN,EXTENSIONS,MIN_SIZE,MAX_SIZE,AFTER,BEFORE,COMPRESS,PASSWORD,CONFIRM,START,ARCHIVE=201,DESTINATION,ARCHIVE_PICK,DESTINATION_PICK,RESTORE_PASSWORD,RESTORE_START,INSPECT_START};
HWND main_window,status_text,progress_bar,heading;
int dpi=96;
int px(int value){return MulDiv(value,dpi,96);}
HFONT normal_font,title_font;
std::vector<HWND> pages[3];std::vector<HWND> inputs;
int current_page=0;
bool filters_open=false;
std::vector<HWND> filter_fields;
HWND filter_hint;
constexpr COLORREF surface=RGB(255,255,255), canvas=RGB(244,247,251);
constexpr COLORREF ink=RGB(25,42,62), muted=RGB(79,99,121), blue=RGB(38,89,199);
HBRUSH surface_brush,canvas_brush;

std::thread worker;std::mutex mutex_;std::atomic<bool> running{false};bool done=false;std::wstring latest;
std::wstring text(HWND h){int n=GetWindowTextLengthW(h);std::wstring s(n+1,0);GetWindowTextW(h,&s[0],n+1);s.resize(n);return s;}
std::wstring field(int id){return text(GetDlgItem(main_window,id));}
HWND control(int page,const wchar_t* cls,const wchar_t* label,DWORD style,int x,int y,int w,int h,int id=0){HWND c=CreateWindowExW((std::wstring(cls)==L"EDIT")?WS_EX_CLIENTEDGE:0,cls,label,WS_CHILD|WS_VISIBLE|style,px(x),px(y),px(w),px(h),main_window,(HMENU)(INT_PTR)id,GetModuleHandleW(nullptr),nullptr);SendMessageW(c,WM_SETFONT,(WPARAM)normal_font,TRUE);if(page>=0)pages[page].push_back(c);if(id>=100)inputs.push_back(c);return c;}
void label(int page,const wchar_t* s,int x,int y,int w=700){control(page,L"STATIC",s,SS_CENTERIMAGE,x,y,w,22);}
void edit(int page,int id,int x,int y,int w,bool password=false){control(page,L"EDIT",L"",WS_TABSTOP|ES_AUTOHSCROLL|(password?ES_PASSWORD:0),x,y,w,30,id);}
HWND button(int page,const wchar_t* caption,int id,int x,int y,int w,int h=34){
    return control(page,L"BUTTON",caption,WS_TABSTOP|BS_OWNERDRAW,x,y,w,h,id);
}
void row(int page,const wchar_t* caption,int id,int pick,int y){
    label(page,caption,205,y,630);
    edit(page,id,205,y+24,555);
    button(page,L"浏览…",pick,772,y+22,86);
}
void show_page(int p){
    current_page=p;
    const int filter_ids[]={NAME,PATH_PATTERN,EXTENSIONS,MIN_SIZE,MAX_SIZE,AFTER,BEFORE};
    const bool has_filters=std::any_of(std::begin(filter_ids),std::end(filter_ids),[](int id){return !field(id).empty();});
    SetWindowTextW(filter_hint,has_filters?L"已设置筛选条件":L"未设置筛选，备份全部文件");
    SetDlgItemTextW(main_window,TOGGLE_FILTERS,filters_open?L"收起筛选条件":L"展开筛选条件");
    for(int i=0;i<3;++i)for(auto h:pages[i])ShowWindow(h,i==p?SW_SHOW:SW_HIDE);
    for(auto h:filter_fields)ShowWindow(h,p==0&&filters_open?SW_SHOW:SW_HIDE);
    ShowWindow(filter_hint,p==0&&!filters_open?SW_SHOW:SW_HIDE);
    SetWindowTextW(heading,p==0?L"创建备份":p==1?L"还原与检查":L"使用说明");
    for(int id=NAV_BACKUP;id<=NAV_ABOUT;++id)InvalidateRect(GetDlgItem(main_window,id),nullptr,TRUE);
}
void draw_button(const DRAWITEMSTRUCT& item){
    const int id=static_cast<int>(item.CtlID);
    const bool nav=id>=NAV_BACKUP&&id<=NAV_ABOUT;
    const bool selected=nav&&id==NAV_BACKUP+current_page;
    const bool primary=id==START||id==RESTORE_START;
    const bool disabled=(item.itemState&ODS_DISABLED)!=0;
    const bool pressed=(item.itemState&ODS_SELECTED)!=0;
    COLORREF background=nav?canvas:surface;
    FillRect(item.hDC,&item.rcItem,nav?canvas_brush:surface_brush);
    COLORREF fill=disabled?RGB(237,241,246):primary?(pressed?RGB(28,69,160):blue):
        selected||pressed?RGB(229,237,254):background;
    COLORREF border=nav?fill:primary&&!disabled?fill:RGB(213,223,235);
    auto brush=CreateSolidBrush(fill);
    auto pen=CreatePen(PS_SOLID,1,border);
    auto old_brush=SelectObject(item.hDC,brush);
    auto old_pen=SelectObject(item.hDC,pen);
    const auto& r=item.rcItem;
    RoundRect(item.hDC,r.left,r.top,r.right,r.bottom,px(9),px(9));
    SelectObject(item.hDC,old_brush);SelectObject(item.hDC,old_pen);
    DeleteObject(brush);DeleteObject(pen);
    auto old_font=SelectObject(item.hDC,normal_font);
    SetBkMode(item.hDC,TRANSPARENT);
    SetTextColor(item.hDC,disabled?muted:primary?surface:selected?blue:ink);
    RECT caption_rect=r;
    auto caption=text(item.hwndItem);
    DrawTextW(item.hDC,caption.c_str(),-1,&caption_rect,DT_CENTER|DT_VCENTER|DT_SINGLELINE);
    SelectObject(item.hDC,old_font);
    if(item.itemState&ODS_FOCUS){
        RECT focus=r;InflateRect(&focus,-px(4),-px(4));DrawFocusRect(item.hDC,&focus);
    }
}
std::wstring folder(){IFileDialog* dialog=nullptr;std::wstring result;if(SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&dialog)))){DWORD flags=0;dialog->GetOptions(&flags);dialog->SetOptions(flags|FOS_PICKFOLDERS|FOS_FORCEFILESYSTEM|FOS_PATHMUSTEXIST);if(SUCCEEDED(dialog->Show(main_window))){IShellItem* item=nullptr;if(SUCCEEDED(dialog->GetResult(&item))){PWSTR p=nullptr;if(SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH,&p))){result=p;CoTaskMemFree(p);}item->Release();}}dialog->Release();}return result;}
std::wstring file_dialog(bool save){wchar_t path[32768]{};if(save)wcscpy_s(path,L"我的备份.sbackup");OPENFILENAMEW o{};o.lStructSize=sizeof(o);o.hwndOwner=main_window;o.lpstrFile=path;o.nMaxFile=32768;o.lpstrFilter=L"备份文件 (*.sbackup)\0*.sbackup\0所有文件\0*.*\0";o.lpstrDefExt=L"sbackup";o.Flags=OFN_EXPLORER|OFN_NOCHANGEDIR|OFN_PATHMUSTEXIST|(save?0:OFN_FILEMUSTEXIST);if(save?GetSaveFileNameW(&o):GetOpenFileNameW(&o))return path;return {};}
std::wstring summary(const Result& r){std::wostringstream o;o<<L"操作成功  ·  "<<r.files<<L" 个文件，"<<r.directories<<L" 个目录（含根）\r\n"<<r.path.wstring()<<L"\r\n原始 "<<r.bytes<<L" 字节 / 备份 "<<r.archive_bytes<<L" 字节";return o.str();}
void launch(std::function<Result(Callback)> task){if(running)return;if(worker.joinable())worker.join();{std::lock_guard<std::mutex> lock(mutex_);done=false;latest=L"正在准备…";}running=true;for(auto h:inputs)EnableWindow(h,FALSE);SendMessageW(progress_bar,PBM_SETMARQUEE,TRUE,30);SetWindowTextW(status_text,L"正在准备…");
    worker=std::thread([task]{std::wstring message;try{auto callback=[](const Progress& p){std::wostringstream o;o<<wide(p.phase)<<L"  ·  已完成 "<<p.files<<L" 个文件，"<<p.bytes<<L" 字节";if(p.total_bytes)o<<L" / "<<p.total_bytes;std::lock_guard<std::mutex> lock(mutex_);latest=o.str();};message=summary(task(callback));}catch(const std::exception& e){try{message=L"操作失败："+wide(e.what());}catch(...){message=L"操作失败：无法处理该路径或文件，请检查权限。";}}catch(...){message=L"操作失败：未知错误。";}std::lock_guard<std::mutex> lock(mutex_);latest=message;done=true;});
}
void start_backup(){Options o;auto source=field(SOURCE),output=field(OUTPUT);require(!source.empty()&&!output.empty(),"请选择源文件夹和备份保存位置");o.filters.name=utf8(field(NAME));o.filters.path=utf8(field(PATH_PATTERN));o.filters.extensions=utf8(field(EXTENSIONS));if(!field(MIN_SIZE).empty())o.filters.min_size=parse_size(utf8(field(MIN_SIZE)));if(!field(MAX_SIZE).empty())o.filters.max_size=parse_size(utf8(field(MAX_SIZE)));if(!field(AFTER).empty())o.filters.after=date_boundary(utf8(field(AFTER)),false);if(!field(BEFORE).empty())o.filters.before=date_boundary(utf8(field(BEFORE)),true);o.filters.validate();o.compression=SendDlgItemMessageW(main_window,COMPRESS,BM_GETCHECK,0,0)==BST_CHECKED;o.password=utf8(field(PASSWORD));require(field(PASSWORD)==field(CONFIRM),"两次输入的密码不一致");if(!o.password.empty())require(wide(o.password).size()>=8,"加密密码至少需要 8 个字符");launch([source,output,o](Callback cb){return create(fs::path(source),fs::path(output),o,cb);});SetDlgItemTextW(main_window,PASSWORD,L"");SetDlgItemTextW(main_window,CONFIRM,L"");}
void start_restore(bool inspect_only){auto archive=field(ARCHIVE),destination=field(DESTINATION);require(!archive.empty(),"请选择备份文件");if(!inspect_only)require(!destination.empty(),"请选择还原位置");auto password=utf8(field(RESTORE_PASSWORD));launch([archive,destination,password,inspect_only](Callback cb){return inspect_only?inspect(fs::path(archive),password,cb):restore(fs::path(archive),fs::path(destination),password,cb);});SetDlgItemTextW(main_window,RESTORE_PASSWORD,L"");}
void build_ui(){
    surface_brush=CreateSolidBrush(surface);
    canvas_brush=CreateSolidBrush(canvas);
    normal_font=CreateFontW(-px(16),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Microsoft YaHei UI");
    title_font=CreateFontW(-px(26),0,0,0,FW_SEMIBOLD,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Microsoft YaHei UI");
    auto brand=control(-1,L"STATIC",L"文件备份",SS_CENTERIMAGE,24,31,145,35);
    SendMessageW(brand,WM_SETFONT,(WPARAM)title_font,TRUE);
    label(-1,L"本地备份助手",24,69,135);
    button(-1,L"创建备份",NAV_BACKUP,20,124,140,40);
    button(-1,L"还原与检查",NAV_RESTORE,20,171,140,40);
    button(-1,L"使用说明",NAV_ABOUT,20,218,140,40);

    heading=control(-1,L"STATIC",L"创建备份",SS_CENTERIMAGE,205,39,650,36);
    SendMessageW(heading,WM_SETFONT,(WPARAM)title_font,TRUE);
    label(0,L"将文件夹保存为一份可还原的备份。",205,80,650);
    row(0,L"源文件夹",SOURCE,SOURCE_PICK,115);
    row(0,L"备份文件保存位置",OUTPUT,OUTPUT_PICK,181);
    control(0,L"BUTTON",L"Huffman 压缩",WS_TABSTOP|BS_AUTOCHECKBOX,205,247,150,32,COMPRESS);
    SendDlgItemMessageW(main_window,COMPRESS,BM_SETCHECK,BST_CHECKED,0);
    label(0,L"加密密码（选填，至少 8 个字符）",205,284,312);
    edit(0,PASSWORD,205,308,312,true);
    label(0,L"确认密码",536,284,322);
    edit(0,CONFIRM,536,308,322,true);
    button(0,L"展开筛选条件",TOGGLE_FILTERS,205,353,132);
    const auto first_filter=pages[0].size();
    label(0,L"文件名 · 例如 *.txt",205,392,312);edit(0,NAME,205,416,312);
    label(0,L"相对路径 · 例如 文档/*",536,392,322);edit(0,PATH_PATTERN,536,416,322);
    label(0,L"扩展名 · 例如 txt,pdf",205,450,312);edit(0,EXTENSIONS,205,474,312);
    label(0,L"文件大小范围（字节）",536,450,322);
    edit(0,MIN_SIZE,536,474,145);label(0,L"至",688,478,20);edit(0,MAX_SIZE,712,474,146);
    label(0,L"修改日期范围（YYYY-MM-DD）",205,508,312);
    edit(0,AFTER,205,532,145);label(0,L"至",357,536,20);edit(0,BEFORE,381,532,136);
    label(0,L"留空表示不限，多项须同时满足。",536,536,322);
    filter_fields.assign(pages[0].begin()+first_filter,pages[0].end());
    filter_hint=control(0,L"STATIC",L"",SS_CENTERIMAGE,351,359,507,24);
    button(0,L"开始创建备份",START,205,577,168,38);
    label(0,L"备份文件需要保存到源文件夹之外。",390,585,468);

    label(1,L"从 .sbackup 文件还原目录，或先检查备份完整性。",205,80,650);
    row(1,L"备份文件",ARCHIVE,ARCHIVE_PICK,115);
    row(1,L"还原位置（已有文件夹）",DESTINATION,DESTINATION_PICK,181);
    label(1,L"备份密码（加密备份需要）",205,252,650);
    edit(1,RESTORE_PASSWORD,205,276,312,true);
    label(1,L"还原结果将保存在以原文件夹命名的子目录中。",205,329,650);
    label(1,L"如果同名目录已存在，请选择其他位置。",205,359,650);
    button(1,L"开始还原",RESTORE_START,205,577,168,38);
    button(1,L"仅检查备份",INSPECT_START,387,577,130,38);

    label(2,L"01   创建备份",205,112,650);
    label(2,L"选择源文件夹和保存位置。需要时可设置筛选、压缩和密码。",205,148,650);
    label(2,L"02   还原或检查",205,215,650);
    label(2,L"选择 .sbackup 文件和还原位置。加密备份需要原密码。",205,251,650);
    label(2,L"03   查看结果",205,318,650);
    label(2,L"底部显示文件数量、位置和大小。可复制状态留作记录。",205,354,650);

    label(-1,L"任务状态",205,644,140);
    button(-1,L"复制状态",COPY_STATUS,772,639,86,28);
    progress_bar=control(-1,PROGRESS_CLASSW,L"",PBS_MARQUEE,205,673,653,6);
    status_text=control(-1,L"EDIT",L"就绪",ES_MULTILINE|ES_READONLY|ES_NOHIDESEL|WS_TABSTOP|WS_VSCROLL,205,686,653,72);
    show_page(0);
    SetTimer(main_window,1,100,nullptr);
}
LRESULT CALLBACK procedure(HWND h,UINT msg,WPARAM w,LPARAM l){
    switch(msg){
    case WM_CREATE:main_window=h;build_ui();return 0;
    case WM_GETMINMAXINFO:{auto m=(MINMAXINFO*)l;m->ptMinTrackSize={px(920),px(820)};return 0;}
    case WM_DRAWITEM:draw_button(*reinterpret_cast<DRAWITEMSTRUCT*>(l));return TRUE;
    case WM_ERASEBKGND:{
        RECT client;GetClientRect(h,&client);
        FillRect((HDC)w,&client,canvas_brush);
        RECT panel{px(180),px(18),px(882),px(625)};
        FillRect((HDC)w,&panel,surface_brush);
        RECT footer{px(180),px(632),px(882),px(773)};
        FillRect((HDC)w,&footer,surface_brush);
        return TRUE;
    }
    case WM_CTLCOLORSTATIC:{
        auto child=reinterpret_cast<HWND>(l);
        RECT rect;GetWindowRect(child,&rect);
        POINT position{rect.left,rect.top};ScreenToClient(h,&position);
        const bool sidebar=position.x<px(180);
        SetBkColor((HDC)w,sidebar?canvas:surface);
        SetTextColor((HDC)w,sidebar?muted:ink);
        return reinterpret_cast<LRESULT>(sidebar?canvas_brush:surface_brush);
    }
    case WM_CTLCOLOREDIT:SetBkColor((HDC)w,RGB(255,255,255));SetTextColor((HDC)w,RGB(32,43,57));return (LRESULT)GetStockObject(WHITE_BRUSH);
    case WM_COMMAND:try{int id=LOWORD(w);if(HIWORD(w)!=BN_CLICKED)return 0;if(id==NAV_BACKUP||id==NAV_RESTORE||id==NAV_ABOUT){show_page(id-NAV_BACKUP);return 0;}if(id==TOGGLE_FILTERS){filters_open=!filters_open;show_page(0);return 0;}if(id==COPY_STATUS){DWORD a=0,b=0;SendMessageW(status_text,EM_GETSEL,(WPARAM)&a,(LPARAM)&b);SendMessageW(status_text,EM_SETSEL,0,-1);SendMessageW(status_text,WM_COPY,0,0);SendMessageW(status_text,EM_SETSEL,a,b);return 0;}if(running)return 0;
        if(id==SOURCE_PICK||id==DESTINATION_PICK){auto p=folder();if(!p.empty())SetDlgItemTextW(h,id==SOURCE_PICK?SOURCE:DESTINATION,p.c_str());}
        else if(id==OUTPUT_PICK||id==ARCHIVE_PICK){auto p=file_dialog(id==OUTPUT_PICK);if(!p.empty())SetDlgItemTextW(h,id==OUTPUT_PICK?OUTPUT:ARCHIVE,p.c_str());}
        else if(id==START)start_backup();else if(id==RESTORE_START||id==INSPECT_START)start_restore(id==INSPECT_START);
    }catch(const std::exception& e){MessageBoxW(h,wide(e.what()).c_str(),L"请检查输入",MB_OK|MB_ICONWARNING);}return 0;
    case WM_TIMER:{bool finished=false;std::wstring s;{std::lock_guard<std::mutex> lock(mutex_);s=latest;finished=done;if(done)done=false;}if(!s.empty()&&s!=text(status_text))SetWindowTextW(status_text,s.c_str());if(finished){worker.join();running=false;for(auto c:inputs)EnableWindow(c,TRUE);SendMessageW(progress_bar,PBM_SETMARQUEE,FALSE,0);SetWindowTextW(h,s.find(L"操作成功")==0?L"文件备份助手 · 操作成功":L"文件备份助手 · 操作失败");}return 0;}
    case WM_CLOSE:if(running){MessageBoxW(h,L"任务正在进行，请等待完成后关闭窗口。",L"文件备份助手",MB_OK|MB_ICONINFORMATION);return 0;}DestroyWindow(h);return 0;
    case WM_DESTROY:KillTimer(h,1);if(worker.joinable())worker.join();DeleteObject(normal_font);DeleteObject(title_font);DeleteObject(surface_brush);DeleteObject(canvas_brush);PostQuitMessage(0);return 0;
    }return DefWindowProcW(h,msg,w,l);
}
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,LPWSTR,int show){SetProcessDPIAware();HDC dc=GetDC(nullptr);dpi=GetDeviceCaps(dc,LOGPIXELSY);ReleaseDC(nullptr,dc);dpi=std::min(dpi,std::min((GetSystemMetrics(SM_CYSCREEN)-64)*96/820,(GetSystemMetrics(SM_CXSCREEN)-32)*96/920));dpi=std::max(dpi,72);CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);INITCOMMONCONTROLSEX ic{sizeof(ic),ICC_PROGRESS_CLASS|ICC_STANDARD_CLASSES};InitCommonControlsEx(&ic);WNDCLASSW cls{};cls.lpfnWndProc=procedure;cls.hInstance=instance;cls.lpszClassName=L"BackupAssistantCppWindow";cls.hCursor=LoadCursor(nullptr,IDC_ARROW);cls.hIcon=LoadIcon(nullptr,IDI_APPLICATION);cls.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);RegisterClassW(&cls);HWND h=CreateWindowExW(0,cls.lpszClassName,L"文件备份助手",(WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX),CW_USEDEFAULT,CW_USEDEFAULT,px(920),px(820),nullptr,nullptr,instance,nullptr);if(!h)return 1;ShowWindow(h,show);MSG msg;while(GetMessageW(&msg,nullptr,0,0)>0){if(!IsDialogMessageW(h,&msg)){TranslateMessage(&msg);DispatchMessageW(&msg);}}CoUninitialize();return (int)msg.wParam;}
