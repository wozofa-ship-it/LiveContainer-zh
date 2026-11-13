//
//  DeviceFingerprint.m
//  LiveContainer
//
//  设备指纹伪装：每个容器一套指纹（多开分身各有一套环境用）。
//  与 IDFV.m 同款路子——客端启动时注入，
//  只 hook 读指纹的那几个入口，其余一律原样放行。
//  IDFA 走 ASIdentifierManager（AdSupport 未链接时先 dlopen，
//  拿不到类就不 hook，不崩）；设备名/系统版本走 UIDevice；
//  机型走 sysctl / sysctlbyname / uname（hw.machine + hw.model）。
//  sysctl 系是全局重绑定：只认 hw.machine / hw.model 这一组
//  mib，其余调用原样调原函数；重绑定只做一次（二次装 orig
//  会指到 hook 自身、无限递归），installed 守住。
//
@import Foundation;
@import ObjectiveC;
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#import "../../litehook/src/litehook.h"

static NSUUID *spoofedIDFAUUID = nil;
static NSString *spoofedDeviceNameStr = nil;
static NSString *spoofedSystemVersionStr = nil;
static NSString *spoofedMachineStr = nil;

static NSUUID *getIDFA_hook(NSObject *self, SEL _cmd) {
    return spoofedIDFAUUID;
}

static NSString *getDeviceName_hook(NSObject *self, SEL _cmd) {
    return spoofedDeviceNameStr;
}

static NSString *getSystemVersion_hook(NSObject *self, SEL _cmd) {
    return spoofedSystemVersionStr;
}

// ATT 状态：IDFA 给了真 UUID，ATT 就得是已授权（YES），
// 不然“有 IDFA 但 ATT 关着”自相矛盾，精细指纹一看即穿。
static BOOL getATTEnabled_hook(NSObject *self, SEL _cmd) {
    return YES;
}

// --- 屏幕（与伪装机型一致） ---
// 机型 -> 屏幕 native 像素 + scale，与 czfRandomMachine 的五款一致。
// bounds（点）= native / scale；nativeBounds（像素）= native。
static CGRect spoofedBounds = CGRectZero;
static CGRect spoofedNativeBounds = CGRectZero;
static CGFloat spoofedScale = 0;

static BOOL czfScreenForMachine(NSString *machine, CGFloat *outW, CGFloat *outH, CGFloat *outScale) {
    if ([machine isEqualToString:@"iPhone17,1"]) { *outW = 1206; *outH = 2622; *outScale = 3; return YES; } // iPhone 16 Pro
    if ([machine isEqualToString:@"iPhone16,2"]) { *outW = 1290; *outH = 2796; *outScale = 3; return YES; } // iPhone 15 Pro Max
    if ([machine isEqualToString:@"iPhone16,1"]) { *outW = 1179; *outH = 2556; *outScale = 3; return YES; } // iPhone 15 Pro
    if ([machine isEqualToString:@"iPhone15,3"]) { *outW = 1290; *outH = 2796; *outScale = 3; return YES; } // iPhone 14 Pro Max
    if ([machine isEqualToString:@"iPhone15,2"]) { *outW = 1179; *outH = 2556; *outScale = 3; return YES; } // iPhone 14 Pro
    return NO;
}

static CGRect getScreenBounds_hook(UIScreen *self, SEL _cmd) {
    return spoofedBounds;
}

static CGRect getScreenNativeBounds_hook(UIScreen *self, SEL _cmd) {
    return spoofedNativeBounds;
}

static CGFloat getScreenScale_hook(UIScreen *self, SEL _cmd) {
    return spoofedScale;
}

static CGFloat getScreenNativeScale_hook(UIScreen *self, SEL _cmd) {
    return spoofedScale;
}

// --- 地区（语言 + 时区 + 地区） ---
// 地区码 -> locale + 语言 + 时区，与 czfRandomRegion 的八个码一致。
static NSLocale *spoofedLocale = nil;
static NSArray *spoofedLanguages = nil;
static NSTimeZone *spoofedTimeZone = nil;

static BOOL czfRegionInfo(NSString *region, NSString **outLocaleID, NSString **outLanguage, NSString **outTimeZoneName) {
    if ([region isEqualToString:@"US"]) { *outLocaleID = @"en_US"; *outLanguage = @"en"; *outTimeZoneName = @"America/New_York"; return YES; }
    if ([region isEqualToString:@"JP"]) { *outLocaleID = @"ja_JP"; *outLanguage = @"ja"; *outTimeZoneName = @"Asia/Tokyo"; return YES; }
    if ([region isEqualToString:@"GB"]) { *outLocaleID = @"en_GB"; *outLanguage = @"en"; *outTimeZoneName = @"Europe/London"; return YES; }
    if ([region isEqualToString:@"DE"]) { *outLocaleID = @"de_DE"; *outLanguage = @"de"; *outTimeZoneName = @"Europe/Berlin"; return YES; }
    if ([region isEqualToString:@"FR"]) { *outLocaleID = @"fr_FR"; *outLanguage = @"fr"; *outTimeZoneName = @"Europe/Paris"; return YES; }
    if ([region isEqualToString:@"KR"]) { *outLocaleID = @"ko_KR"; *outLanguage = @"ko"; *outTimeZoneName = @"Asia/Seoul"; return YES; }
    if ([region isEqualToString:@"AU"]) { *outLocaleID = @"en_AU"; *outLanguage = @"en"; *outTimeZoneName = @"Australia/Sydney"; return YES; }
    if ([region isEqualToString:@"CA"]) { *outLocaleID = @"en_CA"; *outLanguage = @"en"; *outTimeZoneName = @"America/Toronto"; return YES; }
    return NO;
}

static NSLocale *getCurrentLocale_hook(Class self, SEL _cmd) {
    return spoofedLocale;
}

static NSArray *getPreferredLanguages_hook(Class self, SEL _cmd) {
    return spoofedLanguages;
}

static NSTimeZone *getLocalTimeZone_hook(Class self, SEL _cmd) {
    return spoofedTimeZone;
}

static NSTimeZone *getSystemTimeZone_hook(Class self, SEL _cmd) {
    return spoofedTimeZone;
}

static NSTimeZone *getDefaultTimeZone_hook(Class self, SEL _cmd) {
    return spoofedTimeZone;
}

// --- 每分身单独代理（NSURLSessionConfiguration） ---
// 只在用户填了 host 且端口 > 0 时生效：default / ephemeral /
// background 三种 session 配置都挂上 connectionProxyDictionary。
// 没填 = 不走代理，原样放行。代理不可用时客端联网会断，
// 这是填错代理的代价，不是 hook 的 bug。
// 注意与 CZFProxy（单 App VPN 插件）的关系：两者都改写同一份
// connectionProxyDictionary，CZFProxy 是插件、后加载，它的
// hook 在外层、最后盖章，所以同一 App 上单 App VPN 与本代理
// 同时开时，VPN 隧道（127.0.0.1）赢、本代理不生效；要用本
// 代理就别给这个 App 开单 App VPN。两者各司其职，不互相改。
static NSString *spoofedProxyHostStr = nil;
static NSInteger spoofedProxyPortNum = 0;

static NSURLSessionConfiguration *(*orig_defaultSessionConfiguration)(Class, SEL) = NULL;
static NSURLSessionConfiguration *(*orig_ephemeralSessionConfiguration)(Class, SEL) = NULL;
static NSURLSessionConfiguration *(*orig_backgroundSessionConfiguration)(Class, SEL, NSString *) = NULL;

static void czfApplyProxy(NSURLSessionConfiguration *config) {
    if (config == nil || spoofedProxyHostStr == nil || spoofedProxyHostStr.length == 0 || spoofedProxyPortNum <= 0) {
        return;
    }
    // 键名用字符串字面量（与 CZFProxy.m 同款）：kCFNetworkProxies*
    // 常量要链 CFNetwork 框架，仓内没链，用字面量不新增链接依赖。
    NSMutableDictionary *proxy = [config.connectionProxyDictionary mutableCopy];
    if (proxy == nil) proxy = [NSMutableDictionary dictionary];
    proxy[@"HTTPEnable"] = @YES;
    proxy[@"HTTPProxy"] = spoofedProxyHostStr;
    proxy[@"HTTPPort"] = @(spoofedProxyPortNum);
    proxy[@"HTTPSEnable"] = @YES;
    proxy[@"HTTPSProxy"] = spoofedProxyHostStr;
    proxy[@"HTTPSPort"] = @(spoofedProxyPortNum);
    config.connectionProxyDictionary = proxy;
}

static NSURLSessionConfiguration *getDefaultSessionConfig_hook(Class self, SEL _cmd) {
    NSURLSessionConfiguration *config = orig_defaultSessionConfiguration(self, _cmd);
    czfApplyProxy(config);
    return config;
}

static NSURLSessionConfiguration *getEphemeralSessionConfig_hook(Class self, SEL _cmd) {
    NSURLSessionConfiguration *config = orig_ephemeralSessionConfiguration(self, _cmd);
    czfApplyProxy(config);
    return config;
}

static NSURLSessionConfiguration *getBackgroundSessionConfig_hook(Class self, SEL _cmd, NSString *identifier) {
    NSURLSessionConfiguration *config = orig_backgroundSessionConfiguration(self, _cmd, identifier);
    czfApplyProxy(config);
    return config;
}

// --- sysctl 系原函数（重绑定前先存） ---
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_uname)(struct utsname *) = NULL;

static BOOL czfIsMachineMib(int *name, u_int namelen) {
    // hw.machine / hw.model 的 mib 恰好是两级 {CTL_HW, HW_MACHINE|HW_MODEL}，
    // 多一级就不是这俩叶子节点，原样放行，别误拦。
    return name != NULL && namelen == 2 && name[0] == CTL_HW &&
        (name[1] == HW_MACHINE || name[1] == HW_MODEL);
}

static int czfAnswerMachine(void *oldp, size_t *oldlenp) {
    // 调用方保证 oldlenp != NULL（读 hw.machine，newp == NULL）
    const char *machine = [spoofedMachineStr UTF8String];
    size_t need = strlen(machine) + 1;
    if (oldp == NULL) {
        // 只要长度
        *oldlenp = need;
        return 0;
    }
    if (*oldlenp < need) {
        *oldlenp = need;
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, machine, need);
    *oldlenp = need;
    return 0;
}

static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (czfIsMachineMib(name, namelen)) {
        // 写 hw.machine 没有意义、没处写长度的非法调用，
        // 都按原样走（原函数按系统行为拒绝或处理）
        if (newp != NULL || oldlenp == NULL) {
            return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
        }
        return czfAnswerMachine(oldp, oldlenp);
    }
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name != NULL && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0)) {
        if (newp != NULL || oldlenp == NULL) {
            return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
        }
        return czfAnswerMachine(oldp, oldlenp);
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int hook_uname(struct utsname *buf) {
    int ret = orig_uname(buf);
    if (ret == 0 && buf != NULL && spoofedMachineStr != nil) {
        strncpy(buf->machine, [spoofedMachineStr UTF8String], sizeof(buf->machine) - 1);
        buf->machine[sizeof(buf->machine) - 1] = '\0';
    }
    return ret;
}

void DeviceFingerprintHookInit(NSString *advertisingIdentifier, NSString *deviceName, NSString *systemVersion, NSString *machine, NSString *region, NSString *proxyHost, NSInteger proxyPort) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    if (advertisingIdentifier != nil) {
        spoofedIDFAUUID = [[NSUUID alloc] initWithUUIDString:advertisingIdentifier];
        if (spoofedIDFAUUID != nil) {
            Class asClass = objc_getClass("ASIdentifierManager");
            if (asClass == Nil) {
                dlopen("/System/Library/Frameworks/AdSupport.framework/AdSupport", RTLD_NOW);
                asClass = objc_getClass("ASIdentifierManager");
            }
            if (asClass != Nil) {
                Method m = class_getInstanceMethod(asClass, @selector(advertisingIdentifier));
                if (m != NULL) {
                    method_setImplementation(m, (IMP)getIDFA_hook);
                }
                // ATT 状态与 IDFA 一致：给了真 UUID，ATT 就是已授权。
                Method att = class_getInstanceMethod(asClass, @selector(isAdvertisingTrackingEnabled));
                if (att != NULL) {
                    method_setImplementation(att, (IMP)getATTEnabled_hook);
                }
            }
        }
    }

    if (deviceName != nil) {
        spoofedDeviceNameStr = deviceName;
        Method m = class_getInstanceMethod(objc_getClass("UIDevice"), @selector(name));
        if (m != NULL) {
            method_setImplementation(m, (IMP)getDeviceName_hook);
        }
    }

    if (systemVersion != nil) {
        spoofedSystemVersionStr = systemVersion;
        Method m = class_getInstanceMethod(objc_getClass("UIDevice"), @selector(systemVersion));
        if (m != NULL) {
            method_setImplementation(m, (IMP)getSystemVersion_hook);
        }
    }

    if (machine != nil) {
        spoofedMachineStr = machine;
        orig_sysctl = sysctl;
        orig_sysctlbyname = sysctlbyname;
        orig_uname = uname;
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, sysctl, hook_sysctl, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, sysctlbyname, hook_sysctlbyname, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, uname, hook_uname, nil);
        // 屏幕与机型一致：指纹读到的机型与屏幕对得上。
        // 注意：UIScreen.bounds 也参与布局，伪装成比真机小的屏
        // 时个别直接拿它排版的 App 可能留白；真机验到就关指纹。
        CGFloat w = 0, h = 0, s = 0;
        if (czfScreenForMachine(machine, &w, &h, &s)) {
            spoofedNativeBounds = CGRectMake(0, 0, w, h);
            spoofedBounds = CGRectMake(0, 0, w / s, h / s);
            spoofedScale = s;
            Class screenClass = objc_getClass("UIScreen");
            if (screenClass != Nil) {
                Method b = class_getInstanceMethod(screenClass, @selector(bounds));
                if (b != NULL) method_setImplementation(b, (IMP)getScreenBounds_hook);
                Method nb = class_getInstanceMethod(screenClass, @selector(nativeBounds));
                if (nb != NULL) method_setImplementation(nb, (IMP)getScreenNativeBounds_hook);
                Method sc = class_getInstanceMethod(screenClass, @selector(scale));
                if (sc != NULL) method_setImplementation(sc, (IMP)getScreenScale_hook);
                Method ns = class_getInstanceMethod(screenClass, @selector(nativeScale));
                if (ns != NULL) method_setImplementation(ns, (IMP)getScreenNativeScale_hook);
            }
        }
    }

    // 地区（语言 + 时区 + 地区）：客端以为自己在另一个国家/地区。
    // 注意：preferredLanguages 会影响 App 的本地化语言（有该语言
    // 包时界面语言跟着变），时区影响时间显示；这就是地区伪装
    // 本身，不是 bug。
    if (region != nil) {
        NSString *localeID = nil, *language = nil, *tzName = nil;
        if (czfRegionInfo(region, &localeID, &language, &tzName)) {
            spoofedLocale = [NSLocale localeWithLocaleIdentifier:localeID];
            spoofedLanguages = @[language];
            spoofedTimeZone = [NSTimeZone timeZoneWithName:tzName];
            if (spoofedLocale != nil) {
                Class localeClass = objc_getClass("NSLocale");
                if (localeClass != Nil) {
                    Method m = class_getClassMethod(localeClass, @selector(currentLocale));
                    if (m != NULL) method_setImplementation(m, (IMP)getCurrentLocale_hook);
                    Method pl = class_getClassMethod(localeClass, @selector(preferredLanguages));
                    if (pl != NULL) method_setImplementation(pl, (IMP)getPreferredLanguages_hook);
                }
            }
            if (spoofedTimeZone != nil) {
                Class tzClass = objc_getClass("NSTimeZone");
                if (tzClass != Nil) {
                    Method lt = class_getClassMethod(tzClass, @selector(localTimeZone));
                    if (lt != NULL) method_setImplementation(lt, (IMP)getLocalTimeZone_hook);
                    Method st = class_getClassMethod(tzClass, @selector(systemTimeZone));
                    if (st != NULL) method_setImplementation(st, (IMP)getSystemTimeZone_hook);
                    Method dt = class_getClassMethod(tzClass, @selector(defaultTimeZone));
                    if (dt != NULL) method_setImplementation(dt, (IMP)getDefaultTimeZone_hook);
                }
            }
        }
    }

    // 每分身单独代理：只在填了 host 且端口 > 0 时挂，
    // 三种 session 配置都走同一个 czfApplyProxy。
    if (proxyHost != nil && proxyHost.length > 0 && proxyPort > 0) {
        spoofedProxyHostStr = proxyHost;
        spoofedProxyPortNum = proxyPort;
        Class cfgClass = objc_getClass("NSURLSessionConfiguration");
        if (cfgClass != Nil) {
            Method dm = class_getClassMethod(cfgClass, @selector(defaultSessionConfiguration));
            if (dm != NULL) {
                orig_defaultSessionConfiguration = (NSURLSessionConfiguration *(*)(Class, SEL))method_getImplementation(dm);
                method_setImplementation(dm, (IMP)getDefaultSessionConfig_hook);
            }
            Method em = class_getClassMethod(cfgClass, @selector(ephemeralSessionConfiguration));
            if (em != NULL) {
                orig_ephemeralSessionConfiguration = (NSURLSessionConfiguration *(*)(Class, SEL))method_getImplementation(em);
                method_setImplementation(em, (IMP)getEphemeralSessionConfig_hook);
            }
            Method bm = class_getClassMethod(cfgClass, @selector(backgroundSessionConfigurationWithIdentifier:));
            if (bm != NULL) {
                orig_backgroundSessionConfiguration = (NSURLSessionConfiguration *(*)(Class, SEL, NSString *))method_getImplementation(bm);
                method_setImplementation(bm, (IMP)getBackgroundSessionConfig_hook);
            }
        }
    }
}
