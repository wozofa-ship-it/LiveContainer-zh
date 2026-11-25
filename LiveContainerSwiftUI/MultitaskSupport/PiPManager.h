//
//  PiPManager.h
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
@import Foundation;
@import AVKit;
@import UIKit;
#import "FoundationPrivate.h"
#import "AppSceneViewController.h"

API_AVAILABLE(ios(16.0))
@interface PiPManager : NSObject<AVPictureInPictureControllerDelegate>
@property (class, nonatomic, readonly) PiPManager *shared;
@property (nonatomic, readonly) bool isPiP;
- (BOOL)isPiPWithVC:(AppSceneViewController*)vc;
- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc;
- (void)stopPiP;
- (void)startPiPWithVC:(AppSceneViewController*)vc;
// 3.8.900（L601-B#1）：客退出时定向作废待发中的 PiP 启动。
- (void)czfCancelPendingPiPStartForVC:(AppSceneViewController *)vc;

@end
