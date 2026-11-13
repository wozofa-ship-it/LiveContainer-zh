//
//  Tweaks.h
//  LiveContainer
//
//  Created by s s on 2025/2/7.
//

void swizzle(Class class, SEL originalAction, SEL swizzledAction);
bool performHookDyldApi(const char* functionName, uint32_t adrpOffset, void** origFunction, void* hookFunction);

void NUDGuestHooksInit(void);
void SecItemGuestHooksInit(void);
void DyldHooksInit(bool hideLiveContainer, bool hookDlopen, uint32_t spoofSDKVersion);
void NSFMGuestHooksInit(void);
void NSFMGuestExtensionHooksInit(NSString *parentContainerPath);
void NSURLSCGuestHooksInit(void);
void initDead10ccFix(void);
void IDFVHookInit(NSUUID* uuid);
void DeviceFingerprintHookInit(NSString *advertisingIdentifier, NSString *deviceName, NSString *systemVersion, NSString *machine, NSString *region, NSString *proxyHost, NSInteger proxyPort, NSNumber *screenWidth, NSNumber *screenHeight, NSNumber *screenScale, NSString *localeIdentifier, NSString *language, NSString *timeZoneName);

// D9：NSURLSession 代理字典键名（DeviceFingerprint.m 的 czfApplyProxy
// 与 CZFProxy.m 的 CZFProxyDict 共用）：kCFNetworkProxies* 常量要链
// CFNetwork 框架，仓内没链，用字面量宏不新增链接依赖。键名是
// Apple 定义的固定字符串，两边共用同一份，改一处即同步。
#define CZF_PROXY_KEY_HTTP_ENABLE @"HTTPEnable"
#define CZF_PROXY_KEY_HTTP_PROXY @"HTTPProxy"
#define CZF_PROXY_KEY_HTTP_PORT @"HTTPPort"
#define CZF_PROXY_KEY_HTTPS_ENABLE @"HTTPSEnable"
#define CZF_PROXY_KEY_HTTPS_PROXY @"HTTPSProxy"
#define CZF_PROXY_KEY_HTTPS_PORT @"HTTPSPort"
void NSExtensionGuestHooksInit(NSURL *appURL, NSURL *containerURL);
int LCRunGuestExtension(NSDictionary *request, NSExtensionContext *context);
NSString *LCPrepareGuestExtension(NSDictionary *request);

@interface NSBundle(LiveContainer)
- (instancetype)initWithPathForMainBundle:(NSString *)path;
@end


extern uint32_t appMainImageIndex;
extern void* appExecutableHandle;
extern bool tweakLoaderLoaded;
void* getGuestAppHeader(void);
void* getDSCAddr(void);
void* getCachedSymbol(NSString* symbolName, struct mach_header_64* header);
void saveCachedSymbol(NSString* symbolName, struct mach_header_64* header, uint64_t offset);
void* dlopen_nolock(const char *path, int mode);
void bypass_seg_count_check(void (^block)(void));

static void hook_do_nothing(void) {}
