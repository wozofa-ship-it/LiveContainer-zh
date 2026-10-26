#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#import "../LiveContainer/utils.h"

static NSString *loadTweakAtURL(NSURL *url) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"]) {
        return nil;
    }
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL* infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString* binary = infoDict[@"CFBundleExecutable"];
        if(!binary || ![binary isKindOfClass:NSString.class]) {
            return [NSString stringWithFormat:@"Unable to load %@: Unable to read Info.Plist", tweak];
        }
        tweakPath = [[url URLByAppendingPathComponent:binary] path];
    }
    
    void *handle = dlopen(tweakPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    const char *error = dlerror();
    if (handle) {
        NSLog(@"Loaded tweak %@", tweak);
        return nil;
    } else if (error) {
        NSLog(@"Error: %s", error);
        return @(error);
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        return [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", tweakPath];
    }
}

static void loadTweaksRecursively(NSURL *folderURL, NSMutableArray *errors) {
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil];
    for (NSURL *fileURL in items) {
        NSString *name = fileURL.lastPathComponent;
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled tweak %@", name);
            continue;
        }
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        // a .framework is a directory but loads as a single tweak
        if (isDirectory.boolValue && ![name hasSuffix:@".framework"]) {
            loadTweaksRecursively(fileURL, errors);
        } else {
            NSString *error = loadTweakAtURL(fileURL);
            if (error) {
                [errors addObject:error];
            }
        }
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to load tweaks" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 手势不再是独立插件：代码随 TweakLoader 编译进启动器，
// 这里统一装上（禁注入的 App 直接 return，不装；没选插件的
// 游客也照样有手势）。
static void CZFDockGestureInstall(void);

 __attribute__((constructor))
static void TweakLoaderConstructor() {
    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    NSString *globalTweakFolder = @(tweakFolderC);
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");
    
    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }

    CZFDockGestureInstall();
    
    NSMutableArray *errors = [NSMutableArray new];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:globalTweakFolder]
    includingPropertiesForKeys:@[] options:0 error:nil];
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    // Load global tweaks
    NSLog(@"Loading tweaks from the global folder");

    for (NSURL *fileURL in globalTweaks) {
        NSString *name = fileURL.lastPathComponent;
        if ([name isEqualToString:@"TweakLoader.dylib"]) {
            // skip loading myself
            continue;
        }
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled global tweak %@", name);
            continue;
        }
        NSString *error = loadTweakAtURL(fileURL);
        if (error) {
            [errors addObject:error];
        }
    }

    // Load selected tweak folders, recursively（多选：文件夹
    // 名以 | 拼接，逐个加载；旧的单值就是单元素，天然兼容）
    if (tweakFolderName.length > 0) {
        NSLog(@"Loading tweaks from the selected folder");
        for (NSString *name in [tweakFolderName componentsSeparatedByString:@"|"]) {
            if (name.length == 0) continue;
            NSString *tweakFolder = [globalTweakFolder stringByAppendingPathComponent:name];
            loadTweaksRecursively([NSURL fileURLWithPath:tweakFolder], errors);
        }
    }

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}

// ---- 快捷栏边缘手势（游客 App 内部版，直接附在本文件末尾） ----
// 2026-10-24 用户亲定：手势不再是独立插件。之前把手势放进 TweakLoader/
// 目录指望同步组自动编进包，结果构建证明没编进去（链接缺符号）。
// 教训：TweakLoader 靶没接同步组，新文件放目录里也不会编；所以手势
// 代码直接写进本来就编进包的 TweakLoader.m，不再依赖新文件进靶。
// 由上文 TweakLoaderConstructor 调用；禁注入的 App 不装。

static const void *kCZFDockGestureInstalledKey = &kCZFDockGestureInstalledKey;
// 起手位置：0=不在边缘 1=左边缘 2=右边缘（shouldReceive 时记录，handler 里判定）
static NSInteger gCZFStartEdge = 0;
// 起手高度是否在启用带内：边缘手势只认屏幕高度 70%–90% 一段
//（=距底部 10%–30%，2026-10-24 用户红圈定，别再放中间，
// 与宿主中档同值；上下两段不调防误触）
static BOOL gCZFStartInBand = YES;
// 本次滑动是否已触发过（一次滑动只触发一次）
static BOOL gCZFFired = NO;

// 边缘带拦截识别器（手势双触发修正）：只负责一件事——起手
// 在边缘带（44pt 内 + 高度 70%–90%，见 shouldReceiveTouch
// 分支）且约 6pt 内横向占优时，立刻认是手势并取消 App 那路
// 触摸（cancelsTouchesInView=YES）。6pt 是刻意卡在系统 pan
// 门槛（约 10pt）之前：拦截先认，App 的滚动/返回识别器才
// 会失败；竖滑、点按、中部起手一律不认（竖向占优即失败，
// 无位移则到抬手失败），App 完全不受影响。认了之后本识别
// 器即结束（离散型），面板信号仍由观察 pan 按严门槛发，
// 不双份触发；观察 pan 靠与本识别器同时识别存活，继续
// 按严门槛追踪（见 shouldRecognizeSimultaneously 分支）。
@interface CZFEdgeCancelRecognizer : UIGestureRecognizer
@end

@implementation CZFEdgeCancelRecognizer {
    UITouch *_czfTouch;
    CGPoint _czfStart;
}

- (void)reset {
    [super reset];
    _czfTouch = nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    if (!_czfTouch) {
        _czfTouch = touches.anyObject;
        _czfStart = [_czfTouch locationInView:self.view];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (self.state == UIGestureRecognizerStateFailed || self.state == UIGestureRecognizerStateRecognized) return;
    if (!_czfTouch || ![touches containsObject:_czfTouch]) return;
    CGPoint loc = [_czfTouch locationInView:self.view];
    CGFloat adx = fabs(loc.x - _czfStart.x);
    CGFloat ady = fabs(loc.y - _czfStart.y);
    if (adx >= 6 && adx > ady) {
        self.state = UIGestureRecognizerStateRecognized;
    } else if (ady >= 6 && ady >= adx) {
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateFailed;
}

@end

@interface CZFDockGestureHandler : NSObject <UIGestureRecognizerDelegate> {
    UIPanGestureRecognizer *_observerPan;
    CZFEdgeCancelRecognizer *_cancelPan;
}
+ (instancetype)shared;
- (void)installOnWindow:(UIWindow *)window;
- (void)czfPostNotification:(NSString *)notificationName selectorName:(NSString *)selectorName;
@end

// 终结兜底判定（与宿主 processGlobalSwipeFallback 同参）：贴边
// flick 被 App 仲裁取消、或全程方向比过不了严判时，只看物理
// 结果——净位移方向 + 落点贴边。右边缘此前没有兜底（触摸漏斗
// 只管左边缘），轻扫经常被取消导致不跟手，本次补齐。
static BOOL CZFPanFallback(NSInteger startEdge, CGPoint translation, CGFloat endX, CGFloat width, NSString **outName, NSString **outSelector) {
    CGFloat dx = translation.x;
    CGFloat dy = translation.y;
    if (startEdge == 1) {
        // 2026-10-23 真机纠正后对调：往外弹（左移）= 源面板，
        // 往里拖（右移）= App 面板；门槛跟着物理方向走
        if (dx <= -8 && endX <= 12 && fabs(dx) > 0.4 * fabs(dy)) {
            *outName = @"czf.dock.openSources";
            *outSelector = @"czfOpenSourcesPanel";
            return YES;
        }
        if (dx >= 44 && fabs(dx) > 0.8 * fabs(dy)) {
            *outName = @"czf.dock.openPanel";
            *outSelector = @"czfOpenAppPanel";
            return YES;
        }
    } else if (startEdge == 2) {
        if (dx >= 8 && endX >= width - 12 && fabs(dx) > 0.4 * fabs(dy)) {
            *outName = @"czf.dock.rightOutward";
            *outSelector = @"czfEdgeRightOutward";
            return YES;
        }
        if (dx <= -44 && fabs(dx) > 0.8 * fabs(dy)) {
            *outName = @"czf.dock.rightInward";
            *outSelector = @"czfEdgeRightInward";
            return YES;
        }
    }
    return NO;
}

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
    _observerPan = pan;
    [window addGestureRecognizer:pan];
    // 拦截识别器与观察 pan 同窗共存：只接边缘带起手，认了即
    // 取消 App 触摸；面板信号仍由观察 pan 按严门槛发
    CZFEdgeCancelRecognizer *cancel = [[CZFEdgeCancelRecognizer alloc] initWithTarget:self action:@selector(czfCancelPanFired:)];
    cancel.cancelsTouchesInView = YES;
    cancel.delegate = self;
    _cancelPan = cancel;
    [window addGestureRecognizer:cancel];
}

// 拦截识别器动作：只负责取消 App 触摸，不发信号
- (void)czfCancelPanFired:(UIGestureRecognizer *)gesture {
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIWindow *window = (UIWindow *)gestureRecognizer.view;
    if (![window isKindOfClass:[UIWindow class]]) return NO;
    CGPoint loc = [touch locationInView:window];
    CGFloat width = window.bounds.size.width;
    CGFloat height = window.bounds.size.height;
    if (gestureRecognizer == _cancelPan) {
        // 拦截器只接边缘带起手：边缘 44pt 内 + 高度 70%–90%
        // （与观察 pan 的边缘/启用带同值）；其余一律不接，
        // App 完全不受影响；全局变量只归观察 pan 写，不碰
        BOOL inBand = (loc.y >= height * 0.70 && loc.y <= height * 0.90);
        return inBand && (loc.x <= 44 || loc.x >= width - 44);
    }
    gCZFStartInBand = (loc.y >= height * 0.70 && loc.y <= height * 0.90);
    // 全部接收、只记录起手位置；是否触发在 handler 按起手+位移判定
    if (loc.x >= width - 44) {
        gCZFStartEdge = 2;
    } else if (loc.x <= 44) {
        gCZFStartEdge = 1;
    } else {
        gCZFStartEdge = 0;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 拦截器只跟观察 pan 共存：共存观察 pan 才能在拦截认了
    // 之后继续按严门槛追踪发面板信号；对 App 的识别器一律
    // 不同时，拦截一认 App 那路就失败（滚动/返回停住）。
    // 观察 pan 维持原样全放行。
    if (gestureRecognizer == _cancelPan) {
        return otherGestureRecognizer == _observerPan;
    }
    return YES;
}

- (void)czfHandlePan:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        gCZFFired = NO;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateFailed) {
        gCZFFired = NO;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateCancelled) {
        // 被 App 仲裁"没收"不等于没滑：走终结兜底判定（见
        // CZFPanFallback），判完清状态
        if (!gCZFFired && gCZFStartEdge != 0 && gCZFStartInBand) {
            NSString *name = nil;
            NSString *selector = nil;
            if (CZFPanFallback(gCZFStartEdge, [gesture translationInView:gesture.view], [gesture locationInView:gesture.view].x, gesture.view.bounds.size.width, &name, &selector)) {
                [self czfPostNotification:name selectorName:selector];
            }
        }
        gCZFFired = NO;
        return;
    }
    if (gCZFFired) return;
    if (gesture.state != UIGestureRecognizerStateChanged && gesture.state != UIGestureRecognizerStateEnded) return;
    // 启用带外起手的边缘滑动不调（任意位置起手不受此限）
    if (gCZFStartEdge != 0 && !gCZFStartInBand) return;
    CGPoint translation = [gesture translationInView:gesture.view];
    CGFloat endX = [gesture locationInView:gesture.view].x;
    CGFloat width = gesture.view.bounds.size.width;
    if (gesture.state == UIGestureRecognizerStateEnded) {
        // 终结兜底先于严判：落点贴边+净位移够就认；严判的方向比
        // 留给滑动中的提前触发
        NSString *name = nil;
        NSString *selector = nil;
        if (CZFPanFallback(gCZFStartEdge, translation, endX, width, &name, &selector)) {
            gCZFFired = YES;
            [self czfPostNotification:name selectorName:selector];
            return;
        }
    }
    // 方向比：往外弹（左缘左移/右缘右移）物理行程短、拇指走
    // 弧线纵向分量大，1.5 倍会把大半次弹滑判掉（用户真机反馈
    // 左缘往左弹很不灵敏），往外方向放宽到 0.9；其余维持 1.5
    BOOL czfOutward = (gCZFStartEdge == 1 && translation.x < 0) || (gCZFStartEdge == 2 && translation.x > 0);
    if (fabs(translation.x) < (czfOutward ? 0.9 : 1.5) * fabs(translation.y)) return;
    BOOL draggingRight = translation.x > 0;
    CGFloat absX = fabs(translation.x);
    NSString *notificationName = nil;
    NSString *selectorName = nil;
    if (gCZFStartEdge == 2) {
        // 起手在右边缘：往左=上一个已打开 App，往右=下一个已打开
        // App（门槛往左24、往右6，往外滑手指很快出屏）；宿主侧改派
        if (draggingRight) {
            if (absX <= 6) return;
            notificationName = @"czf.dock.rightOutward";
            selectorName = @"czfEdgeRightOutward";
        } else {
            if (absX <= 24) return;
            notificationName = @"czf.dock.rightInward";
            selectorName = @"czfEdgeRightInward";
        }
    } else if (gCZFStartEdge == 1) {
        // 起手在左边缘（2026-10-23 真机纠正后对调）：往里拖
        // （手指右移，门槛30）= App 面板——往里是 App 内常用
        // 方向，门槛保持严，宁可多滑一点也不抢 App 的指令；
        // 往外弹（手指左移，门槛6）= 源面板
        if (draggingRight) {
            if (absX <= 30) return;
            notificationName = @"czf.dock.openPanel";
            selectorName = @"czfOpenAppPanel";
        } else {
            if (absX <= 6) return;
            notificationName = @"czf.dock.openSources";
            selectorName = @"czfOpenSourcesPanel";
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
static NSMutableDictionary *gCZFTapStarts = nil;  // 点按起点（手势误触修正：只有真点按才发置顶信号）
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
                // 点按置顶（用户定 2026-10-25；2026-10-25 手势误触修正）：
                // 游客里任何位置点按都要把本窗口顶到最上，但只有真点按
                // 才操作——手势起手不能当点击。宿主侧容器识别器收不到
                // 游客内容（passthrough view）的触摸——触摸直达游客场景，
                // 故游客侧在点按抬手时发 Darwin 信号（名里带本 App bundleId），
                // 宿主按名找到窗口静默置顶（只调层级、不动画，点按不闪）。
                // 判定在 Ended 做（见下）：按下只记起点，位移超 12pt
                // 或取消的一律不发。纯观察，不改事件、不碰漏斗状态。
                if (!gCZFTapStarts) {
                    gCZFTapStarts = [[NSMutableDictionary alloc] init];
                }
                gCZFTapStarts[key] = @[ @(loc.x), @(loc.y) ];
                // 记录带放宽到 96：抬手兜底规则需要它；移动中的提前
                // 触发仍只认 64 带内起手（见 Moved 分支）。另加启用
                // 带（与宿主中档同值）：带外起手不记录，手势只认
                // 屏幕高度下段（距底部 10%–30%）。
                CGFloat winHeight = window.bounds.size.height;
                if (loc.x <= 96 && loc.y >= winHeight * 0.70 && loc.y <= winHeight * 0.90) {
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
                        // 提前触发（严判定防误触）：64 带内起手、往外
                        // 弹（左移）8、横向占优 1.2 倍 = 源面板
                        // （2026-10-23 对调后）
                        if ([state[0] doubleValue] <= 64 && dx <= -8 && fabs(dx) > 0.9 * fabs(dy)) {
                            fireName = @"czf.dock.openSources";
                            fireSelector = @"czfOpenSourcesPanel";
                        } else if ([state[0] doubleValue] <= 36 && dx >= 36 && fabs(dx) > 1.5 * fabs(dy)) {
                            // 往里拖（右移）= App 面板（2026-10-23
                            // 对调后）：全屏下与 App 的边缘返回/横滑
                            // 共用这条轨迹，防冲突全靠收紧——起手只认
                            // 贴边 36 带、位移 ≥36、方向比 1.5（与 pan
                            // 路径一致）；App 中部起手的横滑根本不进
                            // 记录，进了带的慢拖也过不了方向比。
                            fireName = @"czf.dock.openPanel";
                            fireSelector = @"czfOpenAppPanel";
                        }
                    } else {
                        // 终结兜底（看物理结果，不看轨迹）：拇指弧线在下
                        // 半屏轨迹偏斜，方向比会把整段滑动判掉；只要最
                        // 终落点贴到边缘 12 内、净位移往左 ≥8，就是
                        // 一次滑出左边缘 = 源面板（2026-10-23 对调
                        // 后；门槛原为 15，起手贴边时物理行程总共就
                        // 十几 pt、大半次滑够不着，真机反馈不灵敏）。
                        // 方向比只留 0.4 的底线挡纯竖滑（竖滑
                        // 被取消时落点不在边缘，也进不来）。
                        if (dx <= -8 && loc.x <= 12 && fabs(dx) > 0.4 * fabs(dy)) {
                            fireName = @"czf.dock.openSources";
                            fireSelector = @"czfOpenSourcesPanel";
                        } else if ([state[0] doubleValue] <= 64 && dx >= 44 && fabs(dx) > 0.8 * fabs(dy)) {
                            // 往里拖（右移）终结兜底 = App 面板
                            // （2026-10-23 对调后）：起手 ≤64 带内、
                            // 净位移 ≥44、方向比 ≥0.8。比 Moved 提前
                            // 触发宽在起手带、严在位移：慢拖到终点也
                            // 算数，但必须是明确的横向大位移，不捡
                            // App 的普通滑动。
                            fireName = @"czf.dock.openPanel";
                            fireSelector = @"czfOpenAppPanel";
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
                // 点按判定（与漏斗无关，独立记）：Moved 位移超 12pt
                // = 拖动/滚动/手势，不再是点按，直接丢弃；Ended 时
                // 还在 = 真点按，才发置顶信号；Cancelled 不发
                // （手势识别器接管、系统没收的触摸都不是点按）。
                NSArray *tapStart = gCZFTapStarts[key];
                if (tapStart) {
                    CGFloat tapDx = loc.x - [tapStart[0] doubleValue];
                    CGFloat tapDy = loc.y - [tapStart[1] doubleValue];
                    if (touch.phase == UITouchPhaseMoved) {
                        if (fabs(tapDx) > 12 || fabs(tapDy) > 12) {
                            [gCZFTapStarts removeObjectForKey:key];
                        }
                    } else if (touch.phase == UITouchPhaseEnded) {
                        if (fabs(tapDx) <= 12 && fabs(tapDy) <= 12) {
                            NSString *touchBid = [[NSBundle mainBundle] bundleIdentifier];
                            if (touchBid.length > 0) {
                                NSString *touchName = [NSString stringWithFormat:@"czf.window.touch.%@", touchBid];
                                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)touchName, NULL, NULL, YES);
                            }
                        }
                        [gCZFTapStarts removeObjectForKey:key];
                    } else {
                        [gCZFTapStarts removeObjectForKey:key];
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

// 最小化收键盘（游客进程内）：宿主最小化窗口时只藏了宿主侧
// 的视图，游客进程的第一响应者没变，键盘窗口不随视图隐藏
// 而消失，才会盖在宿主界面上。宿主按 bundleId 发 Darwin 信号
// （czf.window.minimize.<bid>，见 DecoratedAppSceneViewController
// 的 minimizeWindow），这里只认自己 bid 的信号，收到就在主
// 线程让本进程所有窗口 endEditing——键盘归属本进程，只有
// 在这里收才收得掉；不碰其他 App 的键盘，之后再点输入框
// 仍能正常弹出（resign 不破坏输入框本身）。
static void CZFKeyboardDismissOnMinimizeCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            [window endEditing:YES];
        }
    });
}

static void CZFKeyboardDismissOnMinimizeInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;
        NSString *signalName = [NSString stringWithFormat:@"czf.window.minimize.%@", bid];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CZFKeyboardDismissOnMinimizeCallback, (__bridge CFStringRef)signalName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

// 由 TweakLoaderConstructor 调用（不是自己的 constructor）：
// 这样禁注入的 App（dontInjectTweakLoader）不会装手势；且没选
// 任何插件的游客也能用手势——手势是启动器自带功能，不是插件。
static void CZFDockGestureInstall(void) {
    @autoreleasepool {
        CZFInstallSendEventHook();
        CZFKeyboardDismissOnMinimizeInstall();
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
