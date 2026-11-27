// apiaryauth.x
// TubeReplacer - request signing / device registration for 2.3.1 and later.
//
// These versions sign every request with a per-device key obtained from the (dead)
// deviceregistration endpoint, and hold requests in a queue until that registration
// finishes. Nothing here needs the signature any more (the InnerTube bridge talks to the
// real service with its own credentials), so signing is answered immediately with the
// request unchanged, and the registration call is answered with a local result so
// nothing waits on it.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "general.h"

static BOOL TRModernApiary(void) {
    static int cached = -1;
    if (cached < 0) cached = (NSClassFromString(@"YTBaseApiaryService") != nil && !legacyScreensAvailable()) ? 1 : 0;
    return cached == 1;
}

static void TRSignNow(id request, id responseBlock) {
    NSLog(@"[TubeReplacer] sign: passing request through unsigned (%@)", [(NSURLRequest *)request URL]);
    if (responseBlock) ((void (^)(id))responseBlock)(request);
}

%hook YTApiaryDeviceAuthenticator

- (void)signURLRequest:(id)request responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRModernApiary()) { %orig; return; }
    TRSignNow(request, responseBlock);
}

- (void)enqueueSignURLRequest:(id)request responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRModernApiary()) { %orig; return; }
    TRSignNow(request, responseBlock);
}

%end

// Device registration is left to the app: its request already targets
// https://www.googleapis.com/deviceregistration/v1/devices, i.e. the real service.
// Failures are only logged; nothing in the bridge depends on the result.
%hook YTDeviceRegistrationService

- (void)makeDeviceRegistrationRequestWithDeviceID:(id)deviceID responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    NSLog(@"[TubeReplacer] device registration -> Google (id %@)", deviceID);
    id eb = errorBlock ? [[errorBlock copy] autorelease] : nil;
    id rb = responseBlock ? [[responseBlock copy] autorelease] : nil;
    %orig(deviceID,
        ^(id registration) { NSLog(@"[TubeReplacer] device registration succeeded: %@", registration); if (rb) ((void (^)(id))rb)(registration); },
        ^(id error) { NSLog(@"[TubeReplacer] device registration failed: %@", error); if (eb) ((void (^)(id))eb)(error); });
}

%end
