#import <Foundation/Foundation.h>
#import "potoken.h"
#import "common-google/common-google-headers.h"



@interface TRPOTokenSolver (Google)
- (void)fetchJNNPOChallengeWithMethod:(NSString *)method 
                                body:(NSDictionary *)body 
                                callback:(void (^)(NSDictionary *response, NSError *error))callback 
                                 auth:(GTMOAuth2Authentication *)auth;
- (void)fetchBotguardChallengeWithCallback:(void (^)(NSError *error))callback 
                                 auth:(GTMOAuth2Authentication *)auth 
                                 isStudio:(BOOL)isStudio;
-(void)setupPOTokenGenerationWithAuth:(id)authentication;
@end