// CZFKeychainBridge.m
// 游客进程内的钥匙串桥：宿主进程在这台机上查不到游客的
// 钥匙串（按组查、按别名查、整表捞，五版真机实测全为空，
// 且不报错），但游客自己读自己的令牌一直正常——导出和写回
// 干脆都搬进游客进程里做，宿主只搬文件：
//   导出：每次进程启动，把本容器的钥匙串条目（通用/互联网
//         密码两类）写成 CZFKeychainDump.plist 放在容器根
//         目录，宿主备份时直接读这份文件
//   写回：宿主恢复时把快照放成 CZFKeychainImport.plist；
//         进程启动时先把它写回钥匙串（删同键再加，组号、
//         别名都按本容器现算），删掉文件，再做一次导出——
//         赶在 App 自己的代码读令牌之前完成
// 定位容器靠 LCBootstrap 设的 HOME 环境变量 + 容器根目录
// 的 LCContainerInfo.plist（组号在里面）；构造函数运行时
// 引导可能还没跑完，所以轮询等它出现（上限约 6 秒）。
// 全部操作显式带访问组和别名，不依赖 SecItem 钩子是否已
// 装上；任何异常都吞掉，绝不拖垮宿主 App 启动。

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <unistd.h>

// iOS SDK 没有 SecTask.h（宿主工程也是自声明的，见
// LiveContainer/FoundationPrivate.h），这里照抄声明
void *SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(void *task, CFStringRef key, CFErrorRef *error);

static NSString *CZFKBTeamIdentifier(void) {
    // 与 LCSharedUtils.teamIdentifier 同一套取法（SecTask 读
    // 本进程签名里的团队 ID），失败再走钥匙串探针兜底
    NSString *ans = nil;
    void *taskSelf = SecTaskCreateFromSelf(NULL);
    if (taskSelf) {
        CFErrorRef error = NULL;
        CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error);
        if (cfans) {
            if (CFGetTypeID(cfans) == CFStringGetTypeID()) {
                ans = (__bridge NSString *)cfans;
            }
            CFRelease(cfans);
        }
        if (error) CFRelease(error);
        CFRelease(taskSelf);
    }
    if (!ans) {
        NSDictionary *query = @{
            (__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
            (__bridge NSString *)kSecAttrAccount: @"bundleSeedID",
            (__bridge NSString *)kSecAttrService: @"",
            (__bridge NSString *)kSecReturnAttributes: (__bridge NSNumber *)kCFBooleanTrue,
        };
        CFDictionaryRef result = nil;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        if (status == errSecItemNotFound) {
            status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
        }
        if (status == errSecSuccess && result) {
            SecItemDelete((__bridge CFDictionaryRef)query);
            NSDictionary *dict = (__bridge_transfer NSDictionary *)result;
            NSString *accessGroup = dict[(__bridge NSString *)kSecAttrAccessGroup];
            NSString *first = [[accessGroup componentsSeparatedByString:@"."] firstObject];
            if (first.length) ans = first;
        }
    }
    return ans;
}

static NSString *CZFKBGroupString(NSString *team, NSInteger groupId) {
    if (!team.length) return nil;
    if (groupId == 0) {
        return [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared", team];
    }
    return [NSString stringWithFormat:@"%@.com.kdt.livecontainer.shared.%ld", team, (long)groupId];
}

// 本进程签名里真正被授权的钥匙串组全表：团队前缀以签名实
// 际写死的为准（个人 ID 重签后宿主与游客两个进程读到的团
// 队 ID 可能不一致，靠拼字符串永远对不上）。条目不管躺在
// 哪个获授权的组里，逐组查都能捞到
static NSArray<NSString *> *CZFKBEntitledGroups(void) {
    void *taskSelf = SecTaskCreateFromSelf(NULL);
    if (!taskSelf) return nil;
    CFErrorRef error = NULL;
    CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("keychain-access-groups"), &error);
    CFRelease(taskSelf);
    if (error) CFRelease(error);
    if (!cfans) return nil;
    if (CFGetTypeID(cfans) == CFArrayGetTypeID()) {
        // 所有权交给 ARC：不能先 CFRelease 再返回桥接引用
        return (__bridge_transfer NSArray *)cfans;
    }
    CFRelease(cfans);
    return nil;
}

// 只留 plist 能存的类型，引用型字段剔掉（与宿主导出旧逻辑一致）
static NSDictionary *CZFKBCleanItem(NSDictionary *item, NSString *cls) {
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (NSString *k in item) {
        id v = item[k];
        if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSData.class]
            || [v isKindOfClass:NSNumber.class] || [v isKindOfClass:NSDate.class]) {
            clean[k] = v;
        }
    }
    clean[(__bridge NSString *)kSecClass] = cls;
    return clean;
}

// 导出各路的新增条数（去重后按来源记账），写进状态回执
static NSInteger CZFKBStatEntitled = 0;
static NSInteger CZFKBStatAlias = 0;

static void CZFKBExport(NSString *home, NSArray<NSString *> *entitledGroups, NSString *folderName) {
    NSMutableArray *all = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^collect)(NSDictionary *, NSInteger *) = ^(NSDictionary *query, NSInteger *stat) {
        CFTypeRef result = nil;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status != errSecSuccess || !result) return;
        NSArray *items = (__bridge_transfer NSArray *)result;
        if (![items isKindOfClass:NSArray.class]) return;
        for (NSDictionary *item in items) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSString *cls = item[(__bridge NSString *)kSecClass] ?: (__bridge NSString *)kSecClassGenericPassword;
            NSDictionary *clean = CZFKBCleanItem(item, cls);
            NSString *identity = [NSString stringWithFormat:@"%@|%@|%@|%@",
                cls,
                clean[(__bridge NSString *)kSecAttrAccount] ?: @"",
                clean[(__bridge NSString *)kSecAttrService] ?: @"",
                clean[(__bridge NSString *)kSecAttrGeneric] ?: @""];
            // 身份字段多为字符串；NSData 的 description 是内容
            // 的十六进制，同样能区分。撞键只会误丢内容相同的
            // 重复条，不丢数据
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];
            [all addObject:clean];
            if (stat) *stat += 1;
        }
    };
    CZFKBStatEntitled = 0;
    CZFKBStatAlias = 0;
    for (NSString *cls in @[(__bridge NSString *)kSecClassGenericPassword, (__bridge NSString *)kSecClassInternetPassword]) {
        // 主路：逐个获授权组查。游客钩子写条目时把组改成本
        // 容器的组，那个组必在这张表里；团队前缀对不上也不
        // 影响——表里是签名写死的原串
        for (NSString *g in entitledGroups) {
            collect(@{
                (__bridge NSString *)kSecClass: cls,
                (__bridge NSString *)kSecAttrAccessGroup: g,
                (__bridge NSString *)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
                (__bridge NSString *)kSecMatchLimit: (__bridge NSString *)kSecMatchLimitAll,
                (__bridge NSString *)kSecReturnAttributes: @YES,
                (__bridge NSString *)kSecReturnData: @YES,
            }, &CZFKBStatEntitled);
        }
        // 兜底按别名查（存入时盖的容器文件夹名）
        collect(@{
            (__bridge NSString *)kSecClass: cls,
            @"alis": folderName,
            (__bridge NSString *)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
            (__bridge NSString *)kSecMatchLimit: (__bridge NSString *)kSecMatchLimitAll,
            (__bridge NSString *)kSecReturnAttributes: @YES,
            (__bridge NSString *)kSecReturnData: @YES,
        }, &CZFKBStatAlias);
    }
    // 空的也写：文件存在本身就是"桥跑过、快照为空"的凭据，
    // 宿主据此区分"还没打开过 App"和"真没令牌"
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:all format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data) {
        [data writeToFile:[home stringByAppendingPathComponent:@"CZFKeychainDump.plist"] atomically:YES];
    }
}

static NSInteger CZFKBImport(NSString *home, NSString *group, NSString *folderName) {
    NSString *path = [home stringByAppendingPathComponent:@"CZFKeychainImport.plist"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return 0;
    NSInteger imported = 0;
    id parsed = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if ([parsed isKindOfClass:NSArray.class]) {
        for (NSDictionary *raw in (NSArray *)parsed) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            NSString *cls = raw[(__bridge NSString *)kSecClass] ?: (__bridge NSString *)kSecClassGenericPassword;
            NSMutableDictionary *item = [CZFKBCleanItem(raw, cls) mutableCopy];
            // 同步标记摘掉：没有 iCloud 钥匙串权限，带着 sync
            // 写会被系统以缺权限拒绝（宿主写回的老教训）
            [item removeObjectForKey:(__bridge NSString *)kSecAttrSynchronizable];
            item[(__bridge NSString *)kSecAttrAccessGroup] = group;
            item[@"alis"] = folderName;
            // 同键先删再加，保证值以备份为准
            NSMutableDictionary *identity = [NSMutableDictionary dictionary];
            identity[(__bridge NSString *)kSecClass] = cls;
            identity[(__bridge NSString *)kSecAttrAccessGroup] = group;
            for (NSString *k in @[(__bridge NSString *)kSecAttrAccount, (__bridge NSString *)kSecAttrService, (__bridge NSString *)kSecAttrGeneric]) {
                if (item[k]) identity[k] = item[k];
            }
            SecItemDelete((__bridge CFDictionaryRef)identity);
            OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, nil);
            if (status == errSecSuccess) imported += 1;
            if (status == errSecParam) {
                // 全量属性写不进：退到最小属性集再试一次（快照
                // 里可能带着原进程上下文的键，换个进程写会被
                // 系统整条拒绝）
                NSMutableDictionary *minimal = [NSMutableDictionary dictionary];
                for (NSString *k in @[(__bridge NSString *)kSecClass, (__bridge NSString *)kSecAttrAccount,
                                      (__bridge NSString *)kSecAttrService, (__bridge NSString *)kSecAttrGeneric,
                                      (__bridge NSString *)kSecAttrLabel, (__bridge NSString *)kSecAttrAccessible,
                                      (__bridge NSString *)kSecAttrAccessGroup, @"alis",
                                      (__bridge NSString *)kSecValueData]) {
                    if (item[k]) minimal[k] = item[k];
                }
                SecItemDelete((__bridge CFDictionaryRef)identity);
                if (SecItemAdd((__bridge CFDictionaryRef)minimal, nil) == errSecSuccess) imported += 1;
            }
        }
    }
    // 处理完就删：失败的条目不值得每次启动重试，免得一份坏
    // 快照反复拖慢打开
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    return imported;
}

static void CZFKBRun(void) {
    @try {
        // 等 LCBootstrap 把 HOME 指到容器、容器信息文件落位
        // （构造函数跑在引导之前是常态）
        NSString *home = nil;
        NSDictionary *info = nil;
        for (int i = 0; i < 120; i++) {
            const char *envHome = getenv("HOME");
            if (envHome) {
                NSString *candidate = @(envHome);
                NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[candidate stringByAppendingPathComponent:@"LCContainerInfo.plist"]];
                if (dict) {
                    home = candidate;
                    info = dict;
                    break;
                }
            }
            usleep(50000); // 0.05 秒一轮，上限约 6 秒
        }
        if (!home) return; // 不在游客容器里（宿主自载等场景），什么都不做
        NSInteger groupId = [info[@"keychainGroupId"] integerValue];
        NSString *team = CZFKBTeamIdentifier();
        NSString *group = CZFKBGroupString(team, groupId);
        NSArray<NSString *> *entitled = CZFKBEntitledGroups();
        if (!group && entitled.count == 0) return;
        NSString *folderName = home.lastPathComponent;
        // 钩子同款自检：本容器组到底在不在本进程的授权里。
        // 不在（-34018）= 钩子根本没装上，App 的钥匙串调用
        // 全部落空、登录只能走文件——回执里写清，不再瞎猜
        OSStatus probe = 0;
        if (group) {
            NSDictionary *probeQuery = @{
                (__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount: @"NonExistentKey",
                (__bridge NSString *)kSecAttrService: @"NonExistentService",
                (__bridge NSString *)kSecAttrAccessGroup: group,
                (__bridge NSString *)kSecReturnData: @NO,
            };
            probe = SecItemCopyMatching((__bridge CFDictionaryRef)probeQuery, nil);
        }
        NSInteger imported = 0;
        if (group) {
            imported = CZFKBImport(home, group, folderName);
        }
        CZFKBExport(home, entitled ?: @[], folderName);
        // 状态回执：宿主备份弹窗直接带出来，桥跑没跑、组对
        // 不对、条目在不在，一行定案
        BOOL inEntitled = group && [entitled containsObject:group];
        NSString *status = [NSString stringWithFormat:
            @"team=%@ groupId=%ld group=%@ entitled=%lu组 computedInEntitled=%@ probe=%d exported=%ld（逐组%ld 别名%ld） imported=%ld",
            team ?: @"(nil)", (long)groupId, group ?: @"(nil)",
            (unsigned long)entitled.count, inEntitled ? @"YES" : @"NO",
            (int)probe, (long)(CZFKBStatEntitled + CZFKBStatAlias),
            (long)CZFKBStatEntitled, (long)CZFKBStatAlias, (long)imported];
        [status writeToFile:[home stringByAppendingPathComponent:@"CZFKeychainBridgeStatus.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {
        // 桥是配角：任何异常都吞掉，不许拖垮 App 启动
    }
}

__attribute__((constructor)) static void CZFKeychainBridgeInit(void) {
    // 挪到后台队列：构造函数里同步等引导会拖住 dyld
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CZFKBRun();
    });
    // 登录发生在启动之后（首次登录、令牌刷新）：界面起来后
    // 再补导一次，快照尽量新。observer token 必须留住，不留
    // 会被系统当场注销
    static id czfkbLaunchObserver;
    czfkbLaunchObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CZFKBRun();
        });
    }];
}
