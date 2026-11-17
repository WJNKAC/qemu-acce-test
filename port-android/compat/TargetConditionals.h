/* 在 Linux/Android 上冒充 <TargetConditionals.h>。
   两个都设为 0：既不走 macOS 的 MAP_JIT + pthread_jit_write_protect 分支，
   也不走 iOS 的 TXM/Jetsam 分支，平台差异由 port-android 自己的文件承担。 */
#ifndef HV_COMPAT_TARGETCONDITIONALS_H
#define HV_COMPAT_TARGETCONDITIONALS_H

#define TARGET_OS_MAC 0
#define TARGET_OS_OSX 0
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_EMBEDDED 0
#define TARGET_OS_WIN32 0
#define TARGET_OS_LINUX 1

#endif
