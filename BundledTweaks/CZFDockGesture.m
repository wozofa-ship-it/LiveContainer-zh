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
// 门槛：往外滑（隐藏/面板）10pt，往里滑（唤出）24pt，
// 任意位置起手拖到边缘需位移 >50pt（防误触）。
// 方向判定：横向位移须大于纵向的 1.5 倍（原为 2 倍，斜向滑太容易被判掉）。
// 不费电：无定时器（仅启动阶段几次延迟重试）、无轮询。
//
// 左边缘另有「触摸漏斗」（见文件后半）：最大化时左边缘往左滑，pan
// 识别器收不到触摸——每个 App 都有系统左边缘返回手势，短促滑动时
// 触摸先被它判走（多个 App 实测一致；右边缘无此手势故一直正常）。
// 漏斗 hook 窗口 sendEvent，在识别器仲裁之前直读原始触摸判定，
// 与识别器路径共用同一发信号方法，信号完全一致。
// 漏斗判定要点：贴边往外滑时手指滑出屏幕，上报坐标被钳在边缘，
// 可测位移只有几 pt 且抬手时才报全——必须在 Ended 也判定；条件只
// 认起手在左带内 + 净位移往左 ≥8 + 方向占优，不附加位置条件。
//
// 左边缘往右滑 = 源面板（2026-10-21 用户定）：与往左滑的 App 面板
// 对称，同挂左边缘。原左边缘往右是 leftInward（唤出左侧快捷栏），
// 用户快捷栏在右侧、该动作一直空转，就此改派给源面板；pan 路径与
// 漏斗路径都改。防抢 App 自己的滑动：漏斗往右判定门槛比往左严
// （Moved 提前触发要 36 带内起手 + 位移 ≥36 + 方向比 1.5；
// 终结兜底 64 带内起手 + 位移 ≥44），普通横滑（多为中部起手）
// 进不了左带记录，进了带的慢拖也过不了方向比，互不干扰。

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
- (void)czfPostNotification:(NSString *)notificationName selectorName:(NSString *)selectorName;
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
    if (fabs(translation.x) < 1.5 * fabs(translation.y)) return;
    CGFloat endX = [gesture locationInView:gesture.view].x;
    CGFloat width = gesture.view.bounds.size.width;
    BOOL draggingRight = translation.x > 0;
    CGFloat absX = fabs(translation.x);
    NSString *notificationName = nil;
    NSString *selectorName = nil;
    if (gCZFStartEdge == 2) {
        // 起手在右边缘：往右=隐藏（往外滑手指很快出屏，门槛10），往左=唤出（门槛24）
        if (draggingRight) {
            if (absX <= 10) return;
            notificationName = @"czf.dock.rightOutward";
            selectorName = @"czfEdgeRightOutward";
        } else {
            if (absX <= 24) return;
            notificationName = @"czf.dock.rightInward";
            selectorName = @"czfEdgeRightInward";
        }
    } else if (gCZFStartEdge == 1) {
        // 起手在左边缘：往左=打开 App 面板（往外滑，门槛10），往右=源面板（门槛30，
        // 比原唤栏的 24 略严：往右是 App 内常用方向，宁可多滑一点点也不抢 App 的指令）
        if (draggingRight) {
            if (absX <= 30) return;
            notificationName = @"czf.dock.openSources";
            selectorName = @"czfOpenSourcesPanel";
        } else {
            if (absX <= 10) return;
            notificationName = @"czf.dock.openPanel";
            selectorName = @"czfOpenAppPanel";
        }
    } else {
        // 任意位置起手：只有拖到屏幕边缘、位移够大才算隐藏（防误触）
        if (absX <= 50) return;
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
    [self czfPostNotification:notificationName selectorName:selectorName];
}

// 发信号：Darwin 跨进程通知 + 同进程兜底直调。震动不在本侧给——
// 原来插件轻震+宿主入口再中震，一滑震两三下，用户反馈像滑了
// 两次；现在统一由宿主在动作真正生效时只震一下。
// 识别器路径与触摸漏斗路径共用此方法，保证两条路信号完全一致。
- (void)czfPostNotification:(NSString *)notificationName selectorName:(NSString *)selectorName {
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

// ===== 左边缘触摸漏斗（根因修复，见文件头注释）=====
static NSMutableDictionary *gCZFTouchStates = nil;
static NSTimeInterval gCZFLastFunnelFire = 0;

static void CZFFunnelObserve(UIWindow *window, UIEvent *event) {
    if (event.type != UIEventTypeTouches) return;
    if (!gCZFTouchStates) {
        gCZFTouchStates = [[NSMutableDictionary alloc] init];
    }
    for (UITouch *touch in [event touchesForWindow:window]) {
        NSValue *key = [NSValue valueWithPointer:(const void *)touch];
        CGPoint loc = [touch locationInView:window];
        switch (touch.phase) {
            case UITouchPhaseBegan: {
                // 记录带放宽到 96：抬手兜底规则需要它；移动中的提前
                // 触发仍只认 64 带内起手（见 Moved 分支）。
                if (loc.x <= 96) {
                    gCZFTouchStates[key] = @[ @(loc.x), @(loc.y), @NO ];
                }
                break;
            }
            case UITouchPhaseMoved:
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled: {
                // 三个阶段都判定：贴边 flick 的完整位移只在触摸终结时
                // 报全；而快速滑出边缘会被系统仲裁"没收"，游客收到
                // 的是 Cancelled 而非 Ended——终结事件（含取消）必须
                // 一视同仁地判，判完再清状态。
                NSArray *state = gCZFTouchStates[key];
                if (state && ![state[2] boolValue]) {
                    CGFloat dx = loc.x - [state[0] doubleValue];
                    CGFloat dy = loc.y - [state[1] doubleValue];
                    NSString *fireName = nil;
                    NSString *fireSelector = nil;
                    if (touch.phase == UITouchPhaseMoved) {
                        // 提前触发（严判定防误触）：64 带内起手、往左 8、
                        // 横向占优 1.2 倍
                        if ([state[0] doubleValue] <= 64 && dx <= -8 && fabs(dx) > 1.2 * fabs(dy)) {
                            fireName = @"czf.dock.openPanel";
                            fireSelector = @"czfOpenAppPanel";
                        } else if ([state[0] doubleValue] <= 36 && dx >= 36 && fabs(dx) > 1.5 * fabs(dy)) {
                            // 往右=源面板：全屏下与 App 的边缘返回/横滑
                            // 共用这条轨迹，防冲突全靠收紧——起手只认
                            // 贴边 36 带、位移 ≥36、方向比 1.5（与 pan
                            // 路径一致）；App 中部起手的横滑根本不进
                            // 记录，进了带的慢拖也过不了方向比。
                            fireName = @"czf.dock.openSources";
                            fireSelector = @"czfOpenSourcesPanel";
                        }
                    } else {
                        // 终结兜底（看物理结果，不看轨迹）：拇指弧线在下
                        // 半屏轨迹偏斜，方向比会把整段滑动判掉；只要最
                        // 终落点贴到边缘 12 内、净位移往左 ≥15，就是
                        // 一次滑出左边缘。方向比只留 0.4 的底线挡纯竖滑
                        //（竖滑被取消时落点不在边缘，也进不来）。
                        if (dx <= -15 && loc.x <= 12 && fabs(dx) > 0.4 * fabs(dy)) {
                            fireName = @"czf.dock.openPanel";
                            fireSelector = @"czfOpenAppPanel";
                        } else if ([state[0] doubleValue] <= 64 && dx >= 44 && fabs(dx) > 0.8 * fabs(dy)) {
                            // 往右终结兜底：起手 ≤64 带内、净位移 ≥44、
                            // 方向比 ≥0.8。比 Moved 提前触发宽在起手带、
                            // 严在位移：慢拖到终点也算数，但必须是明确
                            // 的横向大位移，不捡 App 的普通滑动。
                            fireName = @"czf.dock.openSources";
                            fireSelector = @"czfOpenSourcesPanel";
                        }
                    }
                    if (fireName) {
                        gCZFTouchStates[key] = @[ state[0], state[1], @YES ];
                        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                        if (now - gCZFLastFunnelFire >= 0.6) {
                            gCZFLastFunnelFire = now;
                            [[CZFDockGestureHandler shared] czfPostNotification:fireName selectorName:fireSelector];
                        }
                    }
                }
                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    [gCZFTouchStates removeObjectForKey:key];
                }
                break;
            }
            default:
                break;
        }
    }
}

@interface UIWindow (CZFDockGestureFunnel)
- (void)czf_sendEvent:(UIEvent *)event;
@end

@implementation UIWindow (CZFDockGestureFunnel)
- (void)czf_sendEvent:(UIEvent *)event {
    // 交换后本方法即原实现：先原样转发，再纯观察（绝不拦截/改事件）
    [self czf_sendEvent:event];
    @try {
        CZFFunnelObserve(self, event);
    } @catch (NSException *exception) {
    }
}
@end

static void CZFInstallSendEventHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method orig = class_getInstanceMethod([UIWindow class], @selector(sendEvent:));
        Method hook = class_getInstanceMethod([UIWindow class], @selector(czf_sendEvent:));
        if (orig && hook) {
            method_exchangeImplementations(orig, hook);
        }
    });
}

static void CZFDockGestureTryInstall(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        [[CZFDockGestureHandler shared] installOnWindow:window];
    }
}

__attribute__((constructor)) static void CZFDockGestureInit(void) {
    @autoreleasepool {
        CZFInstallSendEventHook();
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
