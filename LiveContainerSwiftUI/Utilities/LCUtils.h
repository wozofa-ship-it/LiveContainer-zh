#import <Foundation/Foundation.h>
#import "LCMachOUtils.h"
#import "utils.h"
@import UIKit;

typedef NS_ENUM(NSInteger, Store){
    SideStore = 0,
    AltStore = 1,
    ADP = 2,
    Unknown = -1
};

void refreshFile(NSString* execPath);
int dyld_get_program_sdk_version(void);
uint32_t dyld_get_sdk_version(const struct mach_header* mh);

@interface PKZipArchiver : NSObject

- (NSData *)zippedDataForURL:(NSURL *)url;

@end

@interface UIDevice(private)
@property(readonly) NSString* buildVersion;
@end

@interface LCUtils : NSObject

+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName includingExtraInfoDict:(NSDictionary *)extraInfoDict error:(NSError **)error;
// 3.8.645（F1）：导出已装 App 的 IPA——只复制、不改名、不重签：
// 把 bundlePath 指到的 .app 原样拷到 tmp 唯一子目录 Payload/<名>.app，
// 与 archiveIPAWithBundleName 同款 PKZipArchiver 打成标准 Payload/*.app
// 的 .ipa（插件是启动时由 TweakLoader 从独立插件目录运行时注入的，
// 不在 .app 包内，导出的就是原样已签名包）。返回 tmp 里的 .ipa 路径，
// 调用方分享完自行清理；失败返回 nil 并填 error。
+ (NSURL *)czfExportIPAForBundlePath:(NSString *)bundlePath error:(NSError **)error;
+ (NSData *)certificateData;
+ (void)launchMultitaskGuestApp:(NSString *)displayName completionHandler:(void (^)(NSNumber *pid, NSError *error))completionHandler API_AVAILABLE(ios(16.0));


+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (NSProgress *)signFilesWithZSignWithURLs:(NSArray<NSURL*>*)urls completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (NSString*)getCertTeamIdWithKeyData:(NSData*)keyData password:(NSString*)password;
+ (int)validateCertificateWithCompletionHandler:(void(^)(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error))completionHandler;

+ (BOOL)isTXMScriptRequired;
+ (NSString *)base64EncodedUniversalJITScript;

+ (BOOL)isAppGroupAltStoreLike;
+ (Store)store;
+ (NSString *)appUrlScheme;
// P0 回归（3.8.665）：把 LiveProcess 客进程判据转发给 Swift——
// NSUserDefaults(LiveContainer) 的 isLiveProcess 声明在 utils.h
//（本文件已引），Swift 侧走这一行转发，不直接碰分类方法。
+ (BOOL)czfIsLiveProcess;
+ (NSString *)storeInstallURLScheme;
+ (NSString *)getVersionInfo;
+ (NSString *)liveProcessBundleIdentifier;
+ (NSData*)bookmarkForURL:(NSURL*) url;
@end

@interface NSUserDefaults(LiveContainer)
+ (bool)sideStoreExist;
@end

@interface LCP12CertHelper : NSObject

- (instancetype)initWithP12Data:(NSData*)p12Data password:(NSString*)password error:(NSError**)error;
- (NSDate*)getNotValidityNotAfterWithError:(NSError**)error;
- (NSString*)getOrgnizationUnitWithError:(NSError**)error;

@end

typedef NS_ENUM(NSInteger, GeneratedIconStyle){
    Original = -1,
    Light = 0,
    Dark = 1
};

@interface UIImage(LiveContainer)
+ (instancetype)generateIconForBundleURL:(NSURL*)url style:(GeneratedIconStyle)style hasBorder:(BOOL)hasBorder;
@end
BOOL saveCGImage(CGImageRef image, NSURL *url);
CGImageRef loadCGImageFromURL(NSURL *url);
NSNumber *LCGetDefaultClassicMode(NSURL *appURL);
