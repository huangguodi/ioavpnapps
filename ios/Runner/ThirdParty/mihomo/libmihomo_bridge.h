#ifndef __MobileBridge_H__
#define __MobileBridge_H__

@import Foundation;

@class MobilePacketFlowPacket;
@protocol MobilePacketFlowBridge;
@class MobilePacketFlowBridge;
@protocol MobileSocketProtector;
@class MobileSocketProtector;

@protocol MobilePacketFlowBridge <NSObject>
- (void)onPacketFlowError:(NSString* _Nullable)message;
- (MobilePacketFlowPacket* _Nullable)readPacket;
- (BOOL)writePacket:(MobilePacketFlowPacket* _Nullable)packet;
@end

@protocol MobileSocketProtector <NSObject>
- (BOOL)markSocket:(int64_t)fd network:(NSString* _Nullable)network address:(NSString* _Nullable)address;
- (BOOL)protectSocket:(int64_t)fd network:(NSString* _Nullable)network address:(NSString* _Nullable)address;
@end

@interface MobilePacketFlowPacket : NSObject
- (nullable instancetype)init:(NSData* _Nullable)data af:(int64_t)af;
- (int64_t)af;
- (NSData* _Nullable)data;
@end

FOUNDATION_EXPORT void MobileClearPacketFlowBridge(void);
FOUNDATION_EXPORT void MobileClearSocketProtector(void);
FOUNDATION_EXPORT BOOL MobileFeedPacketBytes(NSData* _Nullable data, int64_t af);
FOUNDATION_EXPORT void MobileForceUpdateConfig(NSString* _Nullable configFileName);
FOUNDATION_EXPORT NSString* _Nonnull MobileGetMode(void);
FOUNDATION_EXPORT NSString* _Nonnull MobileGetProxies(void);
FOUNDATION_EXPORT void MobileMihomoWarmup(void);
FOUNDATION_EXPORT BOOL MobileMobileStartWithMemory(NSString* _Nullable cfgStr, NSError* _Nullable* _Nullable error);
FOUNDATION_EXPORT void MobileResetNetwork(void);
FOUNDATION_EXPORT BOOL MobileRestartTunnelForNetworkChange(void);
FOUNDATION_EXPORT BOOL MobileSelectProxy(NSString* _Nullable groupName, NSString* _Nullable proxyName);
FOUNDATION_EXPORT BOOL MobileSetAppGroupDirectory(NSString* _Nullable dir);
FOUNDATION_EXPORT void MobileSetLogLevel(NSString* _Nullable level);
FOUNDATION_EXPORT void MobileSetMode(NSString* _Nullable mode);
FOUNDATION_EXPORT void MobileSetPacketFlowBridge(id<MobilePacketFlowBridge> _Nullable bridge);
FOUNDATION_EXPORT void MobileSetSocketProtector(id<MobileSocketProtector> _Nullable protector);
FOUNDATION_EXPORT void MobileStop(void);
FOUNDATION_EXPORT NSString* _Nonnull MobileTestLatency(NSString* _Nullable proxyName);
FOUNDATION_EXPORT int64_t MobileTrafficDown(void);
FOUNDATION_EXPORT int64_t MobileTrafficTotalDown(void);
FOUNDATION_EXPORT int64_t MobileTrafficTotalUp(void);
FOUNDATION_EXPORT int64_t MobileTrafficUp(void);

#endif
