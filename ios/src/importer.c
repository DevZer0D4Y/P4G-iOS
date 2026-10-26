// The game import (importer.h): finds the program NCA in the player's NSP / NSZ / XCI / XCZ, decrypts it with their
// prod.keys, and writes its ExeFS and RomFS files. The same steps as tools/nsz_extract.py, plus the encrypted
// containers: an NCA's sections are AES-CTR (the key from the ticket's title key, or the NCA's key area); an NCZ keeps
// them decrypted, zstd-compressed as one stream (or as blocks, NCZBLOCK). Everything streams: nothing the size of the
// game is held or written twice. Key values are never logged.
#include "importer.h"

#include <CommonCrypto/CommonCryptor.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#include "zstd.h"

#define NCZ_HEADER 0x4000
#define CHUNK (4u << 20)

static bool fail(ImportJob *job, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(job->error, sizeof job->error, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[import] %s\n", job->error);
    return false;
}

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t rd64(const uint8_t *p) { return rd32(p) | (uint64_t)rd32(p + 4) << 32; }

static bool read_at(int fd, uint64_t off, void *buf, size_t n) {
    uint8_t *b = buf;
    while (n) {
        ssize_t got = pread(fd, b, n, (off_t)off);
        if (got <= 0) return false;
        b += got, off += (uint64_t)got, n -= (size_t)got;
    }
    return true;
}

bool import_is_game_file(const char *name) {
    const char *dot = strrchr(name, '.');
    if (!dot || name[0] == '.') return false;
    return !strcasecmp(dot, ".nsp") || !strcasecmp(dot, ".nsz") || !strcasecmp(dot, ".xci") || !strcasecmp(dot, ".xcz");
}

// ------------------------------------------------------------------ keys
typedef struct { char *text; } Keys;

static bool keys_load(Keys *k, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    k->text = calloc(1, (size_t)(n > 0 ? n : 0) + 1);
    bool ok = n > 0 && fread(k->text, 1, (size_t)n, f) == (size_t)n;
    fclose(f);
    return ok;
}

static int hexval(int c) { return isdigit(c) ? c - '0' : isxdigit(c) ? (tolower(c) - 'a' + 10) : -1; }

// "name = hex" lines (prod.keys, title.keys); names compare without case
static bool keys_get(const char *text, const char *name, uint8_t *out, size_t size) {
    size_t nl = strlen(name);
    for (const char *p = text; p && *p;) {
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
        if (!strncasecmp(p, name, nl)) {
            const char *q = p + nl;
            while (*q == ' ' || *q == '\t') q++;
            if (*q == '=') {
                q++;
                while (*q == ' ' || *q == '\t') q++;
                size_t i = 0;
                for (; i < size && hexval(q[2 * i]) >= 0 && hexval(q[2 * i + 1]) >= 0; i++)
                    out[i] = (uint8_t)(hexval(q[2 * i]) << 4 | hexval(q[2 * i + 1]));
                if (i == size) return true;
            }
        }
        p = strchr(p, '\n');
    }
    return false;
}

// ------------------------------------------------------------------ AES
static void aes_ecb(bool enc, const uint8_t *key, const void *in, void *out, size_t n) {
    size_t moved;
    CCCrypt(enc ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES, kCCOptionECBMode, key, 16, NULL, in, n, out, n, &moved);
}

// Nintendo's AES-XTS: the tweak is the sector number, big-endian; key = data key | tweak key
static void xts_decrypt(const uint8_t key[32], uint8_t *buf, size_t size, uint64_t first_sector) {
    for (size_t s = 0; s < size / 0x200; s++) {
        uint8_t t[16] = {0};
        uint64_t sec = first_sector + s;
        for (int i = 0; i < 8; i++) t[15 - i] = (uint8_t)(sec >> (8 * i));
        aes_ecb(true, key + 16, t, t, 16);
        uint8_t *b = buf + s * 0x200;
        for (int j = 0; j < 0x200; j += 16) {
            uint8_t x[16];
            for (int i = 0; i < 16; i++) x[i] = b[j + i] ^ t[i];
            aes_ecb(false, key, x, x, 16);
            for (int i = 0; i < 16; i++) b[j + i] = x[i] ^ t[i];
            int carry = t[15] >> 7;
            for (int i = 15; i > 0; i--) t[i] = (uint8_t)(t[i] << 1 | t[i - 1] >> 7);
            t[0] = (uint8_t)(t[0] << 1) ^ (carry ? 0x87 : 0);
        }
    }
}

// ------------------------------------------------------------------ containers: PFS0 (NSP, NSZ), HFS0 (XCI, XCZ)
typedef struct { char name[256]; uint64_t off, size; } Entry;

static int fs0_list(int fd, uint64_t base, const char *magic, int entry_size, Entry **out) {
    uint8_t h[16];
    if (!read_at(fd, base, h, 16) || memcmp(h, magic, 4)) return -1;
    uint32_t n = rd32(h + 4), st = rd32(h + 8);
    if (n > 4096 || st > (1u << 20)) return -1;
    size_t tsz = (size_t)n * entry_size + st;
    uint8_t *t = malloc(tsz + 1);
    if (!read_at(fd, base + 16, t, tsz)) { free(t); return -1; }
    t[tsz] = 0;
    uint64_t data = base + 16 + tsz;
    Entry *e = calloc(n ? n : 1, sizeof *e);
    for (uint32_t i = 0; i < n; i++) {
        const uint8_t *r = t + (size_t)i * entry_size;
        uint32_t so = rd32(r + 16);
        snprintf(e[i].name, sizeof e[i].name, "%s", so < st ? (char *)t + (size_t)n * entry_size + so : "");
        e[i].off = data + rd64(r), e[i].size = rd64(r + 8);
    }
    free(t);
    *out = e;
    return (int)n;
}

// the files of the container that hold content: an NSP's / NSZ's PFS0, or an XCI's / XCZ's secure partition
static int container_list(int fd, Entry **out) {
    uint8_t m[4];
    if (read_at(fd, 0, m, 4) && !memcmp(m, "PFS0", 4)) return fs0_list(fd, 0, "PFS0", 0x18, out);
    for (uint64_t start = 0; start <= 0x1000; start += 0x1000) {  // (some dumps keep the card's 0x1000-byte key area first)
        uint8_t h[0x200];
        if (!read_at(fd, start, h, sizeof h) || memcmp(h + 0x100, "HEAD", 4)) continue;
        Entry *root;
        int n = fs0_list(fd, start + rd64(h + 0x130), "HFS0", 0x40, &root);
        for (int i = 0; i < n; i++)
            if (!strcmp(root[i].name, "secure")) {
                uint64_t at = root[i].off;
                free(root);
                return fs0_list(fd, at, "HFS0", 0x40, out);
            }
        free(n >= 0 ? root : NULL);
        return -1;
    }
    return -1;
}

static bool ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && !strcasecmp(s + a - b, suffix);
}

// ------------------------------------------------------------------ the NCA's plaintext, by NCA offset
enum { SRC_CTR, SRC_ZSTD, SRC_BLOCKS };

typedef struct {
    int kind, fd;
    uint64_t nca;  // where the NCA starts in the file
    uint64_t pos;  // the NCA offset the next read returns
    // SRC_CTR
    uint8_t key[16];
    struct { uint64_t start, end; int enc; uint8_t ctr[8]; } sec[4];
    uint8_t *tmp;
    // SRC_ZSTD / SRC_BLOCKS: decompressed bytes in out[out_off, out_len) are at pos
    uint8_t *in, *out;
    size_t in_len, in_off, out_len, out_off, out_cap;
    uint64_t file_off;  // the next compressed byte to read
    ZSTD_DStream *zs;
    uint32_t *bsize, nblocks, next_block, block_exp;
    uint64_t dec_size;
} Plain;

static void plain_free(Plain *p) {
    free(p->tmp), free(p->in), free(p->out), free(p->bsize);
    if (p->zs) ZSTD_freeDStream(p->zs);
    memset(p, 0, sizeof *p);
}

// SRC_ZSTD / SRC_BLOCKS: the next decompressed bytes into out; false at the end or on a broken stream
static bool fill(Plain *p) {
    p->out_off = p->out_len = 0;
    if (p->kind == SRC_BLOCKS) {
        if (p->next_block >= p->nblocks) return false;
        uint64_t bs = 1ull << p->block_exp, done = (uint64_t)p->next_block * bs;
        size_t dsize = (size_t)(p->dec_size - done < bs ? p->dec_size - done : bs), csize = p->bsize[p->next_block++];
        if (csize > p->out_cap) return false;
        if (!read_at(p->fd, p->file_off, csize < dsize ? p->in : p->out, csize)) return false;
        p->file_off += csize;
        if (csize < dsize) {  // (a block that didn't shrink is stored as it is)
            size_t r = ZSTD_decompress(p->out, dsize, p->in, csize);
            if (ZSTD_isError(r) || r != dsize) return false;
        }
        p->out_len = dsize;
        return true;
    }
    while (!p->out_len) {
        if (p->in_off == p->in_len) {
            ssize_t got = pread(p->fd, p->in, CHUNK, (off_t)p->file_off);
            if (got <= 0) return false;
            p->file_off += (uint64_t)got, p->in_len = (size_t)got, p->in_off = 0;
        }
        ZSTD_inBuffer ib = {p->in, p->in_len, p->in_off};
        ZSTD_outBuffer ob = {p->out, p->out_cap, 0};
        size_t r = ZSTD_decompressStream(p->zs, &ob, &ib);
        if (ZSTD_isError(r)) return false;
        p->in_off = ib.pos, p->out_len = ob.pos;
    }
    return true;
}

static bool plain_read(Plain *p, void *buf, size_t n) {
    uint8_t *b = buf;
    if (p->kind == SRC_CTR) {
        while (n) {
            int s = -1;
            for (int i = 0; i < 4; i++)
                if (p->sec[i].end && p->pos >= p->sec[i].start && p->pos < p->sec[i].end) s = i;
            uint64_t aligned = p->pos & ~15ull, skip = p->pos - aligned, lim = s >= 0 ? p->sec[s].end : p->pos + n;
            size_t take = (size_t)(n < CHUNK - 16 ? n : CHUNK - 16);
            if (take > lim - p->pos) take = (size_t)(lim - p->pos);
            size_t span = (size_t)((skip + take + 15) & ~15ull);
            if (!read_at(p->fd, p->nca + aligned, p->tmp, span)) return false;
            if (s >= 0 && p->sec[s].enc == 3) {
                uint8_t iv[16];
                for (int j = 0; j < 8; j++) iv[j] = p->sec[s].ctr[7 - j];
                for (int j = 0; j < 8; j++) iv[15 - j] = (uint8_t)((aligned >> 4) >> (8 * j));
                CCCryptorRef c;
                size_t moved;
                if (CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv, p->key, 16, NULL, 0,
                                            0, kCCModeOptionCTR_BE, &c) != kCCSuccess)
                    return false;
                CCCryptorUpdate(c, p->tmp, span, p->tmp, span, &moved);
                CCCryptorRelease(c);
            } else if (s >= 0 && p->sec[s].enc != 1 && p->sec[s].enc != 0) {
                return false;  // (XTS / BKTR sections: not in a base game's program NCA)
            }
            memcpy(b, p->tmp + skip, take);
            b += take, n -= take, p->pos += take;
        }
        return true;
    }
    while (n) {
        if (p->out_off == p->out_len && !fill(p)) return false;
        size_t take = p->out_len - p->out_off < n ? p->out_len - p->out_off : n;
        if (b) memcpy(b, p->out + p->out_off, take), b += take;
        p->out_off += take, p->pos += take, n -= take;
    }
    return true;
}

static bool plain_skip_to(Plain *p, uint64_t off, ImportJob *job) {
    if (p->kind == SRC_CTR) { p->pos = off; return true; }
    if (off < p->pos) return false;  // (a stream only goes forward)
    while (p->pos < off) {
        if (job->cancel) return false;
        uint64_t left = off - p->pos;
        if (!plain_read(p, NULL, (size_t)(left < CHUNK ? left : CHUNK))) return false;
        job->done = (int64_t)p->pos;
    }
    return true;
}

// an NCZ's plaintext from its stream: the one zstd stream, or NCZBLOCK blocks
static bool plain_open_ncz(Plain *p, int fd, uint64_t nca, ImportJob *job) {
    memset(p, 0, sizeof *p);
    p->fd = fd, p->nca = nca, p->pos = NCZ_HEADER;
    uint8_t h[16];
    if (!read_at(fd, nca + NCZ_HEADER, h, 16) || memcmp(h, "NCZSECTN", 8)) return fail(job, "The NSZ's NCZ is damaged (no section table).");
    uint64_t start = nca + NCZ_HEADER + 16 + 64 * rd64(h + 8);
    uint8_t b[24];
    if (!read_at(fd, start, b, 24)) return fail(job, "The NSZ ends early: it may not have finished copying.");
    if (!memcmp(b, "NCZBLOCK", 8)) {
        p->kind = SRC_BLOCKS;
        p->block_exp = b[11], p->nblocks = rd32(b + 12), p->dec_size = rd64(b + 16);
        if (p->block_exp < 12 || p->block_exp > 28) return fail(job, "The NCZ's block size isn't valid.");
        p->bsize = malloc((size_t)p->nblocks * 4 + 4);
        if (!read_at(fd, start + 24, p->bsize, (size_t)p->nblocks * 4)) return fail(job, "The NSZ ends early.");
        for (uint32_t i = 0; i < p->nblocks; i++) p->bsize[i] = rd32((uint8_t *)&p->bsize[i]);
        p->file_off = start + 24 + (uint64_t)p->nblocks * 4;
        p->out_cap = (size_t)1 << p->block_exp;
        p->in = malloc(p->out_cap), p->out = malloc(p->out_cap);
        return true;
    }
    p->kind = SRC_ZSTD;
    p->file_off = start;
    p->zs = ZSTD_createDStream();
    ZSTD_initDStream(p->zs);
    p->out_cap = CHUNK;
    p->in = malloc(CHUNK), p->out = malloc(CHUNK);
    return true;
}

// ------------------------------------------------------------------ writing files
static bool mkdirs(char *path) {  // the folders of path (its last part is the file)
    for (char *s = path + 1; (s = strchr(s, '/')); s++) {
        *s = 0;
        int r = mkdir(path, 0755);
        *s = '/';
        if (r && errno != EEXIST) return false;
    }
    return true;
}

static bool copy_out(Plain *p, uint64_t size, const char *dst, ImportJob *job, const char *sink_path, uint8_t *buf,
                     int64_t *done) {
    FILE *w = NULL;
    if (!job->romfs_sink || !sink_path) {
        char path[2048];
        snprintf(path, sizeof path, "%s", dst);
        if (!mkdirs(path) || !(w = fopen(path, "wb"))) return fail(job, "Couldn't write %s (%s).", strrchr(dst, '/') + 1, strerror(errno));
    }
    bool first = true;
    do {
        size_t take = (size_t)(size < CHUNK ? size : CHUNK);
        if (job->cancel) { if (w) fclose(w); return fail(job, "Import cancelled."); }
        if (!plain_read(p, buf, take)) { if (w) fclose(w); return fail(job, "Couldn't read the game's data: the file may be damaged or incomplete."); }
        if (w && fwrite(buf, 1, take, w) != take) {
            int e = errno;
            fclose(w);
            return fail(job, e == ENOSPC ? "Not enough free space on the device." : "Couldn't write %s (%s).", strrchr(dst, '/') + 1, strerror(e));
        }
        if (!w && !job->romfs_sink(job->sink_ctx, sink_path, buf, take, first, size == take)) return fail(job, "test sink refused %s", sink_path);
        first = false;
        size -= take;
        *done += (int64_t)take;
        job->done = *done;
    } while (size);
    if (w && fclose(w)) return fail(job, errno == ENOSPC ? "Not enough free space on the device." : "Couldn't finish writing %s.", strrchr(dst, '/') + 1);
    return true;
}

// ------------------------------------------------------------------ RomFS
typedef struct { char *path; uint64_t off, size; } RFile;

static int rfile_cmp(const void *a, const void *b) {
    uint64_t x = ((const RFile *)a)->off, y = ((const RFile *)b)->off;
    return x < y ? -1 : x > y;
}

typedef struct { const uint8_t *dirs, *files; uint64_t dsz, fsz, data_off; RFile *out; size_t n, cap; bool bad; } Walk;

static void walk(Walk *w, uint32_t d, const char *path, int depth) {
    if (w->bad || depth > 64 || (uint64_t)d + 0x18 > w->dsz) { w->bad = true; return; }
    const uint8_t *e = w->dirs + d;
    for (uint32_t f = rd32(e + 12); f != 0xFFFFFFFF;) {
        if ((uint64_t)f + 0x20 > w->fsz) { w->bad = true; return; }
        const uint8_t *fe = w->files + f;
        uint32_t nl = rd32(fe + 0x1C);
        if ((uint64_t)f + 0x20 + nl > w->fsz) { w->bad = true; return; }
        if (w->n == w->cap) w->out = realloc(w->out, (w->cap = w->cap ? w->cap * 2 : 1024) * sizeof *w->out);
        size_t pl = strlen(path);
        char *p = malloc(pl + nl + 1);
        memcpy(p, path, pl), memcpy(p + pl, fe + 0x20, nl), p[pl + nl] = 0;
        if (strstr(p, "..")) { free(p); w->bad = true; return; }
        w->out[w->n++] = (RFile){p, w->data_off + rd64(fe + 8), rd64(fe + 16)};
        f = rd32(fe + 4);
    }
    for (uint32_t c = rd32(e + 8); c != 0xFFFFFFFF;) {
        if ((uint64_t)c + 0x18 > w->dsz) { w->bad = true; return; }
        const uint8_t *ce = w->dirs + c;
        uint32_t nl = rd32(ce + 0x14);
        if ((uint64_t)c + 0x18 + nl > w->dsz || nl > 512) { w->bad = true; return; }
        char sub[2048];
        snprintf(sub, sizeof sub, "%s%.*s/", path, (int)nl, (const char *)ce + 0x18);
        walk(w, c, sub, depth + 1);
        c = rd32(ce + 4);
    }
}

// the RomFS's files (sorted by where their data is) from its header and tables, read from `s` at the section's data
static bool romfs_list(Plain *s, uint64_t data, Walk *w, ImportJob *job) {
    uint8_t head[0x50];
    if (!plain_skip_to(s, data, job) || !plain_read(s, head, sizeof head)) return fail(job, "Couldn't read the game's RomFS.");
    uint64_t dt_off = rd64(head + 0x18), dt_sz = rd64(head + 0x20), ft_off = rd64(head + 0x38), ft_sz = rd64(head + 0x40),
             data_off = rd64(head + 0x48);
    uint64_t lo = dt_off < ft_off ? dt_off : ft_off, hi = dt_off + dt_sz > ft_off + ft_sz ? dt_off + dt_sz : ft_off + ft_sz;
    if (rd64(head) != 0x50 || lo < 0x50 || hi <= lo || hi - lo > (256u << 20)) return fail(job, "The game's RomFS isn't valid (wrong keys?).");
    uint8_t *tbl = malloc((size_t)(hi - lo));
    if (!plain_skip_to(s, data + lo, job) || !plain_read(s, tbl, (size_t)(hi - lo))) {
        free(tbl);
        return job->cancel ? fail(job, "Import cancelled.") : fail(job, "Couldn't read the game's file list.");
    }
    *w = (Walk){tbl + (dt_off - lo), tbl + (ft_off - lo), dt_sz, ft_sz, data + data_off};
    walk(w, 0, "", 0);
    free(tbl);
    w->dirs = w->files = NULL;
    if (w->bad || !w->n) return fail(job, "The game's file list isn't valid.");
    qsort(w->out, w->n, sizeof *w->out, rfile_cmp);
    return true;
}

static void walk_free(Walk *w) {
    for (size_t i = 0; i < w->n; i++) free(w->out[i].path);
    free(w->out);
    memset(w, 0, sizeof *w);
}

static bool romfs_extract(Plain *s, Walk *w, const char *out_dir, ImportJob *job) {
    uint64_t total = 0;
    for (size_t i = 0; i < w->n; i++) total += w->out[i].size;
    fprintf(stderr, "[import] romfs: %zu files, %llu bytes\n", w->n, (unsigned long long)total);
    struct statfs sf;
    if (!job->romfs_sink && !statfs(out_dir, &sf) && (uint64_t)sf.f_bavail * sf.f_bsize < total + (64u << 20))
        return fail(job, "Not enough free space: the game needs %.1f GB, the device has %.1f GB free.",
                    (double)(total + (64u << 20)) / 1e9, (double)((uint64_t)sf.f_bavail * sf.f_bsize) / 1e9);
    job->phase = "Unpacking the game data";
    job->done = 0, job->total = (int64_t)total;
    int64_t done = 0;
    uint8_t *buf = malloc(CHUNK);
    bool ok = true;
    for (size_t i = 0; i < w->n && ok; i++) {
        char dst[2048];
        snprintf(dst, sizeof dst, "%s/romfs/%s", out_dir, w->out[i].path);
        if (!plain_skip_to(s, w->out[i].off, job)) {
            ok = job->cancel ? fail(job, "Import cancelled.") : fail(job, "Couldn't read the game's data: the file may be damaged or incomplete.");
            break;
        }
        job->done = done;  // (plain_skip_to shows the NCA position)
        if (!w->out[i].size) {
            if (!job->romfs_sink) {
                FILE *f = (mkdirs(dst), fopen(dst, "wb"));
                if (f) fclose(f);
            }
            continue;
        }
        ok = copy_out(s, w->out[i].size, dst, job, job->romfs_sink ? w->out[i].path : NULL, buf, &done);
    }
    free(buf);
    return ok;
}

// ------------------------------------------------------------------ the import
typedef struct { uint8_t h[0xC00]; uint64_t off, size; bool ncz; } Nca;

bool import_game(const char *src, const char *keys_path, const char *out_dir, ImportJob *job) {
    job->error[0] = 0;
    job->phase = "Opening the game file";
    job->done = job->total = 0;
    Keys keys = {0};
    if (!keys_path || !keys_load(&keys, keys_path)) return fail(job, "prod.keys not found: add your console's prod.keys too.");
    uint8_t header_key[32];
    if (!keys_get(keys.text, "header_key", header_key, 32)) {
        free(keys.text);
        return fail(job, "Your prod.keys has no header_key: dump the keys again with Lockpick.");
    }
    int fd = open(src, O_RDONLY);
    if (fd < 0) { free(keys.text); return fail(job, "Couldn't open the game file (%s). If it's in iCloud, download it first.", strerror(errno)); }

    bool ok = false;
    Entry *ents = NULL;
    Plain s = {0};
    Nca prog = {0};
    Walk romfs = {0};
    uint8_t *buf = NULL;
    int n = container_list(fd, &ents);
    if (n <= 0) { fail(job, "That isn't an NSP, NSZ, XCI or XCZ, or it's damaged."); goto out; }

    // the program NCA of this title (the base game, not an update or DLC)
    bool any_nca = false, decrypted = false;
    uint64_t other_tid = 0;
    for (int i = 0; i < n && !prog.size; i++) {
        bool ncz = ends_with(ents[i].name, ".ncz");
        if (!ncz && !ends_with(ents[i].name, ".nca")) continue;
        any_nca = true;
        Nca c = {.off = ents[i].off, .size = ents[i].size, .ncz = ncz};
        if (ents[i].size < 0x4000 || !read_at(fd, c.off, c.h, sizeof c.h)) continue;
        xts_decrypt(header_key, c.h, sizeof c.h, 0);
        if (memcmp(c.h + 0x200, "NCA3", 4)) continue;
        decrypted = true;
        if (c.h[0x205] != 0) continue;  // (0: program)
        uint64_t tid = rd64(c.h + 0x210);
        if (tid == IMPORT_TITLE_ID) prog = c;
        else other_tid = tid;
    }
    if (!prog.size) {
        if (!any_nca) fail(job, "No game content in that file.");
        else if (!decrypted) fail(job, "The game didn't decrypt: header_key in your prod.keys doesn't match.");
        else if (other_tid == (IMPORT_TITLE_ID | 0x800)) fail(job, "That's an update. Pick the base game (version 1.0.0).");
        else if (other_tid) fail(job, "That isn't Persona 4 Golden (title %016llX).", (unsigned long long)other_tid);
        else fail(job, "No program in that file: pick the base game, not an update or DLC.");
        goto out;
    }
    fprintf(stderr, "[import] program NCA %s, %llu bytes, sdk %d.%d.%d\n", prog.ncz ? "(NCZ)" : "", (unsigned long long)prog.size,
            prog.h[0x21F], prog.h[0x21E], prog.h[0x21D]);

    // the sections: where each one's PFS0 / RomFS starts
    struct { uint64_t data; int idx; bool pfs0; } secs[4];
    int ns = 0;
    for (int i = 0; i < 4; i++) {
        uint32_t start = rd32(prog.h + 0x240 + i * 0x10), end = rd32(prog.h + 0x244 + i * 0x10);
        if (!end) continue;
        const uint8_t *fsh = prog.h + 0x400 + i * 0x200;
        uint64_t base = (uint64_t)start * 0x200, data;
        if (fsh[3] == 2) data = base + rd64(fsh + 0x40);
        else if (fsh[3] == 3) data = base + rd64(fsh + 0x8 + 0x10 + 5 * 0x18);
        else { fail(job, "This dump's format isn't supported (section hash type %d).", fsh[3]); goto out; }
        s.sec[i].start = base, s.sec[i].end = (uint64_t)end * 0x200, s.sec[i].enc = fsh[4];
        for (int j = 0; j < 8; j++) s.sec[i].ctr[j] = fsh[0x140 + j];
        secs[ns].data = data, secs[ns].idx = i, secs[ns].pfs0 = fsh[2] == 1, ns++;
    }
    for (int i = 1; i < ns; i++)  // by data offset: a stream reads them in order
        for (int j = i; j > 0 && secs[j].data < secs[j - 1].data; j--) {
            __typeof__(secs[0]) t = secs[j];
            secs[j] = secs[j - 1], secs[j - 1] = t;
        }

    if (prog.ncz) {
        __typeof__(s.sec) keep;
        memcpy(keep, s.sec, sizeof keep);
        if (!plain_open_ncz(&s, fd, prog.off, job)) goto out;
        memcpy(s.sec, keep, sizeof keep);
    } else {
        s.kind = SRC_CTR, s.fd = fd, s.nca = prog.off, s.tmp = malloc(CHUNK);
        int gen = prog.h[0x206] > prog.h[0x220] ? prog.h[0x206] : prog.h[0x220];
        if (gen) gen--;
        static const uint8_t zero[16];
        char name[64];
        if (memcmp(prog.h + 0x230, zero, 16)) {
            // title key crypto: the ticket in the container (or title.keys next to prod.keys) has the title key
            char rid[33];
            for (int j = 0; j < 16; j++) snprintf(rid + 2 * j, 3, "%02x", prog.h[0x230 + j]);
            uint8_t tk[16];
            bool have = false;
            for (int i = 0; i < n && !have; i++) {
                if (!ends_with(ents[i].name, ".tik") || strncasecmp(ents[i].name, rid, 32)) continue;
                uint8_t t[0x2C0];
                if (ents[i].size < 0x180 || !read_at(fd, ents[i].off, t, ents[i].size < sizeof t ? (size_t)ents[i].size : sizeof t)) continue;
                uint32_t sig = rd32(t);
                uint32_t body = sig == 0x10000 || sig == 0x10003 ? 0x240 : sig == 0x10001 || sig == 0x10004 ? 0x140
                              : sig == 0x10002 || sig == 0x10005 ? 0x80 : 0;
                if (!body || body + 0x142 > sizeof t) continue;
                if (t[body + 0x141] != 0) { fail(job, "This dump has a personalized ticket: dump the game again with its ticket made common (nxdumptool)."); goto out; }
                memcpy(tk, t + body + 0x40, 16);
                have = true;
            }
            if (!have) {
                char tkpath[1100];
                snprintf(tkpath, sizeof tkpath, "%s", keys_path);
                char *slash = strrchr(tkpath, '/');
                snprintf(slash ? slash + 1 : tkpath, sizeof tkpath - (slash ? (size_t)(slash + 1 - tkpath) : 0), "title.keys");
                Keys tks = {0};
                if (keys_load(&tks, tkpath)) have = keys_get(tks.text, rid, tk, 16);
                free(tks.text);
            }
            if (!have) { fail(job, "This dump has no ticket for the game: dump it again with its ticket, or add title.keys next to prod.keys."); goto out; }
            uint8_t kek[16];
            snprintf(name, sizeof name, "titlekek_%02x", gen);
            if (!keys_get(keys.text, name, kek, 16)) { fail(job, "Your prod.keys has no %s: the game needs newer keys (dump them again).", name); goto out; }
            aes_ecb(false, kek, tk, s.key, 16);
        } else {
            static const char *kinds[] = {"application", "ocean", "system"};
            uint8_t kak[16], area[64];
            snprintf(name, sizeof name, "key_area_key_%s_%02x", kinds[prog.h[0x207] < 3 ? prog.h[0x207] : 0], gen);
            if (!keys_get(keys.text, name, kak, 16)) { fail(job, "Your prod.keys has no %s: the game needs newer keys (dump them again).", name); goto out; }
            aes_ecb(false, kak, prog.h + 0x300, area, 64);
            memcpy(s.key, area + 0x20, 16);
        }
    }

    // First pass, in the sections' order: the RomFS's file list and the ExeFS (written, then its build checked), all
    // before the long part. An NCZ stream only goes forward, so the RomFS data takes a second pass over it.
    buf = malloc(CHUNK);
    char path[2048];
    snprintf(path, sizeof path, "%s/exefs", out_dir);
    mkdir(out_dir, 0755);
    Plain pass = s;  // (CTR: the same reader; an NCZ: a stream of its own)
    if (prog.ncz && !plain_open_ncz(&pass, fd, prog.off, job)) goto out;
    job->phase = "Reading the game";
    job->total = (int64_t)rd64(prog.h + 0x208);
    bool have_exefs = false, have_romfs = false;
    for (int k = 0; k < ns; k++) {
        if (job->cancel) { fail(job, "Import cancelled."); goto out_pass; }
        if (!secs[k].pfs0) {
            if (have_romfs) continue;
            if (!romfs_list(&pass, secs[k].data, &romfs, job)) goto out_pass;
            have_romfs = true;
            continue;
        }
        if (secs[k].idx != 0) continue;  // (a logo PFS0: not needed)
        uint8_t h[16];
        if (!plain_skip_to(&pass, secs[k].data, job) || !plain_read(&pass, h, 16) || memcmp(h, "PFS0", 4)) {
            fail(job, prog.ncz ? "The game's code didn't read: the NSZ may be damaged."
                               : "The game didn't decrypt: your prod.keys doesn't match this dump (or the ticket is wrong).");
            goto out_pass;
        }
        uint32_t cnt = rd32(h + 4), st = rd32(h + 8);
        if (cnt > 64 || st > 0x10000) { fail(job, "The game's code section isn't valid."); goto out_pass; }
        size_t tsz = (size_t)cnt * 0x18 + st;
        uint8_t *t = malloc(tsz + 1);
        if (!plain_read(&pass, t, tsz)) { free(t); fail(job, "Couldn't read the game's code."); goto out_pass; }
        t[tsz] = 0;
        uint64_t dbase = secs[k].data + 16 + tsz;
        Entry fe[64];
        for (uint32_t i = 0; i < cnt; i++) {
            uint32_t so = rd32(t + i * 0x18 + 16);
            snprintf(fe[i].name, sizeof fe[i].name, "%s", so < st ? (char *)t + cnt * 0x18 + so : "?");
            fe[i].off = dbase + rd64(t + i * 0x18), fe[i].size = rd64(t + i * 0x18 + 8);
        }
        free(t);
        for (uint32_t i = 1; i < cnt; i++)
            for (uint32_t j = i; j > 0 && fe[j].off < fe[j - 1].off; j--) { Entry x = fe[j]; fe[j] = fe[j - 1], fe[j - 1] = x; }
        int64_t ignored = 0;
        for (uint32_t i = 0; i < cnt; i++) {
            if (strchr(fe[i].name, '/') || !fe[i].name[0] || fe[i].name[0] == '.') continue;
            char dst[2100];
            snprintf(dst, sizeof dst, "%s/%s", path, fe[i].name);
            ImportJob quiet = *job;  // (the pass's progress stays the NCA position)
            quiet.romfs_sink = NULL;
            if (!plain_skip_to(&pass, fe[i].off, job)) { fail(job, "Couldn't read the game's code."); goto out_pass; }
            if (!copy_out(&pass, fe[i].size, dst, &quiet, NULL, buf, &ignored)) {
                memcpy(job->error, quiet.error, sizeof job->error);
                goto out_pass;
            }
            fprintf(stderr, "[import] exefs/%s %llu\n", fe[i].name, (unsigned long long)fe[i].size);
        }
        have_exefs = true;
    }
    if (prog.ncz) plain_free(&pass);
    if (!have_exefs || !have_romfs) { fail(job, "The game's code or data is missing from that file."); goto out; }
    if (job->check_exefs && !job->check_exefs(path, job->error, sizeof job->error)) {
        fprintf(stderr, "[import] %s\n", job->error);
        goto out;
    }
    // second pass: the RomFS data
    if (!romfs_extract(&s, &romfs, out_dir, job)) goto out;
    job->phase = "Done";
    ok = true;
    goto out;
out_pass:
    if (prog.ncz) plain_free(&pass);
out:
    walk_free(&romfs);
    free(buf);
    free(ents);
    plain_free(&s);
    close(fd);
    free(keys.text);
    return ok;
}
