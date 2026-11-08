//
//  main.m
//  LiveContainer
//
//  Created by s s on 2026/2/17.
//
#import "LCShareExtensionLauncher.h"
#import "../LiveContainer/utils.h"

// 3.8.381：删 LSApplicationWorkspace 打开路。openURLFromShareExtension /
// openURLFromShareExtensionWithOptions（连同 hook 里的唯一调用方
// EXExtensionContextImplementationHook.m）已随 hook 文件一起删；
// iOS 26 下那路被拦仍返 YES、谎报成功。只留 canOpenURL 查询
//（ViewModel 的 firstFreeInstalledLC 还在用它找空闲 LC）。
// UIKitPrivate.h 只给那路声明类型，一并去掉。

@implementation LCShareExtensionLauncher

+ (BOOL)canOpenURLFromShareExtension:(NSURL *)url {
    id error = nil;
    return [[PrivClass(LSApplicationWorkspace) defaultWorkspace] isApplicationAvailableToOpenURL:url error:&error];
}

@end

NSBundle* lcMainBundle = nil;
__attribute__((constructor))
static void init(void) {
    lcMainBundle = [NSBundle bundleWithURL:NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    NSLog(@"%@", lcMainBundle);
}

@interface NSUserDefaults(ShareExtension)
+ (NSBundle*)lcMainBundle;
@end

@implementation NSUserDefaults(ShareExtension)

+ (NSBundle*)lcMainBundle {
    return lcMainBundle;
}

@end
