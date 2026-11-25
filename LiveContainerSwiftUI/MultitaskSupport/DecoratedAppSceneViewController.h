#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface DecoratedAppSceneViewController : UIViewController<AppSceneViewControllerDelegate>
@property(nonatomic) AppSceneViewController* appSceneVC;
@property(nonatomic) UIStackView *view;
@property(nonatomic) UINavigationBar *navigationBar;
@property(nonatomic) UINavigationItem *navigationItem;
@property(nonatomic) UIView *resizeHandle;
@property(nonatomic) UIView* contentView;

@property(nonatomic) BOOL isMaximized;
@property(nonatomic) CGFloat scaleRatio;
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC;
- (void)minimizeWindow;
- (void)maximizeWindow;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)closeWindow;
// 最小化省电（CZF）：窗口被叫回台前时清最小化标记、恢复前台。
// Swift 侧 animateViewAppearance（带取消隐藏的通用恢复路）调用。
- (void)czfRestoreFromMinimize;
- (void)updateVerticalConstraints;
@property(nonatomic, copy) void (^pidAvailableHandler)(NSNumber *pid, NSError *error);
@end

