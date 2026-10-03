#import "QemuBridge.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

@implementation HarnessQemuBridge
+ (int)runLibrary:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    static BOOL invoked = NO;
    @synchronized(self) {
        if (invoked) return -3;
        invoked = YES;
    }
    void *library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!library) return -1;
    int (*initialize)(int, const char *[], const char *[]) = dlsym(library, "qemu_init");
    void (*mainLoop)(void) = dlsym(library, "qemu_main_loop");
    void (*cleanup)(void) = dlsym(library, "qemu_cleanup");
    if (!initialize || !mainLoop || !cleanup) {
        dlclose(library);
        return -2;
    }
    const char **argv = calloc(arguments.count + 1, sizeof(char *));
    if (!argv) return -4;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        argv[i] = strdup(arguments[i].UTF8String);
        if (!argv[i]) {
            for (NSUInteger j = 0; j < i; j++) free((void *)argv[j]);
            free(argv);
            return -4;
        }
    }
    const char *envp[] = { NULL };
    int result = initialize((int)arguments.count, argv, envp);
    if (result == 0) { mainLoop(); cleanup(); }
    for (NSUInteger i = 0; i < arguments.count; i++) free((void *)argv[i]);
    free(argv);
    // Keep the library loaded; cleanup does not make its global state restartable.
    return result;
}
@end
