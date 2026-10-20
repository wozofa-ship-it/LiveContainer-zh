// CZFDockGesture.m
// 快捷栏边缘手势（游客 App 内部版）
//
// 背景：游客 App 的内容是场景托管的远程视图，触摸不经过宿主窗口，
// 宿主侧装的手势识别器永远收不到 App 内部的触摸（悬浮窗方案 #83/#84
// 真机验证全屏下基本无效）。本插件随全局 Tweaks 加载进每一个游客 App，
// 在 App 自己的窗口上装边缘拖动手势，触发后通过 Darwin 跨进程通知
// 回调宿主进程的 MultitaskDockManager。
//
// 行为：只观察不拦截（cancelsTouchesInView=NO + 同时识别）。
// 判定用「起手位置 + 当前位移」：滑动过程中持续判定，一过门槛立刻
// 触发一次（不等抬指——往外滑手指很快出屏，抬指信号经常等不到）。
// 门槛：往外滑（隐藏/面板）10pt，往里滑（唤出）30pt，
// 任意位置起手拖到边缘需位移 >60pt（防误触）。
// 不费电：无定时器（仅启动阶段几次延迟重试）、无轮询。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *kCZFDockGestureInstalledKey = &kCZFDockGestureInstalledKey;
// 起手位置：0=不在边缘 1=左边缘 2=右边缘（shouldReceive 时记录，handler 里判定）
static NSInteger gCZFStartEdge = 0;
// 本次滑动是否已触发过（一次滑动只触发一次）
static BOOL gCZFFired = NO;

@interface CZFDockGestureHandler : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)installOnWindow:(UIWindow *)window;
@end

@implementation CZFDockGestureHandler

+ (instancetype)shared {
    static CZFDockGestureHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handler = [[CZFDockGestureHandler alloc] init];
    });
    return handler;
}

- (void)installOnWindow:(UIWindow *)window {
    if (!window) return;
    if (objc_getAssociatedObject(window, kCZFDockGestureInstalledKey)) return;
    objc_setAssociatedObject(window, kCZFDockGestureInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(czfHandlePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delegate = self;
    [window addGestureRecognizer:pan];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIWindow *window = (UIWindow *)gestureRecognizer.view;
    if (![window isKindOfClass:[UIWindow class]]) return NO;
    CGFloat x = [touch locationInView:window].x;
    CGFloat width = window.bounds.size.width;
    // 全部接收、只记录起手位置；是否触发在 handler 按起手+位移判定
    if (x >= width - 44) {
        gCZFStartEdge = 2;
    } else if (x <= 44) {
        gCZFStartEdge = 1;
    } else {
        gCZFStartEdge = 0;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)czfHandlePan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        gCZFFired = NO;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        gCZFFired = NO;
        return;
    }
    if (gCZFFired) return;
    if (gesture.state != UIGestureRecognizerStateChanged && gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint translation = [gesture translationInView:gesture.view];
    if (fabs(translation.x) < 2 * fabs(translation.y)) return;
    CGFloat endX = [gesture locationInView:gesture.view].x;
    CGFloat width = gesture.view.bounds.size.width;
    BOOL draggingRight = translation.x > 0;
    CGFloat absX = fabs(translation.x);
    NSString *notificationName = nil;
    NSString *selectorName = nil;
    if (gCZFStartEdge == 2) {
        // 起手在右边缘：往右=隐藏（往外滑手指很快出屏，门槛10），往左=唤出（门槛30）
        if (draggingRight) {
            if (absX <= 10) return;
            notificationName = @"czf.dock.rightOutward";
            selectorName = @"czfEdgeRightOutward";
        } else {
            if (absX <= 30) return;
            notificationName = @"czf.dock.rightInward";
            selectorName = @"czfEdgeRightInward";
        }
    } else if (gCZFStartEdge == 1) {
        // 起手在左边缘：往左=打开 App 面板（往外滑，门槛10），往右=唤出（门槛30）
        if (draggingRight) {
            if (absX <= 30) return;
            notificationName = @"czf.dock.leftInward";
            selectorName = @"czfEdgeLeftInward";
        } else {
            if (absX <= 10) return;
            notificationName = @"czf.dock.openPanel";
            selectorName = @"czfOpenAppPanel";
        }
    } else {
        // 任意位置起手：只有拖到屏幕边缘、位移够大才算隐藏（防误触）
        if (absX <= 60) return;
        if (draggingRight && endX >= width - 30) {
            notificationName = @"czf.dock.rightOutward";
            selectorName = @"czfEdgeRightOutward";
        } else if (!draggingRight && endX <= 30) {
            notificationName = @"czf.dock.leftOutward";
            selectorName = @"czfEdgeLeftOutward";
        } else {
            return;
        }
    }
    gCZFFired = YES;
    // 诊断标记：识别到合格拖动先轻震一下（证明插件侧收到手势）
    UIImpactFeedbackGenerator *buzz = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [buzz impactOccurred];
    // 游客 App 是独立进程（LiveProcess），按类名找宿主管理器必然落空；
    // 改发 Darwin 跨进程通知，宿主注册同名观察者接收。
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)notificationName, NULL, NULL, YES);
    // 同进程模式兜底（若某些场景游客与宿主同进程）：直调宿主入口
    Class managerClass = NSClassFromString(@"MultitaskDockManager");
    if (!managerClass) {
        managerClass = NSClassFromString(@"LiveContainer.MultitaskDockManager");
    }
    if (!managerClass) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id manager = [managerClass performSelector:@selector(shared)];
    SEL selector = NSSelectorFromString(selectorName);
    if ([manager respondsToSelector:selector]) {
        [manager performSelector:selector];
    }
#pragma clang diagnostic pop
}

@end

static void CZFDockGestureTryInstall(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        [[CZFDockGestureHandler shared] installOnWindow:window];
    }
}

__attribute__((constructor)) static void CZFDockGestureInit(void) {
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[UIWindow class]]) {
                [[CZFDockGestureHandler shared] installOnWindow:(UIWindow *)note.object];
            }
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            CZFDockGestureTryInstall();
        }];
        // 窗口出现得晚：启动后数秒内重试几次，装上为止（装过的不重复装）
        for (NSInteger i = 1; i <= 10; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                CZFDockGestureTryInstall();
            });
        }
    }
}
