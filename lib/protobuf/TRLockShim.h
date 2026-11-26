// os_unfair_lock exists only on iOS 10+; a strong reference stops the dylib loading on older iOS.
#import <libkern/OSAtomic.h>
#define os_unfair_lock_lock(l) OSSpinLockLock((volatile OSSpinLock *)(l))
#define os_unfair_lock_unlock(l) OSSpinLockUnlock((volatile OSSpinLock *)(l))
