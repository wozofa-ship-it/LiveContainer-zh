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

// 单开容器的默认钥匙串组：钩子关时 App 的 SecItem 调用原样
// 通过，无组名时 iOS 落到 <团队>.<Bundle ID>。隔离容器不走
// 这里（钩子开，全部改写到共享组），见 CZFKBIsIsolatedContainer。
static NSString *CZFKBDefaultGroup(NSString *team, NSString *bundleID) {
    if (!team.length || !bundleID.length) return nil;
    return [NSString stringWithFormat:@"%@.%@", team, bundleID];
}

// 进程自己的默认钥匙串组 = 代码签名的 application-identifier
// （LiveContainer 进程即 <团队>.com.kdt.livecontainer）。游客
// 代码跑在宿主进程里、签名没变，故游客不带组名的 SecItem
// 调用落的就是这里，与游客 Bundle ID 无关——v217 的
// <团队>.<游客 Bundle ID> 不是进程默认组、也不在授权表里，
// 查它只会得缺授权（静默记 0），不是真空。SecTask 读不到
// 时退到团队拼串；都拿不到返回 nil（跳过此路）。
static NSString *CZFKBApplicationIdentifierGroup(NSString *team) {
    void *taskSelf = SecTaskCreateFromSelf(NULL);
    if (taskSelf) {
        CFErrorRef error = NULL;
        CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("application-identifier"), &error);
        if (error) CFRelease(error);
        CFRelease(taskSelf);
        if (cfans && CFGetTypeID(cfans) == CFStringGetTypeID()) {
            return (__bridge_transfer NSString *)cfans;
        }
        if (cfans) CFRelease(cfans);
    }
    if (team.length) return [NSString stringWithFormat:@"%@.com.kdt.livecontainer", team];
    return nil;
}

// 隔离判定：plist 有 isolateAppGroup 键就用它（现行
// makeLCContainerInfoPlist 已写该键，无需补字段）；缺键的
// 旧版 plist 判不明，保守走共享组路：反向误判（隔离实例按
// 非隔离处理）会把它的快照写进同包名共用的默认组，造成多
// 开串登录；正向误判（非隔离按隔离处理）只维持现状、不回
// 归、不串号。宁可旧容器暂不享受修复，也不冒串登录风险。
static BOOL CZFKBIsIsolatedContainer(NSDictionary *info) {
    id v = info[@"isolateAppGroup"];
    if (!v) return YES;
    return [v boolValue];
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
static NSInteger CZFKBStatDefault = 0;
static NSInteger CZFKBStatLCDefault = 0;
// 自定义组记账（信息性：已含在上面某一路里，不进总数公式）
// 归属过滤计数（信息性：被排除的条目总数，未计入任何一路）
static NSInteger CZFKBStatCustom = 0;
static NSInteger CZFKBStatExcluded = 0;

// 归属过滤（单开通用修复，隔离容器不用）：
// 组名是否以点分段为单位完整包含 Bundle ID（防 com.example.app
// 误含 com.example.app2：子串匹配会错，段匹配不会）。
static BOOL CZFKBGroupContainsBid(NSString *group, NSString *bid) {
    if (!group.length || !bid.length) return NO;
    NSArray<NSString *> *gParts = [group componentsSeparatedByString:@"."];
    NSArray<NSString *> *bParts = [bid componentsSeparatedByString:@"."];
    if (bParts.count == 0 || gParts.count < bParts.count) return NO;
    for (NSUInteger i = 0; i + bParts.count <= gParts.count; i++) {
        BOOL match = YES;
        for (NSUInteger j = 0; j < bParts.count; j++) {
            if (![gParts[i + j] isEqualToString:bParts[j]]) { match = NO; break; }
        }
        if (match) return YES;
    }
    return NO;
}

// 条目字段是否指向本 App（共享组里的逐条目归属，宁可漏收不串号）：
// 只看字符串字段（service/account/generic/label；NSData 的 generic
// 是二进制，没法按名匹配，跳过）。命中任一即归属：
// - 字段含 Bundle ID 全串；
// - 字段含 Bundle ID 末段（末段即 App 名，如 Aweme）；
// - 末段含字段（字段是 App 名的 4 字以上片段，如 awem）；
// - 字段含容器名 / 容器名含字段（容器名若是显示名，能接住中文服务名；
//   若是 UUID 则天然不命中，无误伤）。
// 刻意不用“Bundle ID 含字段”（字段是 login/token 这类通用词时，
// Bundle ID 恰好含它不代表归属，误收就是串号）。
static BOOL CZFKBItemMatchesApp(NSDictionary *item, NSString *bundleID, NSString *folderName) {
    if (!bundleID.length) return NO;
    NSString *last = [bundleID componentsSeparatedByString:@"."].lastObject;
    NSArray<NSString *> *keys = @[
        (__bridge NSString *)kSecAttrService,
        (__bridge NSString *)kSecAttrAccount,
        (__bridge NSString *)kSecAttrGeneric,
        (__bridge NSString *)kSecAttrLabel,
    ];
    for (NSString *k in keys) {
        id v = item[k];
        if (![v isKindOfClass:NSString.class]) continue;
        NSString *f = (NSString *)v;
        if (f.length < 3) continue;
        if ([f localizedCaseInsensitiveContainsString:bundleID]) return YES;
        if (last.length >= 3 && [f localizedCaseInsensitiveContainsString:last]) return YES;
        if (last.length >= 3 && f.length >= 4 && [last localizedCaseInsensitiveContainsString:f]) return YES;
        if (folderName.length >= 3 && [f localizedCaseInsensitiveContainsString:folderName]) return YES;
        if (folderName.length >= 3 && f.length >= 4 && [folderName localizedCaseInsensitiveContainsString:f]) return YES;
    }
    return NO;
}

// defaultGroup：非隔离容器才传（= <团队>.<Bundle ID>）；
// 隔离容器传 nil，归属谓词与旧版一字不差，共享组路不动。
// lcDefaultGroup：进程默认组（= application-identifier），
// 非隔离容器才传；隔离容器传 nil（钩子开时不走这里，且隔
// 离容器绝不碰共享的进程默认组，防串登录）。
// bundleID：非隔离容器才传（= 容器 plist 的 appIdentifier）；
// 隔离容器传 nil，此时归属谓词与旧版一字不差（4 项全留，真隔离
// 时默认组/进程默认组本来就是 nil，退化成共享组 + alis），
// 自定义组/归属过滤/计数一律不启用，隔离路不动。
static void CZFKBExport(NSString *home, NSArray<NSString *> *entitledGroups, NSString *group, NSString *folderName, NSString *defaultGroup, NSString *lcDefaultGroup, NSString *bundleID) {
    NSMutableArray *all = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableSet *seenExcluded = [NSMutableSet set];
    void (^collect)(NSDictionary *, NSInteger *) = ^(NSDictionary *query, NSInteger *stat) {
        CFTypeRef result = nil;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status != errSecSuccess || !result) return;
        NSArray *items = (__bridge_transfer NSArray *)result;
        if (![items isKindOfClass:NSArray.class]) return;
        for (NSDictionary *item in items) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            // 只收本 App 的：逐组扫会扫到别的 App 存在同批共
            // 享组里的条目，混进来恢复时会把别人的令牌写进这
            // 个 App、同键不同值还会在去重时互相顶掉。
            NSString *itemGroup = item[(__bridge NSString *)kSecAttrAccessGroup];
            NSString *itemAlias = item[@"alis"];
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
            BOOL mine = NO;
            if (!bundleID.length) {
                // 无 bundleID（隔离容器传 nil；或非隔离容器 plist
                // 缺 appIdentifier 的回落）：旧谓词一字不动（4 项
                // 全留）。真隔离时 defaultGroup/lcDefaultGroup 本来
                // 就是 nil，本行退化成共享组 + alis；回落时 lcDefault
                // 项仍在（v218 全收行为保留，无法归属时不擅自收紧）。
                // 自定义组/归属过滤/计数一律不启用。
                mine = (group && itemGroup && [itemGroup isEqualToString:group])
                    || (defaultGroup && itemGroup && [itemGroup isEqualToString:defaultGroup])
                    || (lcDefaultGroup && itemGroup && [itemGroup isEqualToString:lcDefaultGroup])
                    || (itemAlias && [itemAlias isEqualToString:folderName]);
            } else {
                // 非隔离：专属组（本容器共享组、默认组、含 Bundle ID
                // 的组）组本身就是归属证明，全收；其他组（进程默认
                // 组、厂商共享组、其他获授权组）是共享存储，逐条目
                // 归属过滤（字段指向本 App 才收），不归属的排除、
                // 不进快照（防串号）。旧版这里只认 4 组：厂商组里
                // 的条目明明被获授权组查询捞到了，却被谓词丢掉——
                // 单开 App（抖音/Muse/Mithka）收 0 的最大漏口。
                // 进程默认组旧版是全收（v218），现改为归属过滤：
                // 通用服务名的条目会被排除（残留缺口，见回执注释），
                // 但快照不再含其他单开 App 的条目。
                if ((itemAlias && [itemAlias isEqualToString:folderName])
                    || (group && itemGroup && [itemGroup isEqualToString:group])
                    || (defaultGroup && itemGroup && [itemGroup isEqualToString:defaultGroup])
                    || CZFKBGroupContainsBid(itemGroup, bundleID)) {
                    mine = YES;
                } else if (itemGroup && CZFKBItemMatchesApp(item, bundleID, folderName)) {
                    mine = YES;
                } else {
                    // 含无组名：无法归属，保守排除
                    mine = NO;
                }
            }
            if (!mine) {
                // 归属过滤掉的去重计数（隔离不计，见上）：同一条目
                // 会被多路查询重复捞到，只计一次，否则数字虚高。
                // 注意：谓词与查询无关（同一条目在任何一路的结论
                // 相同），故先被排除的条目不会在后一路被收进。
                if (bundleID.length && ![seenExcluded containsObject:identity]) {
                    [seenExcluded addObject:identity];
                    CZFKBStatExcluded += 1;
                }
                continue;
            }
            if ([seen containsObject:identity]) continue;
            [seen addObject:identity];
            [all addObject:clean];
            if (stat) *stat += 1;
            // 自定义组记账（信息性，不进 exported 总数公式）：
            // 组既不是共享组、默认组、进程默认组，却被收进来的条目
            // （厂商组等）。它已被上面某一路 stat 计过一次，这里
            // 只做交叉记账，不重复加进总数。
            if (bundleID.length && itemGroup
                && !(group && [itemGroup isEqualToString:group])
                && !(defaultGroup && [itemGroup isEqualToString:defaultGroup])
                && !(lcDefaultGroup && [itemGroup isEqualToString:lcDefaultGroup])) {
                CZFKBStatCustom += 1;
            }
        }
    };
    CZFKBStatEntitled = 0;
    CZFKBStatAlias = 0;
    CZFKBStatDefault = 0;
    CZFKBStatLCDefault = 0;
    CZFKBStatCustom = 0;
    CZFKBStatExcluded = 0;
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
        // 非隔离加一查默认组：默认组若已在授权表里，逐组扫
        // 已捞到、去重后这里不重复记账；若不在表里，只有这
        // 一查能捞到。隔离容器 defaultGroup 为 nil，直接跳过。
        if (defaultGroup) {
            collect(@{
                (__bridge NSString *)kSecClass: cls,
                (__bridge NSString *)kSecAttrAccessGroup: defaultGroup,
                (__bridge NSString *)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
                (__bridge NSString *)kSecMatchLimit: (__bridge NSString *)kSecMatchLimitAll,
                (__bridge NSString *)kSecReturnAttributes: @YES,
                (__bridge NSString *)kSecReturnData: @YES,
            }, &CZFKBStatDefault);
        }
        // 进程默认组：钩子关时 App 不带组名的 SecItem 调用落
        // 到进程自己的默认组（= application-identifier，即
        // <团队>.com.kdt.livecontainer，宿主与游客共用、所有
        // 单开 App 共用）。桥此前从未查过它——单开 App 的令
        // 牌最可能就在这里。隔离容器 lcDefaultGroup 为 nil，
        // 直接跳过（钩子开时写操作已改写到共享组，不走这里；
        // 且隔离容器绝不碰共享的进程默认组，防串登录）。
        // 注意：此组是共享存储，导出时逐条目归属过滤（见 collect
        // 内谓词：字段指向本 App 才收），不归属的排除、不进快照
        // （防串号；旧版 v218 是全收，快照会含其他单开 App 的条目，
        // 现收紧）。写回时归属后的条目原样写回同一共享组（见
        // CZFKBImport），不盖 alis（见导入注释）。回执里进程默认
        // 组计数现为归属后计数（不再是全量），归属过滤掉的数另计。
        if (lcDefaultGroup) {
            collect(@{
                (__bridge NSString *)kSecClass: cls,
                (__bridge NSString *)kSecAttrAccessGroup: lcDefaultGroup,
                (__bridge NSString *)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
                (__bridge NSString *)kSecMatchLimit: (__bridge NSString *)kSecMatchLimitAll,
                (__bridge NSString *)kSecReturnAttributes: @YES,
                (__bridge NSString *)kSecReturnData: @YES,
            }, &CZFKBStatLCDefault);
        }
    }
    // 空的也写：文件存在本身就是"桥跑过、快照为空"的凭据，
    // 宿主据此区分"还没打开过 App"和"真没令牌"
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:all format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data) {
        [data writeToFile:[home stringByAppendingPathComponent:@"CZFKeychainDump.plist"] atomically:YES];
    }
}

// 写回记账：总数、成功数、首个失败状态码，写进状态回执。
// 成功数单独存静态量：一次启动桥会跑两遍（构造函数+启动
// 完成通知），第二遍没有排队文件、本地计数是 0，回执要报
// 的是"最近一次真写回"的战果，不能被第二遍的 0 冲掉
static NSInteger CZFKBStatImportTotal = 0;
static NSInteger CZFKBStatImported = 0;
static OSStatus CZFKBStatImportFail = 0;

// isolated/team/lcDefaultGroup：写回分流用。隔离一律走传入
// 的 group（= 共享组，旧行为不动）；非隔离才按原组分流。
static NSInteger CZFKBImport(NSString *home, NSString *group, NSString *folderName, BOOL isolated, NSString *team, NSString *lcDefaultGroup) {
    NSString *path = [home stringByAppendingPathComponent:@"CZFKeychainImport.plist"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return 0;
    NSInteger imported = 0;
    CZFKBStatImportTotal = 0;
    CZFKBStatImportFail = 0;
    id parsed = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if ([parsed isKindOfClass:NSArray.class]) {
        for (NSDictionary *raw in (NSArray *)parsed) {
            if (![raw isKindOfClass:NSDictionary.class]) continue;
            NSString *cls = raw[(__bridge NSString *)kSecClass] ?: (__bridge NSString *)kSecClassGenericPassword;
            CZFKBStatImportTotal += 1;
            NSMutableDictionary *item = [CZFKBCleanItem(raw, cls) mutableCopy];
            // 同步标记摘掉：没有 iCloud 钥匙串权限，带着 sync
            // 写会被系统以缺权限拒绝（宿主写回的老教训）
            [item removeObjectForKey:(__bridge NSString *)kSecAttrSynchronizable];
            // 创建/修改时间是系统盖的，带着写会被整条拒绝
            [item removeObjectForKey:(__bridge NSString *)kSecAttrCreationDate];
            [item removeObjectForKey:(__bridge NSString *)kSecAttrModificationDate];
            // 写回目标分流（非隔离才分流，隔离一律走传入的
            // group = 共享组，旧行为不动）：
            // - 原组是进程默认组（任意团队前缀 + .com.kdt.livecontainer）
            //   → 写回当前进程默认组（团队前缀换成当前团队）；
            //   App 不带组名读写时落的就是这里，写别处它读不到。
            // - 原组是共享组 → 保留组号、只换当前团队前缀（App
            //   显式指定共享组时读的就是这个确切组，钩子关不改
            //   写，写进游客默认组反而读不到）。
            // - 其他 → 传入的 group（旧行为）。
            NSString *target = group;
            BOOL isLCDefaultItem = NO;
            if (!isolated) {
                NSString *origGroup = raw[(__bridge NSString *)kSecAttrAccessGroup];
                if ([origGroup isKindOfClass:NSString.class]) {
                    if ([origGroup hasSuffix:@".com.kdt.livecontainer"]) {
                        if (lcDefaultGroup) { target = lcDefaultGroup; isLCDefaultItem = YES; }
                    } else {
                        NSRange sharedRange = [origGroup rangeOfString:@".com.kdt.livecontainer.shared"];
                        if (sharedRange.location != NSNotFound && team.length) {
                            target = [team stringByAppendingString:[origGroup substringFromIndex:sharedRange.location]];
                        } else if (team.length) {
                            // 自定义组（厂商共享组等）：原组既不是进程默认组
                            // 也不是共享组 → 保留后缀、只换当前团队前缀。
                            // 原组是旧团队默认组时换完正好等于 writeGroup，
                            // 与旧 else 行为一致；原组是厂商组时写回 App
                            // 显式指定的那个组，App 才能读到（旧 else 写默认
                            // 组，App 按厂商组查就扑空——自定义组令牌恢复后
                            // 仍未登录的半截修复）。无点/无团队时 target 保
                            // 持传入的 group（旧行为）。
                            NSRange dot = [origGroup rangeOfString:@"."];
                            if (dot.location != NSNotFound) {
                                target = [team stringByAppendingString:[origGroup substringFromIndex:dot.location]];
                            }
                        }
                    }
                }
            }
            item[(__bridge NSString *)kSecAttrAccessGroup] = target;
            // 进程默认组是共享存储：不盖容器 alis 戳。盖了会让
            // 宿主按别名清理时误删其他单开 App 的登录（共享组
            // 里的条目按容器清理是错的），且下次导出会把它们
            // 算进别名路、掩盖进程默认组的真实命中。
            if (isLCDefaultItem) {
                [item removeObjectForKey:@"alis"];
            } else {
                item[@"alis"] = folderName;
            }
            // 同键先删再加，保证值以备份为准
            NSMutableDictionary *identity = [NSMutableDictionary dictionary];
            identity[(__bridge NSString *)kSecClass] = cls;
            identity[(__bridge NSString *)kSecAttrAccessGroup] = target;
            for (NSString *k in @[(__bridge NSString *)kSecAttrAccount, (__bridge NSString *)kSecAttrService, (__bridge NSString *)kSecAttrGeneric]) {
                if (item[k]) identity[k] = item[k];
            }
            SecItemDelete((__bridge CFDictionaryRef)identity);
            OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, nil);
            if (status == errSecSuccess) {
                imported += 1;
            } else {
                // 全量属性写不进（不管什么错）：退到最小属性集
                // 再试一次（快照里可能带着原进程上下文的键，
                // 换个进程写会被系统整条拒绝）
                NSMutableDictionary *minimal = [NSMutableDictionary dictionary];
                for (NSString *k in @[(__bridge NSString *)kSecClass, (__bridge NSString *)kSecAttrAccount,
                                      (__bridge NSString *)kSecAttrService, (__bridge NSString *)kSecAttrGeneric,
                                      (__bridge NSString *)kSecAttrLabel, (__bridge NSString *)kSecAttrAccessible,
                                      (__bridge NSString *)kSecAttrAccessGroup, @"alis",
                                      (__bridge NSString *)kSecValueData]) {
                    if (item[k]) minimal[k] = item[k];
                }
                SecItemDelete((__bridge CFDictionaryRef)identity);
                OSStatus retry = SecItemAdd((__bridge CFDictionaryRef)minimal, nil);
                if (retry == errSecSuccess) {
                    imported += 1;
                } else if (CZFKBStatImportFail == 0) {
                    CZFKBStatImportFail = retry;
                }
            }
        }
    }
    // 处理完就删：失败的条目不值得每次启动重试，免得一份坏
    // 快照反复拖慢打开
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    CZFKBStatImported = imported;
    return imported;
}

static void CZFKBRun(void) {
    @try {
        // 导出计数每遍重数：一次启动桥跑两遍（构造函数+启动
        // 完成通知），不重置回执会翻倍（真机出过 exported=200
        // 而实际 100 条）
        CZFKBStatEntitled = 0;
        CZFKBStatAlias = 0;
        CZFKBStatDefault = 0;
        CZFKBStatLCDefault = 0;
        CZFKBStatCustom = 0;
        CZFKBStatExcluded = 0;
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
        // 分流：隔离 → 共享组（旧路）；非隔离 → 默认组（新口
        // 子）。默认组拿不到（无团队/无 Bundle ID）时回落共
        // 享组，维持现状、不崩。appIdentifier 取自容器 plist，
        // 非字符串时按缺失处理。
        BOOL isolated = CZFKBIsIsolatedContainer(info);
        id bundleIDValue = info[@"appIdentifier"];
        NSString *bundleID = [bundleIDValue isKindOfClass:NSString.class] ? bundleIDValue : nil;
        NSString *defaultGroup = isolated ? nil : CZFKBDefaultGroup(team, bundleID);
        NSString *writeGroup = (!isolated && defaultGroup) ? defaultGroup : group;
        // 进程默认组只对非隔离容器查/写（隔离跳过，见导出注释）。
        NSString *lcDefaultGroup = isolated ? nil : CZFKBApplicationIdentifierGroup(team);
        NSArray<NSString *> *entitled = CZFKBEntitledGroups();
        if (!group && entitled.count == 0 && !lcDefaultGroup) return;
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
        // 进程默认组探针：-25300 = 可读（条目不存在）、-34018 =
        // 缺授权（此路不通）。与默认组计数配合定案：探针通但计
        // 数 0 = 组里真没密码类条目；探针 -34018 = 隐式默认组
        // 假设被证伪，需另寻存储位置。
        OSStatus lcProbe = 0;
        if (lcDefaultGroup) {
            NSDictionary *lcProbeQuery = @{
                (__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount: @"NonExistentKey",
                (__bridge NSString *)kSecAttrService: @"NonExistentService",
                (__bridge NSString *)kSecAttrAccessGroup: lcDefaultGroup,
                (__bridge NSString *)kSecReturnData: @NO,
            };
            lcProbe = SecItemCopyMatching((__bridge CFDictionaryRef)lcProbeQuery, nil);
        }
        NSInteger imported = 0;
        if (writeGroup) {
            imported = CZFKBImport(home, writeGroup, folderName, isolated, team, lcDefaultGroup);
        }
        CZFKBExport(home, entitled ?: @[], group, folderName, defaultGroup, lcDefaultGroup, isolated ? nil : bundleID);
        // 状态回执：宿主备份弹窗直接带出来，桥跑没跑、组对
        // 不对、条目在不在，一行定案
        BOOL inEntitled = group && [entitled containsObject:group];
        // 回执只加字段不改旧字段：宿主原文展示、无解析依赖，
        // 旧字段语义不变（group 仍是共享组、probe 仍探共享
        // 组）；新增 isolated/defaultGroup/writeGroup 与默认
        // 组计数，下次定案直接看默认组有没有命中。本批再加
        // 进程默认组计数 + lcDefaultGroup + lcProbe（exported
        // 总数 = 四路之和，括号里四路分开记账，不混）。
        // 本批再加自定义组 + 归属过滤掉（只加字段，旧字段名、
        // 顺序、总数公式一字不动：exported 总数仍 = 逐组+别名+
        // 默认组+进程默认组四路之和；自定义组是交叉记账（已被某
        // 一路计过，不重复加），归属过滤掉未计入任何一路。
        // 注意：进程默认组计数语义收紧（v218 是全量，现为归属后
        // 计数）；归属过滤掉含被排除的进程默认组/厂商组条目，
        // 两数相加才是该组实际捞到的总数。
        NSString *status = [NSString stringWithFormat:
            @"team=%@ groupId=%ld group=%@ entitled=%lu组 computedInEntitled=%@ probe=%d exported=%ld（逐组%ld 别名%ld 默认组%ld 进程默认组%ld；自定义组%ld 归属过滤掉%ld） isolated=%@ defaultGroup=%@ writeGroup=%@ lcDefaultGroup=%@ lcProbe=%d imported=%ld/%ld fail=%d",
            team ?: @"(nil)", (long)groupId, group ?: @"(nil)",
            (unsigned long)entitled.count, inEntitled ? @"YES" : @"NO",
            (int)probe, (long)(CZFKBStatEntitled + CZFKBStatAlias + CZFKBStatDefault + CZFKBStatLCDefault),
            (long)CZFKBStatEntitled, (long)CZFKBStatAlias, (long)CZFKBStatDefault, (long)CZFKBStatLCDefault,
            (long)CZFKBStatCustom, (long)CZFKBStatExcluded,
            isolated ? @"YES" : @"NO", defaultGroup ?: @"(nil)", writeGroup ?: @"(nil)", lcDefaultGroup ?: @"(nil)", (int)lcProbe,
            (long)CZFKBStatImported,
            (long)CZFKBStatImportTotal, (int)CZFKBStatImportFail];
        [status writeToFile:[home stringByAppendingPathComponent:@"CZFKeychainBridgeStatus.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {
        // 桥是配角：任何异常都吞掉，不许拖垮 App 启动
    }
}

// 构造阶段的抢先写回（同步）：HOME 已指到容器且有排队文件
// 时，当场把令牌导进去——赶在 App 自己的代码读钥匙串之
// 前。后台流程是异步的，App 启动早期读钥匙串可能抢在它前
// 面，那就是恢复了却显示未登录的时序坑。返回 YES 表示已
// 处理或无事可做；NO 表示 HOME 还没就位、交给后台长轮询
static BOOL CZFKBTryImportEarly(void) {
    @try {
        const char *envHome = getenv("HOME");
        if (!envHome) return NO;
        NSString *home = @(envHome);
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[home stringByAppendingPathComponent:@"LCContainerInfo.plist"]];
        if (!info) return NO;
        NSString *importPath = [home stringByAppendingPathComponent:@"CZFKeychainImport.plist"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:importPath]) return YES;
        // 抢导必须与全量流程用同一写回目标，否则抢导写进共
        // 享组、App 读默认组还是看不见，且排队文件已被抢导
        // 删掉、全量流程无从补救。分流逻辑与 CZFKBRun 一致。
        NSInteger groupId = [info[@"keychainGroupId"] integerValue];
        NSString *team = CZFKBTeamIdentifier();
        NSString *group = CZFKBGroupString(team, groupId);
        BOOL isolated = CZFKBIsIsolatedContainer(info);
        id bundleIDValue = info[@"appIdentifier"];
        NSString *bundleID = [bundleIDValue isKindOfClass:NSString.class] ? bundleIDValue : nil;
        NSString *defaultGroup = isolated ? nil : CZFKBDefaultGroup(team, bundleID);
        NSString *writeGroup = (!isolated && defaultGroup) ? defaultGroup : group;
        NSString *lcDefaultGroup = isolated ? nil : CZFKBApplicationIdentifierGroup(team);
        if (!writeGroup) return NO;
        CZFKBImport(home, writeGroup, home.lastPathComponent, isolated, team, lcDefaultGroup);
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

__attribute__((constructor)) static void CZFKeychainBridgeInit(void) {
    // 先在构造线程上抢一轮写回（HOME 没就位就短轮询
    // ≤0.5 秒），抢不到再交给后台长轮询；全量流程（导出+
    // 回执+兜底导入）照常在后台跑一遍
    if (!CZFKBTryImportEarly()) {
        for (int i = 0; i < 10; i++) {
            usleep(50000);
            if (CZFKBTryImportEarly()) break;
        }
    }
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
    // 切后台再刷新一次快照：登录往往发生在启动之后，不刷的
    // 话用户登录完立刻去备份、读到的还是启动时的旧快照
    // （抖音实测踩过：登录后没重开，导出恒为旧值）
    static id czfkbBackgroundObserver;
    czfkbBackgroundObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidEnterBackgroundNotification"
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CZFKBRun();
        });
    }];
    // 前台触发（恢复免登录修正 2026-10-25）：恢复只把快照排队成
    // CZFKeychainImport.plist，真正写回在游客下次全新启动时；但
    // 恢复不杀已运行的游客，用户直接前台切回时构造器不重跑、
    // 启动通知不重发，排队文件原地不动、App 仍显示未登录。
    // 回前台时就地抢导一次（无排队文件时只是文件存在性检查，
    // 不跑全量导出）。token 必须留住，不留会被系统当场注销。
    static id czfkbActiveObserver;
    czfkbActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"UIApplicationDidBecomeActiveNotification"
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CZFKBTryImportEarly();
        });
    }];
}
