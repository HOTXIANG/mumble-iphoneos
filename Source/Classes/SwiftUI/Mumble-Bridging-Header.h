//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

// 导入 Mumble 相关的控制器
#import "MUPublicServerListController.h"
#import "MUFavouriteServerListController.h"
#import "MULanServerListController.h"
#import "MUPreferencesViewController.h"
#import "MULegalViewController.h"

// 导入其他必要的类
#import "MUBackgroundView.h"
#import "MUImage.h"
#import "MUFavouriteServer.h"
#import "MUPublicServerList.h"
#import "MUDatabase.h"
#import "MUConnectionController.h"
#import "MUServerViewController.h"
#import "MUTextMessageProcessor.h"

// 导入 MumbleKit
#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKChannel.h>
#import <MumbleKit/MKUser.h>
#import <MumbleKit/MKTextMessage.h>
#import <MumbleKit/MKAudio.h>
