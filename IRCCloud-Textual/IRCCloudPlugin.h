//
//  IRCCloudPlugin.h
//  IRCCloud-Textual
//
//  Created by Sam Steele on 6/6/18.
//  Copyright © 2018 Sam Steele. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TextualApplication.h"
#import "IRCCloudClient.h"
#import "IRCCloudSocket.h"

@interface IRCCloudPlugin : NSObject<THOPluginProtocol> {
    IRCCloudSocket *_socket;
    IBOutlet NSView *_prefsView;
    IBOutlet NSTextField *_email;
    IBOutlet NSTextField *_password;
}
+(IRCCloudPlugin *)sharedInstance;
-(IRCCloudClient *)getClient:(int)cid;
-(IRCCloudClient *)createIRCCloudClient:(int)cid name:(NSString *)name;
@end
