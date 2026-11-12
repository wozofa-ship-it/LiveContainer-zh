#import <Foundation/Foundation.h>

extern int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress);

// 第 1 条（硬核优化 A 组）：只读 Payload/*.app/Info.plist 这一条目
// 并返回其内容，不建临时目录、不落盘；找不到/读失败返回 nil。
extern NSData * _Nullable czfExtractIpaInfoPlist(NSString *ipaPath);
