#import "DecoratedAppSceneViewController.h"
#import "ResizeHandleView.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "AppSceneViewController.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "PiPManager.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/Localization.h"
#import "utils.h"

@interface DecoratedAppSceneViewController()
@property(nonatomic) NSArray* activatedVerticalConstraints;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) NSString* bundleId;
@property(nonatomic) int pid;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) UIBarButtonItem *maximizeButton;
@property(nonatomic) bool isAppTerminationRequested;
@property(nonatomic) BOOL czfRestoreApplied;
@end

@implementation DecoratedAppSceneViewController
- (instancetype)initWindowName:(NSString*)windowName bundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID rootVC:(UIViewController*)rootVC {
    self = [super initWithNibName:nil bundle:nil];
    self.view = [[UIStackView alloc] initWithFrame:self.view.frame];
    [MultitaskDockManager.shared.windowHostingView addSubview:self.view];
    [rootVC addChildViewController:self];
    
    _dataUUID = dataUUID;
    _bundleId = bundleId;
    _scaleRatio = 1.0;
    _isMaximized = [NSUserDefaults.lcUserDefaults boolForKey:@"LCLaunchMultitaskMaximized"];
    _appSceneVC = [[AppSceneViewController alloc] initWithBundleId:bundleId dataUUID:dataUUID delegate:self];
    self.title = windowName;
    [self setupDecoratedView];
    
    [MultitaskDockManager.shared addRunningApp:windowName appUUID:dataUUID view:self.view];
    
    NSArray *menuItems = @[
        [UIAction actionWithTitle:@"lc.multitask.copyPid".loc image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction * _Nonnull action) {
            UIPasteboard.generalPasteboard.string = @(self.appSceneVC.pid).stringValue;
        }],
        [UIAction actionWithTitle:@"lc.multitask.enablePip".loc image:[UIImage systemImageNamed:@"pip.enter"] identifier:nil handler:^(UIAction * _Nonnull action) {
            if ([PiPManager.shared isPiPWithVC:self.appSceneVC]) {
                [PiPManager.shared stopPiP];
            } else {
                [PiPManager.shared startPiPWithVC:self.appSceneVC];
            }
        }],
        [UICustomViewMenuElement elementWithViewProvider:^UIView *(UICustomViewMenuElement *element) {
            return [self scaleSliderViewWithTitle:@"lc.multitask.scale".loc min:0.5 max:2.0 value:self.scaleRatio stepInterval:0.01];
        }]
    ];
    

    __weak typeof(self) weakSelf = self;
    [self.navigationItem setTitleMenuProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions){
        if(!weakSelf.appSceneVC.isAppRunning) {
            return [UIMenu menuWithTitle:NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", nil) children:@[]];
        } else {
            NSString *pidText = [NSString stringWithFormat:@"PID: %d", weakSelf.pid];
            return [UIMenu menuWithTitle:pidText children:menuItems];
        }
    }];
    
    UIImage *minimizeImage = [UIImage systemImageNamed:@"minus.circle"];
    UIImageConfiguration *minimizeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
    minimizeImage = [minimizeImage imageWithConfiguration:minimizeConfig];
    UIBarButtonItem *minimizeButton = [[UIBarButtonItem alloc] initWithImage:minimizeImage style:UIBarButtonItemStylePlain target:self action:@selector(minimizeWindow)];
    minimizeButton.tintColor = [UIColor systemYellowColor];
    
    NSString *maximizeImageName = _isMaximized ? @"arrow.down.right.and.arrow.up.left.circle" : @"arrow.up.left.and.arrow.down.right.circle";
    UIImage *maximizeImage = [UIImage systemImageNamed:maximizeImageName];
    UIImageConfiguration *maximizeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
    maximizeImage = [maximizeImage imageWithConfiguration:maximizeConfig];
    self.maximizeButton = [[UIBarButtonItem alloc] initWithImage:maximizeImage style:UIBarButtonItemStylePlain target:self action:@selector(maximizeWindow)];
    self.maximizeButton.tintColor = [UIColor systemGreenColor];
    
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark.circle"];
    UIImageConfiguration *closeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
    closeImage = [closeImage imageWithConfiguration:closeConfig];
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithImage:closeImage style:UIBarButtonItemStylePlain target:self action:@selector(closeWindow)];
    closeButton.tintColor = [UIColor systemRedColor];
    
    NSArray *barButtonItems = @[closeButton, self.maximizeButton, minimizeButton];
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
        // resize handle overlaps the close button, so put the buttons on the left
        self.navigationItem.leftBarButtonItems = barButtonItems;
    } else {
        self.navigationItem.rightBarButtonItems = barButtonItems;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-8.0 rightMargin:-4.0];
    });

    return self;
}

// MARK: - 窗口状态还原（CZF）
// 关窗/最大化切换/拖动结束时，把窗口的小窗尺寸、归一化位置
// 和全屏状态按 bundleId 存进 lcUserDefaults；下次打开这个
// App 时在 setupDecoratedView 里还原。设置页开关
// CZFRestoreWindowState（键不存在 = 开）控制。
- (BOOL)czfRestoreEnabled {
    NSUserDefaults *d = NSUserDefaults.lcUserDefaults;
    return [d objectForKey:@"CZFRestoreWindowState"] == nil || [d boolForKey:@"CZFRestoreWindowState"];
}

- (NSString *)czfWindowStateKey {
    return [NSString stringWithFormat:@"CZFWinState-%@", self.bundleId ?: self.dataUUID];
}

- (NSDictionary *)czfSavedWindowState {
    if (![self czfRestoreEnabled] || !self.bundleId) {
        return nil;
    }
    return [NSUserDefaults.lcUserDefaults dictionaryForKey:[self czfWindowStateKey]];
}

// 把存的归一化原点反算成实际 frame：必须用系统自己的约定
// （原点 = 归一化值 × maxFrame 尺寸，不加安全区原点偏移——
// updateOriginalFrame 存的时候就是这么存的，加了偏移反而错位）
- (CGRect)czfDenormalizedFrameForState:(NSDictionary *)state {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    if (CGRectIsEmpty(maxFrame)) {
        maxFrame = UIScreen.mainScreen.bounds;
    }
    CGFloat w = [state[@"w"] doubleValue];
    CGFloat h = [state[@"h"] doubleValue];
    CGFloat ox = [state[@"nx"] doubleValue] * maxFrame.size.width;
    CGFloat oy = [state[@"ny"] doubleValue] * maxFrame.size.height;
    // 夹回可见范围：换过方向/屏幕时别把窗口放飞
    CGRect winBounds = CGRectIsEmpty(self.view.window.bounds) ? UIScreen.mainScreen.bounds : self.view.window.bounds;
    ox = MAX(-w + 60, MIN(ox, winBounds.size.width - 60));
    oy = MAX(0, MIN(oy, winBounds.size.height - 60));
    return CGRectMake(ox, oy, w, h);
}

// 还原的真正落点：窗口建好之后，启动方（LCUtils）会把窗口
// 无条件摆到屏幕正中，setupDecoratedView 里设的 frame 当场被
// 覆盖——这就是前两版大小对、位置永远回正中的根因。改在
// App 初始化完成时再按存的状态摆一次（一次性），这时没人再动它
- (void)czfApplySavedWindowStateIfNeeded {
    if (self.czfRestoreApplied) {
        return;
    }
    self.czfRestoreApplied = YES;
    NSDictionary *savedState = [self czfSavedWindowState];
    if (!savedState || [savedState[@"max"] boolValue]) {
        return;
    }
    CGFloat w = [savedState[@"w"] doubleValue];
    CGFloat h = [savedState[@"h"] doubleValue];
    if (w < 100 || h < 100) {
        return;
    }
    self.view.frame = [self czfDenormalizedFrameForState:savedState];
}

- (void)czfSaveWindowState {
    if (![self czfRestoreEnabled] || !self.bundleId) {
        return;
    }
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    if (CGRectIsEmpty(maxFrame)) {
        return;
    }
    CGFloat nx, ny, w, h;
    if (self.isMaximized) {
        // 最大化时小窗的样子在 originalFrame 里（原点已归一化）
        nx = self.originalFrame.origin.x;
        ny = self.originalFrame.origin.y;
        w = self.originalFrame.size.width;
        h = self.originalFrame.size.height;
    } else {
        // 位置统一从 originalFrame 读：先让系统自己的
        // updateOriginalFrame 按它那套参照系（安全区内的
        // maxFrame）把当前帧刷进去，存取同一套算法，
        // 不再自己另算一套（上一版存时按 maxFrame 归一化、
        // 恢复时按整屏反算，参照系不一致，大小对位置偏）
        [self updateOriginalFrame];
        nx = self.originalFrame.origin.x;
        ny = self.originalFrame.origin.y;
        w = self.originalFrame.size.width;
        h = self.originalFrame.size.height;
    }
    if (w < 50 || h < 50) {
        return;
    }
    NSDictionary *state = @{@"nx": @(nx), @"ny": @(ny), @"w": @(w), @"h": @(h), @"max": @(self.isMaximized)};
    [NSUserDefaults.lcUserDefaults setObject:state forKey:[self czfWindowStateKey]];
}

- (void)setupDecoratedView {
    CGFloat navBarHeight = 44;
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(UIApp.statusBarOrientation);
    CGRect frame = CGRectMake(0, 0, isLandscape ? 480 : 320, (isLandscape ? 320 : 480) + navBarHeight);
    CGPoint rootViewCenter = self.view.superview.center;
    frame.origin = CGPointMake(rootViewCenter.x - frame.size.width / 2, rootViewCenter.y - frame.size.height / 2);

    // 有上次关窗时存的窗口状态就还原它（取代默认居中尺寸）
    NSDictionary *savedState = [self czfSavedWindowState];
    BOOL restored = NO;
    if (savedState) {
        CGFloat sw = [savedState[@"w"] doubleValue];
        CGFloat sh = [savedState[@"h"] doubleValue];
        if (sw >= 100 && sh >= 100) {
            restored = YES;
            _isMaximized = [savedState[@"max"] boolValue];
            if (_isMaximized) {
                self.originalFrame = CGRectMake([savedState[@"nx"] doubleValue], [savedState[@"ny"] doubleValue], sw, sh);
            } else {
                // 这里先摆一次（马上会被启动方的居中覆盖，真
                // 正生效的是初始化完成时 czfApplySavedWindowState
                // 的那一次，两边用同一个反算函数保持一致）
                frame = [self czfDenormalizedFrameForState:savedState];
                self.view.frame = frame;
            }
        }
    }

    if (!restored) {
        if(_isMaximized) {
            CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
            // save origin as normalized coordinates
            frame.origin.x /= maxFrame.size.width;
            frame.origin.y /= maxFrame.size.height;
            self.originalFrame = frame;
        } else {
            self.view.frame = frame;
        }
    }
    
    // Navigation bar
    UINavigationBar *navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, navBarHeight)];
    navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UINavigationItem *navigationItem = [[UINavigationItem alloc] initWithTitle:self.title];
    navigationBar.items = @[navigationItem];
    
    self.view.axis = UILayoutConstraintAxisVertical;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.layer.cornerRadius = 10;
    self.view.layer.masksToBounds = YES;

    self.navigationBar = navigationBar;
    self.navigationItem = navigationBar.items.firstObject;
    if (!self.navigationBar.superview) {
        [self.view addArrangedSubview:self.navigationBar];
    }
    
    CGRect contentFrame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height - navBarHeight);
    UIView *fixedPositionContentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"]) {
        [self.view insertArrangedSubview:fixedPositionContentView atIndex:0];
    } else {
        [self.view addArrangedSubview:fixedPositionContentView];
    }
    [self.view sendSubviewToBack:fixedPositionContentView];
    
    self.contentView = [[UIView alloc] initWithFrame:contentFrame];
    self.contentView.layer.anchorPoint = self.contentView.layer.position = CGPointMake(0, 0);
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fixedPositionContentView addSubview:self.contentView];
    
    UIPanGestureRecognizer *moveGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveWindow:)];
    moveGesture.minimumNumberOfTouches = 1;
    moveGesture.maximumNumberOfTouches = 1;
    [self.navigationBar addGestureRecognizer:moveGesture];

    // 双击标题栏切换最大化/还原（maximizeWindow 本身就是切换式）
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(czfTitleBarDoubleTap)];
    doubleTap.numberOfTapsRequired = 2;
    [self.navigationBar addGestureRecognizer:doubleTap];

    // Resize handle (idea stolen from Notes debugging window)
    UIPanGestureRecognizer *resizeGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(resizeWindow:)];
    resizeGesture.minimumNumberOfTouches = 1;
    resizeGesture.maximumNumberOfTouches = 1;
    self.resizeHandle = [[ResizeHandleView alloc] initWithFrame:CGRectMake(self.view.frame.size.width - navBarHeight, self.view.frame.size.height - navBarHeight, navBarHeight, navBarHeight)];
    self.resizeHandle.alpha = _isMaximized ? 0.0 : 1.0;
    [self.resizeHandle addGestureRecognizer:resizeGesture];
    [self.view addSubview:self.resizeHandle];

    // 点按置顶（用户定 2026-10-25）：几个小窗口叠在一起时，点哪个
    // 窗口露出的边角就把哪个顶到最上、不被压住。原来 touchesBegan
    // 那条路收不到游客内容（passthrough view）的触摸——触摸直接
    // 进了游客场景；改走手势识别器：识别器挂在容器视图上，游客
    // 内容的触摸也会经过它；只观察不拦截（cancelsTouchesInView=NO），
    // 不改窗口大小和状态，只调层级。标题栏双击最大化不受影响
    // （单击置顶是空操作级，不等双击判定）。
    UITapGestureRecognizer *raiseTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(czfRaiseWindowOnTap)];
    raiseTap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:raiseTap];
    
    self.view.layer.borderWidth = _isMaximized ? 0.0 : 1.0;
    self.view.layer.borderColor = UIColor.secondarySystemBackgroundColor.CGColor;
    
    [self addChildViewController:_appSceneVC];
    [self.view insertSubview:_appSceneVC.view atIndex:0];
    _appSceneVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self updateVerticalConstraints];
    [NSLayoutConstraint activateConstraints:@[
        [_appSceneVC.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_appSceneVC.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    
    
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;

    [defaults addObserver:self forKeyPath:@"LCMultitaskBottomWindowBar" options:NSKeyValueObservingOptionNew context:NULL];
    [self updateOriginalFrame];
}


// Stolen from UIKitester
- (UIView *)scaleSliderViewWithTitle:(NSString *)title min:(CGFloat)minValue max:(CGFloat)maxValue value:(CGFloat)initialValue stepInterval:(CGFloat)step {
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.exclusiveTouch = YES;

    UIStackView *stackView = [[UIStackView alloc] init];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = 0.0;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:stackView];
    
    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:10.0],
        [stackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8.0],
        [stackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-16.0]
    ]];
    
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont boldSystemFontOfSize:12.0];
    [stackView addArrangedSubview:label];
    
    _UIPrototypingMenuSlider *slider = [[_UIPrototypingMenuSlider alloc] init];
    slider.minimumValue = minValue;
    slider.maximumValue = maxValue;
    slider.value = initialValue;
    slider.stepSize = step;
    
    NSLayoutConstraint *sliderHeight = [slider.heightAnchor constraintEqualToConstant:40.0];
    sliderHeight.active = YES;
    
    [stackView addArrangedSubview:slider];
    
    [slider addTarget:self action:@selector(scaleSliderChanged:) forControlEvents:UIControlEventValueChanged];
    
    return containerView;
}

- (void)scaleSliderChanged:(_UIPrototypingMenuSlider *)slider {
    self.scaleRatio = slider.value;
    self.appSceneVC.scaleRatio = _scaleRatio;
    if(self.appSceneVC.usesHostingControllerAPI) {
        self.appSceneVC.contentView.transform = CGAffineTransformMakeScale(_scaleRatio, _scaleRatio);
    } else {
        self.appSceneVC.contentView.layer.sublayerTransform = CATransform3DMakeScale(_scaleRatio, _scaleRatio, 1.0);
    }
    __weak typeof(self) weakSelf = self;
    [self.appSceneVC updateFrameWithSettingsBlock:^(UIMutableApplicationSceneSettings *settings) {
        if(weakSelf.isMaximized) {
            [weakSelf updateMaximizedSafeAreaWithSettings:settings];
        } else {
            // it seems some apps don't honor these settings so we don't cover the top of the app
            settings.peripheryInsets = UIEdgeInsetsZero;
            settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
        }
    }];
}

// 收键盘（宿主侧，三个层次缺一不可，上一轮只做了其中
// 半层才没生效）：
// 1) 本视图 + 游客场景视图 endEditing：宿主侧能摸到的
//    响应者链就这两处，单做本视图没用——游客内容不在本
//    视图的响应者链里；
// 2) sendAction resignFirstResponder：键盘焦点在 iOS 18+
//    托管场景下由宿主的事件转交组件（见 AppSceneViewController
//    的事件转交注释）代理，第一响应者实际挂在宿主进程，
//    向空目标发 resign 才能摸到它；只靠游客进程内 endEditing
//    摸不到这一层；
// 3) Darwin 信号：新游客（TweakLoader 含全局信号观察者）
//    收到后在自己进程内 endEditing；老游客（v184 前启动、
//    TweakLoader 里没新观察者）和禁注入 App（TweakLoader
//    的 constructor 直接 return，见 TweakLoader.m）收不到
//    信号，只能靠上面两层宿主侧收——所以信号只是补刀，
//    不能是唯一手段。
// 信号名改发全局 czf.window.minimize，不再只发按 bid 的：
// 上一轮按 self.bundleId 发，但这个 bundleId 来自启动时
// UserDefaults 的 selected，实际是相对包路径（如 Muse.app
// 这类文件夹名，见 LCUtils 的 launchMultitaskGuestApp 与
// LCAppModel 的 selected 赋值），而游客观察者按
// mainBundle.bundleIdentifier（真实 CFBundleIdentifier）
// 订阅，两边名字永远对不上，信号发了等于没发。全局名不
// 依赖 bid：每个游客只收自己窗口的键盘，没键盘的游客
// endEditing 是空操作，不会误伤别的 App；旧按 bid 的名
// 字也一并发出，兼容其它可能在听它的旧实现。
// 调用方都在主线程（按钮动作、Dock 的 main async），不
// 在这里再切线程。
- (void)czfDismissKeyboard {
    [self.view endEditing:YES];
    if (self.appSceneVC.view) {
        [self.appSceneVC.view endEditing:YES];
    }
    [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)@"czf.window.minimize", NULL, NULL, YES);
    if (self.bundleId.length > 0) {
        NSString *minimizeName = [NSString stringWithFormat:@"czf.window.minimize.%@", self.bundleId];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)minimizeName, NULL, NULL, YES);
    }
}

- (void)closeWindow {
    // 关窗前记下窗口状态，下次打开还原（用户要的核心点）
    [self czfDismissKeyboard];
    [self czfSaveWindowState];
    _isAppTerminationRequested = true;
    if([_appSceneVC isAppRunning]) {
        [_appSceneVC terminate];
    } else {
        [self appSceneVCAppDidExit:self.appSceneVC];
    }
}

- (void)minimizeWindow {
    if (self.view.hidden) return;
    // 最小化先收键盘：只藏窗口视图收不掉键盘——键盘窗口
    // 不随本视图隐藏而消失，游客切最小化后键盘会继续盖在
    // 宿主界面上。动画开始前就收，键盘边收边淡出，不用等
    // 0.3 秒动画跑完；具体分层见 czfDismissKeyboard 注释。
    // 注意：本函数是所有“窗口消失、宿主界面露出来”的必经
    // 之路——快捷栏最小化全部（MultitaskDockManager 的
    // minimizeAllWindows）、面板的最小化打开、LCMaxOneAppOnStage
    // 的自动最小化都调它；视频里从全屏游客回宿主 App 页
    // 也是点标题栏的最小化按钮走这里，没有别的路能把宿
    // 主页顶到全屏游客前面（顶层切换只会把游客窗口带到
    // 前面，见 MultitaskDockManager 的 bringMultitaskViewToFront）。
    [self czfDismissKeyboard];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
        self.view.transform = CGAffineTransformMakeScale(0.1, 0.1);
    } completion:^(BOOL finished) {
        if (!finished) return;
        self.view.hidden = YES;
        self.view.transform = CGAffineTransformIdentity;
        [self.view.superview sendSubviewToBack:self.view];
    }];
}

- (void)minimizeWindowPiP {
    // PiP 也一样收键盘：上一轮这条路完全没动，画中画
    // 起来后键盘同样会盖在宿主界面上；PiP 视频本身不受
    // resign 影响（只收第一响应者，不改场景前后台）。
    [self czfDismissKeyboard];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha = 0;
    } completion:^(BOOL finished) {
        self.view.hidden = YES;
    }];
}

- (void)unminimizeWindowPiP {
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.hidden = NO;
        self.view.alpha = 1;
    } completion:nil];
}

- (void)maximizeWindow {
    void (^updateSettingsBlock)(UIMutableApplicationSceneSettings *settings);
    
    [self.view layoutIfNeeded];
    if (self.isMaximized) {
        updateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [self updateWindowedFrameWithSettings:settings];
        };
        CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
        CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.view.frame = newFrame;
            self.view.layer.borderWidth = 1;
            self.resizeHandle.alpha = 1;
            
            [self.appSceneVC updateSettingsWithBlock:updateSettingsBlock];
            
            [self.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            self.isMaximized = NO;
            [self czfSaveWindowState];
            // 还原成小窗口后必须重算标题栏显隐：最大化时若快捷栏是
            // 收起的，栏被自动藏了（沉浸全屏）；不重算的话还原后栏
            // 永久卡在隐藏——拖动和最大/最小化按钮都在栏上，窗口
            // 就成了拖不动、关不掉的死窗。最大化分支有重算，还原
            // 分支漏了，这里补上。
            [self updateVerticalConstraints];
            UIImage *maximizeImage = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right.circle"];
            UIImageConfiguration *maximizeConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
            self.maximizeButton.image = [maximizeImage imageWithConfiguration:maximizeConfig];
        }];
    } else {
        updateSettingsBlock = ^(UIMutableApplicationSceneSettings *settings) {
            [self updateMaximizedFrameWithSettings:settings];
        };
        [self updateOriginalFrame];
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.isMaximized = YES;
            [self updateVerticalConstraints];
            
            self.view.layer.borderWidth = 0;
            self.resizeHandle.alpha = 0;
            
            [self.appSceneVC updateSettingsWithBlock:updateSettingsBlock];
            
            [self.view layoutIfNeeded];
        } completion:^(BOOL finished) {
            [self czfSaveWindowState];
            UIImage *restoreImage = [UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left.circle"];
            UIImageConfiguration *restoreConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightMedium];
            self.maximizeButton.image = [restoreImage imageWithConfiguration:restoreConfig];
        }];
    }
}

- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc {
    BOOL skipTerminationScreen = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCSkipTerminatedScreen"];
    BOOL isManual = _isAppTerminationRequested;
    if(isManual || skipTerminationScreen) {
        
        MultitaskDockManager *dock = [MultitaskDockManager shared];
        [dock removeRunningApp:self.dataUUID];
        
        self.view.layer.masksToBounds = NO;
        [UIView transitionWithView:self.view duration:0.4 options:UIViewAnimationOptionTransitionCurlUp animations:^{
            self.view.hidden = YES;
        } completion:^(BOOL b){
            [self.view removeFromSuperview];
        }];
        
        if(skipTerminationScreen) {
            [MultitaskRelaunchManager scheduleRelaunchIfNeededWithBundleId:self.appSceneVC.bundleId dataUUID:self.dataUUID isManualTermination:isManual];
        }
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.view.bounds];
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        label.lineBreakMode = NSLineBreakByWordWrapping;
        label.numberOfLines = 0;
        label.text = NSLocalizedString(@"lc.multitaskAppWindow.appTerminated", @"");
        label.textAlignment = NSTextAlignmentCenter;
        [self.view insertSubview:label atIndex:0];
    }
}

- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(error) {
            [vc appTerminationCleanUp];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"lc.common.error".loc message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"lc.common.copy".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                UIPasteboard.generalPasteboard.string = error.localizedDescription;
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            self.pid = vc.pid;
            // 先把窗口摆回上次关窗时的位置（启动方在建窗后
            // 强制居中过，这里摆脱它），再让系统按这个 frame
            // 刷新 originalFrame，后续场景更新都以此为准
            [self czfApplySavedWindowStateIfNeeded];
            [self updateOriginalFrame];
            if (self.pidAvailableHandler) {
                self.pidAvailableHandler(@(self.pid), nil);
            }
        }
    });
}

- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc {
    // Set up initial settings such as frame, safe area, etc
    [self appSceneVC:vc didUpdateFromSettings:vc.presenter.scene.settings.mutableCopy transitionContext:nil lifecycleActionType:0];
}

- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)baseSettings transitionContext:(id)newContext lifecycleActionType:(uint32_t)actionType {
    [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
        settings.userInterfaceStyle = baseSettings.userInterfaceStyle;
        settings.interfaceOrientation = baseSettings.interfaceOrientation;
        settings.deviceOrientation = baseSettings.deviceOrientation;
        settings.foreground = YES;
        
        if(self.isMaximized) {
            [self updateMaximizedFrameWithSettings:settings];
        } else {
            [self updateWindowedFrameWithSettings:settings];
        }
        CGRect newFrame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - self.navigationBar.frame.size.height/self.scaleRatio);
        
        if(UIInterfaceOrientationIsLandscape(baseSettings.interfaceOrientation)) {
            settings.frame = CGRectMake(0, 0, newFrame.size.height, newFrame.size.width);
        } else {
            settings.frame = CGRectMake(0, 0, newFrame.size.width, newFrame.size.height);
        }
    }];
}

- (void)adjustNavigationBarButtonSpacingWithNegativeSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    if (!self.navigationBar) return;
    [self findAndAdjustButtonBarStackView:self.navigationBar withSpacing:spacing rightMargin:margin];
}

- (void)findAndAdjustButtonBarStackView:(UIView *)view withSpacing:(CGFloat)spacing rightMargin:(CGFloat)margin {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:NSClassFromString(@"_UIButtonBarStackView")]) {
            if ([subview respondsToSelector:@selector(setSpacing:)]) {
                [(_UIButtonBarStackView *)subview setSpacing:spacing];
            }
            
            if (subview.superview) {
                for (NSLayoutConstraint *constraint in subview.superview.constraints) {
                    if ((constraint.firstItem == subview && constraint.firstAttribute == NSLayoutAttributeTrailing) ||
                        (constraint.secondItem == subview && constraint.secondAttribute == NSLayoutAttributeTrailing)) {
                        constraint.constant = (constraint.firstItem == subview) ? -margin : margin;
                        break;
                    }
                }
                
                [subview setNeedsLayout];
                [subview.superview setNeedsLayout];
            }
            
            return;
        }
        
        [self findAndAdjustButtonBarStackView:subview withSpacing:spacing rightMargin:margin];
    }
}


- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        BOOL bottomWindowBar = [change[NSKeyValueChangeNewKey] boolValue];
        if(bottomWindowBar) {
            self.navigationItem.leftBarButtonItems = self.navigationItem.rightBarButtonItems;
            self.navigationItem.rightBarButtonItems = nil;
            [self.view addArrangedSubview:self.navigationBar];
        } else {
            self.navigationItem.rightBarButtonItems = self.navigationItem.leftBarButtonItems;
            self.navigationItem.leftBarButtonItems = nil;
            [self.view insertArrangedSubview:self.navigationBar atIndex:0];
        }
        
        [self updateVerticalConstraints];
        [self adjustNavigationBarButtonSpacingWithNegativeSpacing:-8.0 rightMargin:-4.0];
        
        if(_isMaximized) {
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [self updateMaximizedFrameWithSettings:settings];
            }];
        }
        [self.view layoutIfNeeded];
    }];
}

- (void)czfTitleBarDoubleTap {
    [self maximizeWindow];
}

// 拖动结束时离可用区域边缘 18pt 内就吸过去：贴边放窗口
// 不用小心翼翼对齐。maxFrame 的算法和最大化/还原保持一致
- (void)czfSnapToEdgesIfNeeded {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    if (CGRectIsEmpty(maxFrame)) {
        maxFrame = UIScreen.mainScreen.bounds;
    }
    CGRect frame = self.view.frame;
    const CGFloat threshold = 18.0;
    BOOL changed = NO;
    if (fabs(frame.origin.x - CGRectGetMinX(maxFrame)) < threshold) {
        frame.origin.x = CGRectGetMinX(maxFrame);
        changed = YES;
    } else if (fabs(CGRectGetMaxX(frame) - CGRectGetMaxX(maxFrame)) < threshold) {
        frame.origin.x = CGRectGetMaxX(maxFrame) - frame.size.width;
        changed = YES;
    }
    if (fabs(frame.origin.y - CGRectGetMinY(maxFrame)) < threshold) {
        frame.origin.y = CGRectGetMinY(maxFrame);
        changed = YES;
    } else if (fabs(CGRectGetMaxY(frame) - CGRectGetMaxY(maxFrame)) < threshold) {
        frame.origin.y = CGRectGetMaxY(maxFrame) - frame.size.height;
        changed = YES;
    }
    if (changed) {
        [UIView animateWithDuration:0.15 animations:^{
            self.view.frame = frame;
        }];
        [self updateOriginalFrame];
    }
}

- (void)moveWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    BOOL ended = (sender.state == UIGestureRecognizerStateEnded);

    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    self.view.center = CGPointMake(self.view.center.x + point.x, self.view.center.y + point.y);
    [self updateOriginalFrame];
    if (ended) {
        // 先吸附再存状态：存下来的是吸附后的位置；顺手修了
        // 以前存状态在应用最后一段位移之前的小偏差
        [self czfSnapToEdgesIfNeeded];
        [self czfSaveWindowState];
    }
}

- (void)resizeWindow:(UIPanGestureRecognizer*)sender {
    if(_isMaximized) return;
    if (sender.state == UIGestureRecognizerStateEnded) {
        [self czfSaveWindowState];
    }

    CGPoint point = [sender translationInView:self.view];
    [sender setTranslation:CGPointZero inView:self.view];

    CGRect frame = self.view.frame;
    frame.size.width = MAX(50, frame.size.width + point.x);
    frame.size.height = MAX(50, frame.size.height + point.y);
    self.view.frame = frame;
    [self updateOriginalFrame];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    // 标题栏等非游客内容区域：按下就置顶。游客内容（passthrough
    // view）的触摸到不了这里，改走 czfRaiseWindowOnTap 手势识别器。
    [self.view.superview bringSubviewToFront:self.view];
}

// 点按置顶：只调层级（与宿主 bringViewToFront 同款：本视图 + 所在
// 窗口），不改大小、不改最大化状态；已在最上时就是空操作
- (void)czfRaiseWindowOnTap {
    [self.view.superview bringSubviewToFront:self.view];
    UIWindow *window = self.view.window;
    if (window.superview) {
        [window.superview bringSubviewToFront:window];
    }
}

- (void)updateVerticalConstraints {
    [self.view layoutIfNeeded];
    [UIView animateWithDuration:0.3 animations:^{
        BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
        BOOL hideWindowBar = MultitaskDockManager.shared.isCollapsed && self.isMaximized;
        CGFloat navBarHeight = hideWindowBar ? 0 : 44;
        self.navigationBar.alpha = hideWindowBar ? 0 : 1;
        self.navigationBar.hidden = hideWindowBar;
        
        // Update safe area insets
        if(self.isMaximized) {
            self.appSceneVC.shouldSkipDebounceOnce = YES;
            __weak typeof(self) weakSelf = self;
            [self.appSceneVC updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
                [weakSelf updateMaximizedFrameWithSettings:settings];
            }];
        }
        
        [NSLayoutConstraint deactivateConstraints:self.activatedVerticalConstraints];
        if(bottomWindowBar) {
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-navBarHeight],
                [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        } else {
            self.activatedVerticalConstraints = @[
                [self.appSceneVC.view.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:navBarHeight],
                [self.appSceneVC.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
                [self.navigationBar.heightAnchor constraintEqualToConstant:navBarHeight]
            ];
        }
        [NSLayoutConstraint activateConstraints:self.activatedVerticalConstraints];

        [self.view layoutIfNeeded];
    }];
}

- (UIEdgeInsets)updateMaximizedSafeAreaWithSettings:(UIMutableApplicationSceneSettings *)settings {
    BOOL bottomWindowBar = [NSUserDefaults.lcSharedDefaults boolForKey:@"LCMultitaskBottomWindowBar"];
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    if(self.navigationBar.hidden) {
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets = UIEdgeInsetsZero;
    } else if(bottomWindowBar) {
        // allow the control bar to overlap the bottom safe area
        safeAreaInsets.bottom = 0;
        settings.peripheryInsets = safeAreaInsets;
        safeAreaInsets.top = safeAreaInsets.left = safeAreaInsets.right = 0;
    } else {
        settings.peripheryInsets = UIEdgeInsetsMake(0, safeAreaInsets.left, safeAreaInsets.bottom, safeAreaInsets.right);
        safeAreaInsets.bottom = safeAreaInsets.left = safeAreaInsets.right = 0;
    }
    
    // scale peripheryInsets to match the scale ratio
    settings.peripheryInsets = UIEdgeInsetsMake(settings.peripheryInsets.top/_scaleRatio, settings.peripheryInsets.left/_scaleRatio, settings.peripheryInsets.bottom/_scaleRatio, settings.peripheryInsets.right/_scaleRatio);
    if(UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPad) {
        UIInterfaceOrientation currentOrientation = UIApp.statusBarOrientation;
        if(UIInterfaceOrientationIsLandscape(currentOrientation)) {
            safeAreaInsets.top = 0;
        }
        settings.safeAreaInsetsPortrait = LCUIEdgeInsetsRotateToOrientation(settings.peripheryInsets, currentOrientation);

    } else {
        settings.safeAreaInsetsPortrait = UIEdgeInsetsMake(settings.peripheryInsets.top, settings.peripheryInsets.left, settings.peripheryInsets.bottom, settings.peripheryInsets.right);
    }
    
    safeAreaInsets.bottom = 0;
    return safeAreaInsets;
}

- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, [self updateMaximizedSafeAreaWithSettings:settings]);
    self.view.frame = maxFrame;
}

- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {
    UIEdgeInsets safeAreaInsets = self.view.window.safeAreaInsets;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, safeAreaInsets);
    settings.peripheryInsets = UIEdgeInsetsZero;
    settings.safeAreaInsetsPortrait = UIEdgeInsetsZero;
    
    CGRect newFrame = CGRectMake(self.originalFrame.origin.x * maxFrame.size.width, self.originalFrame.origin.y * maxFrame.size.height, self.originalFrame.size.width, self.originalFrame.size.height);
    CGPoint center = self.view.center;
    CGRect frame = CGRectZero;
    frame.size.width = MIN(newFrame.size.width, maxFrame.size.width);
    frame.size.height = MIN(newFrame.size.height, maxFrame.size.height);
    CGFloat oobOffset = MAX(30, frame.size.width - 30);
    frame.origin.x = MAX(maxFrame.origin.x - oobOffset, MIN(CGRectGetMaxX(maxFrame) - frame.size.width + oobOffset, center.x - frame.size.width / 2));
    frame.origin.y = MAX(maxFrame.origin.y, MIN(center.y - frame.size.height / 2, CGRectGetMaxY(maxFrame) - frame.size.height));
    [UIView animateWithDuration:0.3 animations:^{
        self.view.frame = frame;
    }];
}

- (void)updateOriginalFrame {
    if(_isMaximized) return;
    CGRect maxFrame = UIEdgeInsetsInsetRect(self.view.window.frame, self.view.window.safeAreaInsets);
    // save origin as normalized coordinates
    self.originalFrame = CGRectMake(self.view.frame.origin.x / maxFrame.size.width, self.view.frame.origin.y / maxFrame.size.height, self.view.frame.size.width, self.view.frame.size.height);
}

@end
