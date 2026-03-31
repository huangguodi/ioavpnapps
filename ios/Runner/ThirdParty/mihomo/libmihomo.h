#ifndef __Mobile_H__
#define __Mobile_H__

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@class MobilePacketFlowPacket;

@protocol MobilePacketFlowBridge <NSObject>
- (void)onPacketFlowError:(nullable NSString *)message;
- (nullable MobilePacketFlowPacket *)readPacket;
- (BOOL)writePacket:(nullable MobilePacketFlowPacket *)packet;
@end

@protocol MobileSocketProtector <NSObject>
- (BOOL)markSocket:(int64_t)fd network:(nullable NSString *)network address:(nullable NSString *)address;
- (BOOL)protectSocket:(int64_t)fd network:(nullable NSString *)network address:(nullable NSString *)address;
@end

@interface MobilePacketFlowPacket : NSObject
- (nullable instancetype)init:(nullable NSData *)data af:(int64_t)af;
- (int64_t)af;
- (nullable NSData *)data;
@end

FOUNDATION_EXPORT void MobileClearPacketFlowBridge(void);
FOUNDATION_EXPORT void MobileClearSocketProtector(void);
FOUNDATION_EXPORT BOOL MobileFeedPacketBytes(nullable NSData *data, int64_t af);
FOUNDATION_EXPORT BOOL MobileFeedPacketFromFlow(nullable MobilePacketFlowPacket *packet);
FOUNDATION_EXPORT void MobileForceUpdateConfig(nullable NSString *configFileName);
FOUNDATION_EXPORT NSString *MobileGetMode(void);
FOUNDATION_EXPORT NSString *MobileGetProxies(void);
FOUNDATION_EXPORT void MobileMihomoWarmup(void);
FOUNDATION_EXPORT BOOL MobileMobileStartWithMemory(nullable NSString *cfgStr, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT nullable MobilePacketFlowPacket *MobileNewPacketFlowPacket(nullable NSData *data, int64_t af);
FOUNDATION_EXPORT NSString *MobileProxyNames(void);
FOUNDATION_EXPORT void MobileResetNetwork(void);
FOUNDATION_EXPORT BOOL MobileRestartTunnelForNetworkChange(void);
FOUNDATION_EXPORT BOOL MobileSelectProxy(nullable NSString *groupName, nullable NSString *proxyName);
FOUNDATION_EXPORT BOOL MobileSetAppGroupDirectory(nullable NSString *dir);
FOUNDATION_EXPORT void MobileSetLogLevel(nullable NSString *level);
FOUNDATION_EXPORT void MobileSetMode(nullable NSString *mode);
FOUNDATION_EXPORT void MobileSetPacketFlowBridge(nullable id<MobilePacketFlowBridge> bridge);
FOUNDATION_EXPORT void MobileSetSocketProtector(nullable id<MobileSocketProtector> protector);
FOUNDATION_EXPORT void MobileSleep(void);
FOUNDATION_EXPORT void MobileStart(nullable NSString *home, nullable NSString *configFileName);
FOUNDATION_EXPORT void MobileStop(void);
FOUNDATION_EXPORT NSString *MobileTestLatency(nullable NSString *proxyName);
FOUNDATION_EXPORT int64_t MobileTrafficDown(void);
FOUNDATION_EXPORT int64_t MobileTrafficTotalDown(void);
FOUNDATION_EXPORT int64_t MobileTrafficTotalUp(void);
FOUNDATION_EXPORT int64_t MobileTrafficUp(void);
FOUNDATION_EXPORT NSString *MobileVersion(void);
FOUNDATION_EXPORT BOOL MobileWake(void);

NS_ASSUME_NONNULL_END

#endif
