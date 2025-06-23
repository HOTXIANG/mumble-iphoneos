// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUServerRootViewController.h"
#import "MUServerViewController.h"
#import "MUServerCertificateTrustViewController.h"
#import "MUAccessTokenViewController.h"
#import "MUCertificateViewController.h"
#import "MUNotificationController.h"
#import "MUConnectionController.h"
#import "MUMessagesViewController.h"
#import "MUDatabase.h"
#import "MUAudioMixerDebugViewController.h"

#import <MumbleKit/MKConnection.h>
#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKCertificate.h>
#import <MumbleKit/MKAudio.h>

#import "MKNumberBadgeView.h"

@interface MUServerRootViewController () <MKConnectionDelegate, MKServerModelDelegate> {
    MKConnection                *_connection;
    MKServerModel               *_model;
    
    NSInteger                   _segmentIndex;
    UISegmentedControl          *_segmentedControl;
    UIBarButtonItem             *_disconnectButton;
    UIBarButtonItem             *_modeSwitchButton;
    UIBarButtonItem             *_muteButton;
    UIBarButtonItem             *_deafenButton;
    UIView                      *_bottomControlsView;
    MKNumberBadgeView           *_numberBadgeView;

    MUServerViewController      *_serverView;
    MUMessagesViewController    *_messagesView;
    
    NSInteger                   _unreadMessages;
    BOOL                        _wasMutedBeforeDeafen; // 用于记录 deafen 前的静音状态
}
@end

@implementation MUServerRootViewController

- (id) initWithConnection:(MKConnection *)conn andServerModel:(MKServerModel *)model {
    if ((self = [super init])) {
        _connection = conn;
        _model = model;
        [_model addDelegate:self];
        
        _unreadMessages = 0;
        _wasMutedBeforeDeafen = NO;
        
        _serverView = [[MUServerViewController alloc] initWithServerModel:_model];
        _messagesView = [[MUMessagesViewController alloc] initWithServerModel:_model];
        
        _numberBadgeView = [[MKNumberBadgeView alloc] initWithFrame:CGRectZero];
        _numberBadgeView.shadow = NO;
        _numberBadgeView.font = [UIFont boldSystemFontOfSize:11.0f];
        _numberBadgeView.hidden = YES;
        _numberBadgeView.shine = NO;
        _numberBadgeView.strokeColor = [UIColor redColor];
    }
    return self;
}

- (void) dealloc {
    [_model removeDelegate:self];
    [_connection setDelegate:nil];
}

- (void) takeOwnershipOfConnectionDelegate {
    [_connection setDelegate:self];
}

#pragma mark - View lifecycle

- (void) viewDidLoad {
    [super viewDidLoad];
    
    // 首先设置导航栏外观
    [self setupNavigationBarAppearance];
    
    // 设置导航栏按钮
    [self setupNavigationBarButtons];
    
    // 创建导航栏中的切换控件
    [self setupNavigationBarSegmentedControl];
    
    // 创建底部控制视图（麦克风静音和扬声器静音）
    [self setupBottomControls];
    
    // 设置初始视图控制器
    [self setViewControllers:[NSArray arrayWithObject:_serverView] animated:NO];
    
    // 更新导航栏
    [self updateNavigationBarForCurrentView];
    
    // 隐藏工具栏
    [self setToolbarHidden:YES animated:NO];
}

- (void) setupNavigationBarAppearance {
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            // 深色模式
            [appearance configureWithOpaqueBackground];
            appearance.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]; // 深灰色背景
            appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
        } else {
            // 浅色模式
            [appearance configureWithDefaultBackground];
            appearance.backgroundColor = [UIColor systemBackgroundColor];
            appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor blackColor]};
        }
        
        // 移除阴影
        appearance.shadowColor = [UIColor clearColor];
        
        self.navigationBar.standardAppearance = appearance;
        self.navigationBar.scrollEdgeAppearance = appearance;
        if (@available(iOS 15.0, *)) {
            self.navigationBar.compactScrollEdgeAppearance = appearance;
        }
        
        // 设置按钮颜色
        self.navigationBar.tintColor = [UIColor labelColor];
        
    } else {
        // iOS 12 及以下
        self.navigationBar.barStyle = UIBarStyleDefault;
        self.navigationBar.backgroundColor = [UIColor whiteColor];
        self.navigationBar.tintColor = [UIColor blackColor];
    }
}

- (void) setupNavigationBarButtons {
    // 左上角：断开连接按钮（红色）
    _disconnectButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Leave", nil)
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(disconnectButtonTapped:)];
    _disconnectButton.tintColor = [UIColor systemRedColor];
    
    // 右上角：模式切换按钮
    _modeSwitchButton = [[UIBarButtonItem alloc] initWithImage:nil
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(modeSwitchButtonTapped:)];
    if (@available(iOS 13.0, *)) {
        _modeSwitchButton.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
        _modeSwitchButton.tintColor = [UIColor labelColor];
    } else {
        _modeSwitchButton.title = @"Mode";
    }
}

- (void) setupNavigationBarSegmentedControl {
    // 创建分段控制器
    _segmentedControl = [[UISegmentedControl alloc] initWithItems:
                         [NSArray arrayWithObjects:
                            NSLocalizedString(@"Server", nil),
                            NSLocalizedString(@"Messages", nil),
                          nil]];
    
    _segmentIndex = 0;
    _segmentedControl.selectedSegmentIndex = _segmentIndex;
    [_segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    
    _numberBadgeView.value = _unreadMessages;
    _numberBadgeView.hidden = _unreadMessages == 0;
}

- (void) setupBottomControls {
    _bottomControlsView = [[UIView alloc] init];
    _bottomControlsView.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 设置透明背景
    _bottomControlsView.backgroundColor = [UIColor clearColor];
    
    // 创建静音按钮 - 使用系统样式
    _muteButton = [[UIBarButtonItem alloc] initWithImage:nil
                                                   style:UIBarButtonItemStylePlain
                                                  target:self
                                                  action:@selector(muteButtonTapped:)];
    if (@available(iOS 13.0, *)) {
        _muteButton.image = [UIImage systemImageNamed:@"mic.fill"];
    } else {
        _muteButton.title = @"Mic";
    }
    
    // 创建耳聋按钮 - 使用系统样式
    _deafenButton = [[UIBarButtonItem alloc] initWithImage:nil
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(deafenButtonTapped:)];
    if (@available(iOS 13.0, *)) {
        _deafenButton.image = [UIImage systemImageNamed:@"speaker.2.fill"];
    } else {
        _deafenButton.title = @"Speaker";
    }
    
    // 创建工具栏来容纳按钮
    UIToolbar *bottomToolbar = [[UIToolbar alloc] init];
    bottomToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    bottomToolbar.barStyle = UIBarStyleDefault;
    
    // 设置工具栏透明背景
    [bottomToolbar setBackgroundImage:[UIImage new] forToolbarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
    [bottomToolbar setShadowImage:[UIImage new] forToolbarPosition:UIBarPositionAny];
    bottomToolbar.backgroundColor = [UIColor clearColor];
    
    // 设置工具栏按钮
    UIBarButtonItem *flexibleSpace1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *flexibleSpace2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *flexibleSpace3 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    
    [bottomToolbar setItems:@[flexibleSpace1, _muteButton, flexibleSpace2, _deafenButton, flexibleSpace3] animated:NO];
    
    [_bottomControlsView addSubview:bottomToolbar];
    [self.view addSubview:_bottomControlsView];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        // 底部控制视图约束
        [_bottomControlsView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_bottomControlsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bottomControlsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_bottomControlsView.heightAnchor constraintEqualToConstant:60],
        
        // 工具栏约束
        [bottomToolbar.topAnchor constraintEqualToAnchor:_bottomControlsView.topAnchor],
        [bottomToolbar.leadingAnchor constraintEqualToAnchor:_bottomControlsView.leadingAnchor],
        [bottomToolbar.trailingAnchor constraintEqualToAnchor:_bottomControlsView.trailingAnchor],
        [bottomToolbar.bottomAnchor constraintEqualToAnchor:_bottomControlsView.bottomAnchor],
    ]];
}

- (void) updateNavigationBarForCurrentView {
    UIViewController *currentVC = [[self viewControllers] firstObject];
    
    // 先设置按钮
    currentVC.navigationItem.leftBarButtonItem = _disconnectButton;
    currentVC.navigationItem.rightBarButtonItem = _modeSwitchButton;
    
    // 然后设置标题视图
    UIView *titleView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 44)];
    titleView.backgroundColor = [UIColor clearColor];
    
    // 重新设置分段控制器的frame
    _segmentedControl.frame = CGRectMake(0, 6, 200, 32);
    
    // 确保分段控制器从之前的父视图中移除
    [_segmentedControl removeFromSuperview];
    [titleView addSubview:_segmentedControl];
    
    // 重新设置消息徽章位置
    _numberBadgeView.frame = CGRectMake(190, -4, 20, 20);
    [_numberBadgeView removeFromSuperview];
    [titleView addSubview:_numberBadgeView];
    
    currentVC.navigationItem.titleView = titleView;
    
    // 确保按钮可见且可交互
    _disconnectButton.enabled = YES;
    _modeSwitchButton.enabled = (currentVC == _serverView);
    
    // 调试信息 - 可以暂时添加来确认按钮存在
    NSLog(@"Left button: %@", currentVC.navigationItem.leftBarButtonItem);
    NSLog(@"Right button: %@", currentVC.navigationItem.rightBarButtonItem);
    NSLog(@"Title view: %@", currentVC.navigationItem.titleView);
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // 确保导航栏按钮正确设置
    [self updateNavigationBarForCurrentView];
    
    // 更新按钮状态
    [self updateMuteButtonStates];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // 再次确保导航栏按钮正确设置
    [self updateNavigationBarForCurrentView];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self setupNavigationBarAppearance];
            [self updateMuteButtonStates];
        }
    }
}

- (void) segmentChanged:(id)sender {
    if (_segmentedControl.selectedSegmentIndex == 0) { // Server view
        [self setViewControllers:[NSArray arrayWithObject:_serverView] animated:NO];
        // 显示底部控制按钮
        [self showBottomControls:YES];
    } else if (_segmentedControl.selectedSegmentIndex == 1) { // Messages view
        [self setViewControllers:[NSArray arrayWithObject:_messagesView] animated:NO];
        // 隐藏底部控制按钮，避免挡住消息输入框
        [self showBottomControls:NO];
    }
    
    // 重要：在切换视图后重新设置导航栏
    [self updateNavigationBarForCurrentView];
    
    if (_segmentedControl.selectedSegmentIndex == 1) { // Messages view
        _unreadMessages = 0;
        _numberBadgeView.value = 0;
        _numberBadgeView.hidden = YES;
        [[UIApplication sharedApplication] setApplicationIconBadgeNumber:0];
    } else if (_numberBadgeView.value > 0) {
        _numberBadgeView.hidden = NO;
    }

    [[MKAudio sharedAudio] setForceTransmit:NO];
}

- (void) showBottomControls:(BOOL)show {
    [UIView animateWithDuration:0.3 animations:^{
        self->_bottomControlsView.alpha = show ? 1.0 : 0.0;
        self->_bottomControlsView.hidden = !show;
    }];
}

- (void) updateMuteButtonStates {
    MKUser *connUser = [_model connectedUser];
    
    // 更新静音按钮状态和图标
    if (@available(iOS 13.0, *)) {
        if ([connUser isSelfMuted]) {
            _muteButton.image = [UIImage systemImageNamed:@"mic.slash.fill"];
            _muteButton.tintColor = [UIColor systemRedColor];
        } else {
            _muteButton.image = [UIImage systemImageNamed:@"mic.fill"];
            _muteButton.tintColor = [UIColor labelColor];
        }
    } else {
        // iOS 12 及以下版本的处理
        if ([connUser isSelfMuted]) {
            _muteButton.title = @"Unmute";
            _muteButton.tintColor = [UIColor redColor];
        } else {
            _muteButton.title = @"Mute";
            _muteButton.tintColor = [UIColor blackColor];
        }
    }
    
    // 更新耳聋按钮状态和图标
    if (@available(iOS 13.0, *)) {
        if ([connUser isSelfDeafened]) {
            _deafenButton.image = [UIImage systemImageNamed:@"speaker.slash.fill"];
            _deafenButton.tintColor = [UIColor systemOrangeColor];
        } else {
            _deafenButton.image = [UIImage systemImageNamed:@"speaker.2.fill"];
            _deafenButton.tintColor = [UIColor labelColor];
        }
    } else {
        // iOS 12 及以下版本的处理
        if ([connUser isSelfDeafened]) {
            _deafenButton.title = @"Undeafen";
            _deafenButton.tintColor = [UIColor orangeColor];
        } else {
            _deafenButton.title = @"Deafen";
            _deafenButton.tintColor = [UIColor blackColor];
        }
    }
}

- (BOOL) shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    // On iPad, we support all interface orientations.
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        return YES;
    }

    return interfaceOrientation == UIInterfaceOrientationPortrait;
}

#pragma mark - Button Actions

- (void) disconnectButtonTapped:(id)sender {
    UIAlertController *alertCtrl = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Disconnect", nil)
                                                                       message:NSLocalizedString(@"Are you sure you want to leave the server?", nil)
                                                                preferredStyle:UIAlertControllerStyleAlert];
    
    [alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                                   style:UIAlertActionStyleCancel
                                                 handler:nil]];
    
    [alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Leave", nil)
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction * _Nonnull action) {
        [[MUConnectionController sharedController] disconnectFromServer];
    }]];
    
    [self presentViewController:alertCtrl animated:YES completion:nil];
}

- (void) modeSwitchButtonTapped:(id)sender {
    [_serverView toggleMode];
}

- (void) muteButtonTapped:(id)sender {
    MKUser *connUser = [_model connectedUser];
    [_model setSelfMuted:![connUser isSelfMuted] andSelfDeafened:[connUser isSelfDeafened]];
    [self updateMuteButtonStates];
}

- (void) deafenButtonTapped:(id)sender {
    MKUser *connUser = [_model connectedUser];
    BOOL currentlyDeafened = [connUser isSelfDeafened];
    
    if (currentlyDeafened) {
        // 正在解除 deafen
        // 恢复到 deafen 前的静音状态
        [_model setSelfMuted:_wasMutedBeforeDeafen andSelfDeafened:NO];
    } else {
        // 正在启用 deafen
        // 记录当前的静音状态
        _wasMutedBeforeDeafen = [connUser isSelfMuted];
        // deafen 会自动静音
        [_model setSelfMuted:YES andSelfDeafened:YES];
    }
    
    [self updateMuteButtonStates];
}

#pragma mark - MKConnection delegate

- (void) connectionOpened:(MKConnection *)conn {
}

- (void) connection:(MKConnection *)conn rejectedWithReason:(MKRejectReason)reason explanation:(NSString *)explanation {
}

- (void) connection:(MKConnection *)conn trustFailureInCertificateChain:(NSArray *)chain {
}

- (void) connection:(MKConnection *)conn unableToConnectWithError:(NSError *)err {
}

- (void) connection:(MKConnection *)conn closedWithError:(NSError *)err {
    if (err) {
        UIAlertController *alertCtrl = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Connection closed", nil)
                                                                           message:[err localizedDescription]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
        [alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil]];
        
        [self presentViewController:alertCtrl animated:YES completion:nil];

        [[MUConnectionController sharedController] disconnectFromServer];
    }
}

#pragma mark - MKServerModel delegate

- (void) serverModel:(MKServerModel *)model userSelfMuteDeafenStateChanged:(MKUser *)user {
    [self updateMuteButtonStates];
}

- (void) serverModel:(MKServerModel *)model userKicked:(MKUser *)user byUser:(MKUser *)actor forReason:(NSString *)reason {
    if (user == [model connectedUser]) {
        NSString *reasonMsg = reason ? reason : NSLocalizedString(@"(No reason)", nil);
        NSString *title = NSLocalizedString(@"You were kicked", nil);
        NSString *alertMsg = [NSString stringWithFormat:
                                NSLocalizedString(@"Kicked by %@ for reason: \"%@\"", @"Kicked by user for reason"),
                                    [actor userName], reasonMsg];
        
        UIAlertController *alertCtrl = [UIAlertController alertControllerWithTitle:title
                                                                           message:alertMsg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
        [alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil]];
        
        [self presentViewController:alertCtrl animated:YES completion:nil];
        
        [[MUConnectionController sharedController] disconnectFromServer];
    }
}

- (void) serverModel:(MKServerModel *)model userBanned:(MKUser *)user byUser:(MKUser *)actor forReason:(NSString *)reason {
    if (user == [model connectedUser]) {
        NSString *reasonMsg = reason ? reason : NSLocalizedString(@"(No reason)", nil);
        NSString *title = NSLocalizedString(@"You were banned", nil);
        NSString *alertMsg = [NSString stringWithFormat:
                                NSLocalizedString(@"Banned by %@ for reason: \"%@\"", nil),
                                    [actor userName], reasonMsg];
        
        UIAlertController *alertCtrl = [UIAlertController alertControllerWithTitle:title
                                                                           message:alertMsg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
        [alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil]];
        
        [self presentViewController:alertCtrl animated:YES completion:nil];
        
        [[MUConnectionController sharedController] disconnectFromServer];
    }
}

- (void) serverModel:(MKServerModel *)model textMessageReceived:(MKTextMessage *)msg fromUser:(MKUser *)user {
    if (_segmentedControl.selectedSegmentIndex != 1) { // When not in messages view
        _unreadMessages++;
        _numberBadgeView.value = _unreadMessages;
        _numberBadgeView.hidden = NO;
    }
}

@end
