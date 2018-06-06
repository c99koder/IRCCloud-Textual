//
//  IRCCloudClient.h
//  IRCCloud-Textual
//
//  Created by Sam Steele on 6/6/18.
//  Copyright © 2018 Sam Steele. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TextualApplication.h"

@interface IRCCloudClient : IRCClient {
    int _cid;
}
@property int cid;

//Setters for read-only properties
-(void)setViewController:(TVCLogController *)viewController;
-(void)setIsConnected:(BOOL)connected;
-(void)setIsConnecting:(BOOL)connecting;
-(void)setIsLoggedIn:(BOOL)isLoggedIn;
-(void)setUserNickname:(NSString *)nickname;
-(void)setIsConnectedToZNC:(BOOL)value;
-(void)setZncBouncerIsPlayingBackHistory:(BOOL)value;

//Private methods we need to use
-(id)initWithConfig:(IRCClientConfig *)config;
-(IRCUser *)addUserAndReturn:(IRCUser *)user;
-(void)processIncomingMessage:(IRCMessage *)message;
-(void)enableCapability:(ClientIRCv3SupportedCapabilities)capability;
@end
