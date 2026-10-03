#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Throwaway bridge: one VM launch per app process. No native iPadOS JIT.
@interface PrototypeQemuBridge : NSObject
+ (int)runLibrary:(NSString *)path arguments:(NSArray<NSString *> *)arguments message:(NSString * _Nullable * _Nullable)message;
@end
NS_ASSUME_NONNULL_END
