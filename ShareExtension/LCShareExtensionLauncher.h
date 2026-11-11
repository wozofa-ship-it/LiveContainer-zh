#import <Foundation/Foundation.h>

// 3.8.381：删 LSApplicationWorkspace 打开路（openURLFromShareExtension /
// openURLFromShareExtensionWithOptions，连同 hook 里的唯一调用方已删；
// iOS 26 下那路被拦仍返 YES、谎报成功）。只留 canOpenURL 查询。
// 3.8.404：收件箱改造删了 firstFreeInstalledLC，Swift 侧已无人调
// canOpenURL；方法先留着（删 ObjC 符号另议），别再当它在用。
@interface LCShareExtensionLauncher : NSObject
+ (BOOL)canOpenURLFromShareExtension:(NSURL *)url;
@end
