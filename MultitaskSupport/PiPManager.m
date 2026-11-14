//
//  PiPManager.m
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
#include "PiPManager.h"
#include "AppSceneViewController.h"
#include "DecoratedAppSceneViewController.h"
#include "../LiveContainer/utils.h"

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
    [self.pipController stopPictureInPicture];
    if(self.displayingVC) {
        [self.displayingDecoratedVC unminimizeWindowPiP];
        [self pictureInPictureControllerDidStopPictureInPicture:self.pipController];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self.pipController isPictureInPictureActive] * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
            [self.pipController startPictureInPicture];
        });
    });

}

- (void)stopPiP {
    // C2：同步清残留标志，不再全靠异步 WillStop 回调——
    // 回调漏掉时标志永久残留，此后全部场景更新被丢。
    // WillStop 到时还会再清一次，幂等。
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.pipController stopPictureInPicture];
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
    [self czfRemoveBoundsObserverForController:pictureInPictureController];
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.displayingDecoratedVC unminimizeWindowPiP];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    [self.displayingVC.view insertSubview:self.displayingVC.contentView atIndex:0];
    [self.displayingVC setBackgroundNotificationEnabled:true];
    // resize if needed (eg orientation differs)
    [self.displayingDecoratedVC updateVerticalConstraints];
    
    self.pipVideoCallContentView.transform = CGAffineTransformIdentity;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoEndPiP"]) {
        self.pipController = nil;
        self.pipVideoCallViewController = nil;
    }
    // 3.8.496（L15）：直接调 DidStop 切会话时（startPiPWithVC）WillStop
    // 未必跑过，这里兜底拆掉该会话的登记；正常流程里 WillStop 已拆，
    // 这里是空操作。
    [self czfRemoveBoundsObserverForController:pictureInPictureController];
    // FIXME: HostingController path causes a tiny flicker during transition to and from PiP.
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    // 3.8.496（L15）：WillStart 已跑、启动失败时没有 WillStop，登记不
    // 清会一直挂着，下次该 VC 被释放时 KVO 释放异常；这里拆掉。
    // 没跑过 WillStart 时找不到登记，是空操作。
    [self czfRemoveBoundsObserverForController:pictureInPictureController];
    NSLog(@"%@", error.description);
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(NSObject*)object change:(NSDictionary<NSString *,id> *) change context:(void *) context {
    // 3.8.496（L15）：displayingVC 已改 weak——客窗关掉、VC 释放后它
    // 自动置空；此时再收到 bounds 变化直接返回，否则 nil.contentView
    // 的 bounds 是零宽，除零会把 transform 算成 NaN。
    if (!self.displayingVC) return;
    CGRect rect = [change[@"new"] CGRectValue];
    CGFloat scale = self.displayingVC.usesHostingControllerAPI ? self.displayingVC.scaleRatio : 1;
    CGAffineTransform transform1 = CGAffineTransformScale(CGAffineTransformIdentity, rect.size.width / self.displayingVC.contentView.bounds.size.width/scale,rect.size.height /self.displayingVC.contentView.bounds.size.height/scale);
    self.pipVideoCallContentView.transform = transform1;
}

@end
