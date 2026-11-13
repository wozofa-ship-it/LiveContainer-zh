#import "LCSharedUtils.h"
#import "FoundationPrivate.h"
#import "UIKitPrivate.h"
#import "utils.h"
@import MachO;

extern NSUserDefaults *lcUserDefaults;
extern NSString *lcAppUrlScheme;
extern NSBundle *lcMainBundle;

NSString* FBSOpenApplicationOptionKeyActivateAsClassic = @"__ActivateAsClassic";
NSString* FBSOpenApplicationOptionKeyPayloadURL = @"__PayloadURL";

@implementation LCSharedUtils

+ (NSString*) teamIdentifier {
    static NSString* ans = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if !TARGET_OS_SIMULATOR
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFErrorRef error = NULL;
        // 3.8.412：SecTaskCreateFromSelf 可能返回 NULL（扩展进程），
        // SecTaskCopyValueForEntitlement 也可能返回 NULL；CFGetTypeID(NULL)
        // 与 CFRelease(NULL) 都会崩。先判空再用。
        CFTypeRef cfans = taskSelf ? SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error) : NULL;
        if(cfans && CFGetTypeID(cfans) == CFStringGetTypeID()) {
            ans = (__bridge NSString*)cfans;
        }
        if (taskSelf) CFRelease(taskSelf);
#endif
        if(!ans) {
            // the above seems not to work if the device is jailbroken by Palera1n, so we use the public api one as backup
            // https://stackoverflow.com/a/11841898
            NSString *tempAccountName = @"bundleSeedID";
            NSDictionary *query = @{
                (__bridge NSString *)kSecClass : (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount : tempAccountName,
                (__bridge NSString *)kSecAttrService : @"",
                (__bridge NSString *)kSecReturnAttributes: (__bridge NSNumber *)kCFBooleanTrue,
            };
            CFDictionaryRef result = nil;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecItemNotFound)
                status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecSuccess) {
                status = SecItemDelete((__bridge CFDictionaryRef)query); // remove temp item
                NSDictionary *dict = (__bridge_transfer NSDictionary *)result;
                NSString *accessGroup = dict[(__bridge NSString *)kSecAttrAccessGroup];
                NSArray *components = [accessGroup componentsSeparatedByString:@"."];
                NSString *bundleSeedID = [[components objectEnumerator] nextObject];
                ans = bundleSeedID;
            }
        }
    });
    return ans;
}

+ (NSString *)appGroupID {
    static dispatch_once_t once;
    static NSString *appGroupID = @"Unknown";
    dispatch_once(&once, ^{
        // 3.8.412：teamIdentifier 可能为 nil——扩展进程里 SecTask
        // 拿不到 team、钥匙串兜底又没有 keychain entitlement，
        // teamIdentifier 直接返回 nil；这时 stringByAppendingString:
        // 传 nil 会抛 NSInvalidArgumentException，扩展启动就崩，
        // 分享从 398 起一直死在这（411 加的不带后缀组根本走不到，
        // 数组构造那行先崩了）。只 team 非空才加带后缀组。
        NSMutableArray<NSString *> *possibleAppGroups = [NSMutableArray array];
        NSString *teamID = [self teamIdentifier];
        if (teamID.length > 0) {
            [possibleAppGroups addObject:[@"group.com.SideStore.SideStore." stringByAppendingString:teamID]];
            [possibleAppGroups addObject:[@"group.com.rileytestut.AltStore." stringByAppendingString:teamID]];
        }
        // 3.8.411：Release 的 entitlements 是不带团队后缀的
        // （Global.xcconfig 里 DEVELOPMENT_TEAM_SUFFIX[Release]
        // 为空，APP_GROUP_* = group.com.*.SideStore/AltStore），
        // 只试带后缀的两组永远命中不了，全靠后面 SecTask 读
        // entitlement 兜底；扩展进程里 SecTask 一旦拿不到，
        // App Group 就解析成 Unknown，收件箱写不进、分享
        // 就死在这。把不带后缀的两组也放进候选，entitlements
        // 是哪种就命中哪种，不再只依赖 SecTask 兜底。
        [possibleAppGroups addObject:@"group.com.SideStore.SideStore"];
        [possibleAppGroups addObject:@"group.com.rileytestut.AltStore"];
        
        // we prefer app groups with "Apps" in it, which indicate this app group is actually used by the store.
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            NSURL *bundlePath = [path URLByAppendingPathComponent:@"Apps"];
            if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath.path]) {
                // This will fail if LiveContainer is installed in both stores, but it should never be the case
                appGroupID = group;
                return;
            }
        }
        
        // if no "Apps" is found, we choose a valid group
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            appGroupID = group;
            return;
        }
        
        // if no possibleAppGroup is found, we detect app group from entitlement file
        // Cache app group after importing cert so we don't have to analyze executable every launch
        NSString *cached = [lcUserDefaults objectForKey:@"LCAppGroupID"];
        if (cached && [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:cached]) {
            appGroupID = cached;
            return;
        }
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef value = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.security.application-groups"), &error);
        CFRelease(taskSelf);
        
        if(!value) {
            return;
        }
        NSArray* appGroups = (__bridge NSArray *)value;
        if(appGroups.count > 0) {
            appGroupID = [appGroups firstObject];
        }
    });
    return appGroupID;
}

+ (NSURL*) appGroupPath {
    static NSURL *appGroupPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
    });
    return appGroupPath;
}

+ (NSString *)certificatePassword {
    NSUserDefaults* nud = NSUserDefaults.lcSharedDefaults;
    NSString *pwd = [nud objectForKey:@"LCCertificatePassword"];
    if (!pwd) {
        pwd = [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificatePassword"];
    }
    return pwd;
}

+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode {
    // 宿主交接：只有客真正起起来才自杀。原来 completion 不看
    // success，失败也 SIGKILL——客没起、宿主也死了，启动静默
    // 丢掉、没有任何报错。失败时宿主活着，失败原因写进 "error"
    //（LCTabView.checkLastLaunchError 现成通道，下次进页即弹）；
    // 成功时先清掉它，别让一次失败的旧文案在后来成功启动后冒出来。
    void (^killHost)(void) = ^{
        [lcUserDefaults removeObjectForKey:@"error"];
        // syscall(SYS_ptrace, PT_DENY_ATTACH, 0, 0, 0);
        __asm__ __volatile__ (
                              "mov x0, #31\n"
                              "mov x16, #26\n"
                              "svc #0x80"
                              );
        raise(SIGKILL);
    };
    void (^reportFailure)(NSError *) = ^(NSError *error) {
        NSString *detail = error.localizedDescription ?: @"未知错误";
        NSLog(@"[LC] launchToGuestApp failed: %@", error);
        [lcUserDefaults setObject:[NSString stringWithFormat:@"启动客 App 失败：%@", detail] forKey:@"error"];
    };

    if (!self.certificatePassword) {
        NSString *urlScheme = nil;
        NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
        if (!access(tsPath.UTF8String, F_OK)) {
            urlScheme = @"apple-magnifier://enable-jit?bundle-id=%@";
        }

        if(urlScheme) {
            NSURL *launchURL = [NSURL URLWithString:[NSString stringWithFormat:urlScheme, NSBundle.mainBundle.bundleIdentifier]];
            UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
            [application openURL:launchURL options:@{} completionHandler:^(BOOL success) {
                if (success) {
                    killHost();
                } else {
                    reportFailure(nil);
                }
            }];
            return YES;
        }
    }

    _LSOpenConfiguration *configuration = [[PrivClass(_LSOpenConfiguration) alloc] init];
    if(classicMode) {
        NSMutableDictionary* dict = [NSMutableDictionary new];
        dict[FBSOpenApplicationOptionKeyActivateAsClassic] = @(classicMode);
        configuration.frontBoardOptions = dict;
    }
    LSApplicationWorkspace* workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];

    // 两次是串行重试（原来 for 循环两次并行齐发，第二发根本
    // 不是重试）：第一发失败才发第二发，两发都失败才报失败。
    __block NSInteger attemptsLeft = 1;
    __block void (^tryOpen)(void);
    tryOpen = ^{
        [workspace openApplicationWithBundleIdentifier:NSUserDefaults.lcMainBundle.bundleIdentifier
                                         configuration:configuration
                                     completionHandler:^(BOOL success, NSError* error) {
            NSLog(@"success=%d error=%@", success, error);
            if (success) {
                killHost();
            } else if (attemptsLeft > 0) {
                attemptsLeft--;
                tryOpen();
            } else {
                reportFailure(error);
            }
        }];
    };
    tryOpen();
    return YES;
}

+ (BOOL)launchToGuestAppWithURL:(NSURL *)url {
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![components.host isEqualToString:@"livecontainer-launch"]) return NO;

    NSString* launchBundleId = nil;
    NSString* openUrl = nil;
    NSString* containerFolderName = nil;
    for (NSURLQueryItem* queryItem in components.queryItems) {
        if ([queryItem.name isEqualToString:@"bundle-name"]) {
            launchBundleId = queryItem.value;
        } else if ([queryItem.name isEqualToString:@"open-url"]){
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
            openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
            containerFolderName = queryItem.value;
        }
    }
    if(launchBundleId) {
        if (openUrl) {
            [lcUserDefaults setObject:openUrl forKey:@"launchAppUrlScheme"];
        }
        
        // Attempt to restart LiveContainer with the selected guest app
        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];
        bool isSharedApp = false;
        NSBundle *appBundle = [self findBundleWithBundleId:launchBundleId isSharedAppOut:&isSharedApp];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
            [appBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSUInteger classicMode = [appInfo[@"classicMode"] boolValue]
            ? [appInfo[@"LCClassicModeCache"][@"defaultClassicMode"] unsignedIntegerValue]
            : 0;
        return [self launchToGuestAppWithClassicMode:classicMode];
    }
    
    return NO;
}

+ (void)setWebPageUrlForNextLaunch:(NSString*) urlString {
    [lcUserDefaults setObject:urlString forKey:@"webPageToOpen"];
}

+ (NSURL*)containerLockPath {
    static dispatch_once_t once;
    static NSURL *infoPath;
    
    dispatch_once(&once, ^{
        infoPath = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer/containerLock.plist"];
    });
    return infoPath;
}

+ (BOOL)isLCSchemeInUse:(NSString*)lc {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return NO;
    }
    
    NSNumber* num57 = info[lc];
    if(![num57 isKindOfClass:NSNumber.class]) {
        return NO;
    }
    
    uint64_t val57 = [num57 longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno != ESRCH;
}

+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return nil;
    }
    
    NSDictionary* appUsageInfo = info[folderName];
    if (!appUsageInfo) {
        return nil;
    }
    uint64_t val57 = [appUsageInfo[@"auditToken57"] longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno==ESRCH ? nil : appUsageInfo[@"runningLC"];
}

// lc can be something like livecontainer or livecontainer2.liveprocess, such that one LC can jump to another LC hosting the multitask app when user presses run while it's running
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57 {
    NSURL* infoPath = [self containerLockPath];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        info = [NSMutableDictionary new];
    }
    
    if(val57 == 0) {
        audit_token_t token;
        mach_msg_type_number_t size = TASK_AUDIT_TOKEN_COUNT;
        
        kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &size);
        if (kr != KERN_SUCCESS) {
            NSLog(@"Error getting task audit_token");
        }
        val57 = token.val[7] | ((uint64_t)token.val[5] << 32);
    }
    info[folderName] = @{
        @"runningLC": lc,
        @"auditToken57": @(val57)
    };
    
    info[lc] = @(val57);

    [info writeBinToFile:infoPath.path atomically:YES];
}

// move app data to private folder to prevent 0xdead10cc https://forums.developer.apple.com/forums/thread/126438
// This method is here for backward compatability, 0xdead10cc is already resolved.
+ (void)moveSharedAppFolderBack {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *libraryPathUrl = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSError *error;
    NSString *sharedAppDataFolderPath = [libraryPathUrl.path stringByAppendingPathComponent:@"SharedDocuments"];
    if(![fm fileExistsAtPath:sharedAppDataFolderPath]){
        return;
    }
    // move all apps in shared folder back
    NSArray<NSString *> * sharedDataFoldersToMove = [fm contentsOfDirectoryAtPath:sharedAppDataFolderPath error:&error];
    
    // something went wrong with app group
    if(!appGroupFolder && sharedDataFoldersToMove.count > 0) {
        [lcUserDefaults setObject:@"LiveContainer was unable to move the data of shared app back because LiveContainer cannot access app group. Please check JITLess diagnose page in LiveContainer settings for more information." forKey:@"error"];
        return;
    }
    
    for(int i = 0; i < [sharedDataFoldersToMove count]; ++i) {
        NSString* destPath = [appGroupFolder.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", sharedDataFoldersToMove[i]]];
        if([fm fileExistsAtPath:destPath]) {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:[docPathUrl.path stringByAppendingPathComponent:[NSString stringWithFormat:@"FOLDER_EXISTS_AT_APP_GROUP_%@", sharedDataFoldersToMove[i]]]
             error:&error
            ];
            
        } else {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:destPath
             error:&error
            ];
        }
    }
    
}

+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut {
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, bundleId];
    NSBundle *appBundle;
    if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        appBundle = [[NSBundle alloc] initWithPath:bundlePath];
    }

    // not found locally, let's look for the app in shared folder
    if (!appBundle) {
        appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
        
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, bundleId];
        if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
            appBundle = [[NSBundle alloc] initWithPath:bundlePath];
        }
        if(appBundle) {
            *isSharedAppOut = true;
        }
    } else {
        *isSharedAppOut = false;
    }
    return appBundle;
}

// This method is here for backward compatability, preferences is direcrly saved to app's preference folder.
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID {
    NSFileManager* fm = [[NSFileManager alloc] init];
    NSError* error1;
    
    NSDictionary* preferences = [lcUserDefaults objectForKey:dataUUID];
    if(!preferences) {
        return;
    }
    
    [fm createDirectoryAtPath:plistLocationTo withIntermediateDirectories:YES attributes:@{} error:&error1];
    for(NSString* identifier in preferences) {
        NSDictionary* preference = preferences[identifier];
        NSString *itemPath = [plistLocationTo stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", identifier]];
        if([preference count] == 0) {
            // Attempt to delete the file
            [fm removeItemAtPath:itemPath error:&error1];
            continue;
        }
        [preference writeToFile:itemPath atomically:YES];
    }
    [lcUserDefaults removeObjectForKey:dataUUID];
}

+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId {
    // find app's default container
    NSURL* appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder.path, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    return infoDict[@"LCDataUUID"];
}

+ (NSArray<NSString*>*)lcUnorderedUrlSchemes {
    NSArray<NSString *> *defaultSchemes = @[@"livecontainer", @"livecontainer2", @"livecontainer3"];
    return defaultSchemes;
}

+ (NSArray<NSString*>*)lcUrlSchemes {
    NSArray<NSString *> *defaultSchemes = [self lcUnorderedUrlSchemes];
    NSSet<NSString *> *allowedSchemes = [NSSet setWithArray:defaultSchemes];
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    id savedValue = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCMultiLaunchPriority"];
    if([savedValue isKindOfClass:NSArray.class]) {
        for(id value in (NSArray *)savedValue) {
            if(![value isKindOfClass:NSString.class]) {
                continue;
            }

            NSString *scheme = [(NSString *)value lowercaseString];
            if(![allowedSchemes containsObject:scheme] || [result containsObject:scheme]) {
                continue;
            }

            [result addObject:scheme];
        }
    }

    for(NSString *scheme in defaultSchemes) {
        if(![result containsObject:scheme]) {
            [result addObject:scheme];
        }
    }

    return result;
}
@end
