#if TARGET_OS_IOS
// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUApplicationDelegate.h"

#import "MUDatabase.h"
#import "MUConnectionController.h"
#import "MUNotificationController.h"
#import "MURemoteControlServer.h"
#import "MUImage.h"
#import "MumbleLogger.h"

#import "Mumble-Swift.h"  // 这是 Xcode 自动生成的 Swift 桥接头文件
#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKVersion.h>
#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKChannel.h>
#import <UserNotifications/UserNotifications.h>

@interface MUApplicationDelegate () <UIApplicationDelegate,
                                     MKAudioDelegate,
                                     UIAlertViewDelegate> {
    UIWindow                  *_window;
    UINavigationController    *_navigationController;
    BOOL                      _connectionActive;
    NSString                  *_lastAudioRestartSignature;
    NSArray<NSString *>       *_pendingDeepLinkChannelPath;
}
- (void) setupAudio;
- (void) forceKeyboardLoad;
- (BOOL) handleMumbleURL:(NSURL *)url;
- (BOOL) hasActiveServerConnection;
- (NSArray<NSString *> *) decodedChannelPathFromURL:(NSURL *)url;
- (BOOL) joinChannelPathComponents:(NSArray<NSString *> *)pathComponents onServerModel:(MKServerModel *)serverModel;
@end

@implementation MUApplicationDelegate

    NSTimeInterval _lastAudioRestartTime;

static NSString *MURestartSignatureFromDefaults(NSUserDefaults *defaults) {
    NSArray<NSString *> *components = @[
        [defaults stringForKey:@"AudioTransmitMethod"] ?: @"vad",
        [defaults stringForKey:@"AudioVADKind"] ?: @"amplitude",
        @([defaults doubleForKey:@"AudioVADBelow"]).stringValue,
        @([defaults doubleForKey:@"AudioVADAbove"]).stringValue,
        @([defaults doubleForKey:@"AudioVADHoldSeconds"]).stringValue,
        [defaults stringForKey:@"AudioQualityKind"] ?: @"balanced",
        @([defaults doubleForKey:@"AudioMicBoost"]).stringValue,
        @([defaults boolForKey:@"AudioStereoInput"]).stringValue,
        @([defaults boolForKey:@"AudioStereoOutput"]).stringValue,
        @([defaults boolForKey:@"AudioSpeakerPhoneMode"]).stringValue,
        @([defaults boolForKey:@"AudioOpusCodecForceCELTMode"]).stringValue,
        @([defaults boolForKey:@"AudioMixerDebug"]).stringValue,
        @([defaults boolForKey:@"AudioPluginInputTrackEnabled"]).stringValue,
        @([defaults doubleForKey:@"AudioPluginInputTrackGain"]).stringValue,
        @([defaults boolForKey:@"AudioPluginRemoteBusEnabled"]).stringValue,
        @([defaults doubleForKey:@"AudioPluginRemoteBusGain"]).stringValue,
    ];
    return [components componentsJoinedByString:@"|"];
}

- (BOOL) application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectionOpened:) name:MUConnectionOpenedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectionClosed:) name:MUConnectionClosedNotification object:nil];
    
    // Reset application badge, in case something brought it into an inconsistent state.
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center setBadgeCount:0 withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            MULogError(General, @"Error setting badge count: %@", error.localizedDescription);
        }
    }];
    
    // Initialize the notification controller
    [MUNotificationController sharedController];
    
    // Set MumbleKit release string
    [[MKVersion sharedVersion] setOverrideReleaseString:
        [NSString stringWithFormat:@"Mumble for iOS %@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]]];
    
    // Enable Opus unconditionally
    [[MKVersion sharedVersion] setOpusEnabled:YES];

    // Register default settings
    [[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                // Audio
                                                                [NSNumber numberWithFloat:1.0f],   @"AudioOutputVolume",
                                                                [NSNumber numberWithFloat:0.6f],   @"AudioVADAbove",
                                                                [NSNumber numberWithFloat:0.3f],   @"AudioVADBelow",
                                                                [NSNumber numberWithFloat:0.1f],   @"AudioVADHoldSeconds",
                                                                @"amplitude",                      @"AudioVADKind",
                                                                @"vad",                            @"AudioTransmitMethod",
                                                                [NSNumber numberWithBool:NO],      @"AudioStereoInput",
                                                                [NSNumber numberWithBool:YES],     @"AudioStereoOutput",
                                                                [NSNumber numberWithFloat:1.0f],   @"AudioMicBoost",
                                                                @"balanced",                       @"AudioQualityKind",
                                                                [NSNumber numberWithBool:NO],      @"AudioSidetone",
                                                                [NSNumber numberWithFloat:0.2f],   @"AudioSidetoneVolume",
                                                                [NSNumber numberWithBool:NO],      @"ShowPTTButton",
                                                                [NSNumber numberWithInt:49],       @"PTTHotkeyCode",
                                                                [NSNumber numberWithBool:YES],     @"AudioSpeakerPhoneMode",
                                                                [NSNumber numberWithBool:NO],      @"AudioOpusCodecForceCELTMode",
                                                                [NSNumber numberWithBool:NO],      @"AudioPluginInputTrackEnabled",
                                                                [NSNumber numberWithFloat:1.0f],   @"AudioPluginInputTrackGain",
                                                                [NSNumber numberWithBool:NO],      @"AudioPluginRemoteBusEnabled",
                                                                [NSNumber numberWithFloat:1.0f],   @"AudioPluginRemoteBusGain",
                                                                [NSNumber numberWithInt:256],      @"AudioPluginHostBufferFrames",
                                                                // Network
                                                                [NSNumber numberWithBool:NO],      @"NetworkForceTCP",
                                                                @"MumbleUser",                     @"DefaultUserName",
                                                                // Notifications
                                                                [NSNumber numberWithBool:YES],     @"NotifyUserJoinedSameChannel",
                                                                [NSNumber numberWithBool:YES],     @"NotifyUserLeftSameChannel",
                                                                [NSNumber numberWithBool:NO],      @"NotifyUserJoinedOtherChannels",
                                                                [NSNumber numberWithBool:NO],      @"NotifyUserLeftOtherChannels",
                                                        nil]];

    // Disable mixer debugging for all builds.
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithBool:NO] forKey:@"AudioMixerDebug"];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                            selector:@selector(reloadPreferences)
                                                name:@"MumblePreferencesChanged"
                                            object:nil];
    
    [self reloadPreferences];
    [[MKAudio sharedAudio] setDelegate:self];
    [MUDatabase initializeDatabase];
    
#ifdef ENABLE_REMOTE_CONTROL
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"RemoteControlServerEnabled"]) {
        [[MURemoteControlServer sharedRemoteControlServer] start];
    }
#endif
    
    // Try to use a dark keyboard throughout the app's text fields.
    if (@available(iOS 7, *)) {
        [[UITextField appearance] setKeyboardAppearance:UIKeyboardAppearanceDark];
    }
    
    /*_window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    if (@available(iOS 7, *)) {
    // XXX: don't do it system-wide just yet
    //    _window.tintColor = [UIColor whiteColor];
    }
    
    // Put a background view in here, to have prettier transitions.
    //[_window addSubview:[MUBackgroundView backgroundView]];

    // Add our default navigation controller
    _navigationController = [[UINavigationController alloc] init];
    _navigationController.toolbarHidden = YES;

    UIUserInterfaceIdiom idiom = [[UIDevice currentDevice] userInterfaceIdiom];
    UIViewController *welcomeScreen = nil;
    // iPhone 使用纯 SwiftUI 实现
    SwiftRootViewControllerWrapper *swiftRoot = [[SwiftRootViewControllerWrapper alloc] init];
    [_window setRootViewController:swiftRoot];
    
    [_window makeKeyAndVisible];*/

    NSURL *url = [launchOptions objectForKey:UIApplicationLaunchOptionsURLKey];
    if (url != nil) {
        [self handleMumbleURL:url];
    }
    return YES;
}

- (BOOL) application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    return [self handleMumbleURL:url];
}

- (BOOL) handleMumbleURL:(NSURL *)url {
    NSString *scheme = [[url scheme] lowercaseString];
    if (![scheme isEqualToString:@"mumble"] && ![scheme isEqualToString:@"neomumble"]) {
        return NO;
    }

    NSString *hostname = [url host];
    if (hostname.length == 0) {
        return NO;
    }

    NSInteger port = [url port] ? [[url port] integerValue] : 64738;
    NSString *username = [url user];
    NSString *password = [url password];
    NSArray<NSString *> *pathComponents = [self decodedChannelPathFromURL:url];

    MUConnectionController *connController = [MUConnectionController sharedController];
    MKConnection *activeConnection = [connController connection];
    BOOL hasActiveOrConnectingConnection = [connController isConnected] || activeConnection != nil;

    if (hasActiveOrConnectingConnection) {
        NSString *activeHost = [[activeConnection hostname] lowercaseString] ?: @"";
        NSInteger activePort = [activeConnection port];
        BOOL sameServer = [activeHost isEqualToString:[hostname lowercaseString]] && activePort == port;

        if (!sameServer) {
            return YES;
        }

        if (pathComponents.count > 0 && [connController isConnected]) {
            if ([self joinChannelPathComponents:pathComponents onServerModel:[connController serverModel]]) {
                _pendingDeepLinkChannelPath = nil;
            } else {
                _pendingDeepLinkChannelPath = [pathComponents copy];
            }
        } else {
            _pendingDeepLinkChannelPath = [pathComponents copy];
        }
        return YES;
    }

    [connController connectToHostname:hostname
                                port:port
                        withUsername:username
                         andPassword:password
                      certificateRef:nil
                         displayName:nil];
    _pendingDeepLinkChannelPath = [pathComponents copy];
    return YES;
}

- (NSArray<NSString *> *) decodedChannelPathFromURL:(NSURL *)url {
    NSArray<NSString *> *rawComponents = [url pathComponents];
    if (rawComponents.count == 0) {
        return @[];
    }

    NSMutableArray<NSString *> *decoded = [NSMutableArray arrayWithCapacity:rawComponents.count];
    for (NSString *component in rawComponents) {
        if (component.length == 0 || [component isEqualToString:@"/"]) {
            continue;
        }
        NSString *value = [component stringByRemovingPercentEncoding] ?: component;
        if (value.length > 0) {
            [decoded addObject:value];
        }
    }
    return decoded;
}

- (BOOL) joinChannelPathComponents:(NSArray<NSString *> *)pathComponents onServerModel:(MKServerModel *)serverModel {
    if (pathComponents.count == 0 || serverModel == nil) {
        return NO;
    }

    MKChannel *current = [serverModel rootChannel];
    if (current == nil) {
        return NO;
    }

    for (NSString *pathName in pathComponents) {
        NSArray *subChannels = [current channels];
        MKChannel *next = nil;
        for (id obj in subChannels) {
            if (![obj isKindOfClass:[MKChannel class]]) {
                continue;
            }
            MKChannel *candidate = (MKChannel *)obj;
            NSString *candidateName = [candidate channelName] ?: @"";
            if ([candidateName isEqualToString:pathName]) {
                next = candidate;
                break;
            }
        }
        if (next == nil) {
            return NO;
        }
        current = next;
    }

    [serverModel joinChannel:current];
    return YES;
}

- (void) applicationWillTerminate:(UIApplication *)application {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"AudioPluginDSPPendingVerification"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"AudioPluginCleanExit"];
    [MUDatabase teardown];
    
    if (@available(iOS 16.1, *)) {
        [LiveActivityCleanup forceEndAllActivitiesBlocking];
    }
}

- (void) setupAudio {
    // Set up a good set of default audio settings.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *restartSignature = MURestartSignatureFromDefaults(defaults);
    MKAudioSettings settings;
    memset(&settings, 0, sizeof(settings));

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastAudioRestartTime < 0.5) {
        MULogDebug(audio, @"Audio restart ignored (too frequent)");
        return;
    }
    _lastAudioRestartTime = now;
    
    if ([[defaults stringForKey:@"AudioTransmitMethod"] isEqualToString:@"vad"])
        settings.transmitType = MKTransmitTypeVAD;
    else if ([[defaults stringForKey:@"AudioTransmitMethod"] isEqualToString:@"continuous"])
        settings.transmitType = MKTransmitTypeContinuous;
    else if ([[defaults stringForKey:@"AudioTransmitMethod"] isEqualToString:@"ptt"])
        settings.transmitType = MKTransmitTypeToggle;
    else
        settings.transmitType = MKTransmitTypeVAD;
    
    settings.vadKind = MKVADKindAmplitude;
    if ([[defaults stringForKey:@"AudioVADKind"] isEqualToString:@"snr"]) {
        settings.vadKind = MKVADKindSignalToNoise;
    } else if ([[defaults stringForKey:@"AudioVADKind"] isEqualToString:@"amplitude"]) {
        settings.vadKind = MKVADKindAmplitude;
    }
    BOOL snrModeEnabled = ([[defaults stringForKey:@"AudioVADKind"] isEqualToString:@"snr"]);
    
    settings.vadMin = [defaults floatForKey:@"AudioVADBelow"];
    settings.vadMax = [defaults floatForKey:@"AudioVADAbove"];
    double vadHoldSeconds = [defaults doubleForKey:@"AudioVADHoldSeconds"];
    if (vadHoldSeconds < 0.0) {
        vadHoldSeconds = 0.0;
    } else if (vadHoldSeconds > 0.3) {
        vadHoldSeconds = 0.3;
    }
    settings.enableVadGate = vadHoldSeconds > 0.0;
    settings.vadGateTimeSeconds = vadHoldSeconds;
    
    NSString *quality = [defaults stringForKey:@"AudioQualityKind"];
    if ([quality isEqualToString:@"low"]) {
        // Will fall back to CELT if the
        // server requires it for inter-op.
        settings.codec = MKCodecFormatOpus;
        settings.quality = 60000;
        settings.audioPerPacket = 4;
    } else if ([quality isEqualToString:@"balanced"]) {
        // Will fall back to CELT if the
        // server requires it for inter-op.
        settings.codec = MKCodecFormatOpus;
        settings.quality = 100000;
        settings.audioPerPacket = 2;
    } else if ([quality isEqualToString:@"high"] || [quality isEqualToString:@"opus"]) {
        // Will fall back to CELT if the
        // server requires it for inter-op.
        settings.codec = MKCodecFormatOpus;
        settings.quality = 192000;
        settings.audioPerPacket = 1;
    } else {
        settings.codec = MKCodecFormatCELT;
        if ([[defaults stringForKey:@"AudioCodec"] isEqualToString:@"opus"])
            settings.codec = MKCodecFormatOpus;
        if ([[defaults stringForKey:@"AudioCodec"] isEqualToString:@"celt"])
            settings.codec = MKCodecFormatCELT;
        if ([[defaults stringForKey:@"AudioCodec"] isEqualToString:@"speex"])
            settings.codec = MKCodecFormatSpeex;
        settings.quality = (int) [defaults integerForKey:@"AudioQualityBitrate"];
        settings.audioPerPacket = (int) [defaults integerForKey:@"AudioQualityFrames"];
    }
    
    settings.noiseSuppression = -42; /* -42 dB */
    settings.amplification = 20.0f;
    settings.jitterBufferSize = 0; /* 10 ms */
    settings.volume = [defaults floatForKey:@"AudioOutputVolume"];
    settings.outputDelay = 0; /* 10 ms */
    settings.micBoost = [defaults floatForKey:@"AudioMicBoost"];
    // Keep preprocessing internal-only for SNR mode so SNR meter/VAD remain functional
    settings.enablePreprocessor = snrModeEnabled;
    settings.enableStereoInput = [defaults boolForKey:@"AudioStereoInput"];
    settings.enableStereoOutput = [defaults boolForKey:@"AudioStereoOutput"];
    settings.enableEchoCancellation = NO;
    settings.enableDenoise = NO;

    settings.enableSideTone = [defaults boolForKey:@"AudioSidetone"];
    settings.sidetoneVolume = [defaults floatForKey:@"AudioSidetoneVolume"];
    
    if ([defaults boolForKey:@"AudioSpeakerPhoneMode"]) {
        settings.preferReceiverOverSpeaker = NO;
    } else {
        settings.preferReceiverOverSpeaker = YES;
    }
    
    settings.opusForceCELTMode = [defaults boolForKey:@"AudioOpusCodecForceCELTMode"];
    settings.audioMixerDebug = [defaults boolForKey:@"AudioMixerDebug"];

    MKAudio *audio = [MKAudio sharedAudio];
    BOOL audioActive = _connectionActive || [audio isRunning];
    BOOL shouldRestart = audioActive
        && _lastAudioRestartSignature != nil
        && ![_lastAudioRestartSignature isEqualToString:restartSignature];
    [audio updateAudioSettings:&settings];
    [audio setPluginHostBufferFrames:(NSUInteger)MAX(64, [defaults integerForKey:@"AudioPluginHostBufferFrames"])];
    [audio setInputTrackPreviewGain:[defaults floatForKey:@"AudioPluginInputTrackGain"]
                            enabled:[defaults boolForKey:@"AudioPluginInputTrackEnabled"]];
    [audio setRemoteBusPreviewGain:[defaults floatForKey:@"AudioPluginRemoteBusGain"]
                           enabled:[defaults boolForKey:@"AudioPluginRemoteBusEnabled"]];
    if (shouldRestart) {
        MULogInfo(audio, @"Settings changed while active. Restarting audio engine.");
        [audio restart];
    } else {
        MULogDebug(audio, @"Settings updated without restart.");
    }
    _lastAudioRestartSignature = [restartSignature copy];

    MULogInfo(audio, @"Audio setup completed.");
}

// Reload application preferences...
- (void) reloadPreferences {
    [self setupAudio];
}

- (void) forceKeyboardLoad {
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectZero];
    [_window addSubview:textField];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [textField becomeFirstResponder];
}

- (void) keyboardWillShow:(NSNotification *)notification {
    for (UIView *view in [_window subviews]) {
        if ([view isFirstResponder]) {
            [view resignFirstResponder];
            [view removeFromSuperview];
            
            [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
        }
    }
}

- (void) connectionOpened:(NSNotification *)notification {
    _connectionActive = YES;
    if (_pendingDeepLinkChannelPath.count > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MUConnectionController *connController = [MUConnectionController sharedController];
            if ([self joinChannelPathComponents:self->_pendingDeepLinkChannelPath onServerModel:[connController serverModel]]) {
                self->_pendingDeepLinkChannelPath = nil;
            }
        });
    }
}

- (void) connectionClosed:(NSNotification *)notification {
    _connectionActive = NO;
    _pendingDeepLinkChannelPath = nil;
}

- (BOOL) hasActiveServerConnection {
    MUConnectionController *connectionController = [MUConnectionController sharedController];
    return _connectionActive
        && [connectionController isConnected]
        && [connectionController serverModel] != nil;
}

- (BOOL) audioShouldBeRunning:(MKAudio *)audio {
    (void)audio;
    return [self hasActiveServerConnection];
}

- (void) applicationWillResignActive:(UIApplication *)application {
    // If we have any active connections, don't stop MKAudio. This is
    // for 'clicking-the-home-button' invocations of this method.
    //
    // In case we've been backgrounded by a phone call, MKAudio will
    // already have shut itself down.
    BOOL hasActiveConnection = [self hasActiveServerConnection];
    if (!hasActiveConnection) {
        _connectionActive = NO;
        MULogInfo(General, @"Not connected to a server. Stopping MKAudio.");
        [[MKAudio sharedAudio] stop];
        
#ifdef ENABLE_REMOTE_CONTROL
        // Also terminate the remote control server.
        [[MURemoteControlServer sharedRemoteControlServer] stop];
#endif
    }
}

- (void) applicationDidBecomeActive:(UIApplication *)application {
    // It is possible that we will become active after a phone call has ended.
    // In the case of phone calls, MKAudio will automatically stop itself, to
    // allow the phone call to go through. However, once we're back inside the
    // application, we have to start ourselves again.
    //
    // For regular backgrounding, we usually don't turn off the audio system, and
    // we won't have to start it again.
    BOOL hasActiveConnection = [self hasActiveServerConnection];
    if (hasActiveConnection && ![[MKAudio sharedAudio] isRunning]) {
        MULogInfo(General, @"Connection active but MKAudio not running. Starting it.");
        [[MKAudio sharedAudio] start];
        
#if ENABLE_REMOTE_CONTROL
        // Re-start the remote control server.
        [[MURemoteControlServer sharedRemoteControlServer] stop];
        [[MURemoteControlServer sharedRemoteControlServer] start];
#endif
    } else if (!hasActiveConnection && [[MKAudio sharedAudio] isRunning]) {
        _connectionActive = NO;
        MULogInfo(General, @"No active server connection on foreground. Stopping MKAudio.");
        [[MKAudio sharedAudio] stop];
    }
}

@end
#endif // TARGET_OS_IOS
