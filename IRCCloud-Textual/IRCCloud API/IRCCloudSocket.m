//
//  IRCCloudSocket.m
//
//  Copyright (C) 2018 IRCCloud, Ltd.
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import "IRCCloudSocket.h"
#import "HandshakeHeader.h"

NSString *_userAgent = nil;
NSString *kIRCCloudConnectivityNotification = @"com.irccloud.notification.connectivity";
NSString *kIRCCloudEventNotification = @"com.irccloud.notification.event";
NSString *kIRCCloudBacklogStartedNotification = @"com.irccloud.notification.backlog.start";
NSString *kIRCCloudBacklogFailedNotification = @"com.irccloud.notification.backlog.failed";
NSString *kIRCCloudBacklogCompletedNotification = @"com.irccloud.notification.backlog.completed";
NSString *kIRCCloudBacklogProgressNotification = @"com.irccloud.notification.backlog.progress";
NSString *kIRCCloudEventKey = @"com.irccloud.event";

#if defined(BRAND_HOST)
NSString *IRCCLOUD_HOST = @BRAND_HOST
#elif defined(ENTERPRISE)
NSString *IRCCLOUD_HOST = @"";
#else
NSString *IRCCLOUD_HOST = @"api.irccloud.com";
#endif
NSString *IRCCLOUD_PATH = @"/";

NSLock *__serializeLock = nil;
NSLock *__userInfoLock = nil;
volatile BOOL __socketPaused = NO;

@interface OOBFetcher : NSObject<NSURLConnectionDelegate> {
    SBJson5Parser *_parser;
    NSString *_url;
    BOOL _cancelled;
    BOOL _running;
    NSURLConnection *_connection;
    int _bid;
    void (^_completionHandler)(BOOL);
}
@property (readonly) NSString *url;
@property int bid;
@property (nonatomic, copy) void (^completionHandler)(BOOL);
-(id)initWithURL:(NSString *)URL;
-(void)cancel;
-(void)start;
@end

@implementation OOBFetcher

-(id)initWithURL:(NSString *)URL {
    self = [super init];
    if(self) {
        IRCCloudSocket *conn = [IRCCloudSocket sharedInstance];
        _url = URL;
        _bid = -1;
        _parser = [SBJson5Parser unwrapRootArrayParserWithBlock:^(id item, BOOL *stop) {
            if(_cancelled)
                *stop = YES;
            else
                [conn parse:item backlog:YES];
        } errorHandler:^(NSError *error) {
            NSLog(@"OOB JSON ERROR: %@", error);
        }];
        _cancelled = NO;
        _running = NO;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_url] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30];
        [request setHTTPShouldHandleCookies:NO];
        [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
        [request setValue:[NSString stringWithFormat:@"session=%@",[IRCCloudSocket sharedInstance].session] forHTTPHeaderField:@"Cookie"];
        
        _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
        [_connection setDelegateQueue:[IRCCloudSocket sharedInstance].queue];
    }
    return self;
}
-(void)cancel {
    NSLog(@"Cancelled OOB fetcher for URL: %@", _url);
    _cancelled = YES;
    _running = NO;
    [_connection cancel];
}
-(void)start {
    if(_cancelled || _running) {
        NSLog(@"Not starting cancelled OOB fetcher");
        return;
    }
    
    if(_connection) {
        _running = YES;
        [_connection start];
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogStartedNotification object:self];
    } else {
        NSLog(@"Failed to create NSURLConnection");
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogFailedNotification object:self];
        if(_completionHandler)
            _completionHandler(NO);
    }
}
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    return nil;
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if(_cancelled) {
        NSLog(@"Request failed for cancelled OOB fetcher, ignoring");
        return;
    }
	NSLog(@"Request failed: %@", error);
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogFailedNotification object:self];
        if(_completionHandler)
            _completionHandler(NO);
    }];
    _running = NO;
    _cancelled = YES;
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if(_cancelled) {
        NSLog(@"Connection finished loading for cancelled OOB fetcher, ignoring");
        return;
    }
	NSLog(@"Backlog download completed");
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        if(!_cancelled) {
            [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogCompletedNotification object:self];
            if(_completionHandler)
                _completionHandler(YES);
        }
    }];
    _running = NO;
}
- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse {
    if(_cancelled)
        return nil;
	NSLog(@"Fetching: %@", [request URL]);
	return request;
}
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
	if(!_cancelled && [response statusCode] != 200) {
        NSLog(@"HTTP status code: %li", (long)[response statusCode]);
		NSLog(@"HTTP headers: %@", [response allHeaderFields]);
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogFailedNotification object:self];
            if(_completionHandler)
                _completionHandler(NO);
        }];
        _cancelled = YES;
	}
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    //NSLog(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    if(!_cancelled) {
        [_parser parse:data];
    } else {
        NSLog(@"Ignoring data for cancelled OOB fetcher");
    }
}

@end

@implementation IRCCloudSocket

+(IRCCloudSocket *)sharedInstance {
    static IRCCloudSocket *sharedInstance;
	
    @synchronized(self) {
        if(!sharedInstance)
            sharedInstance = [[IRCCloudSocket alloc] init];
		
        return sharedInstance;
    }
	return nil;
}

+(void)sync:(NSURL *)file1 with:(NSURL *)file2 {
    NSDictionary *a1 = [[NSFileManager defaultManager] attributesOfItemAtPath:file1.path error:nil];
    NSDictionary *a2 = [[NSFileManager defaultManager] attributesOfItemAtPath:file2.path error:nil];

    if(a1) {
        if(a2 == nil || [[a2 fileModificationDate] compare:[a1 fileModificationDate]] == NSOrderedAscending) {
            [[NSFileManager defaultManager] copyItemAtURL:file1 toURL:file2 error:NULL];
        }
    }
    
    if(a2) {
        if(a1 == nil || [[a1 fileModificationDate] compare:[a2 fileModificationDate]] == NSOrderedAscending) {
            [[NSFileManager defaultManager] copyItemAtURL:file2 toURL:file1 error:NULL];
        }
    }

    [file1 setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:NULL];
    [file2 setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:NULL];
}

+(void)sync {
#ifdef ENTERPRISE
    NSURL *sharedcontainer = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.irccloud.enterprise.share"];
#else
    NSURL *sharedcontainer = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.irccloud.share"];
#endif
    if(sharedcontainer) {
        NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] objectAtIndex:0];
        
        [IRCCloudSocket sync:[caches URLByAppendingPathComponent:@"servers"] with:[sharedcontainer URLByAppendingPathComponent:@"servers"]];
        [IRCCloudSocket sync:[caches URLByAppendingPathComponent:@"buffers"] with:[sharedcontainer URLByAppendingPathComponent:@"buffers"]];
        [IRCCloudSocket sync:[caches URLByAppendingPathComponent:@"channels"] with:[sharedcontainer URLByAppendingPathComponent:@"channels"]];
        [IRCCloudSocket sync:[caches URLByAppendingPathComponent:@"stream"] with:[sharedcontainer URLByAppendingPathComponent:@"stream"]];
    }
}

-(id)init {
    self = [super init];
#ifdef ENTERPRISE
    IRCCLOUD_HOST = [[NSUserDefaults standardUserDefaults] objectForKey:@"host"];
#endif
    if(self) {
    __serializeLock = [[NSLock alloc] init];
    __userInfoLock = [[NSLock alloc] init];
    _queue = [[NSOperationQueue alloc] init];
    _state = kIRCCloudStateDisconnected;
    _oobQueue = [[NSMutableArray alloc] init];
    _awayOverride = nil;
    _lastReqId = 1;
    _idleInterval = 20;
    _reconnectTimestamp = -1;
    _failCount = 0;
    _notifier = NO;
    [self _createJSONParser];
    _writer = [[SBJson5Writer alloc] init];
    _resultHandlers = [[NSMutableDictionary alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backlogStarted:) name:kIRCCloudBacklogStartedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backlogCompleted:) name:kIRCCloudBacklogCompletedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backlogFailed:) name:kIRCCloudBacklogFailedNotification object:nil];
#ifdef APPSTORE
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
#else
    NSString *version = [NSString stringWithFormat:@"%@-%@",[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"], [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"]];
#endif
#ifdef EXTENSION
    NSString *app = @"ShareExtension";
#else
#ifdef ENTERPRISE
    NSString *app = @"IRCEnterprise";
#else
    NSString *app = @"IRCCloud";
#endif
#endif
    _userAgent = @"Textual";
    
    NSString *cacheFile = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"stream"];
    [__userInfoLock lock];
    _userInfo = [NSKeyedUnarchiver unarchiveObjectWithFile:cacheFile];
    [__userInfoLock unlock];
    if(self.userInfo) {
        _config = [self.userInfo objectForKey:@"config"];
    }
    
    NSLog(@"%@", _userAgent);
        
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cacheVersion"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    void (^ignored)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
    };
    
    void (^alert)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
        [self postObject:object forEvent:kIRCEventAlert];
    };
    
    void (^makeserver)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
        [self postObject:object forEvent:kIRCEventMakeServer];
    };
    
    void (^msg)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
        [self postObject:object forEvent:kIRCEventBufferMsg];
    };
    
    void (^joined_channel)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
        [self postObject:object forEvent:kIRCEventJoin];
    };
    
    void (^parted_channel)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
        [self postObject:object forEvent:kIRCEventPart];
    };
    
    void (^kicked_channel)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
        [self postObject:object forEvent:kIRCEventKick];
    };
    
    void (^nickchange)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
        [self postObject:object forEvent:kIRCEventNickChange];
    };
    
    NSMutableDictionary *parserMap = @{
                   @"idle":ignored, @"end_of_backlog":ignored, @"oob_skipped":ignored, @"num_invites":ignored, @"user_account":ignored, @"twitch_hosttarget_start":ignored, @"twitch_hosttarget_stop":ignored, @"twitch_usernotice":ignored,
                   @"header": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       _state = kIRCCloudStateConnected;
                       [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
                       _idleInterval = ([[object objectForKey:@"idle_interval"] doubleValue] / 1000.0) + 10;
                       _clockOffset = [[NSDate date] timeIntervalSince1970] - [[object objectForKey:@"time"] doubleValue];
                       _streamId = [object objectForKey:@"streamid"];
                       _accrued = [[object objectForKey:@"accrued"] intValue];
                       _currentCount = 0;
                       _resuming = [[object objectForKey:@"resumed"] boolValue];
                       NSLog(@"idle interval: %f clock offset: %f stream id: %@ resumed: %i", _idleInterval, _clockOffset, _streamId, _resuming);
                       if(_accrued > 0) {
                           [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                               [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogStartedNotification object:nil];
                           }];
                       }
                   },
                   @"backlog_cache_init": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       NSLog(@"backlog_cache_init for bid%i", object.bid);
                   },
                   @"global_system_message": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!_resuming && !backlog && [object objectForKey:@"system_message_type"] && ![[object objectForKey:@"system_message_type"] isEqualToString:@"eval"] && ![[object objectForKey:@"system_message_type"] isEqualToString:@"refresh"]) {
                           _globalMsg = [object objectForKey:@"msg"];
                           [self postObject:object forEvent:kIRCEventGlobalMsg];
                       }
                   },
                   @"oob_include": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       __socketPaused = YES;
                       _awayOverride = [[NSMutableDictionary alloc] init];
                       _reconnectTimestamp = -1;
                       [self fetchOOB:[NSString stringWithFormat:@"https://%@%@", IRCCLOUD_HOST, [object objectForKey:@"url"]]];
                   },
                   @"oob_timeout": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       NSLog(@"OOB timed out");
                       [self clearOOB];
                       _highestEID = 0;
                       _streamId = nil;
                       [self performSelectorOnMainThread:@selector(disconnect) withObject:nil waitUntilDone:NO];
                       _state = kIRCCloudStateDisconnected;
                       [self performSelectorOnMainThread:@selector(fail) withObject:nil waitUntilDone:NO];
                   },
                   @"stat_user": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [__userInfoLock lock];
                       _userInfo = object.dictionary;
                       [__userInfoLock unlock];
                       if([[self.userInfo objectForKey:@"uploads_disabled"] intValue] == 1 && [[self.userInfo objectForKey:@"id"] intValue] != 11694)
                           [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"uploadsAvailable"];
                       else
                           [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"uploadsAvailable"];
#ifdef ENTERPRISE
                       NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.irccloud.enterprise.share"];
#else
                       NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.irccloud.share"];
#endif
                       [d setObject:[[NSUserDefaults standardUserDefaults] objectForKey:@"uploadsAvailable"] forKey:@"uploadsAvailable"];
                       [d synchronize];

                       _prefs = nil;
                       [self postObject:object forEvent:kIRCEventUserInfo];
                   },
                   @"backlog_starts": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if([object objectForKey:@"numbuffers"]) {
                           _numBuffers = [[object objectForKey:@"numbuffers"] intValue];
                           _totalBuffers = 0;
                           NSLog(@"OOB includes has %i buffers", _numBuffers);
                       }
                   },
                   @"makeserver": makeserver,
                   @"server_details_changed": makeserver,
                   @"makebuffer": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventMakeBuffer];
                       if(_numBuffers > 0) {
                           _totalBuffers++;
                           [self performSelectorOnMainThread:@selector(_postLoadingProgress:) withObject:@((float)_totalBuffers / (float)_numBuffers) waitUntilDone:YES];
                       }
                   },
                   @"backlog_complete": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && _oobQueue.count == 0) {
                           [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                               NSLog(@"backlog_complete from websocket");
                               [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogCompletedNotification object:nil];
                           }];
                       }
                   },
                   @"who_response": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming) {
                           [self postObject:object forEvent:kIRCEventWhoList];
                       }
                   },
                   @"connection_deleted": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventConnectionDeleted];
                   },
                   @"delete_buffer": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventDeleteBuffer];
                   },
                   @"buffer_archived": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventBufferArchived];
                   },
                   @"buffer_unarchived": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventBufferUnarchived];
                   },
                   @"rename_conversation": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventRenameConversation];
                   },
                   @"rename_channel": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventRenameConversation];
                   },
                   @"status_changed": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       NSLog(@"cid%i changed to status %@ (backlog: %i resuming: %i)", object.cid, [object objectForKey:@"new_status"], backlog, _resuming);
                       [self postObject:object forEvent:kIRCEventStatusChanged];
                   },
                   @"time": ^(IRCCloudJSONObject *object, BOOL backlog) {
                   },
                   @"link_channel": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventLinkChannel];
                   },
                   @"channel_init": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventChannelInit];
                   },
                   @"channel_topic": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog) {
                           if(!_resuming)
                               [self postObject:object forEvent:kIRCEventChannelTopic];
                       }
                   },
                   @"channel_topic_is": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog) {
                           if(!_resuming)
                               [self postObject:object forEvent:kIRCEventChannelTopicIs];
                       }
                   },
                   @"channel_url": ^(IRCCloudJSONObject *object, BOOL backlog) {
                   },
                   @"channel_mode": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog) {
                           if(!_resuming)
                               [self postObject:object forEvent:kIRCEventChannelMode];
                       }
                   },
                   @"channel_mode_is": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog) {
                           if(!_resuming)
                               [self postObject:object forEvent:kIRCEventChannelMode];
                       }
                   },
                   @"channel_timestamp": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog) {
                           if(!_resuming)
                               [self postObject:object forEvent:kIRCEventChannelTimestamp];
                       }
                   },
                   @"joined_channel":joined_channel, @"you_joined_channel":joined_channel,
                   @"parted_channel":parted_channel, @"you_parted_channel":parted_channel,
                   @"kicked_channel":kicked_channel, @"you_kicked_channel":kicked_channel,
                   @"nickchange":nickchange, @"you_nickchange":nickchange,
                   @"quit": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventQuit];
                   },
                   @"quit_server": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventQuit];
                   },
                   @"user_channel_mode": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventUserChannelMode];
                   },
                   @"member_updates": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventMemberUpdates];
                   },
                   @"user_away": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventAway];
                   },
                   @"away": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventAway];
                   },
                   @"user_back": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventAway];
                   },
                   @"self_away": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!_resuming) {
                           if(!backlog)
                               [self postObject:object forEvent:kIRCEventAway];
                       }
                   },
                   @"self_back": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [_awayOverride setObject:@YES forKey:@(object.cid)];
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventSelfBack];
                   },
                   @"self_details": ^(IRCCloudJSONObject *object, BOOL backlog) {
                   },
                   @"user_mode": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self postObject:object forEvent:kIRCEventUserMode];
                   },
                   @"isupport_params": ^(IRCCloudJSONObject *object, BOOL backlog) {
                   },
                   @"set_ignores": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventSetIgnores];
                   },
                   @"ignore_list": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventSetIgnores];
                   },
                   @"heartbeat_echo": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventHeartbeatEcho];
                   },
                   @"reorder_connections": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog && !_resuming)
                           [self postObject:object forEvent:kIRCEventReorderConnections];
                   },
                   @"session_deleted": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       [self logout];
                       [self postObject:object forEvent:kIRCEventSessionDeleted];
                   },
                   @"display_name_change": ^(IRCCloudJSONObject *object, BOOL backlog) {
                       if(!backlog) {
                           if(!_resuming)
                               [self postObject:object forEvent:kIRCEventNickChange];
                       }
                   }
               }.mutableCopy;
        
        for(NSString *type in @[@"buffer_msg", @"buffer_me_msg", @"wait", @"banned", @"kill", @"connecting_cancelled",
                                @"target_callerid", @"notice", @"server_motdstart", @"server_welcome", @"server_motd", @"server_endofmotd",
                                @"server_nomotd", @"server_luserclient", @"server_luserop", @"server_luserconns", @"server_luserme", @"server_n_local",
                                @"server_luserchannels", @"server_n_global", @"server_yourhost",@"server_created", @"server_luserunknown",
                                @"services_down", @"your_unique_id", @"callerid", @"target_notified", @"myinfo", @"hidden_host_set", @"unhandled_line",
                                @"unparsed_line", @"connecting_failed", @"nickname_in_use", @"channel_invite", @"motd_response", @"socket_closed",
                                @"channel_mode_list_change", @"msg_services", @"stats", @"statslinkinfo", @"statscommands", @"statscline",
                                @"statsnline", @"statsiline", @"statskline", @"statsqline", @"statsyline", @"statsbline", @"statsgline", @"statstline",
                                @"statseline", @"statsvline", @"statslline", @"statsuptime", @"statsoline", @"statshline", @"statssline", @"statsuline",
                                @"statsdebug", @"spamfilter", @"endofstats", @"inviting_to_channel", @"error", @"too_fast", @"no_bots",
                                @"wallops", @"logged_in_as", @"sasl_fail", @"sasl_too_long", @"sasl_aborted", @"sasl_already",
                                @"you_are_operator", @"btn_metadata_set", @"sasl_success", @"version", @"channel_name_change",
                                @"cap_ls", @"cap_list", @"cap_new", @"cap_del", @"cap_req",@"cap_ack",@"cap_nak",@"cap_raw",@"cap_invalid",
                                @"help_topics_start", @"help_topics", @"help_topics_end", @"helphdr", @"helpop", @"helptlr", @"helphlp", @"helpfwd", @"helpign",
                                @"newsflash", @"invited", @"server_snomask", @"codepage", @"logged_out", @"nick_locked", @"info_response", @"generic_server_info",
                                @"unknown_umode", @"bad_ping", @"cap_raw", @"rehashed_config", @"knock", @"bad_channel_mask", @"kill_deny",
                                @"chan_own_priv_needed", @"not_for_halfops", @"chan_forbidden", @"starircd_welcome", @"zurna_motd",
                                @"ambiguous_error_message", @"list_usage", @"list_syntax", @"who_syntax", @"text", @"admin_info",
                                @"watch_status", @"sqline_nick", @"user_chghost", @"loaded_module", @"unloaded_module", @"invite_notify"]) {
            [parserMap setObject:msg forKey:type];
        }
        
        for(NSString *type in @[@"too_many_channels", @"no_such_channel", @"bad_channel_name",
                                @"no_such_nick", @"invalid_nick_change", @"chan_privs_needed",
                                @"accept_exists", @"banned_from_channel", @"oper_only",
                                @"no_nick_change", @"no_messages_from_non_registered", @"not_registered",
                                @"already_registered", @"too_many_targets", @"no_such_server",
                                @"unknown_command", @"help_not_found", @"accept_full",
                                @"accept_not", @"nick_collision", @"nick_too_fast", @"need_registered_nick",
                                @"save_nick", @"unknown_mode", @"user_not_in_channel",
                                @"need_more_params", @"users_dont_match", @"users_disabled",
                                @"invalid_operator_password", @"flood_warning", @"privs_needed",
                                @"operator_fail", @"not_on_channel", @"ban_on_chan",
                                @"cannot_send_to_chan", @"user_on_channel", @"no_nick_given",
                                @"no_text_to_send", @"no_origin", @"only_servers_can_change_mode",
                                @"silence", @"no_channel_topic", @"invite_only_chan", @"channel_full", @"channel_key_set",
                                @"blocked_channel",@"unknown_error",@"channame_in_use",@"pong",
                                @"monitor_full",@"mlock_restricted",@"cannot_do_cmd",@"secure_only_chan",
                                @"cannot_change_chan_mode",@"knock_delivered",@"too_many_knocks",
                                @"chan_open",@"knock_on_chan",@"knock_disabled",@"cannotknock",@"ownmode",
                                @"nossl",@"redirect_error",@"invalid_flood",@"join_flood",@"metadata_limit",
                                @"metadata_targetinvalid",@"metadata_nomatchingkey",@"metadata_keyinvalid",
                                @"metadata_keynotset",@"metadata_keynopermission",@"metadata_toomanysubs"]) {
            [parserMap setObject:alert forKey:type];
        }
        
        NSDictionary *broadcastMap = @{    @"bad_channel_key":@(kIRCEventBadChannelKey),
                                           @"channel_query":@(kIRCEventChannelQuery),
                                           @"open_buffer":@(kIRCEventOpenBuffer),
                                           @"invalid_nick":@(kIRCEventInvalidNick),
                                           @"ban_list":@(kIRCEventBanList),
                                           @"accept_list":@(kIRCEventAcceptList),
                                           @"quiet_list":@(kIRCEventQuietList),
                                           @"ban_exception_list":@(kIRCEventBanExceptionList),
                                           @"invite_list":@(kIRCEventInviteList),
                                           @"names_reply":@(kIRCEventNamesList),
                                           @"whois_response":@(kIRCEventWhois),
                                           @"list_response_fetching":@(kIRCEventListResponseFetching),
                                           @"list_response_toomany":@(kIRCEventListResponseTooManyChannels),
                                           @"list_response":@(kIRCEventListResponse),
                                           @"map_list":@(kIRCEventServerMap),
                                           @"who_special_response":@(kIRCEventWhoSpecialResponse),
                                           @"modules_list":@(kIRCEventModulesList),
                                           @"links_response":@(kIRCEventLinksResponse),
                                           @"whowas_response":@(kIRCEventWhoWas),
                                           @"trace_response":@(kIRCEventTraceResponse),
                                           @"export_finished":@(kIRCEventLogExportFinished),
                                           @"avatar_change":@(kIRCEventAvatarChange)
                                           };
        void (^broadcast)(IRCCloudJSONObject *object, BOOL backlog) = ^(IRCCloudJSONObject *object, BOOL backlog) {
            if(!backlog && !_resuming)
                [self postObject:object forEvent:[[broadcastMap objectForKey:object.type] intValue]];
        };

        for(NSString *type in broadcastMap.allKeys) {
            [parserMap setObject:broadcast forKey:type];
        }
        
        _parserMap = parserMap;
    }
    return self;
}

-(void)_connect {
    [self connect:_notifier];
}

-(NSDictionary *)login:(NSString *)email password:(NSString *)password token:(NSString *)token {
    return [self _postRequest:@"/chat/login" args:@{@"email":email, @"password":password, @"token":token}];
}

-(NSDictionary *)login:(NSURL *)accessLink {
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:accessLink cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    if(data)
        return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    else
        return nil;
}

-(NSDictionary *)signup:(NSString *)email password:(NSString *)password realname:(NSString *)realname token:(NSString *)token impression:(NSString *)impression {
    return [self _postRequest:@"/chat/signup" args:@{@"realname":realname, @"email":email, @"password":password, @"token":token, @"ios_impression":impression}];
}

-(NSDictionary *)requestPassword:(NSString *)email token:(NSString *)token {
    return [self _postRequest:@"/chat/request-access-link" args:@{@"email":email, @"mobile":@"1", @"token":token}];
}

//From: http://stackoverflow.com/questions/1305225/best-way-to-serialize-a-nsdata-into-an-hexadeximal-string
-(NSString *)dataToHex:(NSData *)data {
    /* Returns hexadecimal string of NSData. Empty string if data is empty.   */
    
    const unsigned char *dataBuffer = (const unsigned char *)[data bytes];
    
    if (!dataBuffer)
        return [NSString string];
    
    NSUInteger          dataLength  = [data length];
    NSMutableString     *hexString  = [NSMutableString stringWithCapacity:(dataLength * 2)];
    
    for (int i = 0; i < dataLength; ++i)
        [hexString appendString:[NSString stringWithFormat:@"%02x", (unsigned int)dataBuffer[i]]];
    
    return [NSString stringWithString:hexString];
}

-(NSDictionary *)registerAPNs:(NSData *)token {
#if defined(DEBUG) || defined(EXTENSION)
    return nil;
#else
    return [self _postRequest:@"/apn-register" args:@{@"device_id":[self dataToHex:token]}];
#endif
}

-(NSDictionary *)unregisterAPNs:(NSData *)token session:(NSString *)session {
#ifdef EXTENSION
    return nil;
#else
    return [self _postRequest:@"/apn-unregister" args:@{@"device_id":[self dataToHex:token], @"session":session}];
#endif
}

-(NSDictionary *)impression:(NSString *)idfa referrer:(NSString *)referrer {
#ifdef EXTENSION
    return nil;
#else
    return [self _postRequest:@"/chat/ios-impressions" args:@{@"idfa":idfa, @"referrer":referrer}];
#endif
}

-(NSDictionary *)requestAuthToken {
    return [self _postRequest:@"/chat/auth-formtoken" args:@{}];
}

-(NSData *)_get:(NSURL *)url {
    NSData *data;
    NSURLResponse *response = nil;
    NSError *error = nil;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    if(self.session.length && [url.scheme isEqualToString:@"https"] && [url.host isEqualToString:IRCCLOUD_HOST])
        [request setValue:[NSString stringWithFormat:@"session=%@",self.session] forHTTPHeaderField:@"Cookie"];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    return data;
}

-(NSDictionary *)requestConfiguration {
    NSData *data = [self _get:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/config", IRCCLOUD_HOST]]];
    NSError *error = nil;
    if(data)
        _config = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
#ifdef ENTERPRISE
    if(![[_config objectForKey:@"enterprise"] isKindOfClass:[NSDictionary class]])
        _globalMsg = [NSString stringWithFormat:@"Some features, such as push notifications, may not work as expected. Please download the standard IRCCloud app from the App Store: %@", [_config objectForKey:@"ios_app"]];
#endif
    return _config;
}

-(NSDictionary *)propertiesForFile:(NSString *)fileID {
    NSData *data = [self _get:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/file/json/%@", IRCCLOUD_HOST, fileID]]];
    NSError *error = nil;
    
    if(data)
        return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    else
        return nil;
}

-(NSDictionary *)getFiles:(int)page {
    NSData *data = [self _get:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/files?page=%i", IRCCLOUD_HOST, page]]];
    NSError *error = nil;
    
    if(data)
        return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    else
        return nil;
}

-(NSDictionary *)getPastebins:(int)page {
    NSData *data = [self _get:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/pastebins?page=%i", IRCCLOUD_HOST, page]]];
    NSError *error = nil;
    
    if(data)
        return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    else
        return nil;
}

-(NSDictionary *)getLogExports {
    NSData *data = [self _get:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/log-exports", IRCCLOUD_HOST]]];
    NSError *error = nil;
    
    if(data)
        return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    else
        return nil;
}

-(int)_sendRequest:(NSString *)method args:(NSDictionary *)args handler:(IRCCloudAPIResultHandler)resultHandler {
    @synchronized(_writer) {
        if(_state == kIRCCloudStateConnected || [method isEqualToString:@"auth"]) {
            NSMutableDictionary *dict = args?[[NSMutableDictionary alloc] initWithDictionary:args]:[[NSMutableDictionary alloc] init];
            [dict setObject:method forKey:@"_method"];
            if(![method isEqualToString:@"auth"])
                [dict setObject:@(++_lastReqId) forKey:@"_reqid"];
            [_socket sendText:[_writer stringWithObject:dict]];
            if(resultHandler)
                [_resultHandlers setObject:resultHandler forKey:@(_lastReqId)];
            return _lastReqId;
        } else {
            NSLog(@"Discarding request '%@' on disconnected socket", method);
            return -1;
        }
    }
}

-(NSDictionary *)_postRequest:(NSString *)path args:(NSDictionary *)args {
    CFStringRef escaped = NULL;
    NSMutableString *body = [[NSMutableString alloc] init];
    
    for (NSString *key in args.allKeys) {
        if(body.length)
            [body appendString:@"&"];
        escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)[args objectForKey:key], NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
        [body appendFormat:@"%@=%@",key,escaped];
        CFRelease(escaped);
    }
    
    NSData *data;
    NSURLResponse *response = nil;
    NSError *error = nil;
    if(self.session.length && ![args objectForKey:@"session"])
        [body appendFormat:@"&session=%@", self.session];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", IRCCLOUD_HOST, path]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    if([args objectForKey:@"token"])
        [request setValue:[args objectForKey:@"token"] forHTTPHeaderField:@"x-auth-formtoken"];
    if([args objectForKey:@"session"])
        [request setValue:[NSString stringWithFormat:@"session=%@",[args objectForKey:@"session"]] forHTTPHeaderField:@"Cookie"];
    else if(self.session.length)
        [request setValue:[NSString stringWithFormat:@"session=%@",self.session] forHTTPHeaderField:@"Cookie"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    
    if(error) {
        NSLog(@"HTTP request failed: %@ %@", error.localizedDescription, error.localizedFailureReason);
    }
    
    if(data)
        return [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
    else
        return nil;
}

-(NSDictionary *)POSTsay:(NSString *)message to:(NSString *)to cid:(int)cid {
    if(to)
        return [self _postRequest:@"/chat/say" args:@{@"msg":message, @"to":to, @"cid":[@(cid) stringValue]}];
    else
        return [self _postRequest:@"/chat/say" args:@{@"msg":message, @"to":@"*", @"cid":[@(cid) stringValue]}];
}

-(int)say:(NSString *)message to:(NSString *)to cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    if(!message)
        message = @"";
    if(to)
        return [self _sendRequest:@"say" args:@{@"cid":@(cid), @"msg":message, @"to":to} handler:resultHandler];
    else
        return [self _sendRequest:@"say" args:@{@"cid":@(cid), @"msg":message, @"to":@"*"} handler:resultHandler];
}

-(int)reply:(NSString *)message to:(NSString *)to cid:(int)cid msgid:(NSString *)msgid handler:(IRCCloudAPIResultHandler)resultHandler {
    if(!message)
        message = @"";
    return [self _sendRequest:@"reply" args:@{@"cid":@(cid), @"reply":message, @"to":to, @"msgid":msgid} handler:resultHandler];
}

-(int)heartbeat:(int)selectedBuffer cids:(NSArray *)cids bids:(NSArray *)bids lastSeenEids:(NSArray *)lastSeenEids handler:(IRCCloudAPIResultHandler)resultHandler {
    @synchronized(_writer) {
        NSMutableDictionary *heartbeat = [[NSMutableDictionary alloc] init];
        for(int i = 0; i < cids.count; i++) {
            NSMutableDictionary *d = [heartbeat objectForKey:[NSString stringWithFormat:@"%@",[cids objectAtIndex:i]]];
            if(!d) {
                d = [[NSMutableDictionary alloc] init];
                [heartbeat setObject:d forKey:[NSString stringWithFormat:@"%@",[cids objectAtIndex:i]]];
            }
            [d setObject:[lastSeenEids objectAtIndex:i] forKey:[NSString stringWithFormat:@"%@",[bids objectAtIndex:i]]];
        }
        NSString *seenEids = [_writer stringWithObject:heartbeat];
        [__userInfoLock lock];
        NSMutableDictionary *d = _userInfo.mutableCopy;
        [d setObject:@(selectedBuffer) forKey:@"last_selected_bid"];
        _userInfo = d;
        [__userInfoLock unlock];
        return [self _sendRequest:@"heartbeat" args:@{@"selectedBuffer":@(selectedBuffer), @"seenEids":seenEids} handler:resultHandler];
    }
}
-(int)heartbeat:(int)selectedBuffer cid:(int)cid bid:(int)bid lastSeenEid:(NSTimeInterval)lastSeenEid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self heartbeat:selectedBuffer cids:@[@(cid)] bids:@[@(bid)] lastSeenEids:@[@(lastSeenEid)] handler:resultHandler];
}

-(int)join:(NSString *)channel key:(NSString *)key cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    if(key.length) {
        return [self _sendRequest:@"join" args:@{@"cid":@(cid), @"channel":channel, @"key":key} handler:resultHandler];
    } else {
        return [self _sendRequest:@"join" args:@{@"cid":@(cid), @"channel":channel} handler:resultHandler];
    }
}

-(int)part:(NSString *)channel msg:(NSString *)msg cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    if(msg.length) {
        return [self _sendRequest:@"part" args:@{@"cid":@(cid), @"channel":channel, @"msg":msg} handler:resultHandler];
    } else {
        return [self _sendRequest:@"part" args:@{@"cid":@(cid), @"channel":channel} handler:resultHandler];
    }
}

-(int)kick:(NSString *)nick chan:(NSString *)chan msg:(NSString *)msg cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self say:[NSString stringWithFormat:@"/kick %@ %@",nick,(msg.length)?msg:@""] to:chan cid:cid handler:resultHandler];
}

-(int)mode:(NSString *)mode chan:(NSString *)chan cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self say:[NSString stringWithFormat:@"/mode %@ %@",chan,mode] to:chan cid:cid handler:resultHandler];
}

-(int)invite:(NSString *)nick chan:(NSString *)chan cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self say:[NSString stringWithFormat:@"/invite %@ %@",nick,chan] to:chan cid:cid handler:resultHandler];
}

-(int)archiveBuffer:(int)bid cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"archive-buffer" args:@{@"cid":@(cid),@"id":@(bid)} handler:resultHandler];
}

-(int)unarchiveBuffer:(int)bid cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"unarchive-buffer" args:@{@"cid":@(cid),@"id":@(bid)} handler:resultHandler];
}

-(int)deleteBuffer:(int)bid cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"delete-buffer" args:@{@"cid":@(cid),@"id":@(bid)} handler:resultHandler];
}

-(int)deleteServer:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"delete-connection" args:@{@"cid":@(cid)} handler:(IRCCloudAPIResultHandler)resultHandler];
}

-(int)changePassword:(NSString *)password newPassword:(NSString *)newPassword handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"change-password" args:@{@"password":password,@"newPassword":newPassword} handler:resultHandler];
}

-(int)deleteAccount:(NSString *)password handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"delete-account" args:@{@"password":password} handler:resultHandler];
}


-(int)addServer:(NSString *)hostname port:(int)port ssl:(int)ssl netname:(NSString *)netname nick:(NSString *)nick realname:(NSString *)realname serverPass:(NSString *)serverPass nickservPass:(NSString *)nickservPass joinCommands:(NSString *)joinCommands channels:(NSString *)channels handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"add-server" args:@{
                                                   @"hostname":hostname?hostname:@"",
                                                   @"port":@(port),
                                                   @"ssl":[NSString stringWithFormat:@"%i",ssl],
                                                   @"netname":netname?netname:@"",
                                                   @"nickname":nick?nick:@"",
                                                   @"realname":realname?realname:@"",
                                                   @"server_pass":serverPass?serverPass:@"",
                                                   @"nspass":nickservPass?nickservPass:@"",
                                                   @"joincommands":joinCommands?joinCommands:@"",
                                                   @"channels":channels?channels:@""} handler:resultHandler];
}

-(int)editServer:(int)cid hostname:(NSString *)hostname port:(int)port ssl:(int)ssl netname:(NSString *)netname nick:(NSString *)nick realname:(NSString *)realname serverPass:(NSString *)serverPass nickservPass:(NSString *)nickservPass joinCommands:(NSString *)joinCommands handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"edit-server" args:@{
                                                    @"hostname":hostname?hostname:@"",
                                                    @"port":@(port),
                                                    @"ssl":[NSString stringWithFormat:@"%i",ssl],
                                                    @"netname":netname?netname:@"",
                                                    @"nickname":nick?nick:@"",
                                                    @"realname":realname?realname:@"",
                                                    @"server_pass":serverPass?serverPass:@"",
                                                    @"nspass":nickservPass?nickservPass:@"",
                                                    @"joincommands":joinCommands?joinCommands:@"",
                                                    @"cid":@(cid)} handler:resultHandler];
}

-(int)ignore:(NSString *)mask cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"ignore" args:@{@"cid":@(cid),@"mask":mask} handler:resultHandler];
}

-(int)unignore:(NSString *)mask cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"unignore" args:@{@"cid":@(cid),@"mask":mask} handler:resultHandler];
}

-(int)setPrefs:(NSString *)prefs handler:(IRCCloudAPIResultHandler)resultHandler {
    _prefs = nil;
    return [self _sendRequest:@"set-prefs" args:@{@"prefs":prefs} handler:resultHandler];
}

-(int)setRealname:(NSString *)realname highlights:(NSString *)highlights autoaway:(BOOL)autoaway handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"user-settings" args:@{
                                                      @"realname":realname,
                                                      @"hwords":highlights,
                                                      @"autoaway":autoaway?@"1":@"0"} handler:resultHandler];
}

-(int)changeEmail:(NSString *)email password:(NSString *)password handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"change-password" args:@{
                                                      @"email":email,
                                                      @"password":password} handler:resultHandler];
}

-(int)ns_help_register:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"ns-help-register" args:@{@"cid":@(cid)} handler:resultHandler];
}

-(int)setNickservPass:(NSString *)nspass cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"set-nspass" args:@{@"cid":@(cid),@"nspass":nspass} handler:resultHandler];
}

-(int)whois:(NSString *)nick server:(NSString *)server cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    if(server.length) {
        return [self _sendRequest:@"whois" args:@{@"cid":@(cid), @"nick":nick, @"server":server} handler:resultHandler];
    } else {
        return [self _sendRequest:@"whois" args:@{@"cid":@(cid), @"nick":nick} handler:resultHandler];
    }
}

-(int)topic:(NSString *)topic chan:(NSString *)chan cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"topic" args:@{@"cid":@(cid),@"channel":chan,@"topic":topic} handler:resultHandler];
}

-(int)back:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"back" args:@{@"cid":@(cid)} handler:resultHandler];
}

-(int)resendVerifyEmailWithHandler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"resend-verify-email" args:nil handler:resultHandler];
}

-(int)disconnect:(int)cid msg:(NSString *)msg handler:(IRCCloudAPIResultHandler)resultHandler {
    NSLog(@"Disconnecting cid%i", cid);
    if(msg.length)
        return [self _sendRequest:@"disconnect" args:@{@"cid":@(cid), @"msg":msg} handler:resultHandler];
    else
        return [self _sendRequest:@"disconnect" args:@{@"cid":@(cid)} handler:resultHandler];
}

-(int)reconnect:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    NSLog(@"Reconnecting cid%i", cid);
    int reqid = [self _sendRequest:@"reconnect" args:@{@"cid":@(cid)} handler:resultHandler];
    return reqid;
}

-(int)reorderConnections:(NSString *)cids handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"reorder-connections" args:@{@"cids":cids} handler:resultHandler];
}

-(NSDictionary *)finalizeUpload:(NSString *)uploadID filename:(NSString *)filename originalFilename:(NSString *)originalFilename avatar:(BOOL)avatar orgId:(int)orgId {
    if(avatar) {
        if(orgId == -1) {
            return [self _postRequest:@"/chat/upload-finalise" args:@{@"id":uploadID, @"filename":filename, @"original_filename":originalFilename, @"type":@"avatar", @"primary":@"1"}];
        } else {
            return [self _postRequest:@"/chat/upload-finalise" args:@{@"id":uploadID, @"filename":filename, @"original_filename":originalFilename, @"type":@"avatar", @"org":[NSString stringWithFormat:@"%i", orgId]}];
        }
    } else {
        return [self _postRequest:@"/chat/upload-finalise" args:@{@"id":uploadID, @"filename":filename, @"original_filename":originalFilename}];
    }
}

-(int)deleteFile:(NSString *)fileID handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"delete-file" args:@{@"file":fileID} handler:resultHandler];
}

-(int)paste:(NSString *)name contents:(NSString *)contents extension:(NSString *)extension handler:(IRCCloudAPIResultHandler)resultHandler {
    if(name.length) {
        return [self _sendRequest:@"paste" args:@{@"name":name, @"contents":contents, @"extension":extension} handler:resultHandler];
    } else {
        return [self _sendRequest:@"paste" args:@{@"contents":contents, @"extension":extension} handler:resultHandler];
    }
}

-(int)deletePaste:(NSString *)pasteID handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"delete-pastebin" args:@{@"id":pasteID} handler:resultHandler];
}

-(int)editPaste:(NSString *)pasteID name:(NSString *)name contents:(NSString *)contents extension:(NSString *)extension handler:(IRCCloudAPIResultHandler)resultHandler {
    if(name.length) {
        return [self _sendRequest:@"edit-pastebin" args:@{@"id":pasteID, @"name":name, @"body":contents, @"extension":extension} handler:resultHandler];
    } else {
        return [self _sendRequest:@"edit-pastebin" args:@{@"id":pasteID, @"body":contents, @"extension":extension} handler:resultHandler];
    }
}

-(int)exportLog:(NSString *)timezone cid:(int)cid bid:(int)bid handler:(IRCCloudAPIResultHandler)resultHandler {
    if(cid > 0) {
        if(bid > 0) {
            return [self _sendRequest:@"export-log" args:@{@"cid":@(cid), @"bid":@(bid), @"timezone":timezone} handler:resultHandler];
        } else {
            return [self _sendRequest:@"export-log" args:@{@"cid":@(cid), @"timezone":timezone} handler:resultHandler];
        }
    } else {
        return [self _sendRequest:@"export-log" args:@{@"timezone":timezone} handler:resultHandler];
    }
}

-(int)renameChannel:(NSString *)name cid:(int)cid bid:(int)bid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"rename-channel" args:@{@"cid":@(cid), @"id":@(bid), @"name":name} handler:resultHandler];
}

-(int)renameConversation:(NSString *)name cid:(int)cid bid:(int)bid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"rename-conversation" args:@{@"cid":@(cid), @"id":@(bid), @"name":name} handler:resultHandler];
}

-(int)setAvatar:(NSString *)avatarId orgId:(int)orgId handler:(IRCCloudAPIResultHandler)resultHandler {
    if(orgId == -1) {
        if(avatarId)
            return [self _sendRequest:@"set-avatar" args:@{@"id":avatarId, @"primary":@"1"} handler:resultHandler];
        else
            return [self _sendRequest:@"set-avatar" args:@{@"clear":@"1", @"primary":@"1"} handler:resultHandler];
    } else {
        if(avatarId)
            return [self _sendRequest:@"set-avatar" args:@{@"id":avatarId, @"org":@(orgId)} handler:resultHandler];
        else
            return [self _sendRequest:@"set-avatar" args:@{@"clear":@"1", @"org":@(orgId)} handler:resultHandler];
    }
}

-(int)setNetworkName:(NSString *)name cid:(int)cid handler:(IRCCloudAPIResultHandler)resultHandler {
    return [self _sendRequest:@"set-netname" args:@{@"cid":@(cid), @"netname":name} handler:resultHandler];
}

-(void)_createJSONParser {
    _parser = [SBJson5Parser multiRootParserWithBlock:^(id item, BOOL *stop) {
        [self parse:item backlog:NO];
    } errorHandler:^(NSError *error) {
        NSLog(@"JSON ERROR: %@", error);
        _streamId = nil;
        _highestEID = 0;
    }];
}

-(void)connect:(BOOL)notifier {
    @synchronized(self) {
        if(_mock) {
            _reconnectTimestamp = -1;
            _state = kIRCCloudStateConnected;
            _ready = YES;
            return;
        }
        
        if(IRCCLOUD_HOST.length < 1) {
            NSLog(@"Not connecting, no host");
            return;
        }
        
        if(self.session.length < 1) {
            NSLog(@"Not connecting, no session");
            return;
        }
        
        [_idleTimer invalidate];
        _idleTimer = nil;

        if(_socket) {
            NSLog(@"Discarding previous socket");
            WebSocket *s = _socket;
            _socket = nil;
            s.delegate = nil;
            [s close];
        }
        
        if(_oobQueue.count) {
            NSLog(@"Cancelling pending OOB requests");
            for(OOBFetcher *fetcher in _oobQueue) {
                [fetcher cancel];
            }
            [_oobQueue removeAllObjects];
            _streamId = nil;
            _highestEID = 0;
        }
        NSString *url = [NSString stringWithFormat:@"wss://%@%@",IRCCLOUD_HOST,IRCCLOUD_PATH];
        if(_highestEID > 0 && _streamId.length) {
            url = [url stringByAppendingFormat:@"?since_id=%.0lf&stream_id=%@", _highestEID, _streamId];
        }
        if(notifier) {
            if([url rangeOfString:@"?"].location == NSNotFound)
                url = [url stringByAppendingFormat:@"?notifier=1"];
            else
                url = [url stringByAppendingFormat:@"&notifier=1"];
        }
        if([url rangeOfString:@"?"].location == NSNotFound)
            url = [url stringByAppendingFormat:@"?exclude_archives=1"];
        else
            url = [url stringByAppendingFormat:@"&exclude_archives=1"];

        NSLog(@"Connecting: %@", url);
        _notifier = notifier;
        _state = kIRCCloudStateConnecting;
        _idleInterval = 20;
        _accrued = 0;
        _currentCount = 0;
        _totalCount = 0;
        _reconnectTimestamp = -1;
        _resuming = NO;
        _ready = NO;
        _firstEID = 0;
        __socketPaused = NO;
        _lastReqId = 1;
        [_resultHandlers removeAllObjects];
        
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
        WebSocketConnectConfig* config = [WebSocketConnectConfig configWithURLString:url origin:[NSString stringWithFormat:@"https://%@", IRCCLOUD_HOST] protocols:nil
                                                                         tlsSettings:[@{
                                                                         (NSString *)kCFStreamSSLPeerName: IRCCLOUD_HOST,
                                                                         (NSString *)GCDAsyncSocketSSLProtocolVersionMin:@(kTLSProtocol1)
                                                                                        } mutableCopy]
                                                                             headers:[@[[HandshakeHeader headerWithValue:_userAgent forKey:@"User-Agent"]] mutableCopy]
                                                                   verifySecurityKey:YES extensions:@[@"x-webkit-deflate-frame"]];
        _socket = [WebSocket webSocketWithConfig:config delegate:self];
        
        [_socket open];
    }
}

-(void)cancelPendingBacklogRequests {
    for(OOBFetcher *fetcher in _oobQueue.copy) {
        if(fetcher.bid > 0) {
            [fetcher cancel];
            [_oobQueue removeObject:fetcher];
        }
    }
}

-(void)disconnect {
    NSLog(@"Closing websocket");
    _reachabilityValid = NO;
    if(_oobQueue.count) {
        for(OOBFetcher *fetcher in _oobQueue) {
            [fetcher cancel];
        }
        [_oobQueue removeAllObjects];
        _streamId = nil;
        _highestEID = 0;
    }
    _reconnectTimestamp = 0;
    [self cancelIdleTimer];
    _state = kIRCCloudStateDisconnected;
    [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    [_socket close];
    _socket = nil;
}

-(void)clearPrefs {
    _prefs = nil;
    [__userInfoLock lock];
    _userInfo = nil;
    [__userInfoLock unlock];
}

-(void)webSocketDidOpen:(WebSocket *)socket {
    if(socket == _socket) {
        NSLog(@"Socket connected");
        _idleInterval = 20;
        _reconnectTimestamp = -1;
        [self _sendRequest:@"auth" args:@{@"cookie":self.session} handler:nil];
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
        [self performSelectorInBackground:@selector(requestConfiguration) withObject:nil];
    } else {
        NSLog(@"Socket connected, but it wasn't the active socket");
    }
}

-(void)fail {
    [self clearOOB];
    _failCount++;
    if(_failCount < 4)
        _idleInterval = _failCount;
    else if(_failCount < 10)
        _idleInterval = 10;
    else
        _idleInterval = 30;
    _reconnectTimestamp = -1;
    NSLog(@"Fail count: %i will reconnect in %f seconds", _failCount, _idleInterval);
    [self performSelectorOnMainThread:@selector(scheduleIdleTimer) withObject:nil waitUntilDone:YES];
}

-(void)webSocket:(WebSocket *)socket didClose:(NSUInteger) aStatusCode message:(NSString*) aMessage error:(NSError*) aError {
    if(socket == _socket) {
        NSLog(@"Status Code: %lu", (unsigned long)aStatusCode);
        NSLog(@"Close Message: %@", aMessage);
        NSLog(@"Error: errorDesc=%@, failureReason=%@", [aError localizedDescription], [aError localizedFailureReason]);
        _state = kIRCCloudStateDisconnected;
        __socketPaused = NO;
        if(aStatusCode == WebSocketCloseStatusProtocolError) {
            _streamId = nil;
            _highestEID = 0;
        }
        if([self reachable] == kIRCCloudReachable && _reconnectTimestamp != 0) {
            [self fail];
        } else {
            NSLog(@"IRCCloud is unreacahable or reconnecting is disabled");
            [self performSelectorOnMainThread:@selector(cancelIdleTimer) withObject:nil waitUntilDone:YES];
            [self serialize];
        }
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    } else {
        NSLog(@"Socket closed, but it wasn't the active socket");
    }
}

-(void)webSocket:(WebSocket *)socket didReceiveError: (NSError*) aError {
    if(socket == _socket) {
        NSLog(@"Error: errorDesc=%@, failureReason=%@", [aError localizedDescription], [aError localizedFailureReason]);
        _state = kIRCCloudStateDisconnected;
        __socketPaused = NO;
        if([self reachable] && _reconnectTimestamp != 0) {
            [self fail];
        }
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    } else {
        NSLog(@"Socket received error, but it wasn't the active socket");
    }
}

-(void)webSocket:(WebSocket *)socket didReceiveTextMessage:(NSString*)aMessage {
    if(socket == _socket) {
        if(aMessage) {
            while(__socketPaused) { //GCD uses a thread pool and can't guarantee NSLock will be locked and unlocked on the same thread, so here's an ugly hack instead
                [NSThread sleepForTimeInterval:0.05];
            }
            [_parser parse:[aMessage dataUsingEncoding:NSUTF8StringEncoding]];
        }
    } else {
        NSLog(@"Got event for inactive socket");
    }
}

- (void)webSocket:(WebSocket *)socket didReceiveBinaryMessage: (NSData*) aMessage {
    if(socket == _socket) {
        if(aMessage) {
            while(__socketPaused) {
                [NSThread sleepForTimeInterval:0.05];
            }
            [_parser parse:aMessage];
        }
    } else {
        NSLog(@"Got event for inactive socket");
    }
}

-(void)postObject:(id)object forEvent:(kIRCEvent)event {
    if(_accrued == 0) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudEventNotification object:object userInfo:@{kIRCCloudEventKey:[NSNumber numberWithInt:event]}];
        }];
    }
}

-(void)_postLoadingProgress:(NSNumber *)progress {
    static NSNumber *lastProgress = nil;
    if(!lastProgress || (int)(lastProgress.floatValue * 100) != (int)(progress.floatValue * 100))
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogProgressNotification object:progress];
    lastProgress = progress;
}

-(void)_postConnectivityChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudConnectivityNotification object:nil userInfo:nil];
}

-(NSDictionary *)prefs {
    @synchronized(self) {
        if(!_prefs && self.userInfo && [[self.userInfo objectForKey:@"prefs"] isKindOfClass:[NSString class]] && [[self.userInfo objectForKey:@"prefs"] length]) {
            NSError *error;
            _prefs = [NSJSONSerialization JSONObjectWithData:[[self.userInfo objectForKey:@"prefs"] dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
            if(error) {
                NSLog(@"Prefs parse error: %@", error);
                NSLog(@"JSON string: %@", [self.userInfo objectForKey:@"prefs"]);
            }
        }
        return _prefs;
    }
}

-(void)parse:(NSDictionary *)dict backlog:(BOOL)backlog {
    if(![dict isKindOfClass:[NSDictionary class]])
        return;
    @synchronized(_parserMap) {
        NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
        if(backlog)
            _totalCount++;
        if([NSThread currentThread].isMainThread)
            NSLog(@"WARNING: Parsing on main thread");
        [self performSelectorOnMainThread:@selector(cancelIdleTimer) withObject:nil waitUntilDone:YES];
        if(_accrued > 0) {
            [self performSelectorOnMainThread:@selector(_postLoadingProgress:) withObject:@(((float)_totalCount++ / (float)_accrued)) waitUntilDone:NO];
        }
        IRCCloudJSONObject *object = [[IRCCloudJSONObject alloc] initWithDictionary:dict];
        if(object.type) {
            //NSLog(@"New event (backlog: %i resuming: %i highestEID: %f) (%@) %@", backlog, _resuming, _highestEID, object.type, object);
            if((backlog || _accrued > 0) && object.bid > -1 && object.bid != _currentBid && object.eid > 0) {
                if(!backlog) {
                    if(_firstEID == 0) {
                        _firstEID = object.eid;
                        if(object.eid > _highestEID) {
                            NSLog(@"Backlog gap detected, purging cache");
                            _highestEID = 0;
                            _streamId = nil;
                            [self performSelectorOnMainThread:@selector(disconnect) withObject:nil waitUntilDone:NO];
                            _state = kIRCCloudStateDisconnected;
                            [self performSelectorOnMainThread:@selector(fail) withObject:nil waitUntilDone:NO];
                            return;
                        } else {
                            NSLog(@"First EID matched");
                        }
                    }
                }
                _currentBid = object.bid;
                _currentCount = 0;
            }
            void (^block)(IRCCloudJSONObject *o, BOOL backlog) = [_parserMap objectForKey:object.type];
            if(block != nil) {
                block(object,backlog);
            } else {
                NSLog(@"Unhandled type: %@", object.type);
            }
            if(backlog || _accrued > 0) {
                if(_numBuffers > 1 && (object.bid > -1 || [object.type isEqualToString:@"backlog_complete"]) && ![object.type isEqualToString:@"makebuffer"] && ![object.type isEqualToString:@"channel_init"]) {
                    if(object.bid != _currentBid) {
                        _currentBid = object.bid;
                        _currentCount = 0;
                    }
                    [self performSelectorOnMainThread:@selector(_postLoadingProgress:) withObject:@(((float)_totalBuffers + (float)_currentCount/100.0f)/ (float)_numBuffers) waitUntilDone:NO];
                    _currentCount++;
                }
            }
            if(!backlog && [object objectForKey:@"reqid"]) {
                IRCCloudAPIResultHandler handler = [_resultHandlers objectForKey:@([[object objectForKey:@"reqid"] intValue])];
                if(handler) {
                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        handler(object);
                    }];
                }
            }
            if([NSDate timeIntervalSinceReferenceDate] - start > _longestEventTime) {
                _longestEventTime = [NSDate timeIntervalSinceReferenceDate] - start;
                _longestEventType = object.type;
            }
        } else {
            if([object objectForKey:@"success"] && ![[object objectForKey:@"success"] boolValue] && [object objectForKey:@"message"]) {
                NSLog(@"Failure: %@", object);
                if([[object objectForKey:@"message"] isEqualToString:@"invalid_nick"]) {
                    [self postObject:object forEvent:kIRCEventInvalidNick];
                } else if([[object objectForKey:@"message"] isEqualToString:@"auth"]) {
                    [self postObject:object forEvent:kIRCEventAuthFailure];
                } else if([[object objectForKey:@"message"] isEqualToString:@"set_shard"]) {
                    if([object objectForKey:@"websocket_host"])
                        IRCCLOUD_HOST = [object objectForKey:@"websocket_host"];
                    if([object objectForKey:@"websocket_path"])
                        IRCCLOUD_PATH = [object objectForKey:@"websocket_path"];
                    [self setSession:[object objectForKey:@"cookie"]];
                    [[NSUserDefaults standardUserDefaults] setObject:IRCCLOUD_HOST forKey:@"host"];
                    [[NSUserDefaults standardUserDefaults] setObject:IRCCLOUD_PATH forKey:@"path"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
#ifdef ENTERPRISE
                    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.irccloud.enterprise.share"];
#else
                    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.irccloud.share"];
#endif
                    [d setObject:IRCCLOUD_HOST forKey:@"host"];
                    [d setObject:IRCCLOUD_PATH forKey:@"path"];
                    [d setObject:[[NSUserDefaults standardUserDefaults] objectForKey:@"uploadsAvailable"] forKey:@"uploadsAvailable"];
                    [d synchronize];
                    [self connect:NO];
                } else if([_resultHandlers objectForKey:@([[object objectForKey:@"_reqid"] intValue])]) {
                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        ((IRCCloudAPIResultHandler)[_resultHandlers objectForKey:@([[object objectForKey:@"_reqid"] intValue])])(object);
                    }];
                }
            } else if([object objectForKey:@"success"]) {
                if([_resultHandlers objectForKey:@([[object objectForKey:@"_reqid"] intValue])])
                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        ((IRCCloudAPIResultHandler)[_resultHandlers objectForKey:@([[object objectForKey:@"_reqid"] intValue])])(object);
                    }];
            }
        }
        if(!backlog && _reconnectTimestamp != 0)
            [self performSelectorOnMainThread:@selector(scheduleIdleTimer) withObject:nil waitUntilDone:YES];
    }
}

-(void)cancelIdleTimer {
    if(![NSThread currentThread].isMainThread)
        NSLog(@"WARNING: cancel idle timer called outside of main thread");
    
    [_idleTimer invalidate];
    _idleTimer = nil;
}

-(void)scheduleIdleTimer {
    if(![NSThread currentThread].isMainThread)
        NSLog(@"WARNING: schedule idle timer called outside of main thread");
    [_idleTimer invalidate];
    _idleTimer = nil;
    if(_reconnectTimestamp == 0)
        return;
    
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:_idleInterval target:self selector:@selector(_idle) userInfo:nil repeats:NO];
    _reconnectTimestamp = [[NSDate date] timeIntervalSince1970] + _idleInterval;
}

-(void)_idle {
    _reconnectTimestamp = 0;
    _idleTimer = nil;
    [_socket close];
    _state = kIRCCloudStateDisconnected;
#ifndef EXTENSION
    NSLog(@"Websocket idle time exceeded, reconnecting...");
    [self connect:_notifier];
#endif
}

-(void)requestBacklogForBuffer:(int)bid server:(int)cid completion:(void (^)(BOOL))completionHandler {
    [self requestBacklogForBuffer:bid server:cid beforeId:-1 completion:completionHandler];
}

-(void)requestBacklogForBuffer:(int)bid server:(int)cid beforeId:(NSTimeInterval)eid completion:(void (^)(BOOL))completionHandler {
    NSString *URL = nil;
    if(eid > 0)
        URL = [NSString stringWithFormat:@"https://%@/chat/backlog?cid=%i&bid=%i&beforeid=%.0lf", IRCCLOUD_HOST, cid, bid, eid];
    else
        URL = [NSString stringWithFormat:@"https://%@/chat/backlog?cid=%i&bid=%i", IRCCLOUD_HOST, cid, bid];
    OOBFetcher *fetcher = [self fetchOOB:URL];
    fetcher.bid = bid;
    fetcher.completionHandler = completionHandler;
}

-(void)requestArchives:(int)cid {
  OOBFetcher *fetcher = [self fetchOOB:[NSString stringWithFormat:@"https://%@/chat/archives?cid=%i", IRCCLOUD_HOST, cid]];
  fetcher.bid = -1;
}

-(OOBFetcher *)fetchOOB:(NSString *)url {
    @synchronized(_oobQueue) {
        NSArray *fetchers = _oobQueue.copy;
        for(OOBFetcher *fetcher in fetchers) {
            if([fetcher.url isEqualToString:url]) {
                NSLog(@"Cancelling previous OOB request");
                [fetcher cancel];
                [_oobQueue removeObject:fetcher];
            }
        }
        OOBFetcher *fetcher = [[OOBFetcher alloc] initWithURL:url];
        [_oobQueue addObject:fetcher];
        if(_oobQueue.count == 1) {
            [_queue addOperationWithBlock:^{
                @autoreleasepool {
                    NSLog(@"Starting fetcher for URL: %@", url);
                    [fetcher start];
                }
            }];
        } else {
            NSLog(@"OOB Request has been queued");
        }
        return fetcher;
    }
}

-(void)clearOOB {
    @synchronized(_oobQueue) {
        NSMutableArray *oldQueue = _oobQueue;
        _oobQueue = [[NSMutableArray alloc] init];
        for(OOBFetcher *fetcher in oldQueue) {
            [fetcher cancel];
        }
    }
}

-(void)_backlogStarted:(NSNotification *)notification {
    _OOBStartTime = [NSDate timeIntervalSinceReferenceDate];
    _longestEventTime = 0;
    _longestEventType = nil;
    if(_awayOverride.count)
        NSLog(@"Caught %lu self_back events", (unsigned long)_awayOverride.count);
    _currentBid = -1;
    _currentCount = 0;
    _totalCount = 0;
}

-(void)_backlogCompleted:(NSNotification *)notification {
    if(_OOBStartTime) {
        NSTimeInterval total = [NSDate timeIntervalSinceReferenceDate] - _OOBStartTime;
        NSLog(@"OOB processed %i events in %f seconds (%f seconds / event)", _totalCount, total, total / (double)_totalCount);
        NSLog(@"Longest event: %@ (%f seconds)", _longestEventType, _longestEventTime);
        _OOBStartTime = 0;
        _longestEventTime = 0;
        _longestEventType = nil;
    }
    _failCount = 0;
    _accrued = 0;
    _resuming = NO;
    _awayOverride = nil;
    _reconnectTimestamp = [[NSDate date] timeIntervalSince1970] + _idleInterval;
    [self performSelectorOnMainThread:@selector(scheduleIdleTimer) withObject:nil waitUntilDone:NO];
    OOBFetcher *fetcher = notification.object;
    NSLog(@"Backlog finished for bid: %i", fetcher.bid);
    if(fetcher.bid > 0) {
        //[_buffers getBuffer:fetcher.bid].deferred = 0;
        //[_buffers updateTimeout:0 buffer:fetcher.bid];
    } else {
        _ready = YES;
        _numBuffers = 0;
        __socketPaused = NO;
    }
    NSLog(@"I downloaded %i events", _totalCount);
    [_oobQueue removeObject:fetcher];
    [self performSelectorInBackground:@selector(serialize) withObject:nil];
}

-(void)serialize {
}

-(void)_backlogFailed:(NSNotification *)notification {
    _accrued = 0;
    _awayOverride = nil;
    _reconnectTimestamp = [[NSDate date] timeIntervalSince1970] + _idleInterval;
    [self performSelectorOnMainThread:@selector(scheduleIdleTimer) withObject:nil waitUntilDone:NO];
    [_oobQueue removeObject:notification.object];
    if([(OOBFetcher *)notification.object bid] > 0) {
        NSLog(@"Backlog download failed, rescheduling timed out buffers");
        [self _scheduleTimedoutBuffers];
    } else {
        NSLog(@"Initial backlog download failed");
        [self disconnect];
        __socketPaused = NO;
        _state = kIRCCloudStateDisconnected;
        _streamId = nil;
        _highestEID = 0;
        [self fail];
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    }
}

-(void)_scheduleTimedoutBuffers {
}

-(void)_logout:(NSString *)session {
    NSLog(@"Unregister result: %@", [self unregisterAPNs:[[NSUserDefaults standardUserDefaults] objectForKey:@"APNs"] session:session]);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"APNs"];
    [self _postRequest:@"/chat/logout" args:@{@"session":session}];
}

-(void)logout {
    NSLog(@"Logging out");
    _reconnectTimestamp = 0;
    _streamId = nil;
    [__userInfoLock lock];
    _userInfo = @{};
    [__userInfoLock unlock];
    _highestEID = 0;
    _session = nil;
    [self disconnect];
    [self cancelIdleTimer];
}

-(NSString *)session {
    return _session;
}

-(void)setSession:(NSString *)session {
    _session = session;
}

-(BOOL)notifier {
    return _notifier;
}

-(void)setNotifier:(BOOL)notifier {
    _notifier = notifier;
    if(_state == kIRCCloudStateConnected && !notifier) {
        NSLog(@"Upgrading websocket");
        [self _sendRequest:@"upgrade_notifier" args:nil handler:nil];
    }
}

-(NSDictionary *)userInfo {
    [__userInfoLock lock];
    NSDictionary *d = _userInfo;
    [__userInfoLock unlock];
    return d;
}

-(void)setUserInfo:(NSDictionary *)userInfo {
  [__userInfoLock lock];
  _userInfo = userInfo;
  [__userInfoLock unlock];
}

-(void)setLastSelectedBID:(int)bid {
  [__userInfoLock lock];
  NSMutableDictionary *d = _userInfo.mutableCopy;
  [d setObject:@(bid) forKey:@"last_selected_bid"];
  _userInfo = d;
  [__userInfoLock unlock];
  
}

@end
