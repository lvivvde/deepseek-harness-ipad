#import "QemuBridge.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

@implementation PrototypeQemuBridge
+ (int)runLibrary:(NSString *)path arguments:(NSArray<NSString *> *)arguments message:(NSString **)message {
    void *library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        if (message) *message = [NSString stringWithUTF8String:dlerror()];
        return -1;
    }
    int (*initialize)(int, const char *[], const char *[]) = dlsym(library, "qemu_init");
    void (*mainLoop)(void) = dlsym(library, "qemu_main_loop");
    void (*cleanup)(void) = dlsym(library, "qemu_cleanup");
    if (!initialize || !mainLoop || !cleanup) {
        if (message) *message = @"Missing UTM shared-library QEMU entry points";
        dlclose(library);
        return -2;
    }
    const char **argv = calloc(arguments.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < arguments.count; i++) argv[i] = strdup(arguments[i].UTF8String);
    const char *envp[] = { NULL };
    int result = initialize((int)arguments.count, argv, envp);
    if (result == 0) {
        mainLoop();
        cleanup();
    }
    for (NSUInteger i = 0; i < arguments.count; i++) free((void *)argv[i]);
    free(argv);
    // Keep the library loaded: QEMU global state is not safely restartable here.
    if (message) *message = [NSString stringWithFormat:@"QEMU returned %d; relaunch the app before another VM", result];
    return result;
}
@end
