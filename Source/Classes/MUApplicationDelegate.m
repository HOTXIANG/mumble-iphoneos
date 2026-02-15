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

#import "Mumble-Swift.h"  // 这是 Xcode 自动生成的 Swift 桥接头文件
#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKVersion.h>
#import <UserNotifications/UserNotifications.h>

@interface MUApplicationDelegate () <UIApplicationDelegate,
                                     UIAlertViewDelegate> {
    UIWindow                  *_window;
    UINavigationController    *_navigationController;
    BOOL                      _connectionActive;
    NSString                  *_lastAudioRestartSignature;

}
- (void) setupAudio;
- (void) forceKeyboardLoad;
@end

@implementation MUApplicationDelegate

    NSTimeInterval _lastAudioRestartTime;

static NSString *MURestartSignatureFromDefaults(NSUserDefaults *defaults) {
    return [NSString stringWithFormat:@"%@|%@|%f|%f|%@|%f|%d|%d|%d|%f|%d|%d|%d",
            [defaults stringForKey:@"AudioTransmitMethod"] ?: @"vad",
            [defaults stringForKey:@"AudioVADKind"] ?: @"amplitude",
            [defaults doubleForKey:@"AudioVADBelow"],
            [defaults doubleForKey:@"AudioVADAbove"],
            [defaults stringForKey:@"AudioQualityKind"] ?: @"balanced",
            [defaults doubleForKey:@"AudioMicBoost"],
            [defaults boolForKey:@"AudioPreprocessor"],
            [defaults boolForKey:@"AudioEchoCancel"],
            [defaults boolForKey:@"AudioSidetone"],
            [defaults doubleForKey:@"AudioSidetoneVolume"],
            [defaults boolForKey:@"AudioSpeakerPhoneMode"],
            [defaults boolForKey:@"AudioOpusCodecForceCELTMode"],
            [defaults boolForKey:@"AudioMixerDebug"]];
}

- (BOOL) application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectionOpened:) name:MUConnectionOpenedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectionClosed:) name:MUConnectionClosedNotification object:nil];
    
    // Reset application badge, in case something brought it into an inconsistent state.
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center setBadgeCount:0 withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"Error setting badge count: %@", error.localizedDescription);
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
                                                                @"amplitude",                      @"AudioVADKind",
                                                                @"vad",                            @"AudioTransmitMethod",
                                                                [NSNumber numberWithBool:YES],     @"AudioPreprocessor",
                                                                [NSNumber numberWithBool:YES],     @"AudioEchoCancel",
                                                                [NSNumber numberWithFloat:1.0f],   @"AudioMicBoost",
                                                                @"balanced",                       @"AudioQualityKind",
                                                                [NSNumber numberWithBool:NO],      @"AudioSidetone",
                                                                [NSNumber numberWithFloat:0.2f],   @"AudioSidetoneVolume",
                                                                [NSNumber numberWithBool:YES],     @"AudioSpeakerPhoneMode",
                                                                [NSNumber numberWithBool:YES],     @"AudioOpusCodecForceCELTMode",
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
    if ([[url scheme] isEqualToString:@"mumble"]) {
        MUConnectionController *connController = [MUConnectionController sharedController];
        NSString *hostname = [url host];
        NSNumber *port = [url port];
        NSString *username = [url user];
        NSString *password = [url password];
        [connController connetToHostname:hostname
                                    port:port ? [port integerValue] : 64738
                            withUsername:username
                             andPassword:password
                          certificateRef:nil
                             displayName:nil];
        return YES;
    }
    return YES;
}

- (BOOL) application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    if ([[url scheme] isEqualToString:@"mumble"]) {
        MUConnectionController *connController = [MUConnectionController sharedController];
        if ([connController isConnected]) {
            return NO;
        }
        NSString *hostname = [url host];
        NSNumber *port = [url port];
        NSString *username = [url user];
        NSString *password = [url password];
        [connController connetToHostname:hostname
                                    port:port ? [port integerValue] : 64738
                            withUsername:username
                             andPassword:password
                          certificateRef:nil
                             displayName:nil];
        return YES;
    }
    return NO;
}

- (void) applicationWillTerminate:(UIApplication *)application {
    [MUDatabase teardown];
    
    if (@available(iOS 16.1, *)) {
        [LiveActivityCleanup forceEndAllActivitiesBlocking];
    }
}

- (void) setupAudio {
    NSLog(@"[DEBUG] 🔧 setupAudio CALLED! Time: %f", [[NSDate date] timeIntervalSince1970]); // <--- 添加这行
    // Set up a good set of default audio settings.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *restartSignature = MURestartSignatureFromDefaults(defaults);
    MKAudioSettings settings;
    memset(&settings, 0, sizeof(settings));

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastAudioRestartTime < 0.5) {
        NSLog(@"⚠️ Audio restart ignored (too frequent)");
        // 如果你需要确保最后一次设置生效，这里其实应该用 NSTimer 再次尝试
        // 但配合 Swift 端的 Debounce，这里直接 return 也是一种保护防止崩坏
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
    
    settings.vadMin = [defaults floatForKey:@"AudioVADBelow"];
    settings.vadMax = [defaults floatForKey:@"AudioVADAbove"];
    
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
    settings.enablePreprocessor = [defaults boolForKey:@"AudioPreprocessor"];
    if (settings.enablePreprocessor) {
        settings.enableEchoCancellation = [defaults boolForKey:@"AudioEchoCancel"];
    } else {
        settings.enableEchoCancellation = NO;
    }

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
    if (shouldRestart) {
        NSLog(@"[DEBUG] 🔧 Settings changed while active. Restarting audio engine...");
        [audio restart];
    } else {
        NSLog(@"[DEBUG] 💤 Settings updated without restart.");
    }
    _lastAudioRestartSignature = [restartSignature copy];
    
    NSLog(@"[DEBUG] ✅ setupAudio FINISHED. Engine should be running.");
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
}

- (void) connectionClosed:(NSNotification *)notification {
    _connectionActive = NO;
}

- (void) applicationWillResignActive:(UIApplication *)application {
    // If we have any active connections, don't stop MKAudio. This is
    // for 'clicking-the-home-button' invocations of this method.
    //
    // In case we've been backgrounded by a phone call, MKAudio will
    // already have shut itself down.
    if (!_connectionActive) {
        NSLog(@"MumbleApplicationDelegate: Not connected to a server. Stopping MKAudio.");
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
    if (_connectionActive && ![[MKAudio sharedAudio] isRunning]) {
        NSLog(@"MumbleApplicationDelegate: Connection active but MKAudio not running. Starting it.");
        [[MKAudio sharedAudio] start];
        
#if ENABLE_REMOTE_CONTROL
        // Re-start the remote control server.
        [[MURemoteControlServer sharedRemoteControlServer] stop];
        [[MURemoteControlServer sharedRemoteControlServer] start];
#endif
    }
}

@end
#endif // TARGET_OS_IOS
