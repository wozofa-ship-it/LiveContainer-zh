#import "unarchive.h"

#include "archive.h"
#include "archive_entry.h"

static int
copy_data(struct archive *ar, struct archive *aw, NSProgress *progress)
{
  int r;
  const void *buff;
  size_t size;
  la_int64_t offset;

  for (;;) {
    r = archive_read_data_block(ar, &buff, &size, &offset);
    if (r == ARCHIVE_EOF)
      return (ARCHIVE_OK);
    if (r < ARCHIVE_OK)
      return (r);
    r = archive_write_data_block(aw, buff, size, offset);
    if (r < ARCHIVE_OK) {
      fprintf(stderr, "%s\n", archive_error_string(aw));
      return (r);
    }
    progress.completedUnitCount += size;
  }
}

// 第 1 条（硬核优化 A 组）：安装预览只读 Payload/*.app/Info.plist
// 这一条目，流式读进内存直接返回，不建临时目录、不落盘。
// 其余条目用 archive_read_data_skip 跳过（不解压）；数据块用
// copy_data 同款 archive_read_data_block 循环读。
NSData * _Nullable czfExtractIpaInfoPlist(NSString *ipaPath)
{
    struct archive *a;
    struct archive_entry *entry;
    int r;
    NSMutableData *data = nil;

    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, ipaPath.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return nil;
    }
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            archive_read_close(a);
            archive_read_free(a);
            return nil;
        }
        NSString *path = [NSString stringWithUTF8String:archive_entry_pathname(entry)];
        // Payload/<Name>.app/Info.plist：中间只允许一段 .app 目录
        BOOL isInfoPlist = NO;
        if ([path hasPrefix:@"Payload/"] && [path hasSuffix:@".app/Info.plist"]) {
            NSString *middle = [path substringWithRange:NSMakeRange(8, path.length - 8 - 15)];
            if ([middle rangeOfString:@"/"].location == NSNotFound && middle.length > 4) {
                isInfoPlist = YES;
            }
        }
        if (!isInfoPlist) {
            archive_read_data_skip(a);
            continue;
        }
        // Info.plist 只有几 KB；超过 4MB 当异常包，拒绝进内存。
        la_int64_t entrySize = archive_entry_size(entry);
        if (entrySize > 4 * 1024 * 1024) {
            archive_read_close(a);
            archive_read_free(a);
            return nil;
        }
        data = [NSMutableData dataWithCapacity:(NSUInteger)(entrySize > 0 ? entrySize : 0)];
        for (;;) {
            const void *buff;
            size_t size;
            la_int64_t offset;
            r = archive_read_data_block(a, &buff, &size, &offset);
            if (r == ARCHIVE_EOF)
                break;
            if (r < ARCHIVE_OK) {
                archive_read_close(a);
                archive_read_free(a);
                return nil;
            }
            [data appendBytes:buff length:size];
        }
        break;
    }
    archive_read_close(a);
    archive_read_free(a);
    return data;
}

int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress)
{
    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int flags;
    int r;

    /* Select which attributes we want to restore. */
    flags = ARCHIVE_EXTRACT_TIME;
    flags |= ARCHIVE_EXTRACT_PERM;
    flags |= ARCHIVE_EXTRACT_ACL;
    flags |= ARCHIVE_EXTRACT_FFLAGS;

    // Calculate decompressed size
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN) {
            archive_read_close(a);
            archive_read_free(a);
            return 1;
        }
        progress.totalUnitCount += archive_entry_size(entry);
    }
    archive_read_close(a);
    archive_read_free(a);

    // Re-open the archive and extract
    a = archive_read_new();
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    if ((r = archive_read_open_filename(a, fileToExtract.fileSystemRepresentation, 10240))) {
        archive_read_free(a);
        return 1;
    }
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);
    archive_write_disk_set_standard_lookup(ext);

    while ((r = archive_read_next_header(a, &entry)) != ARCHIVE_EOF) {
        if (r == ARCHIVE_EOF)
            break;
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(a));
        if (r < ARCHIVE_WARN)
            break;
        
        NSString* currentFile = [NSString stringWithUTF8String:archive_entry_pathname(entry)];
        NSString* fullOutputPath = [extractionPath stringByAppendingPathComponent:currentFile];
        //printf("extracting %@ to %@\n", currentFile, fullOutputPath);
        archive_entry_set_pathname(entry, fullOutputPath.fileSystemRepresentation);
        
        r = archive_write_header(ext, entry);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        else if (archive_entry_size(entry) > 0) {
            r = copy_data(a, ext, progress);
            if (r < ARCHIVE_OK)
                fprintf(stderr, "%s\n", archive_error_string(ext));
            if (r < ARCHIVE_WARN)
                break;
        }
        r = archive_write_finish_entry(ext);
        if (r < ARCHIVE_OK)
            fprintf(stderr, "%s\n", archive_error_string(ext));
        if (r < ARCHIVE_WARN)
            break;
    }
    archive_read_close(a);
    archive_read_free(a);
    archive_write_close(ext);
    archive_write_free(ext);

    // O-2 修法：第二遍循环正常走完以 ARCHIVE_EOF 退出；中途 break
    //（读头/拷数据/收尾失败）时 r 是错误码，损坏、截断的 IPA 不能
    // 当成解包成功。之前无条件 return 0，坏包一路往下报的全是错的错。
    return (r == ARCHIVE_EOF) ? 0 : 1;
}
