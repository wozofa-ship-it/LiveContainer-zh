// CZFProxy.m
// 单 App VPN 重定向插件（验证版，2026-10-21）
//
// 只部署到被标记 App 的专属插件目录（不进全局目录），加载即生效：
// 把该 App 的 TCP 流量拐进宿主进程里的 Xray 核心（本地 SOCKS5
// 127.0.0.1:10827，核心再走用户指定的节点出网）。
//
// 方案（fake-IP，与主流 tun 实现同路）：
// - getaddrinfo：A 查询不真解析，直接发一个 198.18.x.x 的假 IP，
//   域名↔假IP 映射留表；AAAA 查询返回无结果，让 App 回退 IPv4
//   （顺带堵住走真 IPv6 绕过代理的口子）；IP 字面量/.local/
//   AI_NUMERICHOST 走原函数。
// - connect：目标是假 IP → 按域名向 SOCKS 请求；目标是真实公网
//   IP（App 自带 DoH 等绕过 getaddrinfo 的情况）→ 按 IP 向 SOCKS
//   请求，一样不漏；回环/局域网 → 直连。
// - 兜底 fail-open：动手前先廉价探一次核心在不在（5 秒缓存），
//   核心不在 → 全部直连，App 照常上网，绝不因为 VPN 没开而断网。
//   核心在但某条连接经节点不可达 → 如实把失败返回给 App（与
//   正常网络错误无异）。
//
// 只处理 TCP/IPv4（v0 验证范围）。UDP、IPv6 后续再补。
// 性能：只在连接建立那一瞬干活（握手一次），数据通路是原始
// socket 直通，无逐包开销；无定时器、无轮询。

#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "litehook.h"

#define CZF_SOCKS_PORT 10827
#define CZF_HTTP_PORT 10828
// fake-IP 段 198.18.0.0/15 是 RFC 2544 基准测试保留段，
// 现实网络里不会有真主机，各家 tun 实现都拿它当假 IP 池。
#define CZF_FAKE_NET 0xC6120000u // 198.18.0.0

static int (*orig_connect)(int, const struct sockaddr *, socklen_t);
static int (*orig_getaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int);
// connectx 的参数全是指针/32 位整数，用 ABI 等价的不透明
// 签名声明，避免依赖系统头里冷门的 sa_endpoints_t 等 typedef
static int (*orig_connectx)(int, const void *, uint32_t, unsigned int, const void *, unsigned int, size_t *, uint32_t *);

static int CZFConnect(int, const struct sockaddr *, socklen_t);

// MARK: - 运行统计
// 计数写到插件同目录的 CZFProxyStats.txt，宿主在该 App 的
// 设置页读出来显示——用来一眼分清"插件没干活/某类连接没
// 被拦到/拦到了但没连通"，不再靠猜。
static volatile int64_t gStatLoads = 0;
static volatile int64_t gStatGaiFake = 0;
static volatile int64_t gStatGaiPass = 0;
static volatile int64_t gStatConnProxied = 0;
static volatile int64_t gStatConnDirect = 0;
static volatile int64_t gStatConnFailed = 0;
static volatile int64_t gStatConnPass = 0;
static volatile int64_t gStatConnx = 0;
static volatile int64_t gStatSelfTest = 0;
static volatile int64_t gStatSwizzled = 0;
static volatile int64_t gStatQuicBlocked = 0;
static volatile int64_t gStatCfg = 0;
static double gLastStatWrite = 0;
static pthread_mutex_t gStatLock = PTHREAD_MUTEX_INITIALIZER;
// 统计按 App 分文件（CZFProxyStats-<包名>.txt）：所有开了
// VPN 又没专属目录的 App 共用同一个插件目录，写同一个文件
// 会互相覆盖，根本分不清是谁的数字（真机实测踩到）。
static NSString *gStatsPath = nil;

static void CZFWriteStats(BOOL force) {
    if (!gStatsPath) return;
    double now = [NSDate timeIntervalSinceReferenceDate];
    pthread_mutex_lock(&gStatLock);
    if (!force && now - gLastStatWrite < 1.5) {
        pthread_mutex_unlock(&gStatLock);
        return;
    }
    gLastStatWrite = now;
    pthread_mutex_unlock(&gStatLock);
    NSString *text = [NSString stringWithFormat:@"load=%lld gaiFake=%lld gaiPass=%lld proxied=%lld direct=%lld failed=%lld pass=%lld connectx=%lld selftest=%lld swizzled=%lld quic=%lld cfg=%lld",
        gStatLoads, gStatGaiFake, gStatGaiPass, gStatConnProxied, gStatConnDirect, gStatConnFailed, gStatConnPass, gStatConnx, gStatSelfTest, gStatSwizzled, gStatQuicBlocked, gStatCfg];
    [text writeToFile:gStatsPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

// MARK: - 域名 ↔ fake-IP 映射表

static pthread_mutex_t gMapLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSString *, NSString *> *gIPByHost;
static NSMutableDictionary<NSString *, NSString *> *gHostByIP;
static uint32_t gFakeCounter = 0;

static NSString *CZFFakeIPForHost(NSString *host) {
    pthread_mutex_lock(&gMapLock);
    NSString *ip = gIPByHost[host];
    if (!ip) {
        gFakeCounter++;
        // 跳过 .0/.255 结尾这类不像主机地址的值
        if ((gFakeCounter & 0xFF) == 0 || (gFakeCounter & 0xFF) == 0xFF) gFakeCounter++;
        uint32_t v = CZF_FAKE_NET | (gFakeCounter & 0xFFFF);
        struct in_addr a; a.s_addr = htonl(v);
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &a, buf, sizeof(buf));
        ip = [NSString stringWithUTF8String:buf];
        gIPByHost[host] = ip;
        gHostByIP[ip] = host;
    }
    pthread_mutex_unlock(&gMapLock);
    return ip;
}

static NSString *CZFHostForFakeIP(NSString *ip) {
    pthread_mutex_lock(&gMapLock);
    NSString *host = gHostByIP[ip];
    pthread_mutex_unlock(&gMapLock);
    return host;
}

static BOOL CZFIsFakeIP(uint32_t hostOrderIP) {
    return (hostOrderIP & 0xFFFE0000u) == CZF_FAKE_NET;
}

static BOOL CZFIsPrivateOrLoopback(uint32_t h) {
    if ((h >> 24) == 127) return YES;                    // 127.0.0.0/8
    if ((h >> 24) == 10) return YES;                     // 10.0.0.0/8
    if ((h >> 20) == 0xAC1) return YES;                  // 172.16.0.0/12
    if ((h >> 16) == 0xC0A8) return YES;                  // 192.168.0.0/16
    if ((h >> 16) == 0xA9FE) return YES;                  // 169.254.0.0/16
    if (h == 0) return YES;                              // 0.0.0.0
    return NO;
}

// MARK: - SOCKS5 握手

static BOOL CZFWriteAll(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        p += n; len -= (size_t)n;
    }
    return YES;
}

static BOOL CZFReadAll(int fd, void *buf, size_t len) {
    char *p = (char *)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        p += n; len -= (size_t)n;
    }
    return YES;
}

// 核心在不在：临时 socket 连本地 SOCKS 口 + 打个招呼，成功即在。
// 结果缓存：活 5 秒、死 2 秒（核心刚起来能很快被发现）。
static BOOL CZFCoreAlive(void) {
    static double lastCheck = 0;
    static BOOL lastResult = NO;
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    double now = [NSDate timeIntervalSinceReferenceDate];
    pthread_mutex_lock(&lock);
    // "活着"的结论缓存 60 秒：核心跟着宿主进程走，活着时极少
    // 中途死掉；缓存太短时偶发探活失败会让一批连接/会话漏掉
    // 代理、直连卡死，表现为"抽风"。死了的结论只缓存 3 秒，
    // 核心被重新拉起后能很快恢复。
    double ttl = lastResult ? 60.0 : 3.0;
    if (now - lastCheck < ttl && lastCheck > 0) {
        BOOL r = lastResult;
        pthread_mutex_unlock(&lock);
        return r;
    }
    pthread_mutex_unlock(&lock);

    BOOL alive = NO;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        // 探活必须快：它卡在连接/建会话的必经之路上，超时压到
        // 0.3 秒（回环握手正常是毫秒级，慢了就是核心不在状态）
        struct timeval tv = { .tv_sec = 0, .tv_usec = 300 * 1000 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(CZF_SOCKS_PORT);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (orig_connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
            const unsigned char greet[3] = {0x05, 0x01, 0x00};
            unsigned char resp[2] = {0, 0};
            if (CZFWriteAll(fd, greet, 3) && CZFReadAll(fd, resp, 2) && resp[0] == 0x05 && resp[1] == 0x00) {
                alive = YES;
            }
        }
        close(fd);
    }

    pthread_mutex_lock(&lock);
    lastCheck = [NSDate timeIntervalSinceReferenceDate];
    lastResult = alive;
    pthread_mutex_unlock(&lock);
    return alive;
}

// 在已连上 SOCKS 口的 fd 上发连接请求（域名或 IPv4 二选一）。
static BOOL CZFSocksRequest(int fd, NSString *hostOrNil, uint32_t ipHostOrder, uint16_t portNetworkOrder) {
    const unsigned char greet[3] = {0x05, 0x01, 0x00};
    unsigned char resp[2];
    if (!CZFWriteAll(fd, greet, 3) || !CZFReadAll(fd, resp, 2)) return NO;
    if (resp[0] != 0x05 || resp[1] != 0x00) return NO;

    unsigned char req[300];
    size_t n = 0;
    req[n++] = 0x05; req[n++] = 0x01; req[n++] = 0x00;
    if (hostOrNil) {
        NSData *d = [hostOrNil dataUsingEncoding:NSUTF8StringEncoding];
        if (d.length == 0 || d.length > 255) return NO;
        req[n++] = 0x03;
        req[n++] = (unsigned char)d.length;
        memcpy(req + n, d.bytes, d.length);
        n += d.length;
    } else {
        req[n++] = 0x01;
        uint32_t v = htonl(ipHostOrder);
        memcpy(req + n, &v, 4);
        n += 4;
    }
    memcpy(req + n, &portNetworkOrder, 2);
    n += 2;
    if (!CZFWriteAll(fd, req, n)) return NO;

    unsigned char head[4];
    if (!CZFReadAll(fd, head, 4)) return NO;
    if (head[0] != 0x05 || head[1] != 0x00) return NO; // REP != 0 即失败
    // 吞掉应答里的绑定地址+端口
    size_t rest = 0;
    switch (head[3]) {
        case 0x01: rest = 4 + 2; break;
        case 0x03: {
            unsigned char lenb;
            if (!CZFReadAll(fd, &lenb, 1)) return NO;
            rest = lenb + 2;
            break;
        }
        case 0x04: rest = 16 + 2; break;
        default: return NO;
    }
    unsigned char buf[300];
    while (rest > 0) {
        size_t chunk = rest > sizeof(buf) ? sizeof(buf) : rest;
        if (!CZFReadAll(fd, buf, chunk)) return NO;
        rest -= chunk;
    }
    return YES;
}

// MARK: - connect 钩子

static int CZFConnect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    if (!addr || addr->sa_family != AF_INET) {
        __sync_add_and_fetch(&gStatConnPass, 1);
        return orig_connect(sockfd, addr, addrlen);
    }
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    uint32_t ip = ntohl(sin->sin_addr.s_addr);

    if (CZFIsPrivateOrLoopback(ip)) {
        __sync_add_and_fetch(&gStatConnPass, 1);
        return orig_connect(sockfd, addr, addrlen);
    }
    // 只代理 TCP 流套接字：UDP 的 connect 只是给数据包定个默认
    // 去向，拿去做 SOCKS 握手只会把它卡死。例外：发往公网
    // 443 的 UDP 就是 QUIC（YouTube 等），直连必死还会拖住它
    // 回退 TCP——当场拒掉，让它立刻改走 TCP 被代理接住。
    int sockType = 0;
    socklen_t sockTypeLen = sizeof(sockType);
    if (getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sockType, &sockTypeLen) != 0 || sockType != SOCK_STREAM) {
        if (sockType == SOCK_DGRAM && ntohs(sin->sin_port) == 443) {
            __sync_add_and_fetch(&gStatQuicBlocked, 1);
            CZFWriteStats(NO);
            errno = ECONNREFUSED;
            return -1;
        }
        __sync_add_and_fetch(&gStatConnPass, 1);
        return orig_connect(sockfd, addr, addrlen);
    }
    if (!CZFCoreAlive()) {
        // 核心不在：fail-open 直连，App 不断网
        __sync_add_and_fetch(&gStatConnDirect, 1);
        CZFWriteStats(NO);
        return orig_connect(sockfd, addr, addrlen);
    }

    NSString *host = nil;
    if (CZFIsFakeIP(ip)) {
        char buf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf));
        host = CZFHostForFakeIP([NSString stringWithUTF8String:buf]);
        // 映射丢失（极少数情况）时退化为按 IP 请求
    }

    // 非阻塞 socket 临时转阻塞做握手，做完恢复；握手超时 10 秒封顶，
    // 不让 connect 无限期挂住 App 的网络线程。
    int flags = fcntl(sockfd, F_GETFL, 0);
    BOOL wasNonBlocking = (flags >= 0) && (flags & O_NONBLOCK);
    struct timeval oldRcv, oldSnd;
    socklen_t optLen = sizeof(struct timeval);
    BOOL hasOldRcv = getsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &oldRcv, &optLen) == 0;
    optLen = sizeof(struct timeval);
    BOOL hasOldSnd = getsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &oldSnd, &optLen) == 0;
    if (wasNonBlocking) fcntl(sockfd, F_SETFL, flags & ~O_NONBLOCK);
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    int result = -1;
    int savedErrno = ECONNREFUSED;
    struct sockaddr_in socksAddr;
    memset(&socksAddr, 0, sizeof(socksAddr));
    socksAddr.sin_family = AF_INET;
    socksAddr.sin_port = htons(CZF_SOCKS_PORT);
    socksAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (orig_connect(sockfd, (struct sockaddr *)&socksAddr, sizeof(socksAddr)) == 0) {
        if (CZFSocksRequest(sockfd, host, ip, sin->sin_port)) {
            result = 0;
        }
    } else {
        savedErrno = errno;
    }

    if (hasOldRcv) setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &oldRcv, sizeof(oldRcv));
    if (hasOldSnd) setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &oldSnd, sizeof(oldSnd));
    if (wasNonBlocking) fcntl(sockfd, F_SETFL, flags);

    if (result != 0) {
        // fd 已连到 SOCKS 口但请求失败时，这个 fd 没法再改作直连，
        // 如实返回失败（语义=经 VPN 不可达，与普通连接失败无异）。
        errno = savedErrno;
        __sync_add_and_fetch(&gStatConnFailed, 1);
    } else {
        __sync_add_and_fetch(&gStatConnProxied, 1);
    }
    CZFWriteStats(NO);
    return result;
}

// connectx 只观察不拦截：新式网络栈（Network.framework）发
// 起连接走的是这个接口而不是 connect，先数它到底来不来、
// 来多少，确认后再决定要不要代理它。
static int CZFConnectx(int s, const void *ep, uint32_t aid, unsigned int flags, const void *iov, unsigned int iovcnt, size_t *len, uint32_t *cid) {
    __sync_add_and_fetch(&gStatConnx, 1);
    CZFWriteStats(NO);
    return orig_connectx(s, ep, aid, flags, iov, iovcnt, len, cid);
}

// MARK: - QUIC 快速失败（sendto/sendmsg）
// QUIC 也常用"不 connect、直接带地址发包"的 UDP 套接字，上
// 面的 connect 拦不住。凡是发往公网 443 的 UDP 包当场拒掉
// （只认 443：DNS 的 53 等其它 UDP 一概不碰）。
static BOOL CZFIsQUICAddr(const struct sockaddr *addr) {
    if (!addr || addr->sa_family != AF_INET) return NO;
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    if (ntohs(sin->sin_port) != 443) return NO;
    return !CZFIsPrivateOrLoopback(ntohl(sin->sin_addr.s_addr));
}

static BOOL CZFIsUDPSocket(int fd) {
    int t = 0;
    socklen_t tl = sizeof(t);
    return getsockopt(fd, SOL_SOCKET, SO_TYPE, &t, &tl) == 0 && t == SOCK_DGRAM;
}

static ssize_t CZFSendto(int fd, const void *buf, size_t len, int flags, const struct sockaddr *addr, socklen_t addrlen) {
    if (addr && CZFIsQUICAddr(addr) && CZFIsUDPSocket(fd)) {
        __sync_add_and_fetch(&gStatQuicBlocked, 1);
        CZFWriteStats(NO);
        errno = ECONNREFUSED;
        return -1;
    }
    return orig_sendto(fd, buf, len, flags, addr, addrlen);
}

static ssize_t CZFSendmsg(int fd, const struct msghdr *msg, int flags) {
    if (msg && msg->msg_name && CZFIsQUICAddr((const struct sockaddr *)msg->msg_name) && CZFIsUDPSocket(fd)) {
        __sync_add_and_fetch(&gStatQuicBlocked, 1);
        CZFWriteStats(NO);
        errno = ECONNREFUSED;
        return -1;
    }
    return orig_sendmsg(fd, msg, flags);
}

// MARK: - NSURLSession 配置改写（第二层拦截）
// 有一类 App（如 X）的网络完全不经过 getaddrinfo/connect——它
// 们走 NSURLSession 框架。就改写框架这一层：App 创建会话时
// 给它的配置塞一份代理字典，指向核心的 HTTP 入口，框架会自
// 己把请求（含 HTTPS 的 CONNECT 隧道）送进代理。核心不在时
// 不动配置（fail-open，别把 App 的网弄断）。
static NSURLSession *(*orig_sessionWithConfig)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *);

static NSDictionary *CZFProxyDict(void) {
    return @{
        @"HTTPEnable": @YES,
        @"HTTPProxy": @"127.0.0.1",
        @"HTTPPort": @(CZF_HTTP_PORT),
        @"HTTPSEnable": @YES,
        @"HTTPSProxy": @"127.0.0.1",
        @"HTTPSPort": @(CZF_HTTP_PORT),
        @"SOCKSEnable": @YES,
        @"SOCKSProxy": @"127.0.0.1",
        @"SOCKSPort": @(CZF_SOCKS_PORT),
    };
}

// 给一份会话配置盖上代理字典（核心不在时不动）。isFactory 区分
// 统计口径：YES=配置出厂时盖的，NO=建会话时盖的。
static NSURLSessionConfiguration *CZFStampConfig(NSURLSessionConfiguration *config, BOOL isFactory) {
    if (!config || !CZFCoreAlive()) return config;
    NSMutableDictionary *merged = [config.connectionProxyDictionary mutableCopy] ?: [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:CZFProxyDict()];
    config.connectionProxyDictionary = merged;
    __sync_add_and_fetch(isFactory ? &gStatCfg : &gStatSwizzled, 1);
    CZFWriteStats(NO);
    return config;
}

static NSURLSession *CZFSessionWithConfig(id self, SEL _cmd, NSURLSessionConfiguration *config, id delegate, NSOperationQueue *queue) {
    CZFStampConfig(config, NO);
    return orig_sessionWithConfig(self, _cmd, config, delegate, queue);
}

// 配置工厂方法的替换实现：播放器（AVPlayer）等系统媒体管线不走
// App 自己建会话的入口，它们在内部用这些工厂方法取配置建会话。
// 代理字典盖在出厂配置上，才能把这类流量也罩住（X 的视频就是
// 栽在这里：文字会话被盖、播放器管线没被盖，视频一直直连转圈）。
static NSURLSessionConfiguration *(*orig_defaultConfig)(id, SEL);
static NSURLSessionConfiguration *CZFDefaultConfig(id self, SEL _cmd) {
    return CZFStampConfig(orig_defaultConfig(self, _cmd), YES);
}
static NSURLSessionConfiguration *(*orig_ephemeralConfig)(id, SEL);
static NSURLSessionConfiguration *CZFEphemeralConfig(id self, SEL _cmd) {
    return CZFStampConfig(orig_ephemeralConfig(self, _cmd), YES);
}
static NSURLSessionConfiguration *(*orig_backgroundConfig)(id, SEL, NSString *);
static NSURLSessionConfiguration *CZFBackgroundConfig(id self, SEL _cmd, NSString *identifier) {
    return CZFStampConfig(orig_backgroundConfig(self, _cmd, identifier), YES);
}

static void CZFInstallSessionSwizzle(void) {
    Class cls = NSClassFromString(@"NSURLSession");
    if (cls) {
        Method m = class_getClassMethod(cls, @selector(sessionWithConfiguration:delegate:delegateQueue:));
        if (m) {
            orig_sessionWithConfig = (NSURLSession *(*)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *))method_getImplementation(m);
            method_setImplementation(m, (IMP)CZFSessionWithConfig);
        }
    }
    Class cfgCls = NSClassFromString(@"NSURLSessionConfiguration");
    if (cfgCls) {
        Method dm = class_getClassMethod(cfgCls, @selector(defaultSessionConfiguration));
        if (dm) {
            orig_defaultConfig = (NSURLSessionConfiguration *(*)(id, SEL))method_getImplementation(dm);
            method_setImplementation(dm, (IMP)CZFDefaultConfig);
        }
        Method em = class_getClassMethod(cfgCls, @selector(ephemeralSessionConfiguration));
        if (em) {
            orig_ephemeralConfig = (NSURLSessionConfiguration *(*)(id, SEL))method_getImplementation(em);
            method_setImplementation(em, (IMP)CZFEphemeralConfig);
        }
        Method bm = class_getClassMethod(cfgCls, @selector(backgroundSessionConfigurationWithIdentifier:));
        if (bm) {
            orig_backgroundConfig = (NSURLSessionConfiguration *(*)(id, SEL, NSString *))method_getImplementation(bm);
            method_setImplementation(bm, (IMP)CZFBackgroundConfig);
        }
    }
}

// MARK: - getaddrinfo 钩子

static uint16_t CZFPortFromService(const char *service) {
    if (!service) return 0;
    char *end = NULL;
    long v = strtol(service, &end, 10);
    if (end && *end == '\0') return htons((uint16_t)v);
    struct servent *se = getservbyname(service, "tcp");
    if (se) return (uint16_t)se->s_port; // 已是网络字节序
    return 0;
}

static int CZFGetAddrInfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    // gaiPass 记总调用数，gaiFake 记其中被换成假 IP 的次数
    __sync_add_and_fetch(&gStatGaiPass, 1);
    if (!node || !*node) {
        return orig_getaddrinfo(node, service, hints, res);
    }
    // IP 字面量、.local、显式要求数值主机：走原函数
    struct in_addr v4;
    struct in6_addr v6;
    if (inet_pton(AF_INET, node, &v4) == 1 || inet_pton(AF_INET6, node, &v6) == 1) {
        return orig_getaddrinfo(node, service, hints, res);
    }
    NSString *host = [NSString stringWithUTF8String:node];
    if ([host hasSuffix:@".local"]) {
        return orig_getaddrinfo(node, service, hints, res);
    }
    if (hints) {
        if (hints->ai_flags & AI_NUMERICHOST) {
            return orig_getaddrinfo(node, service, hints, res);
        }
        if (hints->ai_socktype == SOCK_DGRAM) {
            // v0 不代理 UDP：给假 IP 只会把 UDP 包发进死地址，
            // 不如走原解析直连（已知的 v0 限制，后续补 UDP）
            return orig_getaddrinfo(node, service, hints, res);
        }
        if (hints->ai_family == AF_INET6) {
            // v0 只代理 IPv4：AAAA 单独查询返回无结果，促回退
            return EAI_NONAME;
        }
        if (hints->ai_family != AF_UNSPEC && hints->ai_family != AF_INET) {
            return orig_getaddrinfo(node, service, hints, res);
        }
    }

    NSString *fakeIP = CZFFakeIPForHost([host lowercaseString]);
    struct addrinfo *ai = calloc(1, sizeof(struct addrinfo));
    struct sockaddr_in *sin = calloc(1, sizeof(struct sockaddr_in));
    if (!ai || !sin) {
        free(ai); free(sin);
        return EAI_MEMORY;
    }
    sin->sin_len = sizeof(struct sockaddr_in);
    sin->sin_family = AF_INET;
    sin->sin_port = CZFPortFromService(service);
    inet_pton(AF_INET, fakeIP.UTF8String, &sin->sin_addr);

    ai->ai_family = AF_INET;
    ai->ai_socktype = hints ? hints->ai_socktype : SOCK_STREAM;
    if (ai->ai_socktype == 0) ai->ai_socktype = SOCK_STREAM;
    ai->ai_protocol = hints ? hints->ai_protocol : IPPROTO_TCP;
    if (ai->ai_protocol == 0 && ai->ai_socktype == SOCK_STREAM) ai->ai_protocol = IPPROTO_TCP;
    ai->ai_addrlen = sizeof(struct sockaddr_in);
    ai->ai_addr = (struct sockaddr *)sin;
    if (hints && (hints->ai_flags & AI_CANONNAME)) {
        ai->ai_canonname = strdup(node);
    }
    // 链是手工 calloc 的，系统 freeaddrinfo 按 ai_addr/ai_canonname/
    // 节点逐个 free，正好对得上（POSIX 布局）。
    *res = ai;
    __sync_add_and_fetch(&gStatGaiFake, 1);
    CZFWriteStats(NO);
    return 0;
}

// MARK: - 安装

// litehook 全局重绑：覆盖全部镜像（含运行中懒加载的框架，它
// 内部注册了 dyld 新镜像回调补挂），且能处理现代 App 的链式
// 绑定格式——fishhook 在那种格式下找不到符号槽、钩子根本不
// 生效（真机表现为开了 VPN 和没开一样）。原函数在重绑之前
// 用 dlsym 拿函数直址存好：直址调用不经任何符号槽，既不
// 会递归、也不受重绑影响。
__attribute__((constructor))
static void CZFProxyInit(void) {
    gIPByHost = [NSMutableDictionary dictionary];
    gHostByIP = [NSMutableDictionary dictionary];
    // 先定好本 App 的统计文件路径（构造器最开始，后面钩子随时能写）
    Dl_info selfInfo;
    if (dladdr((const void *)CZFProxyInit, &selfInfo) && selfInfo.dli_fname) {
        NSString *dir = [[NSString stringWithUTF8String:selfInfo.dli_fname] stringByDeletingLastPathComponent];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        gStatsPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"CZFProxyStats-%@.txt", bid]];
    }
    orig_connect = (int (*)(int, const struct sockaddr *, socklen_t))dlsym(RTLD_DEFAULT, "connect");
    orig_getaddrinfo = (int (*)(const char *, const char *, const struct addrinfo *, struct addrinfo **))dlsym(RTLD_DEFAULT, "getaddrinfo");
    orig_connectx = (int (*)(int, const void *, uint32_t, unsigned int, const void *, unsigned int, size_t *, uint32_t *))dlsym(RTLD_DEFAULT, "connectx");
    if (orig_connect) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_connect, (void *)CZFConnect, NULL);
    }
    if (orig_getaddrinfo) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_getaddrinfo, (void *)CZFGetAddrInfo, NULL);
    }
    if (orig_connectx) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_connectx, (void *)CZFConnectx, NULL);
    }
    orig_sendto = (ssize_t (*)(int, const void *, size_t, int, const struct sockaddr *, socklen_t))dlsym(RTLD_DEFAULT, "sendto");
    orig_sendmsg = (ssize_t (*)(int, const struct msghdr *, int))dlsym(RTLD_DEFAULT, "sendmsg");
    if (orig_sendto) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_sendto, (void *)CZFSendto, NULL);
    }
    if (orig_sendmsg) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, (void *)orig_sendmsg, (void *)CZFSendmsg, NULL);
    }
    CZFInstallSessionSwizzle();
    __sync_add_and_fetch(&gStatLoads, 1);
    // 自检：钩子装完立刻自调一次解析——计数涨了说明本进程的
    // 符号重绑真的活着（区分"钩子失效"与"App 不走这些接口"）。
    // 查的是不存在的域名，我的钩子会同步发假 IP，不碰真网络。
    int64_t gaiBefore = gStatGaiFake;
    struct addrinfo *selfRes = NULL;
    getaddrinfo("czf-selftest.invalid", "443", NULL, &selfRes);
    if (selfRes) freeaddrinfo(selfRes);
    gStatSelfTest = (gStatGaiFake > gaiBefore) ? 1 : 0;
    CZFWriteStats(YES);
    NSLog(@"[CZFProxy] 已加载：本 App 流量将经 127.0.0.1:%d 的 SOCKS 核心出网（核心不在时直连）", CZF_SOCKS_PORT);
}
