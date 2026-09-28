// DynamicBar — Now Playing helper, loaded into /usr/bin/perl.
//
// Why a helper inside perl?
//
// Since macOS 15.4 the `mediaremoted` daemon answers only clients it trusts, so
// an ordinary app gets `kMRMediaRemoteFrameworkErrorDomain Code=3
// "Operation not permitted"` no matter what it asks. Claiming the entitlement
// (`com.apple.nowplaying.entitlement`) does not help: it is restricted, and a
// process that claims it without Apple's authorization is killed at launch.
//
// /usr/bin/perl, however, is a platform binary that the daemon does trust, and
// it is signed without library validation — so it can dlopen this dylib. Running
// the MediaRemote calls from inside that process yields the full record: title,
// artist, album, duration, position, artwork, and the commands the player
// currently accepts.
//
// Protocol (line delimited, one JSON object per line on stdout):
//   -> {"ready":true,"version":1}          once, at start
//   -> {"playing":…,"title":…,…}           on every change and on every poll
//   -> {"error":"mediaremote-unavailable"} if the framework cannot be loaded
// stdin commands (one per line):
//   get            request a snapshot now
//   cmd <code>     play=0 pause=1 next=4 previous=5
//   seek <seconds> jump to a position
// The helper exits when stdin closes, so it can never outlive the app.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

#pragma mark - MediaRemote symbols

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSendCommandToPlayerFn)(int, CFDictionaryRef, id, id, id, void (^)(id));
typedef void (*MRGetCommandsForPlayerFn)(id, dispatch_queue_t, void (^)(NSArray *));

static MRGetInfoFn sGetInfo;
static MRGetBoolFn sGetIsPlaying;
static MRGetPIDFn sGetPID;
static MRGetClientsFn sGetClients;
static MRSendCommandFn sSendCommand;
static MRSendCommandToPlayerFn sSendCommandToPlayer;
static MRGetCommandsForPlayerFn sGetCommandsForPlayer;

static int sOwnerPID;
static dispatch_queue_t sQueue;
static NSString *sArtworkID;
static NSArray *sCommands;

/// Codes read live off a real session's `GetSupportedCommandsForPlayer` — not
/// the old global enum, whose numbering is not always the same. Play, Pause,
/// NextTrack and PreviousTrack happen to match (0/1/4/5); SeekToPlaybackPosition
/// does not (24, not the 11 the old enum suggests).
typedef NS_ENUM(int, DBCommand) {
    DBCommandPlay = 0,
    DBCommandPause = 1,
    DBCommandNextTrack = 4,
    DBCommandPreviousTrack = 5,
    DBCommandSeekToPlaybackPosition = 24,
};

static NSString *const kMediaRemotePath =
    @"/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";

#pragma mark - Output

static void emit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

#pragma mark - Player path

/// The daemon already tracks which player is active system-wide. Asking it
/// directly gives an already-resolved, already-matched path; one built by hand
/// from a bundle identifier resolves too, but the per-client API then reports it
/// supports nothing and silently drops every command sent to it.
///
/// `activePlayerPath` also answers nil until `MRMediaRemoteGetNowPlayingClients`
/// has been called at least once in this process — `startFeed` does that once,
/// at launch.
static id activePlayerPath(void) {
    id serviceClient = [NSClassFromString(@"MRMediaRemoteServiceClient") performSelector:@selector(sharedServiceClient)];
    if (!serviceClient) return nil;
    return [serviceClient performSelector:@selector(activePlayerPath)];
}

/// Which commands the player accepts right now. Cached, because it only labels
/// the payload, and refreshed flat rather than nested inside the info callback —
/// asked from inside a block already running on `sQueue`, the answer never
/// arrives and the feed goes silent.
static void refreshCommands(void) {
    if (!sGetCommandsForPlayer) return;
    id path = activePlayerPath();
    if (!path) return;
    sGetCommandsForPlayer(path, sQueue, ^(NSArray *infos) {
        NSMutableArray *codes = [NSMutableArray array];
        for (id info in infos) {
            id code = [info valueForKey:@"command"];
            id enabled = [info valueForKey:@"enabled"];
            // A command can be listed and still be off right now; only what is
            // both listed and enabled counts as offered.
            if ([code isKindOfClass:NSNumber.class] && (enabled == nil || [enabled boolValue])) {
                [codes addObject:code];
            }
        }
        sCommands = codes;
    });
}

#pragma mark - Publishing

/// Reads the current record and prints it. Artwork is included only when the
/// track changed — it is the bulk of the payload and never changes mid-track.
///
/// `elapsed` travels with the moment it was taken: the daemon does not keep that
/// field running, it is a reading from the last change of state. What advances
/// is the clock beside it, so both have to be sent.
static void publish(void) {
    if (!sGetInfo) return;
    if (sGetPID) sGetPID(sQueue, ^(int pid) { sOwnerPID = pid; });
    refreshCommands();

    void (^withPlaying)(Boolean) = ^(Boolean playing) {
        sGetInfo(sQueue, ^(CFDictionaryRef raw) {
            NSDictionary *info = (__bridge NSDictionary *)raw;
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";

            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            // `playing ? @YES : @NO`, not `@(playing ? YES : NO)`: in C the ternary
            // promotes both branches to int, so the boxed number would serialise
            // as 1 instead of true.
            out[@"playing"] = playing ? @YES : @NO;
            out[@"title"] = title;
            out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
            out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
            out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
            out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
            out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
            out[@"pid"] = @(sOwnerPID);

            id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            out[@"timestamp"] = [stamp isKindOfClass:NSDate.class]
                ? @([(NSDate *)stamp timeIntervalSince1970])
                : @0;

            NSString *artworkID = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] ?: title;
            NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if (artwork.length > 0 && ![artworkID isEqualToString:sArtworkID]) {
                out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                sArtworkID = artworkID;
            }
            if (title.length == 0) sArtworkID = nil;

            // Left out entirely until an answer has arrived: absent is not the
            // same as empty, and "unknown" must not read as "accepts nothing".
            if (sCommands) out[@"commands"] = sCommands;

            emit(out);
        });
    };

    if (sGetIsPlaying) {
        sGetIsPlaying(sQueue, withPlaying);
    } else {
        withPlaying(false);
    }
}

#pragma mark - Commands

static void sendCommand(DBCommand command, NSDictionary *options) {
    id path = activePlayerPath();
    if (sSendCommandToPlayer && path) {
        sSendCommandToPlayer(command, (__bridge CFDictionaryRef)options, nil, path, nil, ^(id result) {});
        return;
    }
    // Fallback for the (unlikely) case where no per-client path resolves: the
    // global command is routed by the daemon to whatever is playing.
    if (sSendCommand) {
        sSendCommand(command, (__bridge CFDictionaryRef)options);
    }
}

static void handleCommand(NSString *line) {
    if ([line isEqualToString:@"get"]) {
        publish();
    } else if ([line hasPrefix:@"cmd "]) {
        sendCommand((DBCommand)[line substringFromIndex:4].intValue, nil);
        publish();
    } else if ([line hasPrefix:@"seek "]) {
        double seconds = [line substringFromIndex:5].doubleValue;
        sendCommand(DBCommandSeekToPlaybackPosition, @{@"kMRMediaRemoteOptionPlaybackPosition": @(seconds)});
        publish();
    }
}

#pragma mark - Threads

static void startFeed(void) {
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            sQueue = dispatch_queue_create("com.dynamicbar.mediaremote", DISPATCH_QUEUE_SERIAL);

            void *handle = dlopen(kMediaRemotePath.UTF8String, RTLD_NOW);
            if (!handle) {
                emit(@{@"error": @"mediaremote-unavailable"});
                return;
            }
            sGetInfo = (MRGetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
            sGetIsPlaying = (MRGetBoolFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
            sGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
            sGetClients = (MRGetClientsFn)dlsym(handle, "MRMediaRemoteGetNowPlayingClients");
            sSendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
            sSendCommandToPlayer = (MRSendCommandToPlayerFn)dlsym(handle, "MRMediaRemoteSendCommandToPlayer");
            sGetCommandsForPlayer = (MRGetCommandsForPlayerFn)dlsym(handle, "MRMediaRemoteGetSupportedCommandsForPlayer");

            MRRegisterFn registerNotifications =
                (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
            if (registerNotifications) registerNotifications(sQueue);

            // `activePlayerPath` answers nil until the per-client subscription
            // has been primed at least once in this process — call order
            // matters, not just symbol presence.
            if (sGetClients) sGetClients(sQueue, ^(NSArray *clients) {});

            for (NSString *name in @[
                     @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                     @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                 ]) {
                [NSNotificationCenter.defaultCenter addObserverForName:name
                                                                object:nil
                                                                 queue:nil
                                                            usingBlock:^(NSNotification *note) { publish(); }];
            }

            emit(@{@"ready": @YES, @"version": @1});
            publish();

            // A poll, not just a subscription: on macOS 26 the notifications
            // above were measured arriving zero times across 30-second windows
            // that included real track changes, so a client that only reacted to
            // them would go stale silently.
            [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) { publish(); }];

            [NSRunLoop.currentRunLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
            [NSRunLoop.currentRunLoop run];
        }
    }];
}

static void startCommandReader(void) {
    [NSThread detachNewThreadWithBlock:^{
        char buffer[512];
        while (fgets(buffer, sizeof buffer, stdin)) {
            @autoreleasepool {
                NSString *line = [@(buffer) stringByTrimmingCharactersInSet:
                                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length) handleCommand(line);
            }
        }
        // The pipe closed — the app went away. Never outlive it.
        exit(0);
    }];
}

__attribute__((constructor))
static void dynamicbar_media_init(void) {
    // A player that closes its pipe mid-write must not take the host down.
    signal(SIGPIPE, SIG_IGN);
    startFeed();
    startCommandReader();
}
