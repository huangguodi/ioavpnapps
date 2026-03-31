#ifndef __GO_REF_HDR__
#define __GO_REF_HDR__
#include <Foundation/Foundation.h>
@interface GoSeqRef : NSObject {}
@property(readonly) int32_t refnum;
@property(strong) id obj;
- (instancetype)initWithRefnum:(int32_t)refnum obj:(id)obj;
- (int32_t)incNum;
@end
@protocol goSeqRefInterface
- (GoSeqRef*) _ref;
@end
#endif
