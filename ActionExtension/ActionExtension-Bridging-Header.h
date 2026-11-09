#import "ShareExtension/LCShareExtensionLauncher.h"
#import "LiveContainer/LCSharedUtils.h"
#import "LiveContainer/Localization.h"
// 3.8.386：导入改走 SRCROOT 相对路径（原 ../ 相对路径在 Action
// 目标下桥接头不生效，Swift 读不到 LCSharedUtils /
// LCShareExtensionLauncher / String.loc，385 全是这三类红字；
// 配合 HEADER_SEARCH_PATHS 加 $(SRCROOT)）。
