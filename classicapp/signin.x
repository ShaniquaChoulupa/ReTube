// signin.x
// TubeReplacer - classic YouTube sign-in hooks
//
// Replaces the dead username/password (ClientLogin) dialog with the web-view popup
// from classicauth.m, and keeps YTAccountAuthenticator in the signed-in state using
// the stored OAuth tokens.

#import <Foundation/Foundation.h>
#import "trlog.h"
#import <UIKit/UIKit.h>
#import "classicauth.h"

@interface YTAccountAuthenticator : NSObject
+ (id)sharedAuthenticator;
- (BOOL)loadStoredCredentials;
- (BOOL)cachedCredentialsValid;
- (BOOL)readyToRequestToken;
- (BOOL)_isTokenExpired:(id)date;
- (id)tokenForCurrentAccount;
- (void)validateAccount:(id)account password:(id)password;
@end

@interface YTAuthenticator : NSObject
- (BOOL)isAccountAuthenticated;
- (BOOL)cachedCredentialsValid;
@end

@interface YTSignInOutController : NSObject
- (void)_displayLoginDialog;
- (void)authenticatorNeedsAccountAndPassword:(id)authenticator;
- (void)signOut;
@end

@interface YTController : NSObject
- (void)authenticatorNeedsAccountAndPassword:(id)authenticator;
@end

@interface YTApplication : NSObject
- (void)applicationDidBecomeActive:(id)application;
@end

// The classic app's own "Sign In" dialog is replaced by the popup.
%hook YTSignInOutController

- (void)_displayLoginDialog {
    TRCPresentSignIn();
}

- (void)authenticatorNeedsAccountAndPassword:(id)authenticator {
    if (TRCSignedIn()) TRCApplySignedInState(); else TRCPresentSignIn();
}

// Signing out in the app also forgets our tokens.
- (void)signOut {
    TRCSignOut();
    %orig;
}

%end

%hook YTController

- (void)authenticatorNeedsAccountAndPassword:(id)authenticator {
    if (TRCSignedIn()) TRCApplySignedInState(); else TRCPresentSignIn();
}

%end

%hook YTAccountAuthenticator

// With tokens stored there is nothing to re-validate against the (dead) ClientLogin server.
- (BOOL)loadStoredCredentials {
    if (TRCSignedIn()) {
        TRCApplySignedInState();
        return YES;
    }
    return %orig;
}

- (BOOL)cachedCredentialsValid { return TRCSignedIn() ? YES : %orig; }
- (BOOL)readyToRequestToken    { return TRCSignedIn() ? YES : %orig; }
- (BOOL)_isTokenExpired:(id)date { return TRCSignedIn() ? NO : %orig; }

- (id)tokenForCurrentAccount {
    if (TRCSignedIn()) {
        NSString *t = TRCValidAccessToken();
        if (t) return t;
    }
    return %orig;
}

// Anything that would try to validate a typed username/password gets the popup instead.
- (void)validateAccount:(id)account password:(id)password {
    if (TRCSignedIn()) TRCApplySignedInState(); else TRCPresentSignIn();
}

%end

%hook YTAuthenticator

- (BOOL)isAccountAuthenticated { return TRCSignedIn() ? YES : %orig; }
- (BOOL)cachedCredentialsValid { return TRCSignedIn() ? YES : %orig; }

%end

// Restore the signed-in state shortly after launch.
%hook YTApplication

- (void)applicationDidBecomeActive:(id)application {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (TRCSignedIn()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                TRCApplySignedInState();
            });
        }
    });
}

%end
