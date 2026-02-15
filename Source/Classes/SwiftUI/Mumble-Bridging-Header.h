//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

#if TARGET_OS_IOS
// 导入 Mumble UIKit 控制器 (iOS only)
#import "MUApplicationDelegate.h"
#import "MUImage.h"
#endif

// 导入平台无关的类
#import "MUFavouriteServer.h"
#import "MUDatabase.h"
#import "MUConnectionController.h"
#import "MUTextMessageProcessor.h"
#import "MUCertificateChainBuilder.h"
#import "MUCertificateController.h"

// 导入 MumbleKit
#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKChannel.h>
#import <MumbleKit/MKUser.h>
#import <MumbleKit/MKTextMessage.h>
#import <MumbleKit/MKAudio.h>
#import <MumbleKit/MKVersion.h>
#import "MKAudioOutput.h"
#import <MumbleKit/MKServerPinger.h>
#import <MumbleKit/MKPermission.h>
#import <MumbleKit/MKAccessControl.h>
#import <MumbleKit/MKChannelACL.h>
#import <MumbleKit/MKChannelGroup.h>

@interface MKUser (SwiftExposedPrivateMethods)
- (void) setLocalMuted:(BOOL)flag;
@end
