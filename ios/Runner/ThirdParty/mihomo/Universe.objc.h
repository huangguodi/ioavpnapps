#ifndef __Universe_H__
#define __Universe_H__
@import Foundation;
#include "ref.h"
@protocol Universeerror;
@class Universeerror;
@protocol Universeerror <NSObject>
- (NSString* _Nonnull)error;
@end
@interface Universeerror : NSError <goSeqRefInterface, Universeerror> {
}
@property(strong, readonly) _Nonnull GoSeqRef* _ref;
- (nonnull instancetype)initWithRef:(_Nonnull GoSeqRef*)ref;
- (NSString* _Nonnull)error;
@end
#endif
