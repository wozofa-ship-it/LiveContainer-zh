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
    
    // 手势是启动器自带功能，不是插件：禁注入的 App 也要装，
    // 否则全屏（无标题栏、无栏）时没有任何手势入口，最小化
    // 都没法做；禁注入只跳过下面第三方插件的加载，不动这里。
    CZFDockGestureInstall();

    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }
    
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
// 逐窗识别器：单例 handler 原来只用两个 ivar 存最近一次装的
// pan/cancel，多窗口时后装的窗口会覆盖先装的，delegate 里按
// ivar 比对就认错窗（A 窗的 cancel 被当成观察 pan 等）；改
// 成跟 installed 标志一样挂在窗口自己身上，各窗各认各的。
static const void *kCZFDockGesturePanKey = &kCZFDockGesturePanKey;
static const void *kCZFDockGestureCancelKey = &kCZFDockGestureCancelKey;
// 起手位置：0=不在边缘 1=左边缘 2=右边缘（shouldReceive 时记录，handler 里判定）
static NSInteger gCZFStartEdge = 0;
// 起手高度是否在启用带内：边缘手势只认屏幕高度 70%–90% 一段
//（=距底部 10%–30%，2026-10-24 用户红圈定，别再放中间，
// 与宿主中档同值；上下两段不调防误触）
static BOOL gCZFStartInBand = YES;
// 起手高度是否在往外弹专用带内：用户 2026-11-03 令往外弹
// 高度跟 App 面板一样——即上面普通带 70%–90%（原往外弹带
// 0.55–0.93 已废）；只给左缘往外弹（→源面板）用，往里拖
// 与右边缘一律不认它。
static BOOL gCZFStartInOutwardBand = YES;
// 起手是否真正碰到左边缘（用户 2026-11-02 亲令“面板碰到边缘
// 才调出来”）：往里拖（App 面板）只认起手 x ≤ 20pt 的滑动
// （2026-11-02 用户让往边缘里面放宽一点，16→20pt）；App 内
// 从 20pt 开外的横滑（视频切集、横向滚动）一律不触发，治误
// 触。终结兜底“落点贴边 12”不动；右边缘切 App 不走面板，
// 不用它。
static const CGFloat kCZFEdgeTouchMax = 20;
// 往外弹起手带：44pt（18bfbe5 之前的值，用户亲证丝滑）。
// 20pt 只认拇指正贴边，用户实测“靠边边才能调出来”——拇指
// 贴边时质心本来就在 15–35pt，偏里一点就死。往外弹放宽
// 到 44pt 后，防误触靠左移方向 + 落点贴边/速度判据，不靠
// 起手带；往里拖与拦截器仍用 20pt（不动）。
static const CGFloat kCZFEdgeOutwardMax = 44;
static BOOL gCZFStartAtEdge = NO;
// 起手 x（shouldReceive 时记录）：终结位移跟起手位置挂钩用——
// 贴边起手（≤20pt，见 kCZFEdgeTouchMax）左移行程物理上只有
// 几 pt，终结门槛不能跟离边起手一样（用户 2026-11-04 令，2 号机制修）。
static CGFloat gCZFStartX = 0;
// 本次滑动是否已触发过（一次滑动只触发一次）
static BOOL gCZFFired = NO;

// 起手点落在控件/滑块类视图上时，两路手势都不接（与宿主
// 侧 czfTouchOnControlOrSlider 同款）：视频进度条在底部
// 横跨全屏，边缘起手横拖会误触发；拦截器不接，App 那路
// 触摸就不会被取消，观察 pan 不接，面板信号也不会发。
// 顺着触摸视图往上查祖先：UIControl 全算，类名含
// slider/scrub/seek/progress 的自定义进度条也算。
static BOOL CZFTouchOnControlOrSlider(UITouch *touch) {
    UIView *view = touch.view;
    while (view) {
        if ([view isKindOfClass:[UIControl class]]) return YES;
        NSString *name = [NSStringFromClass([view class]) lowercaseString];
        if ([name rangeOfString:@"slider"].location != NSNotFound ||
            [name rangeOfString:@"scrub"].location != NSNotFound ||
            [name rangeOfString:@"seek"].location != NSNotFound ||
            [name rangeOfString:@"progress"].location != NSNotFound) return YES;
        view = view.superview;
    }
    return NO;
}

// 只认滑块/进度条类（拖动会冲突的那种），普通按钮不算——
// 边缘按钮上的滑动要放行（与宿主侧同款）。
static BOOL CZFTouchOnSliderOrProgress(UITouch *touch) {
    UIView *view = touch.view;
    while (view) {
        if ([view isKindOfClass:[UISlider class]]) return YES;
        NSString *name = [NSStringFromClass([view class]) lowercaseString];
        if ([name rangeOfString:@"slider"].location != NSNotFound ||
            [name rangeOfString:@"scrub"].location != NSNotFound ||
            [name rangeOfString:@"seek"].location != NSNotFound ||
            [name rangeOfString:@"progress"].location != NSNotFound) return YES;
        view = view.superview;
    }
    return NO;
}

// 边缘带拦截识别器（手势双触发修正）：只负责一件事——起手
// 在边缘带（左 16pt / 右 44pt 内 + 高度 70%–90%，见 shouldReceiveTouch
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
}
+ (instancetype)shared;
- (void)installOnWindow:(UIWindow *)window;
- (void)czfPostNotification:(NSString *)notificationName selectorName:(NSString *)selectorName;
@end

// 左缘往外 flick 判据（灵敏修法，不动高度带）：
// 贴边起手（往外弹带 ≤44pt，见 kCZFEdgeOutwardMax）+ 净左移
// （仅作方向确认，≥2pt）+ 左向速度 ≥300pt/s。旧判据 dx ≤ -8
// 是写错的根因：手指起于边缘、往外没有行程——拇指贴边时
// 质心本来就在 15–20pt，往左一共只能移几 pt 就离屏，8pt
// 行程根本凑不齐，纯左滑全被判掉（右滑再左滑才活：右滑
// 先腾出 room，左扫净位移才够 8pt）。速度才是 flick 的信号：
// 300pt/s 左向快扫不是 App 内容操作（竖滑横向速度不够、
// 慢拖速度不够）；velX 必须带符号（≤ -300）：只认左向速度，
// 右向折返（净位移仍为负、速度已转正）不得误触发。
// velX 来源：pan 路用 velocityInView（瞬时速度），漏斗路
// 用最后一段位移除以时间（见 CZFFunnelObserve）。
static BOOL CZFIsOutwardFlick(NSInteger startEdge, BOOL startInOutwardZone, CGFloat dx, CGFloat velX) {
    return startEdge == 1 && startInOutwardZone && dx <= -2 && velX <= -300;
}

// 取消即往外意图（只给 pan Cancelled 用，不给 Ended 用；256起不再验落点）：
// 手指被 App 仲裁取消或滑出左边缘时，位移已无从再长——
// 只要起于左缘、净左移 ≥2pt、横向
// 过 0.2 底线，就认往外意图。误触代价只是一次面板开合
// （可滑回），且去重（0.4/1.0s）兜底。漏斗 Ended/Cancelled
// 共用同一分支，分不清取消与抬手，故漏斗不走这条，只走
// 下面的终结判据（用户 2026-11-04 令，2 号机制修）。
static BOOL CZFIsOutwardCancelled(NSInteger startEdge, CGFloat dx, CGFloat dy) {
    return startEdge == 1 && dx <= -2 && fabs(dx) > 0.2 * fabs(dy);
}

// 终结时贴边往外判据（漏斗 Ended 与 pan Cancelled 共用）：
// 手指起于往外弹带（≤44pt，见 kCZFEdgeOutwardMax）、净左移
// ≥3/6pt（跟起手位置挂钩，见下）且横向分量过 0.2 底线。终结态才
// 有落点信息，比实时门槛（0.9）宽松是合理的：纯竖滑横向位移不够，进不来；拇指弧线纵向分量大的慢速往外滑，0.2
// 能接住、0.4 接不住（251 的 flick 只接快速的，慢速仍漏）。
// 实时门槛不动，免得中途抢滚动。
// 2026-11-04 256修：往外弹不再验落点贴边——endX ≤ 12 等价于
// 行程 ≥ 起手x-12，起手 40pt 的短滑永远够不着，这才是 255
// 之后仍不灵敏的根因（用户模型是“往左滑”，不是“滑出屏幕”）。
// 边缘起手（≤44pt）+ 带内 + 左移 + 方向比已足够；误触代价
// 只是开合面板，可滑回。
static BOOL CZFIsOutwardEnded(NSInteger startEdge, BOOL startInOutwardZone, CGFloat dx, CGFloat dy, CGFloat startX) {
    CGFloat need = (startX <= kCZFEdgeTouchMax) ? 3 : 6;
    return startEdge == 1 && startInOutwardZone && dx <= -need && fabs(dx) > 0.2 * fabs(dy);
}

// 终结兜底判定（与宿主 processGlobalSwipeFallback 同参）：贴边
// flick 被 App 仲裁取消、或全程方向比过不了严判时，只看物理
// 结果——净位移方向 + 落点贴边。右边缘此前没有兜底（触摸漏斗
// 只管左边缘），轻扫经常被取消导致不跟手，本次补齐。
// startInBand：起手是否在普通启用带内——往外弹分支本身不验
// 它，调用点门槛保证起手在带内（往外弹带已与普通带同值，
// 用户 2026-11-03 令）；往里拖与右边缘两个方向在分支内验它。
// startAtEdge：起手是否贴边（≤20pt）——往里拖要求它，App 内
// 滑动不触发；往外弹不要求它（进 startEdge==1 分支即 ≤44pt
// 往外弹带，见 kCZFEdgeOutwardMax）；右边缘两个方向不用它。
static BOOL CZFPanFallback(NSInteger startEdge, CGPoint translation, CGFloat endX, CGFloat width, BOOL startInBand, BOOL startAtEdge, CGFloat startX, NSString **outName, NSString **outSelector) {
    CGFloat dx = translation.x;
    CGFloat dy = translation.y;
    if (startEdge == 1) {
        // 2026-10-23 真机纠正后对调：往外弹（左移）= 源面板，
        // 往里拖（右移）= App 面板；门槛跟着物理方向走。
        // 往外弹起手带已放宽到 44pt（见 kCZFEdgeOutwardMax）：
        // 进 startEdge==1 分支即 ≤44，不再另验 20pt 贴边；
        // 往里拖仍验 20pt 贴边（不动）。
        // 2026-11-04 2 号机制修：同终结判据，位移门槛跟起手
        // 位置挂钩——贴边起手（≤20pt）只认 3pt，离边维持 8pt。
        // 256修：往外弹不再验落点贴边（同终结判据的理由）。
        CGFloat outwardNeed = (startX <= kCZFEdgeTouchMax) ? 3 : 8;
        if (dx <= -outwardNeed && fabs(dx) > 0.4 * fabs(dy)) {
            *outName = @"czf.dock.openSources";
            *outSelector = @"czfOpenSourcesPanel";
            return YES;
        }
        if (startInBand && startAtEdge && dx >= 44 && fabs(dx) > 0.8 * fabs(dy)) {
            *outName = @"czf.dock.openPanel";
            *outSelector = @"czfOpenAppPanel";
            return YES;
        }
    } else if (startEdge == 2) {
        if (startInBand && dx >= 8 && endX >= width - 12 && fabs(dx) > 0.4 * fabs(dy)) {
            *outName = @"czf.dock.rightOutward";
            *outSelector = @"czfEdgeRightOutward";
            return YES;
        }
        if (startInBand && dx <= -44 && fabs(dx) > 0.8 * fabs(dy)) {
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
    objc_setAssociatedObject(window, kCZFDockGesturePanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [window addGestureRecognizer:pan];
    // 拦截识别器与观察 pan 同窗共存：只接边缘带起手，认了即
    // 取消 App 触摸；面板信号仍由观察 pan 按严门槛发
    CZFEdgeCancelRecognizer *cancel = [[CZFEdgeCancelRecognizer alloc] initWithTarget:self action:@selector(czfCancelPanFired:)];
    cancel.cancelsTouchesInView = YES;
    cancel.delegate = self;
    objc_setAssociatedObject(window, kCZFDockGestureCancelKey, cancel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [window addGestureRecognizer:cancel];
}

// 拦截识别器动作：只负责取消 App 触摸，不发信号
- (void)czfCancelPanFired:(UIGestureRecognizer *)gesture {
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIWindow *window = (UIWindow *)gestureRecognizer.view;
    if (![window isKindOfClass:[UIWindow class]]) return NO;
    // 控件/进度条起手：观察 pan 与拦截器都不接——拦截器
    // 不接就不会取消 App 触摸，进度条拖动完整归 App。
    // 但边缘起手且落在普通控件（按钮等）上时放行：点按无
    // 位移不会触发，滑动则进手势——否则边缘被按钮盖住时
    // 左滑全死；滑块/进度条仍拦。
    if (CZFTouchOnControlOrSlider(touch)) {
        CGPoint edgeLoc = [touch locationInView:window];
        BOOL atEdge = (edgeLoc.x <= 44 || edgeLoc.x >= window.bounds.size.width - 44);
        if (!(atEdge && !CZFTouchOnSliderOrProgress(touch))) {
            gCZFStartEdge = 0;
            gCZFStartX = 0;
            return NO;
        }
    }
    CGPoint loc = [touch locationInView:window];
    CGFloat width = window.bounds.size.width;
    CGFloat height = window.bounds.size.height;
    // 身份按本窗挂的识别器认，不按单例 ivar（多窗口覆盖已修）。
    CZFEdgeCancelRecognizer *cancelPan = objc_getAssociatedObject(window, kCZFDockGestureCancelKey);
    if (gestureRecognizer == cancelPan) {
        // 拦截器只接边缘带起手：左边缘贴边 16pt 内（与面板触发
        // 同值，免得 App 内滑动被白白取消）、右边缘 44pt 内 +
        // 高度 70%–90%；其余一律不接，App 完全不受影响；
        // 全局变量只归观察 pan 写，不碰
        BOOL inBand = (loc.y >= height * 0.70 && loc.y <= height * 0.90);
        return inBand && (loc.x <= kCZFEdgeTouchMax || loc.x >= width - 44);
    }
    gCZFStartInBand = (loc.y >= height * 0.70 && loc.y <= height * 0.90);
    // 往外弹带恢复收窄前的好用值 0.55–0.93（用户 2026-11-04
    // 令：左往左滑根本不好用，检查好修复；11-03 收窄到跟
    // App 面板一致后左滑大半高度认不出）；拦截器分支（上
    // 面）仍只认普通带——放宽取消区会误取消 App 触摸，往外
    // 弹不需要取消 App 触摸，故不动它。
    gCZFStartInOutwardBand = (loc.y >= height * 0.55 && loc.y <= height * 0.93);
    // 面板只认贴边起手（见文件头 kCZFEdgeTouchMax 注释）
    gCZFStartAtEdge = (loc.x <= kCZFEdgeTouchMax);
    // 全部接收、只记录起手位置；是否触发在 handler 按起手+位移判定
    if (loc.x >= width - 44) {
        gCZFStartEdge = 2;
    } else if (loc.x <= 44) {
        gCZFStartEdge = 1;
    } else {
        gCZFStartEdge = 0;
    }
    gCZFStartX = loc.x;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 拦截器只跟同窗的观察 pan 共存：共存观察 pan 才能在拦截认了
    // 之后继续按严门槛追踪发面板信号；对 App 的识别器一律
    // 不同时，拦截一认 App 那路就失败（滚动/返回停住）。
    // 观察 pan 维持原样全放行。身份按本窗挂的识别器认。
    UIWindow *gestureWindow = (UIWindow *)gestureRecognizer.view;
    CZFEdgeCancelRecognizer *cancelPan = [gestureWindow isKindOfClass:[UIWindow class]] ? objc_getAssociatedObject(gestureWindow, kCZFDockGestureCancelKey) : nil;
    UIPanGestureRecognizer *observerPan = [gestureWindow isKindOfClass:[UIWindow class]] ? objc_getAssociatedObject(gestureWindow, kCZFDockGesturePanKey) : nil;
    if (gestureRecognizer == cancelPan) {
        return otherGestureRecognizer == observerPan;
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
        // CZFPanFallback），判完清状态；往外弹带起手的取消也
        // 走兜底，往里拖/右边缘仍要求普通带（见函数内）。
        if (!gCZFFired && gCZFStartEdge != 0 && (gCZFStartInBand || gCZFStartInOutwardBand)) {
            NSString *name = nil;
            NSString *selector = nil;
            // 被仲裁取消的往外滑：flick（快速）与终结贴边
            // （慢速弧线，见 CZFIsOutwardEnded）各判一次，
            // 再走原兜底；三路都不中才是真没滑。
            CGPoint czfCancelVelocity = [gesture velocityInView:gesture.view];
            if (CZFIsOutwardFlick(gCZFStartEdge, gCZFStartEdge == 1, [gesture translationInView:gesture.view].x, czfCancelVelocity.x)) {
                [self czfPostNotification:@"czf.dock.openSources" selectorName:@"czfOpenSourcesPanel"];
            } else if (CZFIsOutwardEnded(gCZFStartEdge, gCZFStartEdge == 1, [gesture translationInView:gesture.view].x, [gesture translationInView:gesture.view].y, gCZFStartX)) {
                [self czfPostNotification:@"czf.dock.openSources" selectorName:@"czfOpenSourcesPanel"];
            } else if (CZFPanFallback(gCZFStartEdge, [gesture translationInView:gesture.view], [gesture locationInView:gesture.view].x, gesture.view.bounds.size.width, gCZFStartInBand, gCZFStartAtEdge, gCZFStartX, &name, &selector)) {
                [self czfPostNotification:name selectorName:selector];
            } else if (CZFIsOutwardCancelled(gCZFStartEdge, [gesture translationInView:gesture.view].x, [gesture translationInView:gesture.view].y)) {
                [self czfPostNotification:@"czf.dock.openSources" selectorName:@"czfOpenSourcesPanel"];
            }
        }
        gCZFFired = NO;
        return;
    }
    if (gCZFFired) return;
    if (gesture.state != UIGestureRecognizerStateChanged && gesture.state != UIGestureRecognizerStateEnded) return;
    // 启用带外起手的边缘滑动不调（任意位置起手不受此限）；
    // 往外弹带起手的也放行，方向分支里再拦往里拖/右边缘。
    if (gCZFStartEdge != 0 && !gCZFStartInBand && !gCZFStartInOutwardBand) return;
    CGPoint translation = [gesture translationInView:gesture.view];
    CGFloat endX = [gesture locationInView:gesture.view].x;
    CGFloat width = gesture.view.bounds.size.width;
    if (gesture.state == UIGestureRecognizerStateEnded) {
        // 终结兜底先于严判：落点贴边+净位移够就认；严判的方向比
        // 留给滑动中的提前触发
        NSString *name = nil;
        NSString *selector = nil;
        if (CZFPanFallback(gCZFStartEdge, translation, endX, width, gCZFStartInBand, gCZFStartAtEdge, gCZFStartX, &name, &selector)) {
            gCZFFired = YES;
            [self czfPostNotification:name selectorName:selector];
            return;
        }
    }
    // 方向比：往外弹（左缘左移/右缘右移）物理行程短、拇指走
    // 弧线纵向分量大，1.5 倍会把大半次弹滑判掉（用户真机反馈
    // 左缘往左弹很不灵敏），往外方向放宽到 0.9；其余维持 1.5
    BOOL czfOutward = (gCZFStartEdge == 1 && translation.x < 0) || (gCZFStartEdge == 2 && translation.x > 0);
    // 往外 flick 不走方向比（见 CZFIsOutwardFlick）：拇指弧线
    // 纵向分量大，方向比会把离屏 flick 判掉；慢速竖滑漂移
    // 速度不够，不会误触。只放行左缘往外，其余方向照旧。
    CGPoint czfVelocity = [gesture velocityInView:gesture.view];
    BOOL czfOutwardFlick = CZFIsOutwardFlick(gCZFStartEdge, gCZFStartEdge == 1, translation.x, czfVelocity.x);
    if (!czfOutwardFlick && fabs(translation.x) < (czfOutward ? 0.9 : 1.5) * fabs(translation.y)) return;
    BOOL draggingRight = translation.x > 0;
    CGFloat absX = fabs(translation.x);
    NSString *notificationName = nil;
    NSString *selectorName = nil;
    if (gCZFStartEdge == 2) {
        // 起手在右边缘：往左=上一个已打开 App，往右=下一个已打开
        // App（门槛往左24、往右6，往外滑手指很快出屏）；宿主侧改派
        // 右边缘不放宽：往外弹带起手的右边缘滑动到这里直接返回。
        if (!gCZFStartInBand) return;
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
        // 方向，门槛保持严，宁可多滑一点也不抢 App 的指令，
        // 且只认 20pt 贴边起手（见 kCZFEdgeTouchMax 注释）；
        // 往外弹（手指左移，门槛6，flick 不走位移门槛）= 源面板
        // ——往外弹起手带已放宽到 44pt（见 kCZFEdgeOutwardMax），
        // 进本分支即 ≤44，不再另验 20pt 贴边（20pt 只认拇指
        // 正贴边，用户实测“靠边边才能调出来”）。
        // 往外弹带已与普通带同值（用户 2026-11-03 令）：往里
        // 拖验普通带；往外弹由 handler 入口的带门保证（两带
        // 同值，即普通带）。
        if (draggingRight) {
            if (!gCZFStartAtEdge) return;
            if (!gCZFStartInBand) return;
            if (absX <= 30) return;
            notificationName = @"czf.dock.openPanel";
            selectorName = @"czfOpenAppPanel";
        } else {
            // flick 不走位移门槛：速度已证明是快扫，边缘起手
            // 的 flick 行程只有几 pt，6pt 门槛会把它判掉（纯
            // 左滑死的根因之二）；非 flick 仍要 >6pt 防误触。
            if (!czfOutwardFlick && absX <= 6) return;
            notificationName = @"czf.dock.openSources";
            selectorName = @"czfOpenSourcesPanel";
        }
    } else {
        // 任意位置起手：只有拖到屏幕边缘、位移够大才算隐藏（防误触）；
        // 拖到右边缘切 App 也要起手在带内（跟左边一样，gCZFStartInBand
        // 由 shouldReceiveTouch 对观察 pan 写好）；往左拖到边藏栏维持原样
        if (absX <= 50) return;
        if (draggingRight && gCZFStartInBand && endX >= width - 30) {
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
                // 记录带放宽到 96：抬手兜底规则需要它。高度带：
                // 用户 2026-11-03 令往外弹高度跟 App 面板一样，
                // 记录带即普通带 0.70–0.90（原往外弹带 0.55–
                // 0.93 已废）；第 4 位记起手是否在普通带内——记
                // 录带既已等于普通带，录入的触摸该位恒为真，
                // 字段留着不动结构。触发起手带见各分支（往里拖
                // 20pt、往外弹 44pt）。
                CGFloat winHeight = window.bounds.size.height;
                if (loc.x <= 96 && loc.y >= winHeight * 0.70 && loc.y <= winHeight * 0.90) {
                    BOOL inOldBand = (loc.y >= winHeight * 0.70 && loc.y <= winHeight * 0.90);
                    // 后三位记最后一段位移的起点（终结时算 flick
                    // 速度用）：起手时最后一段就是起手本身。
                    gCZFTouchStates[key] = @[ @(loc.x), @(loc.y), @NO, @(inOldBand), @(loc.x), @(loc.y), @(touch.timestamp) ];
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
                if (touch.phase == UITouchPhaseMoved && state && ![state[2] boolValue]) {
                    // 记最后一段位移的起点（终结时算 flick 速度
                    // 用）：只改后三位，起手与 fired 标志不动，
                    // 判定仍用起手算的净位移。
                    gCZFTouchStates[key] = @[ state[0], state[1], state[2], state[3], @(loc.x), @(loc.y), @(touch.timestamp) ];
                }
                if (state && ![state[2] boolValue]) {
                    CGFloat dx = loc.x - [state[0] doubleValue];
                    CGFloat dy = loc.y - [state[1] doubleValue];
                    NSString *fireName = nil;
                    NSString *fireSelector = nil;
                    if (touch.phase == UITouchPhaseMoved) {
                        // 提前触发（严判定防误触）：往外弹带起手（≤44pt，
                        // 见 kCZFEdgeOutwardMax）、往外弹（左移）8、
                        // 横向占优 = 源面板（2026-10-23 对调后）
                        if ([state[0] doubleValue] <= kCZFEdgeOutwardMax && dx <= -8 && fabs(dx) > 0.9 * fabs(dy)) {
                            fireName = @"czf.dock.openSources";
                            fireSelector = @"czfOpenSourcesPanel";
                        } else if ([state[0] doubleValue] <= kCZFEdgeTouchMax && dx >= 36 && fabs(dx) > 1.5 * fabs(dy) && [state[3] boolValue]) {
                            // 往里拖（右移）= App 面板（2026-10-23
                            // 对调后）：全屏下与 App 的边缘返回/横滑
                            // 共用这条轨迹，防冲突全靠收紧——起手只认
                            // 贴边 16pt、位移 ≥36、方向比 1.5（与 pan
                            // 路径一致）；App 中部起手的横滑根本不进
                            // 记录，进了带的慢拖也过不了方向比。
                            fireName = @"czf.dock.openPanel";
                            fireSelector = @"czfOpenAppPanel";
                        }
                    } else {
                        // 终结兜底（看物理结果，不看轨迹）：拇指弧线在下
                        // 半屏轨迹偏斜，方向比会把整段滑动判掉；起手贴边
                        // （≤16pt）、最终落点贴到边缘 12 内、净位移往左
                        // ≥8，就是一次滑出左边缘 = 源面板（2026-10-23
                        // 对调后；门槛原为 15，起手贴边时物理行程总共就
                        // 十几 pt、大半次滑够不着，真机反馈不灵敏）。
                        // 终结判据（见 CZFIsOutwardEnded）：落点在
                        // 贴边 + 横向分量过 0.2 底线（纯竖滑落点
                        // 不在贴边，进不来）；0.4 接不住拇指弧线
                        // 大的慢速往外滑，251 的 flick 只接快速的。
                        // 终结 flick 速度（见 CZFIsOutwardFlick）：最后
                        // 一段位移除以时间，dt ≤ 0 时记 0（只走终
                        // 结判据那条）；起手贴边已由外层条件保证，
                        // 这里直接复用同一判据，不另写门槛。
                        NSTimeInterval czfFunnelDt = touch.timestamp - [state[6] doubleValue];
                        CGFloat czfFunnelVelX = (czfFunnelDt > 0) ? ((loc.x - [state[4] doubleValue]) / czfFunnelDt) : 0;
                        BOOL czfFunnelAtEdge = ([state[0] doubleValue] <= kCZFEdgeOutwardMax);
                        if (CZFIsOutwardEnded(1, czfFunnelAtEdge, dx, dy, [state[0] doubleValue]) || CZFIsOutwardFlick(1, czfFunnelAtEdge, dx, czfFunnelVelX)) {
                            fireName = @"czf.dock.openSources";
                            fireSelector = @"czfOpenSourcesPanel";
                        } else if ([state[0] doubleValue] <= kCZFEdgeTouchMax && dx >= 44 && fabs(dx) > 0.8 * fabs(dy) && [state[3] boolValue]) {
                            // 往里拖（右移）终结兜底 = App 面板
                            // （2026-10-23 对调后）：起手 ≤16pt、
                            // 净位移 ≥44、方向比 ≥0.8。与 Moved 提前
                            // 触发同认贴边起手，严在位移：慢拖到终点也
                            // 算数，但必须是明确的横向大位移，不捡
                            // App 的普通滑动。
                            fireName = @"czf.dock.openPanel";
                            fireSelector = @"czfOpenAppPanel";
                        }
                    }
                    if (fireName) {
                        gCZFTouchStates[key] = @[ state[0], state[1], @YES, state[3], state[4], state[5], state[6] ];
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

// 最小化收键盘（游客进程内，宿主信号的第二层，见
// DecoratedAppSceneViewController 的 czfDismissKeyboard）：
// 宿主最小化窗口时只藏了宿主侧的视图，游客进程的第一
// 响应者没变，键盘窗口不随视图隐藏而消失，才会盖在宿
// 主界面上。收到信号就在主线程让本进程所有窗口
// endEditing——之后再点输入框仍能正常弹出（resign 不破
// 坏输入框本身）。
// 订阅两个名字：全局 czf.window.minimize 是本轮主信号，
// 不依赖 bid——上一轮只订阅按 bid 的名字，但宿主发的
// bid 实际是相对包路径文件夹名（见 Decorated 注释），
// 和这里的 mainBundle.bundleIdentifier 永远对不上，信
// 号发了等于没发；全局名下每个游客只收自己窗口的键
// 盘，没键盘的游客 endEditing 是空操作，不误伤别的 App。
// 按 bid 的旧名字也留着，兼容其它可能按 bid 发信号的宿主。
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
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CZFKeyboardDismissOnMinimizeCallback, (__bridge CFStringRef)@"czf.window.minimize", NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;
        NSString *signalName = [NSString stringWithFormat:@"czf.window.minimize.%@", bid];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CZFKeyboardDismissOnMinimizeCallback, (__bridge CFStringRef)signalName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

// 由 TweakLoaderConstructor 调用（不是自己的 constructor）：
// 手势是启动器自带功能，不是插件，故无条件安装——禁注入的
// App 也要装（禁注入只跳过第三方插件的加载）；否则禁注入
// App 全屏（无标题栏、无栏）时没有任何手势入口，最小化都
// 没法做。且没选任何插件的游客也能用手势。
static void CZFDockGestureInstall(void) {
    @autoreleasepool {
        CZFInstallSendEventHook();
        CZFKeyboardDismissOnMinimizeInstall();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[UIWindow class]]) {
                [[CZFDockGestureHandler shared] installOnWindow:(UIWindow *)note.object];
            }
        }];
        // 窗口出现触发点：只成 key 不够——有些窗口出现时并不成
        // key（例如先出现的非 key 窗），DidBecomeKey 永远等不到；
        // 出现即装，装过的不重复装（installed 标志幂等）。
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
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
