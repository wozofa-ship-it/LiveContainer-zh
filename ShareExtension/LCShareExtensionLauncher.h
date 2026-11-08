#import <Foundation/Foundation.h>

// 3.8.381：删 LSApplicationWorkspace 打开路（openURLFromShareExtension /
// openURLFromShareExtensionWithOptions，连同 hook 里的唯一调用方已删；
// iOS 26 下那路被拦仍返 YES、谎报成功）。只留 canOpenURL 查询
//（ViewModel 的 firstFreeInstalledLC 还在用它找空闲 LC）。
@interface LCShareExtensionLauncher : NSObject
+ (BOOL)canOpenURLFromShareExtension:(NSURL *)url;
@end
