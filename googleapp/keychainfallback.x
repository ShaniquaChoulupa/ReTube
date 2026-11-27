// Re-signed installs of 13.x have no keychain entitlement, so SecItem* fail with -34018 (errSecMissingEntitlement) and
// the signed-in account is never stored. When that happens, keep the items in a plist inside the app's sandbox instead.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <substrate.h>

static NSLock *gKCLock;
static NSString *KCPath(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/dev.preloading.tubereplacer.keychain.plist"]; }
static NSMutableArray *KCLoad(void) {
    NSArray *a = [NSArray arrayWithContentsOfFile:KCPath()];
    NSMutableArray *m = [NSMutableArray array];
    for (NSDictionary *d in a) [m addObject:[[d mutableCopy] autorelease]];
    return m;
}
static void KCSave(NSArray *items) { [items writeToFile:KCPath() atomically:YES]; }
static NSArray *KCIdKeys(void) { return @[ (id)kSecClass, (id)kSecAttrService, (id)kSecAttrAccount, (id)kSecAttrServer, (id)kSecAttrLabel, (id)kSecAttrGeneric ]; }
static BOOL KCMatches(NSDictionary *item, NSDictionary *q) {
    for (id k in KCIdKeys()) {
        id want = q[k]; if (!want) continue;
        if (![item[k] isEqual:want]) return NO;
    }
    return YES;
}
static NSDictionary *KCOnlyAttrs(NSDictionary *d) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (id k in d) {
        NSString *ks = k;
        if (![ks isKindOfClass:[NSString class]]) continue;
        if ([ks hasPrefix:@"r_"] || [ks hasPrefix:@"m_"] || [ks isEqualToString:@"u_OpPrompt"]) continue;
        id v = d[k];
        // only what a plist can hold (access control objects and the like cannot be mirrored)
        if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSData class]] || [v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSDate class]]) m[k] = v;
    }
    return m;
}

// Every item is mirrored into the app's own plist; the real keychain stays the first choice. Re-signed installs lose
// access to (or never get) the keychain, which logged the account out on every launch.
static OSStatus (*orig_add)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_copy)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_update)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*orig_delete)(CFDictionaryRef);

static void KCMirrorStore(NSDictionary *a) {
    [gKCLock lock];
    NSMutableArray *items = KCLoad(); BOOL replaced = NO;
    for (NSInteger i = 0; i < (NSInteger)[items count]; i++) if (KCMatches(items[i], a)) { items[i] = [[a mutableCopy] autorelease]; replaced = YES; break; }
    if (!replaced) [items addObject:a];
    KCSave(items);
    [gKCLock unlock];
}

static OSStatus tr_add(CFDictionaryRef attrs, CFTypeRef *result) {
    OSStatus r = orig_add(attrs, result);
    if (r == errSecDuplicateItem) return r;
    NSDictionary *a = KCOnlyAttrs((NSDictionary *)attrs);
    if (r == errSecSuccess) { if (a[(id)kSecValueData]) KCMirrorStore(a); return r; }
    KCMirrorStore(a);
    NSLog(@"[TubeReplacer] keychain fallback: SecItemAdd failed (%d), stored item (%@ / %@) in the app instead", (int)r, a[(id)kSecAttrService], a[(id)kSecAttrAccount]);
    if (result) *result = NULL;
    return errSecSuccess;
}
static OSStatus tr_copy(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus r = orig_copy(query, result);
    if (r == errSecSuccess) return r;
    NSDictionary *q = (NSDictionary *)query;
    [gKCLock lock];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSDictionary *it in KCLoad()) if (KCMatches(it, q)) [hits addObject:it];
    [gKCLock unlock];
    if (![hits count]) return r;
    NSLog(@"[TubeReplacer] keychain fallback: SecItemCopyMatching gave %d, answered from the app's copy (%lu item(s), %@)", (int)r, (unsigned long)[hits count], q[(id)kSecAttrService]);
    BOOL wantData = [q[(id)kSecReturnData] boolValue], wantAttrs = [q[(id)kSecReturnAttributes] boolValue];
    BOOL all = [q[(id)kSecMatchLimit] isEqual:(id)kSecMatchLimitAll];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in (all ? hits : @[ hits[0] ])) {
        if (wantAttrs) {
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:it];
            if (!wantData) [d removeObjectForKey:(id)kSecValueData];
            [out addObject:d];
        } else if (wantData) { id v = it[(id)kSecValueData]; if (v) [out addObject:v]; }
        else [out addObject:it];
    }
    if (result) {
        if (!wantData && !wantAttrs) *result = NULL;
        else if (![out count]) return r;
        else *result = all ? (CFTypeRef)[out retain] : (CFTypeRef)[out[0] retain];
    }
    return errSecSuccess;
}
static OSStatus tr_update(CFDictionaryRef query, CFDictionaryRef upd) {
    OSStatus r = orig_update(query, upd);
    [gKCLock lock];
    NSMutableArray *items = KCLoad(); BOOL any = NO;
    for (NSMutableDictionary *it in items) if (KCMatches(it, (NSDictionary *)query)) { [it addEntriesFromDictionary:KCOnlyAttrs((NSDictionary *)upd)]; any = YES; }
    if (any) KCSave(items);
    [gKCLock unlock];
    return (r != errSecSuccess && any) ? errSecSuccess : r;
}
static OSStatus tr_delete(CFDictionaryRef query) {
    OSStatus r = orig_delete(query);
    [gKCLock lock];
    NSMutableArray *items = KCLoad(); NSUInteger before = [items count];
    for (NSInteger i = (NSInteger)[items count] - 1; i >= 0; i--) if (KCMatches(items[i], (NSDictionary *)query)) [items removeObjectAtIndex:i];
    if ([items count] != before) KCSave(items);
    [gKCLock unlock];
    return (r != errSecSuccess && [items count] != before) ? errSecSuccess : r;
}

__attribute__((constructor)) static void TRKeychainFallbackInit(void) {
    gKCLock = [[NSLock alloc] init];
    MSHookFunction((void *)SecItemAdd, (void *)tr_add, (void **)&orig_add);
    MSHookFunction((void *)SecItemCopyMatching, (void *)tr_copy, (void **)&orig_copy);
    MSHookFunction((void *)SecItemUpdate, (void *)tr_update, (void **)&orig_update);
    MSHookFunction((void *)SecItemDelete, (void *)tr_delete, (void **)&orig_delete);
}
