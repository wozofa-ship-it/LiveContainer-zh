//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"

@implementation VirtualWindowsHostView
- (instancetype)init {
    CGRect frame = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.bounds;
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;
    return self;
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
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        return hitView;
    }
}
@end
