//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"
#import "CZFHitTestLog.h"

@implementation VirtualWindowsHostView
- (instancetype)init {
    UIWindow *keyWindow = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow;
    // CZF 3.8.680：init 时 keyWindow 可能还没就绪（nil.keyWindow.bounds
    // 得 CGRectZero），容器生来就是零框，之后再没人改过它的 frame
    //（全仓 grep 无一处写 windowHostingView.frame）。keyWindow 为空
    // 时用屏幕 bounds 兜底；挂载时 didMoveToSuperview 再按父视图校准。
    CGRect frame = keyWindow ? keyWindow.bounds : UIScreen.mainScreen.bounds;
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;
    return self;
}
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    // CZF 3.8.680：挂载时按父视图 bounds 校准 frame。父视图是
    // keyWindow 根视图的第一个子视图（全屏容器）；init 的 frame 只在
    // keyWindow 就绪时才对，挂载时再校准一次，之后 autoresizing
    //（flexible 宽高）跟随转屏。
    if (self.superview) {
        self.frame = self.superview.bounds;
    }
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if ([super pointInside:point withEvent:event]) {
        return YES;
    }
    // CZF 3.8.680：容器 frame 为零时 super pointInside 恒返 NO，
    // hitTest 根本走不到子视图——小窗看得见、点不到，顶栏按钮、
    // 菜单、拖动全死（3.8.679 日志：HOST-VIEW frameWin=(0,0,0,0)，
    // 子窗 frameWin=(0,62,440,894) 正常、ptInside=1）。
    // 点落在任一可见可交互子视图 frame 内即放行，让 hitTest 走到
    // 子视图；不在任何子窗内仍返 NO，空区继续穿透到宿主 UI
    //（原有 hit==self → nil 设计不变）。
    for (UIView *subview in self.subviews) {
        if (subview.hidden || subview.alpha < 0.01 || !subview.userInteractionEnabled) {
            continue;
        }
        if (CGRectContainsPoint(subview.frame, point)) {
            return YES;
        }
    }
    return NO;
}
- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if(!self.shouldForwardTapAction) return NO;
    // 3.8.900（L580-B1）：只看 lastObject 会漏掉下面的可见窗——
    // 进画中画的窗口只淡出置 hidden=YES，不像普通最小化那样
    // sendSubviewToBack（minimizeWindowPiP 全程没调它，唯一调
    // 的是 minimizeWindow 的 completion）；hidden 的 PiP 窗仍占
    // 着最上层级。下面还露着另一个可见客窗口时，点状态栏只会
    // 看到藏着的 PiP 窗、返 NO 落到宿主自己的回顶，可见的客窗
    // 口永远收不到回顶。改为从最上往下找第一个可见的窗口转发
    //（可见口径与 czfFrontmostApp 同款：!hidden 且 alpha >= 0.1）；
    // 全藏着/没子视图时仍返 NO（L14-3 的语义不变）。
    // L14-3：无子视图时 frontmostView 为 nil，nil.hidden 得 NO、
    // !NO 得 YES，等于谎称已处理、实际什么都没干，LC 自己的列表点
    // 状态栏回顶就此失效；子视图 hidden 时返 NO（落到 super）才是对的，
    // 没子视图也该返 NO。3.8.495（L14）
    for (UIView *candidate in self.subviews.reverseObjectEnumerator) {
        if (candidate.hidden || candidate.alpha < 0.1) continue;
        DecoratedAppSceneViewController *decoratedVC = (id)candidate._viewDelegate;
        if (![decoratedVC isKindOfClass:[DecoratedAppSceneViewController class]]) continue;
        [decoratedVC.appSceneVC handleStatusBarTapAction:action];
        return YES;
    }
    return NO;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    // P0 hitTest 诊断（3.8.676）：只记日志，行为一字不动。
    // 这一行出现 = 触摸走到了宿主窗的 hitTest；hitView==self
    // 时返 nil（触摸穿到宿主 App），否则返命中的子视图。
    [CZFHitTestLog czfHitTestLogLine:[NSString stringWithFormat:@"HOST-HIT pt=%@ hit=%@ fwd=%d", [CZFHitTestLog czfPointString:point], hitView ? NSStringFromClass([hitView class]) : @"nil", (int)(hitView != self)]];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        return hitView;
    }
}
@end
