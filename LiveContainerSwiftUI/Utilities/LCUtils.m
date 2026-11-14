@import Darwin;
@import MachO;
@import UIKit;
@import UniformTypeIdentifiers;
@import Security;
#import <IOKit/IOKitLib.h>
#import <CommonCrypto/CommonCrypto.h>

#import "LCUtils.h"
#import "../../LiveContainer/LCSharedUtils.h"
#import "LCAppInfo.h"
#import "../../MultitaskSupport/DecoratedAppSceneViewController.h"
#import "../../ZSign/zsigner.h"
#import "LiveContainerSwiftUI-Swift.h"

// make SFSafariView happy and open data: URLs
@implementation NSURL(hack)
- (BOOL)safari_isHTTPFamilyURL {
    // Screw it, Apple
    return YES;
}
@end

@implementation LCUtils
#pragma mark Certificate & password

+ (NSData *)certificateData {
    NSUserDefaults* nud = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    if(!nud) {
        nud = NSUserDefaults.standardUserDefaults;
    }
    return [nud objectForKey:@"LCCertificateData"];
}


+ (void)setCertificatePassword:(NSString *)certPassword {
    [NSUserDefaults.standardUserDefaults setObject:certPassword forKey:@"LCCertificatePassword"];
    [[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]] setObject:certPassword forKey:@"LCCertificatePassword"];
}


#pragma mark Multitasking
+ (NSString *)liveProcessBundleIdentifier {
    // first check if we have LiveProcess extension in our own bundle
    NSBundle *liveProcessBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"]];
    if(liveProcessBundle) {
        return liveProcessBundle.bundleIdentifier;
    }
    
    // in LC2, attempt to guess LC1's LiveProcess extension
    NSString *bundleID = [NSString stringWithFormat:@"com.kdt.livecontainer.%@.LiveProcess", LCSharedUtils.teamIdentifier];
    if([NSExtension extensionWithIdentifier:bundleID error:nil]) {
        return bundleID;
    }
    
    return nil;
}

+ (void)launchMultitaskGuestApp:(NSString *)displayName completionHandler:(void (^)(NSNumber *pid, NSError *error))completionHandler {
    if(!self.liveProcessBundleIdentifier) {
        NSError *error = [NSError errorWithDomain:displayName code:2 userInfo:@{NSLocalizedDescriptionKey: @"LiveProcess extension not found. Please reinstall LiveContainer and select Keep Extensions"}];
        if (completionHandler) completionHandler(nil, error);
        return;
    }
    
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    NSString* bundleId = [lcUserDefaults stringForKey:@"selected"];
    NSString* dataUUID = [lcUserDefaults stringForKey:@"selectedContainer"];
    
    [lcUserDefaults removeObjectForKey:@"selected"];
    [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.1, *)) {
            if(UIApplication.sharedApplication.supportsMultipleScenes && [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode"] == 1) {
                [MultitaskWindowManager openAppWindowWithDisplayName:displayName dataUUID:dataUUID bundleId:bundleId pidCallback:completionHandler];
                MultitaskDockManager *dock = [MultitaskDockManager shared];
                [dock addRunningApp:displayName appUUID:dataUUID view:nil];
                return;
            }
        }
        
        UIViewController *rootVC = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.rootViewController;
        DecoratedAppSceneViewController *launcherView = [[DecoratedAppSceneViewController alloc] initWindowName:displayName bundleId:bundleId dataUUID:dataUUID rootVC:rootVC];
        // Wire PID callback
        launcherView.pidAvailableHandler = completionHandler;
        launcherView.view.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        launcherView.view.center = rootVC.view.center;
    });
}

#pragma mark Code signing


+ (void)loadStoreFrameworksWithError2:(NSError **)error {
    // too lazy to use dispatch_once
    static BOOL loaded = NO;
    if (loaded) return;

    void* handle = dlopen("@executable_path/Frameworks/ZSign.dylib", RTLD_GLOBAL);
    const char* dlerr = dlerror();
    if (!handle || (uint64_t)handle > 0xf00000000000) {
        if (dlerr) {
            *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load ZSign: %s", dlerr]}];
        } else {
            *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load ZSign: An unknown error occurred."]}];
        }
        NSLog(@"[LC] %s", dlerr);
        return;
    }
    
    loaded = YES;
}

+ (NSURL *)storeBundlePath {
    if ([self store] == SideStore) {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.SideStore.SideStore/App.app"];
    } else {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.rileytestut.AltStore/App.app"];
    }
}

+ (NSString *)storeInstallURLScheme {
    if ([self store] == SideStore) {
        return @"sidestore://install?url=%@";
    } else {
        return @"altstore://install?url=%@";
    }
}

+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error;

    // use zsign as our signer~
    // Load libraries from Documents, yeah
    [self loadStoreFrameworksWithError2:&error];

    if (error) {
        completionHandler(NO, error);
        return nil;
    }

    NSLog(@"[LC] starting signing...");
    
    NSProgress* ans = [NSClassFromString(@"ZSigner") signWithAppPath:[path path] bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData pass:LCSharedUtils.certificatePassword completionHandler:completionHandler];
    
    return ans;
}

+ (NSProgress *)signFilesWithZSignWithURLs:(NSArray<NSURL*>*)urls completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        completionHandler(NO, error);
        return nil;
    }
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[urls count]];
    for (NSURL *url in urls) {
        [paths addObject:url.path];
    }
    
    return [NSClassFromString(@"ZSigner") signMachOPathArr:paths bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData
                                                      pass:LCSharedUtils.certificatePassword completionHandler:completionHandler];
}

// P3：证书内容 SHA256 + 密码拼成的缓存键（hex）。
// 放 getCertTeamIdWithKeyData 前面（同文件内先声明后调用，免得编译警告）。
+ (NSString *)czfCertTeamCacheKeyWithData:(NSData *)keyData password:(NSString *)password {
    NSMutableData *input = [NSMutableData dataWithData:keyData];
    [input appendData:[password dataUsingEncoding:NSUTF8StringEncoding]];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

+ (NSString*)getCertTeamIdWithKeyData:(NSData*)keyData password:(NSString*)password {
    // P3（3.8.280）：p12 解析一次够了——每次启动验签、每个
    // tweak 文件夹验签都重新解密解析一遍。按证书内容 SHA256 +
    // 密码缓存团队号；证书换了自然 miss 重新解析，不会拿错团队；
    // 解析失败（nil）不缓存，下次重试。缓存是进程内字典，只认
    // 两三个证书，不设上限。调用方在什么线程都可能，字典加锁。
    if (keyData && password) {
        static NSMutableDictionary<NSString*, NSString*> *teamIdCache = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ teamIdCache = [NSMutableDictionary dictionary]; });
        NSString *cacheKey = [self czfCertTeamCacheKeyWithData:keyData password:password];
        @synchronized(teamIdCache) {
            NSString *cached = teamIdCache[cacheKey];
            if (cached) {
                return cached;
            }
        }
        NSError *error;
        [self loadStoreFrameworksWithError2:&error];
        if (error) {
            return nil;
        }
        NSString* ans = [NSClassFromString(@"ZSigner") getTeamIdWithCert:keyData pass:password];
        if (ans) {
            @synchronized(teamIdCache) {
                teamIdCache[cacheKey] = ans;
            }
        }
        return ans;
    }
    NSError *error;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        return nil;
    }
    NSString* ans = [NSClassFromString(@"ZSigner") getTeamIdWithCert:keyData pass:password];
    return ans;
}

+ (int)validateCertificateWithCompletionHandler:(void(^)(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error))completionHandler {
    NSError *error;
    NSData *certData = [LCUtils certificateData];
    if (error) {
        return -6;
    }
    [self loadStoreFrameworksWithError2:&error];
    int ans = [NSClassFromString(@"ZSigner") checkCert:certData pass:[LCSharedUtils certificatePassword] completionHandler:completionHandler];
    return ans;
}

#pragma mark JIT

+ (BOOL)isTXMScriptRequired {
    if (@available(iOS 19.0, *)) {
        // https://github.com/opa334/Dopamine/commit/e8438b4a64ead3997d2c70a575431cb1b4070fb9
        io_registry_entry_t memory_map = IORegistryEntryFromPath(0, "IODeviceTree:/chosen/memory-map");
        if (memory_map == IO_OBJECT_NULL)
            return NO;
        NSArray *keys = (__bridge_transfer NSArray *)IORegistryEntryCreateCFProperty(memory_map, CFSTR(kIORegistryEntryPropertyKeysKey), 0, 0);
        IOObjectRelease(memory_map);
        return keys && [keys containsObject:@"TXM"];
    }
    return NO;
}

+ (NSString *)base64EncodedUniversalJITScript {
    static dispatch_once_t onceToken;
    static NSString *script;
    dispatch_once(&onceToken, ^{
        NSData *data = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"universal" ofType:@"js"]];
        script = [data base64EncodedStringWithOptions:0];
    });
    return script;
}

#pragma mark Setup

+ (Store) store {
    static Store ans;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // use uttype to accurately detect store
        if([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.sidestore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = SideStore;
        } else if ([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.altstore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = AltStore;
        } else {
            ans = Unknown;
        }
        
        if(ans != Unknown) {
            return;
        }
        
        if([[LCSharedUtils appGroupID] containsString:@"AltStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.rileytestut.AltStore"]) {
            ans = AltStore;
        } else if ([[LCSharedUtils appGroupID] containsString:@"SideStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.SideStore.SideStore"]) {
            ans = SideStore;
        } else if (![[LCSharedUtils appGroupID] containsString:@"Unknown"] ) {
            ans = ADP;
        } else {
            ans = Unknown;
        }
    });
    return ans;
}

+ (NSString *)appUrlScheme {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
}

+ (BOOL)isAppGroupAltStoreLike {
    return [LCSharedUtils.appGroupID containsString:@"SideStore"] || [LCSharedUtils.appGroupID containsString:@"AltStore"];
}

+ (void)changeMainExecutableTo:(NSString *)exec error:(NSError **)error {
    NSURL *infoPath = [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.kdt.livecontainer/App.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return;

    infoDict[@"CFBundleExecutable"] = exec;
    [infoDict writeToURL:infoPath error:error];
}

+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    // Verify that the certificate is usable
    // Create a test app bundle
    NSString *path = NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpLibPath = [path stringByAppendingPathComponent:@"TestJITLess.dylib"];
    [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TestJITLess.dylib"] toPath:tmpLibPath error:nil];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block bool signSuccess = false;
    __block NSError* signError = nil;
    
    // Sign the test app bundle

    [LCUtils signFilesWithZSignWithURLs:@[[NSURL fileURLWithPath:tmpLibPath]]
                  completionHandler:^(BOOL success, NSError *_Nullable error) {
        signSuccess = success;
        signError = error;
        dispatch_semaphore_signal(sema);
    }];

    // 3.8.500（L19）：等 ZSigner 回调不能无限等——zsign.mm 的
    // dispatch_group_wait 是 DISPATCH_TIME_FOREVER，单个文件签名
    // 卡住时回调永远不来，这里跟着永远等、诊断页转圈永远不停
    // （后台线程，不冻主界面，但测试永远没结果）。5 分钟超时
    // 按失败走（与 Swift 侧签名超时同款）；迟来的回调只 signal
    // 一个没人等的信号量，无害。
    if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC))) != 0) {
        signSuccess = NO;
        signError = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:-1 userInfo:@{
            NSLocalizedDescriptionKey: @"签名超时（已等待 5 分钟），请重试"
        }];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!signSuccess) {
            completionHandler(NO, signError);
        } else if (checkCodeSignature([tmpLibPath UTF8String])) {
            completionHandler(YES, signError);
        } else {
            completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:@{NSLocalizedDescriptionKey: @"lc.signer.latestCertificateInvalidErr"}]);
        }
        [NSFileManager.defaultManager removeItemAtPath:tmpLibPath error:nil];
    });
}

+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName includingExtraInfoDict:(NSDictionary *)extraInfoDict error:(NSError **)error {
    if (*error) return nil;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *bundlePath = NSBundle.mainBundle.bundleURL;

    NSURL *tmpPath = manager.temporaryDirectory;

    NSURL *tmpPayloadPath = [tmpPath URLByAppendingPathComponent:@"LiveContainer2/Payload"];
    [manager removeItemAtURL:tmpPayloadPath error:nil];
    [manager createDirectoryAtURL:tmpPayloadPath withIntermediateDirectories:YES attributes:nil error:error];
    if (*error) return nil;
    
    NSURL *tmpIPAPath = [tmpPath URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipa", newBundleName]];
    

    [manager copyItemAtURL:bundlePath toURL:[tmpPayloadPath URLByAppendingPathComponent:@"App.app"] error:error];
    if (*error) return nil;
    
    NSURL *infoPath = [tmpPayloadPath URLByAppendingPathComponent:@"App.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return nil;

    infoDict[@"CFBundleDisplayName"] = newBundleName;
    infoDict[@"CFBundleName"] = newBundleName;
    infoDict[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.kdt.%@", newBundleName];
    infoDict[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0] = [newBundleName lowercaseString];
    while([infoDict[@"CFBundleURLTypes"] count] > 1) {
        [infoDict[@"CFBundleURLTypes"] removeLastObject];
    }
    [infoDict removeObjectForKey:@"UTExportedTypeDeclarations"];
    infoDict[@"CFBundleIconName"] = @"AppIconGrey";
    if (infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"]) {
        infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"] = @"AppIconGrey";
    }
    infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][0] = @"AppIconGrey60x60";
    
    if (infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"]) {
        infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"] = @"AppIconGrey";
    }
    infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][0] = @"AppIconGrey60x60";
    infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][1] = @"AppIconGrey76x76";
    [infoDict addEntriesFromDictionary:extraInfoDict];
    
    // reset a executable name so they don't look the same on the log
    NSURL* appBundlePath = [tmpPayloadPath URLByAppendingPathComponent:@"App.app"];
    
    NSURL* execFromPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    infoDict[@"CFBundleExecutable"] = newBundleName;
    NSURL* execToPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    
    // MARK: patch main executable
    // we remove the teamId after app group id so it can be correctly signed by AltSign.
    NSString* entitlementXML = getExecutableEntitlementXML(NSBundle.mainBundle.executablePath);
    NSData *plistData = [entitlementXML dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSPropertyListSerialization propertyListWithData:plistData
                                                                          options:NSPropertyListMutableContainers
                                                                           format:nil
                                                                            error:error];
    if(*error) {
        return nil;
    }
    
    NSString* teamId = dict[@"com.apple.developer.team-identifier"];
    if(![teamId isKindOfClass:NSString.class]) {
        *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"com.apple.developer.team-identifier is not a string!"}];
        return nil;
    }
    infoDict[@"PrimaryLiveContainerTeamId"] = teamId;
    NSArray* appGroupsToFind = @[
        @"group.com.SideStore.SideStore",
        @"group.com.rileytestut.AltStore",
    ];
    
    // remove the team id prefix in app group id added by SideStore/AltStore
    for(NSString* appGroup in appGroupsToFind) {
        NSUInteger appGroupCount = [dict[@"com.apple.security.application-groups"] count];
        for(int i = 0; i < appGroupCount; ++i) {
            NSString* targetAppGroup = [NSString stringWithFormat:@"%@.%@", appGroup, teamId];
            if([dict[@"com.apple.security.application-groups"][i] isEqualToString:targetAppGroup]) {
                dict[@"com.apple.security.application-groups"][i] = appGroup;
            }
        }
    }
    
    // set correct application-identifier
    dict[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, infoDict[@"CFBundleIdentifier"]];
    
    // For TrollStore
    NSString* containerId = dict[@"com.apple.private.security.container-required"];
    if(containerId) {
        dict[@"com.apple.private.security.container-required"] = infoDict[@"CFBundleIdentifier"];
    }
    
    
    // We have to change executable's UUID so iOS won't consider 2 executables the same
    NSString* errorChangeUUID = LCParseMachO([execFromPath.path UTF8String], false, ^(const char *path, struct mach_header_64 *header, int fd, void* filePtr) {
        LCChangeMachOUUID(header);
    });
    if (errorChangeUUID) {
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:errorChangeUUID forKey:NSLocalizedDescriptionKey];
        // populate the error object with the details
        *error = [NSError errorWithDomain:@"world" code:200 userInfo:details];
        NSLog(@"[LC] %@", errorChangeUUID);
        return nil;
    }
    
    NSData* newEntitlementData = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    [LCUtils loadStoreFrameworksWithError2:error];
    BOOL adhocSignSuccess = [NSClassFromString(@"ZSigner") adhocSignMachOAtPath:execFromPath.path bundleId:infoDict[@"CFBundleIdentifier"] entitlementData:newEntitlementData];
    if (!adhocSignSuccess) {
        *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Failed to adhoc sign main executable!"}];
        return nil;
    }
    
    // MARK: archive bundle
    
    [manager moveItemAtURL:execFromPath toURL:execToPath error:error];
    if (*error) {
        NSLog(@"[LC] %@", *error);
        return nil;
    }
    
    // we don't care about errors when removing unnecessary files. errors occur probably because the file does not exist
    // we remove the extension
    [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"PlugIns"] error:nil];
    // remove all sidestore stuff
    if([NSUserDefaults sideStoreExist]) {
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreSupport.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStore.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Intents.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"ViewApp.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Metadata.appintents"] error:nil];
        [infoDict removeObjectForKey:@"INIntentsSupported"];
        [infoDict removeObjectForKey:@"NSUserActivityTypes"];
    }
    
    [infoDict writeToURL:infoPath error:error];
    // 3.8.492（L10）：写盘失败必须当时拦——原来不查 *error
    // 就继续打包，Info.plist 写失败（磁盘满）时 zip 里是旧
    // 名字/旧 Bundle ID 的陈旧 plist，装出来的分身名字和
    // Bundle ID 全是旧的；与本函数其余步骤“写完即查”同款。
    if (*error) return nil;
    
    dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_GLOBAL);
    NSData *zipData = [[NSClassFromString(@"PKZipArchiver") new] zippedDataForURL:tmpPayloadPath.URLByDeletingLastPathComponent];
    if (!zipData) return nil;

    [manager removeItemAtURL:tmpPayloadPath error:error];
    if (*error) return nil;
    
    if([manager fileExistsAtPath:tmpIPAPath.path]) {
        [manager removeItemAtURL:tmpIPAPath error:error];
        if (*error) return nil;
    }

    [zipData writeToURL:tmpIPAPath options:0 error:error];
    if (*error) return nil;

    return tmpIPAPath;
}

+ (NSString *)getVersionInfo {
    // 3.8.336：页脚改成“解剖自我 🅥 LiveContainer 版本号”
    // （用户 13:16 截图圈定）；只用短版本号，不再拼
    // Release/提交号/修改版。
    return [NSString stringWithFormat:@"解剖自我 🅥 LiveContainer %@",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]];
}

+ (NSData*)bookmarkForURL:(NSURL*) url {
    return [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
}


@end
