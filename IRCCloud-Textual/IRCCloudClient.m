//
//  IRCCloudClient.m
//  IRCCloud-Textual
//
//  Created by Sam Steele on 6/6/18.
//  Copyright © 2018 Sam Steele. All rights reserved.
//

#import "IRCCloudClient.h"
#import "IRCCloudSocket.h"

@interface IRCWorld(Private)
- (void)setClientList:(NSArray<IRCClient *> *)clientList;
@end

@interface IRCClient(Private)
-(id)initWithConfig:(IRCClientConfig *)config;
@end

@implementation IRCCloudClient
-(id)initWithConfig:(IRCClientConfig *)config {
    return [super initWithConfig:config];
}

- (void)sendLine:(NSString *)string {
}

- (void)send:(NSString *)string arguments:(NSArray<NSString *> *)arguments {
    NSString *cmd = [NSString stringWithFormat:@"/%@", string];
    if(arguments.count)
        cmd = [NSString stringWithFormat:@"%@ %@", cmd, [arguments componentsJoinedByString:@" "]];
    [[IRCCloudSocket sharedInstance] say:cmd to:nil cid:_cid handler:nil];
}

- (void)sendText:(NSAttributedString *)string asCommand:(IRCPrivateCommand)command toChannel:(IRCChannel *)channel withEncryption:(BOOL)encryptText {
    switch(command) {
        case IRCPrivateCommandPrivmsgIndex:
            for (NSAttributedString *line in string.splitIntoLines) {
                [[IRCCloudSocket sharedInstance] say:line.string to:channel.name cid:_cid handler:nil];
            }
            break;
        default:
            NSLog(@"Unsupported command: %lu", (unsigned long)command);
            break;
    }
}

- (void)connect:(IRCClientConnectMode)connectMode preferIPv4:(BOOL)preferIPv4 bypassProxy:(BOOL)bypassProxy {
    [[IRCCloudSocket sharedInstance] reconnect:_cid handler:nil];
}

- (void)disconnect {
    [[IRCCloudSocket sharedInstance] disconnect:_cid msg:nil handler:nil];
}

- (NSDictionary *)configurationDictionary {
    return @{@"proxyType":@(9999),@"proxyPort":@(9999),@"proxyAddress":@"IRCCLOUD_STUB"};
}
@end
