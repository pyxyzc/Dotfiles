/* Linux-only diagnostic: time the real fsync without changing its durability. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

int fsync(int fd)
{
    static int (*native_fsync)(int);
    static int trace_fd = -1;
    struct timespec begin, end;
    char descriptor[64], path[4096], record[4224];
    if (!native_fsync)
        native_fsync = dlsym(RTLD_NEXT, "fsync");
    clock_gettime(CLOCK_MONOTONIC, &begin);
    int result = native_fsync(fd);
    int saved_errno = errno;
    clock_gettime(CLOCK_MONOTONIC, &end);
    const char *destination = getenv("VIM_FSYNC_TRACE");
    if (trace_fd < 0 && destination && *destination)
        trace_fd = open(destination, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (trace_fd >= 0) {
        snprintf(descriptor, sizeof(descriptor), "/proc/self/fd/%d", fd);
        ssize_t length = readlink(descriptor, path, sizeof(path) - 1);
        path[length < 0 ? 0 : length] = '\0';
        double elapsed = (end.tv_sec - begin.tv_sec) * 1000.0
                       + (end.tv_nsec - begin.tv_nsec) / 1000000.0;
        int size = snprintf(record, sizeof(record), "%.3f\t%d\t%s\n", elapsed, result, path);
        if (size > 0 && (size_t)size < sizeof(record)) {
            ssize_t ignored = write(trace_fd, record, (size_t)size);
            (void)ignored;
        }
    }
    errno = saved_errno;
    return result;
}
