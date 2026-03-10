// ================================================================
//  recovery_engine.cpp
//  DeepRecover — Android File Recovery Engine
//  Methods: Signature Scan + EXT4 Journal + F2FS Recovery
//  Compiled via Android NDK (CMakeLists.txt)
// ================================================================

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <vector>
#include <string>
#include <algorithm>
#include <android/log.h>

#define TAG "DeepRecover"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern "C" {

// ──────────────────────────────────────────────
//  Constants
// ──────────────────────────────────────────────

static const int DR_BLOCK_SIZE  = 4096;
static const int DR_READ_SIZE   = 1024 * 1024; // 1 MB read buffer
static const int MAX_FILES      = 2000;

static volatile int g_stop     = 0;
static volatile int g_progress = 0;

// ──────────────────────────────────────────────
//  File Signature Table
// ──────────────────────────────────────────────

struct FileSig {
    const char* ext;
    const uint8_t* magic;
    int magic_len;
    int max_size;  // bytes, 0 = default 50MB
    const char* type; // image/video/audio/document/other
};

static const uint8_t SIG_JPEG[]    = {0xFF, 0xD8, 0xFF};
static const uint8_t SIG_PNG[]     = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
static const uint8_t SIG_GIF[]     = {0x47, 0x49, 0x46, 0x38};
static const uint8_t SIG_BMP[]     = {0x42, 0x4D};
static const uint8_t SIG_WEBP[]    = {0x52, 0x49, 0x46, 0x46};
static const uint8_t SIG_MP4[]     = {0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70};
static const uint8_t SIG_MP4B[]    = {0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70};
static const uint8_t SIG_MKV[]     = {0x1A, 0x45, 0xDF, 0xA3};
static const uint8_t SIG_AVI[]     = {0x52, 0x49, 0x46, 0x46};
static const uint8_t SIG_MP3[]     = {0xFF, 0xFB};
static const uint8_t SIG_MP3_ID3[] = {0x49, 0x44, 0x33};
static const uint8_t SIG_M4A[]     = {0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41};
static const uint8_t SIG_PDF[]     = {0x25, 0x50, 0x44, 0x46};
static const uint8_t SIG_DOCX[]    = {0x50, 0x4B, 0x03, 0x04};
static const uint8_t SIG_ZIP[]     = {0x50, 0x4B, 0x03, 0x04};
static const uint8_t SIG_SQLite[]  = {0x53, 0x51, 0x4C, 0x69, 0x74, 0x65};

static const FileSig FILE_SIGS[] = {
    {"jpg",  SIG_JPEG,    3,  15000000, "image"},
    {"png",  SIG_PNG,     8,  20000000, "image"},
    {"gif",  SIG_GIF,     4,  10000000, "image"},
    {"bmp",  SIG_BMP,     2,  30000000, "image"},
    {"mp4",  SIG_MP4,     8, 500000000, "video"},
    {"mp4",  SIG_MP4B,    8, 500000000, "video"},
    {"mkv",  SIG_MKV,     4, 500000000, "video"},
    {"mp3",  SIG_MP3,     2,  50000000, "audio"},
    {"mp3",  SIG_MP3_ID3, 3,  50000000, "audio"},
    {"m4a",  SIG_M4A,    11,  50000000, "audio"},
    {"pdf",  SIG_PDF,     4,  50000000, "document"},
    {"docx", SIG_DOCX,    4,  50000000, "document"},
    {"zip",  SIG_ZIP,     4, 200000000, "other"},
    {"db",   SIG_SQLite,  6,  50000000, "other"},
};
static const int SIG_COUNT = sizeof(FILE_SIGS) / sizeof(FILE_SIGS[0]);

// ──────────────────────────────────────────────
//  Recovered File Entry
// ──────────────────────────────────────────────

struct FileEntry {
    char name[256];
    char ext[16];
    char type[16];
    char block_dev[128];
    int64_t offset;
    int64_t size;
    int confidence; // 0–100
};

static FileEntry g_entries[MAX_FILES];
static int g_entry_count = 0;

static void add_entry(const char* block_dev, int64_t offset,
                      int64_t size, const char* ext, const char* type,
                      int confidence) {
    if (g_entry_count >= MAX_FILES) return;
    FileEntry& e = g_entries[g_entry_count++];
    snprintf(e.name, sizeof(e.name), "recovered_%04d.%s", g_entry_count, ext);
    strncpy(e.ext, ext, sizeof(e.ext)-1);
    strncpy(e.type, type, sizeof(e.type)-1);
    strncpy(e.block_dev, block_dev, sizeof(e.block_dev)-1);
    e.offset     = offset;
    e.size       = size;
    e.confidence = confidence;
}

// ──────────────────────────────────────────────
//  Helper: get block device for a path
// ──────────────────────────────────────────────

static bool get_block_device(const char* path, char* out, int out_len) {
    // Try common Android block devices
    const char* candidates[] = {
        "/dev/block/mmcblk0",
        "/dev/block/mmcblk0p12",
        "/dev/block/sda",
        "/dev/block/sda4",
        "/dev/block/dm-0",
    };
    for (int i = 0; i < 5; i++) {
        int fd = open(candidates[i], O_RDONLY);
        if (fd >= 0) {
            close(fd);
            strncpy(out, candidates[i], out_len-1);
            return true;
        }
    }
    // Fallback: use the path itself for external/SD
    strncpy(out, path, out_len-1);
    return false;
}

// ──────────────────────────────────────────────
//  1. SIGNATURE SCAN — works without root
//     Scans accessible storage for file headers
// ──────────────────────────────────────────────

static void signature_scan_dir(const char* dir_path) {
    if (g_stop) return;
    DIR* dir = opendir(dir_path);
    if (!dir) return;

    struct dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
        if (g_stop) break;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;

        char full[512];
        snprintf(full, sizeof(full), "%s/%s", dir_path, entry->d_name);

        if (entry->d_type == DT_DIR) {
            // Recurse (skip Android system dirs)
            if (strstr(full, "/proc") || strstr(full, "/sys") ||
                strstr(full, "/dev") || strstr(full, "Android/data/com.")) {
                continue;
            }
            signature_scan_dir(full);
            continue;
        }

        // Read file header
        int fd = open(full, O_RDONLY);
        if (fd < 0) continue;

        uint8_t header[32] = {0};
        ssize_t n = read(fd, header, sizeof(header));

        struct stat st;
        fstat(fd, &st);
        close(fd);

        if (n < 2) continue;

        // Match signatures
        for (int i = 0; i < SIG_COUNT; i++) {
            const FileSig& sig = FILE_SIGS[i];
            if (n < sig.magic_len) continue;
            if (memcmp(header, sig.magic, sig.magic_len) == 0) {
                // Check if filename extension matches (or is .tmp/.no_ext)
                const char* dot = strrchr(entry->d_name, '.');
                int confidence = 70;
                if (dot && strcmp(dot+1, sig.ext) == 0) confidence = 85;
                // For deep scan, include even mismatched extensions
                add_entry(full, 0, st.st_size, sig.ext, sig.type, confidence);
                break;
            }
        }
    }
    closedir(dir);
}

// ──────────────────────────────────────────────
//  Block-level raw signature scan (needs read
//  access to block device — root helps a lot)
// ──────────────────────────────────────────────

static void signature_scan_block(const char* block_dev) {
    int fd = open(block_dev, O_RDONLY);
    if (fd < 0) {
        LOGE("Cannot open block device %s: %s", block_dev, strerror(errno));
        return;
    }

    // Get device size
    int64_t dev_size = 0;
    ioctl(fd, BLKGETSIZE64, &dev_size);
    if (dev_size <= 0) {
        struct stat st;
        fstat(fd, &st);
        dev_size = st.st_size;
    }

    LOGI("Block scan: %s size=%lld", block_dev, (long long)dev_size);

    uint8_t* buf = (uint8_t*)malloc(DR_READ_SIZE);
    if (!buf) { close(fd); return; }

    int64_t offset = 0;
    int64_t total_scanned = 0;

    while (offset < dev_size && !g_stop) {
        int64_t to_read = std::min((int64_t)DR_READ_SIZE, dev_size - offset);
        ssize_t got = pread(fd, buf, to_read, offset);
        if (got <= 0) { offset += DR_BLOCK_SIZE; continue; }

        // Slide through the buffer in 512-byte steps
        for (int i = 0; i < got - 32 && !g_stop; i += 512) {
            uint8_t* p = buf + i;
            for (int s = 0; s < SIG_COUNT; s++) {
                const FileSig& sig = FILE_SIGS[s];
                if (memcmp(p, sig.magic, sig.magic_len) == 0) {
                    int64_t file_offset = offset + i;
                    int64_t est_size = sig.max_size > 0 ? sig.max_size : 50*1024*1024;
                    // Try to detect actual size from container
                    if (strcmp(sig.ext, "jpg") == 0) {
                        // Find EOI marker FF D9
                        for (int j = i+3; j < got-1; j++) {
                            if (buf[j] == 0xFF && buf[j+1] == 0xD9) {
                                est_size = (j + 2) - i;
                                break;
                            }
                        }
                    }
                    add_entry(block_dev, file_offset, est_size, sig.ext, sig.type, 75);
                    break;
                }
            }
        }

        total_scanned += got;
        g_progress = (int)(total_scanned * 100 / dev_size);
        offset += got;
    }

    free(buf);
    close(fd);
}

// ──────────────────────────────────────────────
//  2. EXT4 JOURNAL RECOVERY
//     Parses the ext4 journal (requires root for
//     raw block access). Falls back to readable
//     paths when no root.
// ──────────────────────────────────────────────

// EXT4 super block (simplified)
struct Ext4SuperBlock {
    uint32_t s_inodes_count;
    uint32_t s_blocks_count_lo;
    uint8_t  _pad1[8];
    uint32_t s_log_block_size;   // DR_BLOCK_SIZE = 1024 << s_log_block_size
    uint8_t  _pad2[12];
    uint32_t s_inodes_per_group;
    uint8_t  _pad3[32];
    uint16_t s_magic;            // 0xEF53
    uint8_t  _rest[400];
} __attribute__((packed));

static const uint32_t EXT4_MAGIC         = 0xEF53;
static const uint32_t EXT4_SUPERBLOCK_OFF = 1024;
static const uint32_t EXT4_DELETED_DTIME  = 0; // non-zero = deleted

// EXT4 inode (simplified)
struct Ext4Inode {
    uint16_t i_mode;
    uint16_t i_uid;
    uint32_t i_size_lo;
    uint32_t i_atime;
    uint32_t i_ctime;
    uint32_t i_mtime;
    uint32_t i_dtime;   // deletion time; non-zero => deleted
    uint16_t i_gid;
    uint16_t i_links_count;
    uint32_t i_blocks_lo;
    uint32_t i_flags;
    uint8_t  _pad[88];
    uint32_t i_block[15]; // block pointers
    uint8_t  _rest[100];
} __attribute__((packed));

static void ext4_scan(const char* block_dev) {
    int fd = open(block_dev, O_RDONLY);
    if (fd < 0) {
        LOGE("EXT4: cannot open %s", block_dev);
        return;
    }

    // Read superblock
    Ext4SuperBlock sb;
    if (pread(fd, &sb, sizeof(sb), EXT4_SUPERBLOCK_OFF) != sizeof(sb)) {
        close(fd); return;
    }

    if (sb.s_magic != EXT4_MAGIC) {
        LOGE("EXT4: bad magic 0x%x", sb.s_magic);
        close(fd); return;
    }

    uint32_t DR_BLOCK_SIZE    = 1024 << sb.s_log_block_size;
    uint32_t inodes_total  = sb.s_inodes_count;
    uint32_t inodes_pg     = sb.s_inodes_per_group;
    uint32_t groups        = (inodes_total + inodes_pg - 1) / inodes_pg;

    LOGI("EXT4: DR_BLOCK_SIZE=%u inodes=%u groups=%u", DR_BLOCK_SIZE, inodes_total, groups);

    // Inode table is at block group offset
    // Block Group Descriptor starts at block 1 (after superblock block)
    uint32_t gdt_block = (DR_BLOCK_SIZE == 1024) ? 2 : 1;
    int64_t gdt_offset = (int64_t)gdt_block * DR_BLOCK_SIZE;

    // Each group descriptor is 32 bytes (ext2/3/4 without 64-bit)
    const int GDT_ENTRY_SIZE = 32;

    for (uint32_t g = 0; g < groups && !g_stop && g_entry_count < MAX_FILES; g++) {
        uint8_t gd[GDT_ENTRY_SIZE];
        if (pread(fd, gd, GDT_ENTRY_SIZE, gdt_offset + g * GDT_ENTRY_SIZE) != GDT_ENTRY_SIZE) continue;

        uint32_t inode_table_block = *((uint32_t*)(gd + 8));
        int64_t inode_table_off = (int64_t)inode_table_block * DR_BLOCK_SIZE;

        uint32_t count = std::min(inodes_pg, inodes_total - g * inodes_pg);
        for (uint32_t i = 0; i < count && !g_stop; i++) {
            Ext4Inode inode;
            int64_t inode_off = inode_table_off + (int64_t)i * 256; // 256-byte inode
            if (pread(fd, &inode, sizeof(inode), inode_off) < (int)sizeof(inode)) continue;

            // Deleted file: dtime != 0, size > 0, links_count == 0
            if (inode.i_dtime == 0) continue;
            if (inode.i_size_lo == 0) continue;
            if (inode.i_links_count != 0) continue;

            // Only regular files
            if ((inode.i_mode & 0xF000) != 0x8000) continue;

            // Use first direct block to read header and guess type
            if (inode.i_block[0] == 0) continue;
            int64_t data_off = (int64_t)inode.i_block[0] * DR_BLOCK_SIZE;
            uint8_t header[32] = {0};
            pread(fd, header, sizeof(header), data_off);

            const char* ext  = "bin";
            const char* type = "other";
            int conf = 80;

            for (int s = 0; s < SIG_COUNT; s++) {
                const FileSig& sig = FILE_SIGS[s];
                if (memcmp(header, sig.magic, sig.magic_len) == 0) {
                    ext  = sig.ext;
                    type = sig.type;
                    conf = 88;
                    break;
                }
            }

            add_entry(block_dev, data_off, inode.i_size_lo, ext, type, conf);
        }
        g_progress = (int)(g * 100 / groups);
    }
    close(fd);
}

// ──────────────────────────────────────────────
//  3. F2FS RECOVERY
//     Flash-Friendly File System used by Samsung
//     and newer Android devices.
//     Parses segment summary blocks to find
//     orphaned (deleted) file blocks.
// ──────────────────────────────────────────────

// F2FS superblock magic
static const uint32_t F2FS_MAGIC              = 0xF2F52010;
static const uint64_t F2FS_SUPER_OFFSET       = 1024;
static const int      F2FS_SEGMENT_SIZE       = 2 * 1024 * 1024; // 2 MB
static const int      F2FS_BLKS_PER_SEG       = 512;

struct F2fsSuperBlock {
    uint32_t magic;
    uint16_t major_ver;
    uint16_t minor_ver;
    uint32_t log_sectorsize;
    uint32_t log_sectors_per_block;
    uint32_t log_blocksize;
    uint32_t log_blocks_per_seg;
    uint32_t segs_per_sec;
    uint32_t secs_per_zone;
    uint32_t checksum_offset;
    uint64_t block_count;
    uint32_t section_count;
    uint32_t segment_count;
    uint32_t segment_count_ckpt;
    uint32_t segment_count_sit;
    uint32_t segment_count_nat;
    uint32_t segment_count_ssa;
    uint32_t segment_count_main;
    uint32_t segment0_blkaddr;
    uint32_t cp_blkaddr;
    uint32_t sit_blkaddr;
    uint32_t nat_blkaddr;
    uint32_t ssa_blkaddr;
    uint32_t main_blkaddr;
    uint32_t root_ino;
    uint32_t node_ino;
    uint32_t meta_ino;
    uint8_t  uuid[16];
    uint16_t volume_name[512];
    uint32_t extension_count;
    uint8_t  extension_list[64][8];
    uint32_t cp_payload;
    uint8_t  version[256];
    uint8_t  init_version[256];
    uint32_t feature;
    uint8_t  encryption_level;
    uint8_t  encrypt_pw_salt[16];
    uint8_t  _pad[871];
} __attribute__((packed));

// F2FS Summary Entry (per-block in SSA)
struct F2fsSumEntry {
    uint32_t nid;        // node id
    uint8_t  reserved;
    uint8_t  version;
    uint16_t ofs_in_node;
} __attribute__((packed));

static void f2fs_scan(const char* block_dev) {
    int fd = open(block_dev, O_RDONLY);
    if (fd < 0) {
        LOGE("F2FS: cannot open %s", block_dev);
        return;
    }

    F2fsSuperBlock sb;
    if (pread(fd, &sb, sizeof(sb), F2FS_SUPER_OFFSET) != sizeof(sb)) {
        close(fd); return;
    }
    if (sb.magic != F2FS_MAGIC) {
        LOGE("F2FS: bad magic 0x%x (expected 0x%x)", sb.magic, F2FS_MAGIC);
        close(fd); return;
    }

    uint32_t DR_BLOCK_SIZE  = 1 << sb.log_blocksize;
    uint32_t blks_per_seg = 1 << sb.log_blocks_per_seg;
    uint32_t main_blk    = sb.main_blkaddr;
    uint32_t main_segs   = sb.segment_count_main;
    uint32_t ssa_blk     = sb.ssa_blkaddr;

    LOGI("F2FS: blk=%u blks_per_seg=%u main_segs=%u", DR_BLOCK_SIZE, blks_per_seg, main_segs);

    uint8_t* seg_buf = (uint8_t*)malloc(DR_BLOCK_SIZE);
    if (!seg_buf) { close(fd); return; }

    // Iterate SSA (Segment Summary Area) blocks to find orphaned data
    for (uint32_t seg = 0; seg < main_segs && !g_stop; seg++) {
        int64_t ssa_off = (int64_t)(ssa_blk + seg) * DR_BLOCK_SIZE;
        if (pread(fd, seg_buf, DR_BLOCK_SIZE, ssa_off) != (ssize_t)DR_BLOCK_SIZE) continue;

        // Each SSA block contains an array of F2fsSumEntry (one per block in segment)
        F2fsSumEntry* entries = (F2fsSumEntry*)seg_buf;
        int entry_count = DR_BLOCK_SIZE / sizeof(F2fsSumEntry);

        for (int b = 0; b < entry_count && b < (int)blks_per_seg; b++) {
            F2fsSumEntry& e = entries[b];
            // nid == 0 or 0xFFFFFFFF often indicates free/orphaned block
            if (e.nid == 0 || e.nid == 0xFFFFFFFF) {
                int64_t data_off = (int64_t)(main_blk + seg * blks_per_seg + b) * DR_BLOCK_SIZE;
                uint8_t header[32] = {0};
                if (pread(fd, header, sizeof(header), data_off) < 8) continue;

                const char* ext  = nullptr;
                const char* type = nullptr;
                for (int s = 0; s < SIG_COUNT; s++) {
                    if (memcmp(header, FILE_SIGS[s].magic, FILE_SIGS[s].magic_len) == 0) {
                        ext  = FILE_SIGS[s].ext;
                        type = FILE_SIGS[s].type;
                        break;
                    }
                }
                if (ext) {
                    add_entry(block_dev, data_off, DR_BLOCK_SIZE * 8, ext, type, 65);
                }
            }
        }
        g_progress = (int)(seg * 100 / main_segs);
    }

    free(seg_buf);
    close(fd);
}

// ──────────────────────────────────────────────
//  Result serialization: name|ext|size|block|offset|confidence\n
// ──────────────────────────────────────────────

static int serialize_results(char* buf, int buf_size) {
    int written = 0;
    for (int i = 0; i < g_entry_count; i++) {
        FileEntry& e = g_entries[i];
        int n = snprintf(buf + written, buf_size - written,
            "%s|%s|%lld|%s|%lld|%d\n",
            e.name, e.type,
            (long long)e.size,
            e.block_dev,
            (long long)e.offset,
            e.confidence);
        if (n < 0 || written + n >= buf_size) break;
        written += n;
    }
    return written;
}

// ──────────────────────────────────────────────
//  Public API (called via Dart FFI)
// ──────────────────────────────────────────────

/**
 * init_engine() → 0 on success
 */
int init_engine() {
    g_entry_count = 0;
    g_progress    = 0;
    g_stop        = 0;
    LOGI("DeepRecover engine initialized");
    return 0;
}

/**
 * start_scan(path, mode, out_buffer, buf_size)
 * mode: 0=Signature 1=EXT4 2=F2FS 3=Deep(all)
 * Returns number of files found, fills out_buffer with CSV lines.
 */
int start_scan(const char* path, int mode, char* out_buf, int buf_size) {
    g_entry_count = 0;
    g_progress    = 0;
    g_stop        = 0;

    char block_dev[128] = {0};
    bool has_block = get_block_device(path, block_dev, sizeof(block_dev));

    LOGI("start_scan path=%s mode=%d block=%s", path, mode, block_dev);

    // Always do filesystem-level signature scan (no root needed)
    if (mode == 0 || mode == 3) {
        LOGI("Running filesystem signature scan...");
        signature_scan_dir(path);

        // If we can open block device, do raw scan too
        if (has_block) {
            LOGI("Running block-level signature scan...");
            signature_scan_block(block_dev);
        }
    }

    // EXT4 Journal (needs block device access)
    if ((mode == 1 || mode == 3) && has_block) {
        LOGI("Running EXT4 journal scan...");
        ext4_scan(block_dev);
    }

    // F2FS (needs block device access)
    if ((mode == 2 || mode == 3) && has_block) {
        LOGI("Running F2FS scan...");
        f2fs_scan(block_dev);
    }

    // Remove duplicates by offset
    // (simple O(n^2) for now; for production use sorted dedup)
    for (int i = 0; i < g_entry_count; i++) {
        for (int j = i+1; j < g_entry_count; j++) {
            if (g_entries[i].offset == g_entries[j].offset &&
                g_entries[i].offset != 0) {
                // Prefer higher confidence
                if (g_entries[i].confidence < g_entries[j].confidence) {
                    g_entries[i] = g_entries[j];
                }
                // Remove j
                g_entries[j] = g_entries[g_entry_count-1];
                g_entry_count--;
                j--;
            }
        }
    }

    serialize_results(out_buf, buf_size);
    g_progress = 100;
    LOGI("Scan complete: %d files found", g_entry_count);
    return g_entry_count;
}

/**
 * recover_file(block_dev, offset, size, out_path)
 * Reads raw bytes from block device and writes to out_path.
 * Returns 0 on success.
 */
int recover_file(const char* block_dev, int64_t offset, int64_t size, const char* out_path) {
    // Ensure output directory exists
    char dir[512];
    strncpy(dir, out_path, sizeof(dir)-1);
    char* slash = strrchr(dir, '/');
    if (slash) {
        *slash = '\0';
        mkdir(dir, 0755);
    }

    // Open source
    int src_fd = open(block_dev, O_RDONLY);
    if (src_fd < 0) {
        // block device not accessible; try as regular file path
        src_fd = open(block_dev, O_RDONLY);
        if (src_fd < 0) {
            LOGE("recover_file: cannot open source %s: %s", block_dev, strerror(errno));
            return -1;
        }
    }

    // Open destination
    int dst_fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (dst_fd < 0) {
        LOGE("recover_file: cannot open dest %s: %s", out_path, strerror(errno));
        close(src_fd);
        return -1;
    }

    uint8_t* buf = (uint8_t*)malloc(DR_BLOCK_SIZE);
    if (!buf) { close(src_fd); close(dst_fd); return -1; }

    int64_t remaining = size;
    int64_t cur_off   = offset;
    bool ok = true;

    while (remaining > 0) {
        int64_t to_read = std::min(remaining, (int64_t)DR_BLOCK_SIZE);
        ssize_t got = pread(src_fd, buf, to_read, cur_off);
        if (got <= 0) { ok = false; break; }
        ssize_t wrote = write(dst_fd, buf, got);
        if (wrote != got) { ok = false; break; }
        cur_off   += got;
        remaining -= got;
    }

    free(buf);
    close(src_fd);
    close(dst_fd);

    if (!ok) unlink(out_path);
    return ok ? 0 : -1;
}

/**
 * get_progress() → 0–100
 */
int get_progress() {
    return g_progress;
}

/**
 * stop_scan() — signals the scan loop to exit
 */
void stop_scan() {
    g_stop = 1;
}

} // extern "C"
