//
//  CZFHitTestLog.m
//  LiveContainer
//
//  P0 hitTest 诊断（3.8.676）：只记日志，不改行为。
//  写盘走串行队列、逐行 open/close（不留常驻句柄，不怕
//  进程被杀时丢缓冲）；超 2MB 删掉重建并留一行轮转标记。
//
#import "CZFHitTestLog.h"

@implementation CZFHitTestLog

static dispatch_queue_t czfHitTestLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.livecontainer.czfHitTestLog", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

+ (NSURL *)czfHitTestLogURL {
    NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!docs) return nil;
    return [docs URLByAppendingPathComponent:@"CZF-HitTest.log"];
}

+ (void)czfHitTestLogLine:(NSString *)line {
    if (!line) return;
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    NSString *stamped = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], line];
    NSLog(@"[CZF-HitTest] %@", line);
    dispatch_async(czfHitTestLogQueue(), ^{
        NSURL *url = [self czfHitTestLogURL];
        if (!url) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        NSDictionary *attrs = [fm attributesOfItemAtPath:url.path error:&error];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if (size > 2 * 1024 * 1024) {
            [fm removeItemAtURL:url error:nil];
            NSString *marker = @"--- CZF-HitTest.log rotated (was > 2MB) ---\n";
            [marker writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:&error];
        if (!handle) {
            [stamped writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:[stamped dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *exception) {
        } @finally {
            [handle closeFile];
        }
    });
}

+ (NSString *)czfDescribeView:(UIView *)view {
    if (!view) return @"nil";
    return [NSString stringWithFormat:@"%@(frame=(%.0f,%.0f,%.0f,%.0f) hid=%d a=%.2f ui=%d)",
            NSStringFromClass([view class]),
            view.frame.origin.x, view.frame.origin.y, view.frame.size.width, view.frame.size.height,
            (int)view.hidden, view.alpha, (int)view.userInteractionEnabled];
}

+ (NSString *)czfDescribeWindow:(UIWindow *)window {
    if (!window) return @"nil";
    return [NSString stringWithFormat:@"%@(lv=%.1f key=%d frame=(%.0f,%.0f,%.0f,%.0f))",
            NSStringFromClass([window class]),
            window.windowLevel, (int)window.isKeyWindow,
            window.frame.origin.x, window.frame.origin.y, window.frame.size.width, window.frame.size.height];
}

+ (NSString *)czfPointString:(CGPoint)point {
    return [NSString stringWithFormat:@"(%.1f,%.1f)", point.x, point.y];
}

@end
