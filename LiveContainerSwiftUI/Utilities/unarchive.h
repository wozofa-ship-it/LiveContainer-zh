#import <Foundation/Foundation.h>

extern int extract(NSString* fileToExtract, NSString* extractionPath, NSProgress* progress);

// 第 1 条（硬核优化 A 组）：只读 Payload/*.app/Info.plist 这一条目
// 并返回其内容，不建临时目录、不落盘；找不到/读失败返回 nil。
extern NSData * _Nullable czfExtractIpaInfoPlist(NSString *ipaPath);

// 3.8.670（F-2）：只读 Payload/*.app/embedded.mobileprovision
// 这一条目并返回其内容（安装前预览取签名用），与上面同款流式
// 循环与路径校验；上限放宽到 1MB（mobileprovision 约 10KB 级）。
// 未签名包没有这一条目，返回 nil，不拦安装。
extern NSData * _Nullable czfExtractIpaMobileProvision(NSString *ipaPath);
