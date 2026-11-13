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

void DeviceFingerprintHookInit(NSString *advertisingIdentifier, NSString *deviceName, NSString *systemVersion, NSString *machine) {
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
    }
}
