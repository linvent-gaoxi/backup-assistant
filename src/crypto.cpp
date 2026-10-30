#include "io.hpp"
#include <cstring>
#ifndef _WIN32
#include <openssl/evp.h>
#include <memory>
#endif

namespace backup {
namespace {
#ifdef _WIN32
void check(NTSTATUS status) { require(status>=0,"系统密码运算失败"); }
struct Crypto {
    BCRYPT_ALG_HANDLE aes=nullptr,hash=nullptr;
    BCRYPT_KEY_HANDLE key=nullptr;
    Bytes object, secret;
    Crypto(const std::string& password,const unsigned char* salt) {
        try {
            check(BCryptOpenAlgorithmProvider(&hash,BCRYPT_SHA256_ALGORITHM,nullptr,BCRYPT_ALG_HANDLE_HMAC_FLAG));
            secret.resize(32);
            check(BCryptDeriveKeyPBKDF2(hash,(PUCHAR)password.data(),(ULONG)password.size(),(PUCHAR)salt,16,200000,secret.data(),32,0));
            check(BCryptOpenAlgorithmProvider(&aes,BCRYPT_AES_ALGORITHM,nullptr,0));
            check(BCryptSetProperty(aes,BCRYPT_CHAINING_MODE,(PUCHAR)BCRYPT_CHAIN_MODE_GCM,sizeof(BCRYPT_CHAIN_MODE_GCM),0));
            ULONG n=0,got=0;check(BCryptGetProperty(aes,BCRYPT_OBJECT_LENGTH,(PUCHAR)&n,sizeof(n),&got,0));object.resize(n);
            check(BCryptGenerateSymmetricKey(aes,&key,object.data(),n,secret.data(),32,0));
        } catch(...) {release();throw;}
    }
    void release() {if(key)BCryptDestroyKey(key);if(aes)BCryptCloseAlgorithmProvider(aes,0);if(hash)BCryptCloseAlgorithmProvider(hash,0);if(!secret.empty())SecureZeroMemory(secret.data(),secret.size());}
    ~Crypto(){release();}
    Bytes block(const Bytes& input,const Bytes& header,uint32_t index,unsigned char* tag,bool decrypt) {
        unsigned char nonce[12];memcpy(nonce,header.data()+24,8);for(int i=0;i<4;++i)nonce[8+i]=(index>>(8*i))&255;
        Bytes aad=header;for(int i=0;i<4;++i)aad.push_back((index>>(8*i))&255);uint32_t size=(uint32_t)input.size();for(int i=0;i<4;++i)aad.push_back((size>>(8*i))&255);
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;BCRYPT_INIT_AUTH_MODE_INFO(info);info.pbNonce=nonce;info.cbNonce=12;info.pbAuthData=aad.data();info.cbAuthData=(ULONG)aad.size();info.pbTag=tag;info.cbTag=16;
        Bytes output(input.size()+16);ULONG count=0;unsigned char dummy=0;
        NTSTATUS status=decrypt?BCryptDecrypt(key,input.empty()?&dummy:(PUCHAR)input.data(),size,&info,nullptr,0,output.data(),(ULONG)output.size(),&count,0):BCryptEncrypt(key,input.empty()?&dummy:(PUCHAR)input.data(),size,&info,nullptr,0,output.data(),(ULONG)output.size(),&count,0);
        if(decrypt)require(status>=0,"密码错误或加密备份已损坏");else check(status);
        require(count==size,"加密块长度异常");output.resize(count);return output;
    }
};
#else
struct Crypto {
    unsigned char key[32]{};
    Crypto(const std::string& password,const unsigned char* salt) {
        require(PKCS5_PBKDF2_HMAC(password.data(),password.size(),salt,16,200000,EVP_sha256(),32,key)==1,"密钥派生失败");
    }
    ~Crypto(){OPENSSL_cleanse(key,sizeof key);}
    Bytes block(const Bytes& input,const Bytes& header,uint32_t index,unsigned char* tag,bool decrypt){
        unsigned char nonce[12];
        memcpy(nonce,header.data()+24,8);
        Bytes aad=header;
        auto size=static_cast<uint32_t>(input.size());
        for(int i=0;i<4;++i){nonce[8+i]=(index>>(8*i))&255;aad.push_back(nonce[8+i]);}
        for(int i=0;i<4;++i)aad.push_back((size>>(8*i))&255);
        std::unique_ptr<EVP_CIPHER_CTX,decltype(&EVP_CIPHER_CTX_free)> ctx(EVP_CIPHER_CTX_new(),EVP_CIPHER_CTX_free);
        require(ctx&&EVP_CipherInit_ex(ctx.get(),EVP_aes_256_gcm(),nullptr,key,nonce,!decrypt)==1,"加密初始化失败");
        int count=0,tail=0;
        require(EVP_CipherUpdate(ctx.get(),nullptr,&count,aad.data(),aad.size())==1,"认证头处理失败");
        Bytes output(size+16);
        count=0;
        if(size)require(EVP_CipherUpdate(ctx.get(),output.data(),&count,input.data(),size)==1,"加密块处理失败");
        if(decrypt)require(EVP_CIPHER_CTX_ctrl(ctx.get(),EVP_CTRL_GCM_SET_TAG,16,tag)==1,"认证标签无效");
        require(EVP_CipherFinal_ex(ctx.get(),output.data()+count,&tail)==1,"密码错误或加密备份已损坏");
        if(!decrypt)require(EVP_CIPHER_CTX_ctrl(ctx.get(),EVP_CTRL_GCM_GET_TAG,16,tag)==1,"无法生成认证标签");
        output.resize(count+tail);
        return output;
    }
};
#endif
}
bool encrypted(const fs::path& p) {std::ifstream in(p,std::ios::binary);require(bool(in),"无法打开备份文件");char m[8];read_bytes(in,m,8);return memcmp(m,"SBKENC01",8)==0;}
void encrypt_file(const fs::path& source,const fs::path& target,const std::string& password) {
    require(wide(password).size()>=8,"加密密码至少需要 8 个字符");
    Bytes header(32);memcpy(header.data(),"SBKENC01",8);random_bytes(header.data()+8,24);Crypto crypto(password,header.data()+8);
    std::ifstream in(source,std::ios::binary);std::ofstream out(target,std::ios::binary|std::ios::trunc);require(bool(in)&&bool(out),"无法打开加密临时文件");write_bytes(out,header.data(),header.size());
    uint32_t index=0;
    while(true) {Bytes b(BLOCK);in.read((char*)b.data(),b.size());auto n=in.gcount();require(!in.bad(),"读取待加密文件失败");b.resize((size_t)n);unsigned char tag[16]{};auto c=crypto.block(b,header,index,tag,false);put<uint32_t>(out,(uint32_t)c.size());write_bytes(out,c.data(),c.size());write_bytes(out,tag,16);if(!n)break;require(index<UINT32_MAX,"加密文件过大");++index;}
    finish(out);
}
void decrypt_file(const fs::path& source,const fs::path& target,const std::string& password) {
    require(!password.empty(),"该备份需要密码");
    std::ifstream in(source,std::ios::binary);std::ofstream out(target,std::ios::binary|std::ios::trunc);require(bool(in)&&bool(out),"无法创建解密临时文件");Bytes header(32);read_bytes(in,header.data(),header.size());require(memcmp(header.data(),"SBKENC01",8)==0,"加密格式无效");Crypto crypto(password,header.data()+8);
    uint32_t index=0;
    while(true) {auto n=get<uint32_t>(in);require(n<=BLOCK,"加密块长度无效");Bytes c(n);read_bytes(in,c.data(),n);unsigned char tag[16];read_bytes(in,tag,16);auto b=crypto.block(c,header,index,tag,true);write_bytes(out,b.data(),b.size());if(!n)break;require(index<UINT32_MAX,"加密文件过大");++index;}
    require(in.peek()==EOF,"加密备份含多余数据");finish(out);
}
}
