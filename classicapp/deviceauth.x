// deviceauth.x
// TubeReplacer - classic YouTube
//
// Every YTXMLHTTPRequest is deferred until the YTDeviceAuthenticator completes a
// challenge/response handshake with a Google server that no longer exists. A dead
// host makes the connection *fail* (not finish), so nothing waited on it ever ran
// and every list in the app stayed empty.  Complete the handshake locally.

#import <Foundation/Foundation.h>
#import "trlog.h"

@interface YTDeviceAuthenticator : NSObject {
	double _timeTokenGranted;
}
-(void)_loadStatusChanged;
-(void)_connectionDidEnd;
-(void)_succeeded;
-(id)token;
@end

@interface YTAuthenticator : NSObject
@end

static void TRCGrantDeviceToken(YTDeviceAuthenticator *self_) {
	[self_ setValue:@"token" forKey:@"_token"];
	[self_ setValue:@([NSDate timeIntervalSinceReferenceDate]) forKey:@"_timeTokenGranted"];
	[self_ _connectionDidEnd];
	[self_ _succeeded];
}

%hook YTDeviceAuthenticator

// Never touch the network: succeed immediately.
- (void)authenticate {
	TRCGrantDeviceToken(self);
}

- (BOOL)canAuthenticate { return YES; }
- (BOOL)isAuthenticating { return NO; }

- (id)token {
	id t = %orig;
	return [t length] ? t : @"token";
}

// If a handshake connection does get started, still ignore whatever it says.
- (void)connectionDidFinishLoading:(id)connection {
	TRCGrantDeviceToken(self);
}

// ...and a *failed* connection (dead server) must not fail the deferred requests.
- (void)connection:(id)connection didFailWithError:(id)error {
	TRCGrantDeviceToken(self);
}

%end

%hook YTAuthenticator

- (BOOL)isWaitingForAuthentication { return NO; }

%end
