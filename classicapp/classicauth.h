// classicauth.h
#import <Foundation/Foundation.h>

extern NSString *const TRCSignedInStateDidChangeNotification;

BOOL TRCSignedIn(void);
NSString *TRCAccountName(void);
NSString *TRCValidAccessToken(void);   // refreshes synchronously when expired; nil if signed out
void TRCSignOut(void);
void TRCApplySignedInState(void);      // tells the classic framework we're signed in
void TRCPresentSignIn(void);           // shows the sign-in popup

// Authenticated InnerTube request (TVHTML5 client + Bearer token); nil when signed out.
NSMutableURLRequest *TRCMakeTVRequest(NSString *endpoint, NSDictionary *extraBody, NSString *params);
