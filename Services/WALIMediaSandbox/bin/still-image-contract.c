#define _DARWIN_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

/* Header/container policy only. FFmpeg remains the full pixel decoder. */
#define MAX_BYTES ((size_t)128 * 1024 * 1024)
#define MAX_PIXELS ((uint64_t)7680 * 4320)
static const unsigned char png_signature[8] = {137,80,78,71,13,10,26,10};
static const char *failure = "invalid_image_container";
typedef struct { const char *format; uint32_t width, height; unsigned orientation; bool alpha, srgb; } image_info;
static uint16_t be16(const unsigned char *p) { return (uint16_t)((uint16_t)p[0] << 8 | p[1]); }
static uint32_t be32(const unsigned char *p) { return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]; }
static uint16_t u16(const unsigned char *p, bool le) { return le ? (uint16_t)((uint16_t)p[1]<<8 | p[0]) : be16(p); }
static uint32_t u32(const unsigned char *p, bool le) { return le ? (uint32_t)p[3]<<24 | (uint32_t)p[2]<<16 | (uint32_t)p[1]<<8 | p[0] : be32(p); }
static bool reject(const char *code) { failure = code; return false; }
static bool bounded(image_info *info) {
    if (!info->width || !info->height || info->width > 7680 || info->height > 7680 ||
        (uint64_t)info->width * info->height > MAX_PIXELS) return reject("media_limits_exceeded");
    return true;
}
static bool tiff_ifd(const unsigned char *p, size_t n, uint32_t offset, bool le,
                     image_info *info, bool *found_orientation, uint32_t *exif_ifd) {
    if (offset < 8 || offset > n || n-offset < 2) return reject("invalid_image_orientation");
    uint16_t count = u16(p+offset, le);
    if (count > 1024 || (size_t)count * 12 + 6 > n-offset) return reject("invalid_image_orientation");
    for (uint16_t i=0; i<count; i++) {
        const unsigned char *entry = p+offset+2+(size_t)i*12;
        uint16_t tag=u16(entry,le), type=u16(entry+2,le);
        uint32_t values=u32(entry+4,le);
        if (tag == 0x112) {
            if (*found_orientation || type != 3 || values != 1) return reject("invalid_image_orientation");
            unsigned value=u16(entry+8,le);
            if (value < 1 || value > 8) return reject("invalid_image_orientation");
            *found_orientation=true; info->orientation=value;
        } else if (tag == 0x8769 && exif_ifd) {
            if (*exif_ifd || type != 4 || values != 1) return reject("invalid_image_orientation");
            *exif_ifd=u32(entry+8,le);
        } else if (tag == 0xa001) {
            if (type != 3 || values != 1 || u16(entry+8,le) != 1) return reject("image_color_profile_unsupported");
            info->srgb=true;
        }
    }
    return true;
}
static bool exif(const unsigned char *p, size_t n, image_info *info, bool *seen) {
    if (*seen || n < 8 || n > 1024*1024) return reject("invalid_image_orientation");
    *seen=true;
    bool le = p[0]=='I' && p[1]=='I';
    if (!le && !(p[0]=='M' && p[1]=='M')) return reject("invalid_image_orientation");
    if (u16(p+2,le)!=42) return reject("invalid_image_orientation");
    bool found=false; uint32_t child=0, first=u32(p+4,le);
    if (!tiff_ifd(p,n,first,le,info,&found,&child)) return false;
    if (child && (child==first || !tiff_ifd(p,n,child,le,info,&found,NULL))) return false;
    return true;
}
static bool write_bytes(FILE *output, const unsigned char *p, size_t n) {
    return !output || fwrite(p,1,n,output)==n || reject("canonicalization_failed");
}
static bool png_chunk(FILE *out, const char *kind, const unsigned char *p, uint32_t n) {
    unsigned char header[8] = {n>>24,n>>16,n>>8,n};
    memcpy(header+4,kind,4);
    uLong crc=crc32(0L,Z_NULL,0); crc=crc32(crc,(const Bytef *)kind,4); if(n) crc=crc32(crc,p,n);
    unsigned char tail[4]={(unsigned char)(crc>>24),(unsigned char)(crc>>16),(unsigned char)(crc>>8),(unsigned char)crc};
    return write_bytes(out,header,8) && write_bytes(out,p,n) && write_bytes(out,tail,4);
}
static bool inspect_png(const unsigned char *p, size_t n, image_info *info, bool canonical, FILE *out) {
    if (n<8 || memcmp(p,png_signature,8)) return false;
    info->format="png";
    bool header=false,pixels=false,seen_exif=false,seen_srgb=false,seen_gamma=false,seen_chroma=false;
    size_t offset=8; unsigned chunks=0;
    if (!write_bytes(out,png_signature,8)) return false;
    while (offset<n) {
        if (++chunks>16384 || n-offset<12) return false;
        uint32_t length=be32(p+offset);
        if ((size_t)length>n-offset-12) return false;
        const unsigned char *kind=p+offset+4,*data=p+offset+8;
        uLong crc=crc32(0L,Z_NULL,0); crc=crc32(crc,kind,length+4);
        if ((uint32_t)crc!=be32(data+length)) return false;
        bool ihdr=!memcmp(kind,"IHDR",4),idat=!memcmp(kind,"IDAT",4),iend=!memcmp(kind,"IEND",4);
        if (!header && !ihdr) return false;
        if (!memcmp(kind,"acTL",4)||!memcmp(kind,"fcTL",4)||!memcmp(kind,"fdAT",4)) return reject("animated_image_unsupported");
        if (!memcmp(kind,"iCCP",4)||!memcmp(kind,"cICP",4)||!memcmp(kind,"mDCv",4)||!memcmp(kind,"cLLi",4)||!memcmp(kind,"mDCV",4)||!memcmp(kind,"cLLI",4)) return reject("image_color_profile_unsupported");
        if (ihdr) {
            if (header||offset!=8||length!=13) return false;
            info->width=be32(data); info->height=be32(data+4);
            if (!bounded(info)) return false;
            unsigned depth=data[8],color=data[9];
            if (depth!=8 || (color!=2&&color!=3&&color!=6)) return reject("image_color_profile_unsupported");
            if (data[10]||data[11]||data[12]>1) return false;
            info->alpha=color==4||color==6; header=true;
            if ((canonical||out) && (color!=2||depth!=8)) return reject("invalid_canonical_image");
            if (out && (!png_chunk(out,"IHDR",data,length)||!png_chunk(out,"sRGB",(const unsigned char *)"\0",1))) return false;
        } else if (!memcmp(kind,"sRGB",4)) {
            if (seen_srgb||length!=1||data[0]>3) return reject("image_color_profile_unsupported");
            seen_srgb=true; info->srgb=true;
        } else if (!memcmp(kind,"gAMA",4)) {
            if (seen_gamma||length!=4||be32(data)!=45455) return reject("image_color_profile_unsupported");
            seen_gamma=true;
        } else if (!memcmp(kind,"cHRM",4)) {
            static const uint32_t standard[8]={31270,32900,64000,33000,30000,60000,15000,6000};
            if (seen_chroma||length!=32) return reject("image_color_profile_unsupported");
            for (unsigned i=0;i<8;i++) if (be32(data+i*4)!=standard[i]) return reject("image_color_profile_unsupported");
            seen_chroma=true;
        } else if (!memcmp(kind,"eXIf",4)) {
            if (canonical || !exif(data,length,info,&seen_exif)) return reject(canonical ? "private_image_metadata" : failure);
        } else if (!memcmp(kind,"tRNS",4)) {
            info->alpha=true;
            if (canonical||out) return reject("invalid_canonical_image");
        } else if (idat) {
            pixels=pixels||length>0;
            if (out&&!png_chunk(out,"IDAT",data,length)) return false;
        } else if (iend) {
            if (length||!pixels||offset+12!=n) return false;
            if (canonical&&!seen_srgb) return reject("image_color_profile_unsupported");
            return !out||png_chunk(out,"IEND",NULL,0);
        } else {
            bool structural=!memcmp(kind,"PLTE",4)||!memcmp(kind,"sBIT",4)||!memcmp(kind,"pHYs",4);
            if (canonical&&!structural) return reject("private_image_metadata");
            if (!(kind[0]&32)&&memcmp(kind,"PLTE",4)) return false;
        }
        offset+=(size_t)length+12;
    }
    return false;
}
static bool inspect_jpeg(const unsigned char *p, size_t n, image_info *info, bool canonical, FILE *out) {
    if (n<4||p[0]!=255||p[1]!=216) return false;
    info->format="jpeg"; bool frame=false,scan=false,in_scan=false,seen_exif=false;
    size_t offset=2; unsigned markers=0;
    if (!write_bytes(out,p,2)) return false;
    while (offset<n) {
        if (++markers>16384) return false;
        if (in_scan) {
            size_t begin=offset;
            while (offset<n) {
                if (p[offset]!=255) { offset++; continue; }
                if (n-offset<2) return false;
                unsigned next=p[offset+1];
                if (next==0||(next>=0xd0&&next<=0xd7)) { offset+=2; continue; }
                if (next==255) { offset++; continue; }
                break;
            }
            if (!write_bytes(out,p+begin,offset-begin)) return false;
            in_scan=false;
        }
        size_t start=offset;
        if (n-offset<2||p[offset++]!=255) return false;
        while (offset<n&&p[offset]==255) offset++;
        if (offset>=n) return false;
        unsigned marker=p[offset++];
        if (marker==0xd9) return frame&&scan&&offset==n&&write_bytes(out,p+start,offset-start);
        if (marker==0xd8||marker==0||n-offset<2) return false;
        uint16_t length=be16(p+offset);
        if (length<2||length>n-offset) return false;
        const unsigned char *data=p+offset+2; size_t count=length-2;
        bool app=marker>=0xe1&&marker<=0xef,comment=marker==0xfe;
        if (marker==0xe2) return reject("image_color_profile_unsupported");
        if (marker==0xe1&&count>=6&&!memcmp(data,"Exif\0\0",6)) {
            if (!exif(data+6,count-6,info,&seen_exif)) return false;
        }
        if (canonical&&(app||comment)) return reject("private_image_metadata");
        // Canonical JFIF may retain its fixed color/density header, never a
        // thumbnail or arbitrary APP0 extension payload.
        if ((canonical||out) && marker==0xe0 &&
            (count!=14 || memcmp(data,"JFIF\0",5) || data[12] || data[13]))
            return reject("private_image_metadata");
        if (marker==0xc0||marker==0xc1||marker==0xc2) {
            if (frame||count<6||data[0]!=8||data[5]!=3||count!=(size_t)6+data[5]*3) return reject("unsupported_image_format");
            info->height=be16(data+1); info->width=be16(data+3); frame=true;
            if (!bounded(info)) return false;
        } else if (marker>=0xc0&&marker<=0xcf&&marker!=0xc4&&marker!=0xc8&&marker!=0xcc) return reject("unsupported_image_format");
        if (marker==0xda) { if (!frame) return false; scan=true; in_scan=true; }
        offset+=length;
        if ((!app&&!comment)&&!write_bytes(out,p+start,offset-start)) return false;
    }
    return false;
}
static unsigned char *read_file(const char *path, size_t *length) {
    int fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC); if(fd<0)return NULL;
    struct stat st;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||(uint64_t)st.st_size>MAX_BYTES){close(fd);failure="input_too_large";return NULL;}
    *length=(size_t)st.st_size; unsigned char *data=malloc(*length); if(!data){close(fd);return NULL;}
    size_t got=0;
    while(got<*length){ssize_t count=read(fd,data+got,*length-got);if(count<0&&errno==EINTR)continue;if(count<=0){free(data);close(fd);return NULL;}got+=(size_t)count;}
    unsigned char extra; ssize_t tail=read(fd,&extra,1);close(fd);if(tail!=0){free(data);return NULL;}return data;
}
int main(int argc,char **argv) {
    bool canonical=argc>=2&&!strcmp(argv[1],"inspect-canonical");
    bool png_out=argc==4&&!strcmp(argv[1],"canonicalize-png");
    bool jpeg_out=argc==4&&!strcmp(argv[1],"canonicalize-jpeg");
    if(!((argc==3&&(!strcmp(argv[1],"inspect-source")||canonical))||png_out||jpeg_out)){fputs("invalid_contract\n",stderr);return 64;}
    size_t length=0;unsigned char *data=read_file(argv[2],&length);FILE *out=NULL;
    if(!data){fprintf(stderr,"%s\n",failure);return 65;}
    if(png_out||jpeg_out){int fd=open(argv[3],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0){free(data);fputs("canonicalization_failed\n",stderr);return 65;}out=fdopen(fd,"wb");if(!out){close(fd);unlink(argv[3]);free(data);return 65;}}
    image_info info={.orientation=1}; bool ok=false;
    if(length>=8&&!memcmp(data,png_signature,8)&&!jpeg_out)ok=inspect_png(data,length,&info,canonical,out);
    else if(length>=2&&data[0]==255&&data[1]==216&&!png_out)ok=inspect_jpeg(data,length,&info,canonical,out);
    else failure="unsupported_image_format";
    free(data);
    if(out&&fclose(out))ok=false;
    if(!ok){if(out)unlink(argv[3]);fprintf(stderr,"%s\n",failure);return 65;}
    if(!out)printf("{\"format\":\"%s\",\"width\":%u,\"height\":%u,\"orientation\":%u,\"has_alpha\":%s,\"color_profile\":\"%s\"}\n",info.format,info.width,info.height,info.orientation,info.alpha?"true":"false",info.srgb?"srgb":"untagged_assumed_srgb");
    return 0;
}
