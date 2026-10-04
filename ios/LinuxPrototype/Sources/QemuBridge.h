#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Throwaway bridge: one VM launch per app process. No native iPadOS JIT.
@interface PrototypeQemuBridge : NSObject
+ (int)runLibrary:(NSString *)path arguments:(NSArray<NSString *> *)arguments message:(NSString * _Nullable * _Nullable)message;
+ (NSDictionary<NSString *, NSNumber *> *)memoryFootprint;
@end
NS_ASSUME_NONNULL_END
