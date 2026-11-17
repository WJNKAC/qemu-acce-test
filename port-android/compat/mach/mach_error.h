#ifndef HV_COMPAT_MACH_ERROR_H
#define HV_COMPAT_MACH_ERROR_H
static inline char *mach_error_string(int kr) { (void)kr; return (char *)"mach error"; }
#define mach_error_string(a) ((char *)"mach error")
#endif
