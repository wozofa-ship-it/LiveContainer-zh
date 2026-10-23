// CZFKeepAlive.m
// 极简保活插件（LiveContainer 注入用 dylib）v1.2
// 原理：App 进后台后循环播放无声音频，保持进程不被系统挂起。
// 设计原则：只做保活这一件事 —— 不用定位、不用画中画、不轮询剪贴板；
//          前台自动停、后台才开；30 秒看门狗只检查不管闲事；全程异常兜底，绝不让宿主 App 崩。
// v1.1 优化：静音音频改为内存数据直接播放（initWithData），去掉临时文件落盘与被系统清理的风险。
// v1.2 优化（减损耗）：白名单门 —— dylib 同目录放 CZFKeepAliveApps.txt
//          （一行一个 bundle id）时，只给名单里的 App 保活；其他 App
//          里完全休眠（不注册通知、不碰音频、零损耗）。没这个文件时
//          维持原行为（所有 App 都保活）。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

static AVAudioPlayer *gPlayer = nil;
static NSTimer *gWatchdog = nil;
static BOOL gInBackground = NO;

// 生成 1 秒静音 WAV 数据（8000Hz 单声道 16bit PCM），生成一次后缓存
static NSData *CZFSilentWAVData(void) {
    static NSData *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t sampleRate = 8000;
        const uint16_t channels = 1;
        const uint16_t bitsPerSample = 16;
        const uint32_t dataSize = sampleRate * channels * (bitsPerSample / 8);
        const uint32_t chunkSize = 36 + dataSize;
        const uint16_t blockAlign = channels * (bitsPerSample / 8);
        const uint32_t byteRate = sampleRate * blockAlign;

        NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataSize];
        [data appendBytes:"RIFF" length:4];
        [data appendBytes:&chunkSize length:4];
        [data appendBytes:"WAVE" length:4];
        [data appendBytes:"fmt " length:4];
        uint32_t subChunk1Size = 16;
        uint16_t audioFormat = 1; // PCM
        [data appendBytes:&subChunk1Size length:4];
        [data appendBytes:&audioFormat length:2];
        [data appendBytes:&channels length:2];
        [data appendBytes:&sampleRate length:4];
        [data appendBytes:&byteRate length:4];
        [data appendBytes:&blockAlign length:2];
        [data appendBytes:&bitsPerSample length:2];
        [data appendBytes:"data" length:4];
        [data appendBytes:&dataSize length:4];
        [data increaseLengthBy:dataSize]; // 补零 = 静音采样
        cached = [data copy];
    });
    return cached;
}

static void CZFStartPlayer(void) {
    if (gPlayer && gPlayer.isPlaying) return;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:nil];
    [session setActive:YES error:nil];
    if (!gPlayer) {
        gPlayer = [[AVAudioPlayer alloc] initWithData:CZFSilentWAVData() error:nil];
        gPlayer.numberOfLoops = -1; // 无限循环
        gPlayer.volume = 0.0;
        [gPlayer prepareToPlay];
    }
    [gPlayer play];
}

static void CZFStartKeepAlive(void) {
    @try {
        CZFStartPlayer();
        if (!gWatchdog) {
            gWatchdog = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
                @try {
                    if (gInBackground && !gPlayer.isPlaying) {
                        CZFStartPlayer(); // 被打断/暂停后自动恢复
                    }
                } @catch (__unused NSException *e) {}
            }];
        }
    } @catch (__unused NSException *e) {}
}

static void CZFStopKeepAlive(void) {
    @try {
        [gWatchdog invalidate];
        gWatchdog = nil;
        [gPlayer pause];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
    } @catch (__unused NSException *e) {}
}

// 白名单门：名单文件存在时按名单决定本 App 要不要保活；
// 文件不存在或读不到，一律保活（不改变现有用法）
static BOOL CZFShouldActivate(void) {
    Dl_info info;
    if (dladdr((void *)&CZFShouldActivate, &info) == 0 || !info.dli_fname) return YES;
    NSString *dir = [@(info.dli_fname) stringByDeletingLastPathComponent];
    NSString *listPath = [dir stringByAppendingPathComponent:@"CZFKeepAliveApps.txt"];
    NSString *content = [NSString stringWithContentsOfFile:listPath encoding:NSUTF8StringEncoding error:nil];
    if (!content) return YES;
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    for (NSString *line in [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length && [trimmed isEqualToString:bundleId]) return YES;
    }
    return NO;
}

__attribute__((constructor))
static void CZFKeepAliveInit(void) {
    @autoreleasepool {
        if (!CZFShouldActivate()) return;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue *mainQ = [NSOperationQueue mainQueue];

        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        gInBackground = YES;
                        CZFStartKeepAlive();
                    }];

        [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        gInBackground = NO;
                        CZFStopKeepAlive();
                    }];

        // 启动时已经在后台的兜底（极少见）
        [nc addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
                            gInBackground = YES;
                            CZFStartKeepAlive();
                        }
                    }];

        // 音频被来电等打断结束后，还在后台就恢复播放
        [nc addObserverForName:AVAudioSessionInterruptionNotification
                        object:[AVAudioSession sharedInstance] queue:mainQ
                    usingBlock:^(NSNotification *note) {
                        NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
                        if (typeNum && typeNum.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded && gInBackground) {
                            CZFStartKeepAlive();
                        }
                    }];
    }
}
