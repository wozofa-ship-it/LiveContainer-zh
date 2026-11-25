//
//  PiPManager.m
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
#include "PiPManager.h"
#include "AppSceneViewController.h"
#include "DecoratedAppSceneViewController.h"
#include "../../LiveContainer/utils.h"

API_AVAILABLE(ios(16.0))
@interface PiPManager()
@property(nonatomic, strong) UIView *pipVideoCallContentView;
@property(nonatomic, strong) AVPictureInPictureVideoCallViewController *pipVideoCallViewController;
@property(nonatomic, strong) AVPictureInPictureController *pipController;
@property(nonatomic, weak) AppSceneViewController* displayingVC;
// 3.8.496（L15）：bounds KVO 按会话登记（控制器→当时观察的 layer）。
// displayingVC 原来是 assign：窗口关掉、VC 释放后它就悬空，
// 下次进 PiP 的 if(self.displayingVC) 会读野指针；改 weak 自动置空。
@property(nonatomic, strong) NSMapTable<AVPictureInPictureController *, CALayer *> *pipObservedLayers;
// 3.8.900（L601-B#1）：待发 PiP 启动的序号 + 待发目标——startPiPWithVC
// 有 0.3 秒外层延时 + 0.3 秒内层延时，客在这段里死掉时内层仍会把
// 浮窗弹出来（isPictureInPictureActive 恒 NO，全部停 PiP 收尾都
// 够不到待发启动）；序号让迟到的块自废，目标让退出回调能定向作废。
@property(nonatomic) NSInteger czfPendingPiPStartSeq;
@property(nonatomic, weak) AppSceneViewController *czfPendingPiPVC;
@end


@implementation PiPManager
API_AVAILABLE(ios(16.0))
static PiPManager* sharedInstance = nil;

+ (instancetype)shared {
    if(!sharedInstance)
        sharedInstance = [[self alloc] init];
    return sharedInstance;
}

- (DecoratedAppSceneViewController *)displayingDecoratedVC {
    return (id)self.displayingVC.delegate;
}

- (BOOL)isPiP {
    return self.pipController.isPictureInPictureActive;
}

- (BOOL)isPiPWithVC:(AppSceneViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingVC == vc;
}

- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingDecoratedVC == vc;
}

- (instancetype)init {
    NSError* error = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    [[AVAudioSession sharedInstance] setActive:YES withOptions:1 error:&error];
    self.pipObservedLayers = [NSMapTable strongToStrongObjectsMapTable];
    return self;
}

- (void)startPiPWithVC:(AppSceneViewController*)vc {
    // 3.8.900（L601-B#1）：待发启动记序号（见属性注释）；新一次启动/
    // stopPiP/退出回调作废都会 +1，迟到的外层/内层块凭序号自废。
    self.czfPendingPiPStartSeq += 1;
    NSInteger czfSeq = self.czfPendingPiPStartSeq;
    self.czfPendingPiPVC = vc;
    [self.pipController stopPictureInPicture];
    if(self.displayingVC) {
        [self.displayingDecoratedVC unminimizeWindowPiP];
        [self pictureInPictureControllerDidStopPictureInPicture:self.pipController];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self.pipController isPictureInPictureActive] * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (czfSeq != self.czfPendingPiPStartSeq) return;
        self.displayingVC = vc;
        self.pipVideoCallViewController = [AVPictureInPictureVideoCallViewController new];
        self.pipVideoCallViewController.preferredContentSize = vc.view.bounds.size;
        if(vc.usesHostingControllerAPI) {
            self.pipVideoCallContentView = [[UIView alloc] initWithFrame:self.pipVideoCallViewController.view.bounds];
            //self.pipVideoCallContentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.pipVideoCallContentView.layer.anchorPoint = CGPointMake(0, 0);
            self.pipVideoCallContentView.layer.position = CGPointMake(0, 0);
            [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
        } else {
            self.pipVideoCallContentView = vc.contentView;
        }
        AVPictureInPictureControllerContentSource* contentSource =  [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:vc.view contentViewController:self.pipVideoCallViewController];
        self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        self.pipController.delegate = self;
        [self.pipController setValue:@1 forKey:@"controlsStyle"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 3.8.900（L601-B#1）：启动前再验——序号已作废（又点了
            // 别的 PiP/stopPiP/客已退出）或客已死/窗口已拆时放弃，
            // 不弹一张死画面的浮窗；pid 未落位的新窗读作未在跑，
            // 但 0.6 秒延时后 pid 早已落位，误拦面极小，点 PiP 重试即可。
            if (czfSeq != self.czfPendingPiPStartSeq) return;
            AppSceneViewController *czfVC = self.displayingVC;
            if (!czfVC || !czfVC.view.window || !czfVC.isAppRunning) return;
            [self.pipController startPictureInPicture];
        });
    });

}

- (void)stopPiP {
    // 3.8.900（L601-B#1）：作废待发启动（见 startPiPWithVC）——
    // 待发期内 pipController 还没激活，stopPictureInPicture
    // 拦不住内层块，不加序号它照样弹出来。
    self.czfPendingPiPStartSeq += 1;
    self.czfPendingPiPVC = nil;
    // C2：同步清残留标志，不再全靠异步 WillStop 回调——
    // 回调漏掉时标志永久残留，此后全部场景更新被丢。
    // WillStop 到时还会再清一次，幂等。
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.pipController stopPictureInPicture];
}

// 3.8.900（L601-B#1）：客退出时定向作废待发启动——只有待发目标
// 恰是退出的这个 VC 时才 +1，别家窗口待发的 PiP 不动；外层延时
// 还没跑到时 displayingVC 还是旧值，够不到那路，但内层启动前
// 的 isAppRunning 检查兜底（客已死必拦）。
- (void)czfCancelPendingPiPStartForVC:(AppSceneViewController *)vc {
    if (vc && self.czfPendingPiPVC == vc) {
        self.czfPendingPiPStartSeq += 1;
        self.czfPendingPiPVC = nil;
    }
}

// PIP delegate
// 3.8.496（L15）：bounds KVO 按会话登记、按会话注销——WillStart/WillStop
// 是一一配对的，但 stopPictureInPicture 的 WillStop 是异步回调，切画中
// 画时新会话的 WillStart 可能先跑（startPiPWithVC 里新 VC 在 0.3 秒后
// 才建，WillStop 正常先到，但主线程卡住 0.3 秒以上就会反过来）；L14-2
// 那种“WillStop 里直接对当前 VC 的 layer 拆观察者”会在错位时对从未注
// 册过的 layer 调 removeObserver，直接抛 NSRangeException 崩。
// 改按控制器分键记下当时观察的 layer，WillStop/failedToStart/DidStop
// 都只拆自己那个会话的登记，错位的回调找不到登记就是空操作。
- (void)czfRemoveBoundsObserverForController:(AVPictureInPictureController *)pictureInPictureController {
    // 3.8.497（L16）：controller 可能为 nil——LCAutoEndPiP 开着时
    // DidStop 会把 pipController 置 nil，但 displayingVC 还留着，
    // 下次 startPiPWithVC 会直接调 DidStop(nil) 走到这里；
    // NSMapTable 的 nil 键查询行为未写进文档（NSDictionary 同款
    // 会抛异常），先守空再查表。
    if (!pictureInPictureController) return;
    CALayer *layer = [self.pipObservedLayers objectForKey:pictureInPictureController];
    if (layer) {
        [layer removeObserver:self forKeyPath:@"bounds"];
        [self.pipObservedLayers removeObjectForKey:pictureInPictureController];
    }
}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // L57-1：回调只认当前会话——startPiPWithVC 切新会话后旧控制器的
    // 迟到 WillStart 会把新会话的 contentView 挪走、把新窗口最小化；
    // 新控制器的 WillStart 恒过（startPiPWithVC 先赋值 self.pipController
    // 再调 startPictureInPicture，见该函数）。KVO 登记按控制器 key
    // 记，错会话的重复 WillStart 不重复注册（L15），守卫与它不冲突。
    if (pictureInPictureController != self.pipController) return;
    // 3.8.900（L569-4）：displayingVC 是 weak，点 PiP 后
    // 0.6 秒里关窗（或客进程自己死了）会把它置空——下面托管
    // 路径往非空内容视图里 addSubview:nil 内容视图，直接抛
    // NSInvalidArgumentException、宿主跟着闪退；WillStart
    // 晚到一步就直接放弃，PiP 本来也已没了。observeValue
    // 同款守空（L15）。
    if (!self.displayingVC) return;
    [self.displayingDecoratedVC minimizeWindowPiP];
    if(self.displayingVC.usesHostingControllerAPI) {
        self.pipVideoCallContentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
        self.pipVideoCallViewController.additionalSafeAreaInsets = self.displayingVC.view.safeAreaInsets;
        [self.pipVideoCallContentView addSubview:self.displayingVC.contentView];
    } else {
        self.displayingVC.contentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
    }
    [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
    // 3.8.496（L15）：按会话登记（见 czfRemoveBoundsObserverForController
    // 注释）；同一控制器只登记一次，重复 WillStart 不重复注册。
    CALayer *pipLayer = self.pipVideoCallViewController.view.layer;
    if (![self.pipObservedLayers objectForKey:pictureInPictureController]) {
        [pipLayer addObserver:self
                   forKeyPath:@"bounds"
                      options:NSKeyValueObservingOptionNew
                      context:NULL];
        [self.pipObservedLayers setObject:pipLayer forKey:pictureInPictureController];
    }
    self.pipVideoCallViewController.preferredContentSize = self.displayingVC.view.bounds.size;
    [self.displayingVC setBackgroundNotificationEnabled:false];
    self.displayingVC.shouldIgnoreSceneUpdates = YES;
}



- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // L14-2 + L15：WillStart 里注册的 bounds KVO 观察者，这里必须注销；
    // 否则 LCAutoEndPiP 开着时 DidStop 把 VC 置 nil、layer 释放时观察者还
    // 在册，KVO 释放异常崩溃。L15 改按会话登记拆（见 helper 注释），
    // 错位的 WillStop 不会误拆新会话的 layer。3.8.495（L14）/3.8.496（L15）
    // L57-1：KVO 注销无条件跑（只拆该控制器的登记），但其余工作只认
    // 当前会话——旧控制器的迟到 WillStop 会清新会话的 shouldIgnoreSceneUpdates、
    // 把新画中画的窗口取消最小化。
    [self czfRemoveBoundsObserverForController:pictureInPictureController];
    if (pictureInPictureController != self.pipController) return;
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.displayingDecoratedVC unminimizeWindowPiP];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // 3.8.496（L15）：直接调 DidStop 切会话时（startPiPWithVC）WillStop
    // 未必跑过，这里兜底拆掉该会话的登记；正常流程里 WillStop 已拆，
    // 这里是空操作。
    [self czfRemoveBoundsObserverForController:pictureInPictureController];
    // L57-1：只认当前会话——旧控制器的迟到 DidStop 会把新会话的
    // contentView 插回旧 VC、把新 pipController 置 nil（LCAutoEndPiP
    // 开着时），画中画直接丢了。注销放最前、守卫放其后，错会话的
    // 登记照样拆干净。
    if (pictureInPictureController != self.pipController) return;
    [self.displayingVC.view insertSubview:self.displayingVC.contentView atIndex:0];
    [self.displayingVC setBackgroundNotificationEnabled:true];
    // resize if needed (eg orientation differs)
    [self.displayingDecoratedVC updateVerticalConstraints];
    
    self.pipVideoCallContentView.transform = CGAffineTransformIdentity;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoEndPiP"]) {
        self.pipController = nil;
        self.pipVideoCallViewController = nil;
    }
    // FIXME: HostingController path causes a tiny flicker during transition to and from PiP.
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    // 3.8.496（L15）：WillStart 已跑、启动失败时没有 WillStop，登记不
    // 清会一直挂着，下次该 VC 被释放时 KVO 释放异常；这里拆掉。
    // 没跑过 WillStart 时找不到登记，是空操作。
    [self czfRemoveBoundsObserverForController:pictureInPictureController];
    NSLog(@"%@", error.description);
    // 3.8.900（L565-4）：WillStart 已跑、启动失败时没有 WillStop/
    // DidStop——WillStart 已把窗口最小化（hidden=YES）、iOS 18+ 托管
    // 路径把 contentView 从客 VC 视图里挪进 PiP 内容视图、还置了
    // shouldIgnoreSceneUpdates=YES、关了后台通知；失败回调只拆 KVO，
    // 窗口直接消失，坞里点回是空窗（contentView 还挂在已死的 PiP VC
    // 里）。按 WillStop+DidStop 的逆操作恢复：只认当前会话（L57-1
    // 同款守卫，错会话的迟到失败不碰新会话）；displayingVC 已释放时
    // 全是 nil 消息，空操作。pipController 不置 nil，用户可再点 PiP
    // 重试（DidStop 那路的 LCAutoEndPiP 清理是正常结束才走的，不照搬）。
    if (pictureInPictureController != self.pipController) return;
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.displayingDecoratedVC unminimizeWindowPiP];
    [self.displayingVC.view insertSubview:self.displayingVC.contentView atIndex:0];
    [self.displayingVC setBackgroundNotificationEnabled:true];
    [self.displayingDecoratedVC updateVerticalConstraints];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(NSObject*)object change:(NSDictionary<NSString *,id> *) change context:(void *) context {
    // 3.8.496（L15）：displayingVC 已改 weak——客窗关掉、VC 释放后它
    // 自动置空；此时再收到 bounds 变化直接返回，否则 nil.contentView
    // 的 bounds 是零宽，除零会把 transform 算成 NaN。
    if (!self.displayingVC) return;
    CGRect rect = [change[@"new"] CGRectValue];
    CGFloat scale = self.displayingVC.usesHostingControllerAPI ? self.displayingVC.scaleRatio : 1;
    // L57-2：contentView 尚未布局时 bounds 是零宽（view 刚建、窗口还没
    // 上屏就进 PiP），零除会把 transform 算成 inf/NaN，画中画内容缩没
    // 或渲染异常；scaleRatio 是滑条值，同样守 0。L15 只守了 displayingVC
    // 为 nil 一半（那时 nil.contentView 的 bounds 也是零宽），VC 在但
    // contentView 零宽这一半没守。
    CGFloat contentW = self.displayingVC.contentView.bounds.size.width;
    CGFloat contentH = self.displayingVC.contentView.bounds.size.height;
    if (contentW == 0 || contentH == 0 || scale == 0) return;
    CGAffineTransform transform1 = CGAffineTransformScale(CGAffineTransformIdentity, rect.size.width / contentW / scale, rect.size.height / contentH / scale);
    self.pipVideoCallContentView.transform = transform1;
}

@end
