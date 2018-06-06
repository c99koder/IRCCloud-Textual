//
//  IRCCloudPlugin.m
//  IRCCloud-Textual
//
//  Created by Sam Steele on 6/6/18.
//  Copyright © 2018 Sam Steele. All rights reserved.
//

#import "IRCCloudPlugin.h"
#import "IRCCloudClient.h"

@interface TVCServerList(Private)
-(void)addItemToList:(NSInteger)index inParent:(id)parent;
@end

@interface TXMenuController(Private)
-(void)populateNavigationChannelList;
@end

@interface TVCMainWindow(Private)
-(void)reloadLoadingScreen;
-(void)reloadTreeItem:(id)item;
-(void)updateTitleFor:(id)item;
@end

@interface IRCWorld(Private)
- (void)setClientList:(NSArray<IRCClient *> *)clientList;
- (void)postClientListWasModifiedNotification;
- (TVCLogController *)createViewControllerWithClient:(IRCClient *)client channel:(nullable IRCChannel *)channel;
@end

@interface IRCChannel(Private)
- (void)addMember:(IRCChannelUser *)member checkForDuplicates:(BOOL)checkForDuplicates;
- (void)setStatus:(IRCChannelStatus)status;
@end

@interface IRCChannelUserMutable(Private)
- (instancetype)initWithUser:(IRCUser *)user;
@end

IRCCloudPlugin *__shared_plugin;

@implementation IRCCloudPlugin

+(IRCCloudPlugin *)sharedInstance {
    return __shared_plugin;
}

-(NSView *)pluginPreferencesPaneView {
    return _prefsView;
}

-(NSString *)pluginPreferencesPaneMenuItemName {
    return @"IRCCloud";
}

-(IBAction)loginButtonClicked:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        IRCCLOUD_HOST = @"www.irccloud.com";
        NSDictionary *result = [_socket requestConfiguration];
        IRCCLOUD_HOST = [result objectForKey:@"api_host"];
        if([IRCCLOUD_HOST hasPrefix:@"http://"])
            IRCCLOUD_HOST = [IRCCLOUD_HOST substringFromIndex:7];
        if([IRCCLOUD_HOST hasPrefix:@"https://"])
            IRCCLOUD_HOST = [IRCCLOUD_HOST substringFromIndex:8];
        if([IRCCLOUD_HOST hasSuffix:@"/"])
            IRCCLOUD_HOST = [IRCCLOUD_HOST substringToIndex:IRCCLOUD_HOST.length - 1];
        
        result = [_socket requestAuthToken];
        if([[result objectForKey:@"success"] intValue] == 1) {
            result = [_socket login:_email.stringValue password:_password.stringValue token:[result objectForKey:@"token"]];
            if([[result objectForKey:@"success"] intValue] == 1) {
                if([result objectForKey:@"websocket_host"])
                    IRCCLOUD_HOST = [result objectForKey:@"websocket_host"];
                if([result objectForKey:@"websocket_path"])
                    IRCCLOUD_PATH = [result objectForKey:@"websocket_path"];
                _socket.session = [result objectForKey:@"session"];
                [[NSUserDefaults standardUserDefaults] setObject:IRCCLOUD_HOST forKey:@"IRCCLOUD_HOST"];
                [[NSUserDefaults standardUserDefaults] setObject:IRCCLOUD_PATH forKey:@"IRCCLOUD_PATH"];
                [[NSUserDefaults standardUserDefaults] setObject:_socket.session forKey:@"IRCCLOUD_SESSION"];
                [self performBlockOnMainThread:^{
                    [_socket connect:NO];
                }];
            }
        }
    });
}

-(void)pluginLoadedIntoMemory {
    __shared_plugin = self;
    _socket = [IRCCloudSocket sharedInstance];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleEvent:) name:kIRCCloudEventNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(backlogCompleted:) name:kIRCCloudBacklogCompletedNotification object:nil];

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Connect to IRCCloud" action:@selector(showConnectMenu:) keyEquivalent:@""];
    item.target = self;
    
    [menuController().mainMenuServerMenuItem.submenu addItem:item];
    [self performBlockOnMainThread:^{
        [TPIBundleFromClass() loadNibNamed:@"IRCCloudPrefs" owner:self topLevelObjects:nil];
    }];
    
    IRCCLOUD_HOST = [[NSUserDefaults standardUserDefaults] objectForKey:@"IRCCLOUD_HOST"];
    IRCCLOUD_PATH = [[NSUserDefaults standardUserDefaults] objectForKey:@"IRCCLOUD_PATH"];
    _socket.session = [[NSUserDefaults standardUserDefaults] objectForKey:@"IRCCLOUD_SESSION"];
    if(_socket.session) {
        [self performBlockOnMainThread:^{
            [_socket connect:NO];
        }];
    }
}

-(void)pluginWillBeUnloadedFromMemory {
    [self performBlockOnMainThread:^{
        _socket.session = nil;
        [_socket disconnect];
        NSMutableArray *clients = worldController().clientList.mutableCopy;
        for(int i = 0; i < clients.count; i++) {
            if([[clients objectAtIndex:i] isKindOfClass:IRCCloudClient.class]) {
                [clients removeObjectAtIndex:i];
                i--;
            }
        }
        [worldController() setClientList:clients];
        [worldController() save];
    }];
}

-(void)showConnectMenu:(id)sender {
    [_socket connect:NO];
}

-(IRCCloudClient *)getClient:(int)cid {
    IRCWorld *world = worldController();
    
    for(IRCClient *client in world.clientList) {
        if([client isKindOfClass:IRCCloudClient.class] && ((IRCCloudClient *)client).cid == cid)
            return (IRCCloudClient *)client;
    }

    return nil;
}

-(IRCCloudClient *)createIRCCloudClient:(int)cid name:(NSString *)name {
    IRCWorld *world = worldController();
    IRCClientConfigMutable *config = [[IRCClientConfigMutable alloc] init];
    config.connectionName = name;
    IRCCloudClient *client = [[IRCCloudClient alloc] initWithConfig:config];
    client.viewController = [world createViewControllerWithClient:client channel:nil];
    client.cid = cid;
    client.isConnectedToZNC = YES;
    [client enableCapability:ClientIRCv3SupportedCapabilityEchoMessage];
    NSMutableArray *clients = worldController().clientList.mutableCopy;
    [clients addObject:client];
    [worldController() setClientList:clients];

    NSInteger index = [clients indexOfObject:client];
    
    [mainWindowServerList() addItemToList:index inParent:nil];
    
    if (clients.count == 1) {
        [mainWindow() select:client];
    }
    (void)[mainWindow() reloadLoadingScreen];
    
    [menuController() populateNavigationChannelList];
    
    [world postClientListWasModifiedNotification];
    return client;
}

- (void)backlogCompleted:(NSNotification *)notification {
    if(notification.object == nil || [notification.object bid] < 1) {
    } else {
    }
}

- (void)updateStatus:(NSString *)status forClient:(IRCCloudClient *)client {
    if([status isEqualToString:@"connected_ready"]) {
        client.isConnected = YES;
        client.isConnecting = NO;
        client.isLoggedIn = YES;
    } else if([status isEqualToString:@"queued"] || [status isEqualToString:@"connecting"]) {
        client.isConnected = NO;
        client.isConnecting = YES;
        client.isLoggedIn = NO;
    } else if([status isEqualToString:@"connected"] || [status isEqualToString:@"connected_joining"]) {
        client.isConnected = YES;
        client.isConnecting = NO;
        client.isLoggedIn = NO;
    } else {
        client.isConnected = NO;
        client.isConnecting = NO;
        client.isLoggedIn = YES;
    }
    [mainWindow() updateTitleFor:client];
}

- (void)handleEvent:(NSNotification *)notification {
    kIRCEvent event = [[notification.userInfo objectForKey:kIRCCloudEventKey] intValue];
    IRCCloudJSONObject *o = notification.object;
    IRCCloudClient *client;
    
    switch(event) {
        case kIRCEventMakeServer:
            client = [self getClient:o.cid];
            if(!client)
                client = [self createIRCCloudClient:o.cid name:[[o objectForKey:@"name"] length]?[o objectForKey:@"name"]:[o objectForKey:@"hostname"]];
            if(client) {
                client.userNickname = [o objectForKey:@"nick"];
                [self updateStatus:[o objectForKey:@"status"] forClient:client];
            }
            break;
        case kIRCEventStatusChanged:
            client = [self getClient:o.cid];
            if(client) {
                [self updateStatus:[o objectForKey:@"new_status"] forClient:client];
            }
            break;
        case kIRCEventMakeBuffer:
            client = [self getClient:o.cid];
            if(client) {
                NSString *type = [o objectForKey:@"buffer_type"];
                if([type isEqualToString:@"channel"] || [type isEqualToString:@"conversation"]) {
                    IRCChannelConfigMutable *config = [[IRCChannelConfigMutable alloc] init];
                    config.channelName = [o objectForKey:@"name"];
                    config.type = [type isEqualToString:@"channel"]?IRCChannelChannelType:IRCChannelPrivateMessageType;
                    IRCChannel *c = [worldController() createChannelWithConfig:config onClient:client];
                    c.status = IRCChannelStatusParted;
                }
            }
            break;
        case kIRCEventChannelInit:
            client = [self getClient:o.cid];
            if(client) {
                IRCChannel *c = [client findChannelOrCreate:[o objectForKey:@"chan"]];
                if(c) {
                    if([[[o objectForKey:@"topic"] objectForKey:@"text"] isKindOfClass:NSString.class])
                        c.topic = [[o objectForKey:@"topic"] objectForKey:@"text"];
                    else
                        c.topic = nil;
                    c.status = IRCChannelStatusJoined;
                    [c activate];
                    for(NSDictionary *member in [o objectForKey:@"members"]) {
                        if(member) {
                            IRCUser *user = [client findUser:[member objectForKey:@"nick"]];
                            if(!user) {
                                IRCUserMutable *u = [[IRCUserMutable alloc] initWithNickname:[member objectForKey:@"nick"] onClient:client];
                                u.username = [member objectForKey:@"user"];
                                u.address = [member objectForKey:@"userhost"];
                                u.realName = [member objectForKey:@"realname"];
                                user = [client addUserAndReturn:u];
                            }
                            IRCChannelUserMutable *u = [[IRCChannelUserMutable alloc] initWithUser:user];
                            u.modes = [member objectForKey:@"mode"];
                            [c addMember:u checkForDuplicates:YES];
                        }
                    }
                    [mainWindow() reloadTreeItem:c];
                }
            }
            break;
        case kIRCEventBufferMsg:
            client = [self getClient:o.cid];
            if(client && [[o objectForKey:@"chan"] length]) {
                IRCMessageMutable *m = [[IRCMessageMutable alloc] init];
                m.command = @"PRIVMSG";
                m.params = @[[o objectForKey:@"chan"], [o objectForKey:@"msg"]];
                m.receivedAt = [self dateFromObject:o];

                IRCPrefixMutable *prefix = [[IRCPrefixMutable alloc] init];
                prefix.nickname = [o objectForKey:@"from"];
                prefix.username = [o objectForKey:@"from_name"];
                prefix.address = [o objectForKey:@"from_host"];
                prefix.hostmask = [o objectForKey:@"hostmask"];
                m.sender = prefix;
                
                [client processIncomingMessage:m];
            }
            break;
        case kIRCEventJoin:
        case kIRCEventPart:
        case kIRCEventQuit:
            client = [self getClient:o.cid];
            if(client && [[o objectForKey:@"chan"] length] && [[o objectForKey:@"nick"] length]) {
                IRCMessageMutable *m = [[IRCMessageMutable alloc] init];
                switch(event) {
                    case kIRCEventJoin:
                        m.command = @"JOIN";
                        break;
                    case kIRCEventPart:
                        m.command = @"PART";
                        break;
                    case kIRCEventQuit:
                        m.command = @"QUIT";
                        break;
                    default:
                        break;
                }
                m.params = @[[o objectForKey:@"chan"], [o objectForKey:@"msg"]?[o objectForKey:@"msg"]:@""];
                m.receivedAt = [self dateFromObject:o];
                
                IRCPrefixMutable *prefix = [[IRCPrefixMutable alloc] init];
                prefix.nickname = [o objectForKey:@"nick"];
                prefix.username = [o objectForKey:@"from_name"];
                prefix.address = [o objectForKey:@"from_host"];
                prefix.hostmask = [o objectForKey:@"hostmask"];
                m.sender = prefix;
                
                [client processIncomingMessage:m];
            }
            break;
        default:
            break;
    }
}

-(NSDate *)dateFromObject:(IRCCloudJSONObject *)o {
    NSTimeInterval time = [[o objectForKey:@"server_time"] doubleValue];
    if(time == 0)
        time = (o.eid / 1000000) + _socket.clockOffset;
    return [NSDate dateWithTimeIntervalSince1970:time];
}

@end
