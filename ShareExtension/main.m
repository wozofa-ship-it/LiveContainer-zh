//
//  main.m
//  LiveContainer
//
//  Created by s s on 2026/2/17.
//
#import "LCShareExtensionLauncher.h"
#import "../LiveContainer/utils.h"
#import "../LiveContainer/UIKitPrivate.h"

static Class LSApplicationWorkspaceClass;
static Class _LSOpenConfigurationClass;

@implementation LCShareExtensionLauncher

+ (BOOL)openURLFromShareExtension:(NSURL *)url {
    return [self openURLFromShareExtensionWithOptions:@{ @"url": url }];
}

+ (BOOL)openURLFromShareExtensionWithOptions:(NSDictionary *)options {
    // unfortunately SpringBoard blocks openURL for iOS 10+ new extension types, so we need to chain through this old extension type to open the URL
    NSURL *url = options[@"url"];
    if (![url isKindOfClass:NSURL.class]) {
        return NO;
    }

    LSApplicationWorkspace* workspace = [LSApplicationWorkspaceClass defaultWorkspace];

    NSString* bundleIdToLaunch = nil;
    NSString* scheme = url.scheme;
    if([scheme isEqualToString:@"livecontainer"] || [scheme isEqualToString:@"sidestore"]) {
        bundleIdToLaunch = NSBundle.mainBundle.bundleIdentifier.stringByDeletingPathExtension;
    } else {
        bundleIdToLaunch = [NSUserDefaults.lcSharedDefaults stringForKey:[NSString stringWithFormat:@"LCBundleID.%@", scheme]];
        // 3.8.366：LCBundleID.<scheme> 只在多开（multiLCStatus == 2）时才写，单开设备上为 nil；nil 传给 openApplicationWithBundleIdentifier: 必失败。回落到主 bundle ID。
        if (!bundleIdToLaunch) bundleIdToLaunch = NSBundle.mainBundle.bundleIdentifier.stringByDeletingPathExtension;
    }

    __block BOOL success = NO;
    if(scheme) {
        NSNumber *classicMode = options[@"classicMode"];
        if ([classicMode isKindOfClass:NSNumber.class] && classicMode.unsignedIntegerValue != 0) {
            _LSOpenConfiguration *classicConfig = [[_LSOpenConfigurationClass alloc] init];
            classicConfig.frontBoardOptions = @{
                FBSOpenApplicationOptionKeyActivateAsClassic: classicMode
            };
            [workspace openApplicationWithBundleIdentifier:bundleIdToLaunch configuration:classicConfig completionHandler:nil];
        }

        _LSOpenConfiguration *config = [[_LSOpenConfigurationClass alloc] init];
        config.frontBoardOptions = @{
            FBSOpenApplicationOptionKeyPayloadURL: url
        };
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);

        [workspace openApplicationWithBundleIdentifier:bundleIdToLaunch usingConfiguration:config completionHandler:^(BOOL success1, NSError * err) {
            success = success1;
            dispatch_semaphore_signal(sema);
        }];
        // 3.8.363：5 秒超时，别无限等。iOS 26 下 completion 可能
        // 不回，无限等会把扩展卡死；超时按失败走回落。
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    }
    // 3.8.373：删 [workspace openURL:url] 回落。iOS 26 下从扩展调它被拦
    // 仍返回 YES（假成功），调用方以为打开了就 completeRequest 关面板，
    // 实际 Live 从没被拉起。只返 openApplication 的真实结果，失败留面板报错。
    // 3.8.363：以前这里永远 return true，打开失败也静默关面板，
    // 用户只看到回 QQ、Live 没到前台。改返真实结果，调用方
    // 失败时留面板报错。
    return success;
}

+ (BOOL)canOpenURLFromShareExtension:(NSURL *)url {
    id error = nil;
    return [[PrivClass(LSApplicationWorkspace) defaultWorkspace] isApplicationAvailableToOpenURL:url error:&error];
}

+ (void)load {
    _LSOpenConfigurationClass = PrivClass(_LSOpenConfiguration);
    LSApplicationWorkspaceClass = PrivClass(LSApplicationWorkspace);
}

@end

NSBundle* lcMainBundle = nil;
__attribute__((constructor))
static void init(void) {
    lcMainBundle = [NSBundle bundleWithURL:NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    NSLog(@"%@", lcMainBundle);
}

@interface NSUserDefaults(ShareExtension)
+ (NSBundle*)lcMainBundle;
@end

@implementation NSUserDefaults(ShareExtension)

+ (NSBundle*)lcMainBundle {
    return lcMainBundle;
}

@end
