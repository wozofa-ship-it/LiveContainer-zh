//
//  CZFHitTestLog.h
//  LiveContainer
//
//  P0 hitTest 诊断（3.8.676）：只记日志，不改行为。
//  日志写进 Documents/CZF-HitTest.log（文件 App 可见、可分享导出），
//  同时镜像一份到 NSLog（[CZF-HitTest]）。文件超 2MB 时轮转重建。
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CZFHitTestLog : NSObject

/// 追加一行到诊断日志（自动加时间戳）。Swift/ObjC 共用入口。
+ (void)czfHitTestLogLine:(NSString *)line;

/// 一行描述一个 view：类名 + frame + hidden/alpha/userInteraction。
+ (NSString *)czfDescribeView:(UIView *)view;

/// 一行描述一个 window：类名 + level + 是否 key + frame。
+ (NSString *)czfDescribeWindow:(UIWindow *)window;

/// 点坐标一行：(x.x, y.y)，一位小数。
+ (NSString *)czfPointString:(CGPoint)point;

@end

NS_ASSUME_NONNULL_END
