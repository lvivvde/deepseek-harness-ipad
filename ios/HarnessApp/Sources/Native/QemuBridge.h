#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// One embedded QEMU invocation per process; no native JIT or special entitlements.
@interface HarnessQemuBridge : NSObject
+ (int)runLibrary:(NSString *)path arguments:(NSArray<NSString *> *)arguments;
@end
NS_ASSUME_NONNULL_END
