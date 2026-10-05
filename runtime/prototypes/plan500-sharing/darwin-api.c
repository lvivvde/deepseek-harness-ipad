// PROTOTYPE: tests one Darwin build prerequisite, not the QEMU 9P backend.
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>

#ifdef PLAN500_PRIVATE_DECL
// Explicit declaration matches QEMU v10.2.1 hw/9pfs/9p-util.h.
// QEMU identifies this as a private API; a successful link is not public API approval.
extern int pthread_fchdir_np(int fd);
#endif

int plan500_thread_directory(int fd) { return pthread_fchdir_np(fd); }

#ifndef PLAN500_LIBRARY
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int fd = open(argv[1], O_RDONLY | O_DIRECTORY);
    if (fd < 0) return 3;
    int result = plan500_thread_directory(fd);
    close(fd);
    if (result != 0) return 1;
    FILE *file = fopen("darwin-api-sentinel", "w");
    if (!file) return 4;
    fputs("own scratch directory\n", file);
    fclose(file);
    puts(result == 0 ? "{\"pthreadFchdirWorked\":true}" : "{\"pthreadFchdirWorked\":false}");
    return result == 0 ? 0 : 1;
}
#endif
