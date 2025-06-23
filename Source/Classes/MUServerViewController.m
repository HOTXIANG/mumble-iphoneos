// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUServerViewController.h"
#import "MUUserStateAcessoryView.h"
#import "MUNotificationController.h"
#import "MUColor.h"
#import "MUBackgroundView.h"
#import "MUServerTableViewCell.h"

#import <MumbleKit/MKAudio.h>

#pragma mark -
#pragma mark MUChannelNavigationItem

@interface MUChannelNavigationItem : NSObject {
    id _object;
    NSInteger _indentLevel;
}

+ (MUChannelNavigationItem *) navigationItemWithObject:(id)obj indentLevel:(NSInteger)indentLevel;
- (id) initWithObject:(id)obj indentLevel:(NSInteger)indentLevel;
- (id) object;
- (NSInteger) indentLevel;
@end

@implementation MUChannelNavigationItem

+ (MUChannelNavigationItem *) navigationItemWithObject:(id)obj indentLevel:(NSInteger)indentLevel {
    return [[MUChannelNavigationItem alloc] initWithObject:obj indentLevel:indentLevel];
}

- (id) initWithObject:(id)obj indentLevel:(NSInteger)indentLevel {
    if ((self = [super init])) {
        _object = obj;
        _indentLevel = indentLevel;
    }
    return self;
}

- (id) object {
    return _object;
}

- (NSInteger) indentLevel {
    return _indentLevel;
}

@end

#pragma mark -
#pragma mark MUServerViewController

@interface MUServerViewController () {
    MKServerModel               *_serverModel;
    MUServerViewControllerViewMode _viewMode;
    NSMutableArray              *_modelItems;
    NSMutableDictionary         *_userIndexMap;
    NSMutableDictionary         *_channelIndexMap;
    
    // PTT related
    UIButton                    *_talkButton;
    UIWindow                    *_talkWindow;
}
- (NSInteger) indexForUser:(MKUser *)user;
- (void) reloadUser:(MKUser *)user;
- (void) reloadChannel:(MKChannel *)channel;
- (void) rebuildModelArrayFromChannel:(MKChannel *)channel;
- (void) addChannelTreeToModel:(MKChannel *)channel indentLevel:(NSInteger)indentLevel;
@end

@implementation MUServerViewController

#pragma mark -
#pragma mark Initialization and lifecycle

- (id) initWithServerModel:(MKServerModel *)serverModel {
    // 使用现代化的 InsetGrouped 样式
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _serverModel = serverModel;
        [_serverModel addDelegate:self];
        _viewMode = MUServerViewControllerViewModeServer;
        
        // 初始化数组和字典
        _modelItems = [[NSMutableArray alloc] init];
        _userIndexMap = [[NSMutableDictionary alloc] init];
        _channelIndexMap = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void) dealloc {
    [_serverModel removeDelegate:self];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    
    // 确保数组和字典已初始化
    if (!_modelItems) {
        _modelItems = [[NSMutableArray alloc] init];
    }
    if (!_userIndexMap) {
        _userIndexMap = [[NSMutableDictionary alloc] init];
    }
    if (!_channelIndexMap) {
        _channelIndexMap = [[NSMutableDictionary alloc] init];
    }
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // 设置现代化背景色
    [self updateBackgroundColor];
    
    // 配置现代化的表格视图外观
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    
    // 设置分隔线样式
    if (@available(iOS 7, *)) {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        self.tableView.separatorInset = UIEdgeInsetsZero;
        if (@available(iOS 11.0, *)) {
            self.tableView.separatorInsetReference = UITableViewSeparatorInsetFromCellEdges;
        }
    }
    
    // 调整 table view 的内容边距
    if (@available(iOS 11.0, *)) {
        self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    
    // 设置内容边距 - 给底部麦克风控制留空间
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 80, 0);
    self.tableView.scrollIndicatorInsets = self.tableView.contentInset;
    
    // 确保数组和字典已初始化
    if (!_modelItems) {
        _modelItems = [[NSMutableArray alloc] init];
    }
    if (!_userIndexMap) {
        _userIndexMap = [[NSMutableDictionary alloc] init];
    }
    if (!_channelIndexMap) {
        _channelIndexMap = [[NSMutableDictionary alloc] init];
    }
    
    // 重建模型数据
    if (_viewMode == MUServerViewControllerViewModeServer) {
        [self rebuildModelArrayFromChannel:[_serverModel rootChannel]];
        [self.tableView reloadData];
        
        // 调试输出
        NSLog(@"Server view mode - Model items count: %lu", (unsigned long)[_modelItems count]);
        NSLog(@"Root channel: %@", [[_serverModel rootChannel] channelName]);
        
    } else if (_viewMode == MUServerViewControllerViewModeChannel) {
        [self switchToChannelMode];
        [self.tableView reloadData];
        
        // 调试输出
        NSLog(@"Channel view mode - Model items count: %lu", (unsigned long)[_modelItems count]);
    }
}

- (void) updateBackgroundColor {
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            self.view.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
            self.tableView.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
        } else {
            self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
            self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
        }
    } else {
        self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
        self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    }
}

// 添加主题变化监听
- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self updateBackgroundColor];
            [self.tableView reloadData];
        }
    }
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSInteger) indexForUser:(MKUser *)user {
    NSNumber *index = [_userIndexMap objectForKey:[NSNumber numberWithUnsignedInteger:[user session]]];
    if (index == nil)
        return NSNotFound;
    return [index integerValue];
}

- (NSInteger) indexForChannel:(MKChannel *)channel {
    NSNumber *index = [_channelIndexMap objectForKey:[NSNumber numberWithUnsignedInteger:[channel channelId]]];
    if (index == nil)
        return NSNotFound;
    return [index integerValue];
}

// 重写 reloadUser 方法以确保更新用户状态
- (void) reloadUser:(MKUser *)user {
    NSInteger userIndex = [self indexForUser:user];
    if (userIndex == NSNotFound) {
        return;
    }
    
    [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:userIndex inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
    
    // 如果是当前用户，同时更新频道高亮状态
    MKUser *connectedUser = [_serverModel connectedUser];
    if (user == connectedUser) {
        [self updateChannelHighlightStates];
    }
}

// 重写 reloadChannel 方法以确保更新频道状态
- (void) reloadChannel:(MKChannel *)channel {
    NSInteger idx = [self indexForChannel:channel];
    if (idx != NSNotFound) {
        [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:idx inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
    }
    
    // 同时更新所有频道的高亮状态
    [self updateChannelHighlightStates];
}

- (void) rebuildModelArrayFromChannel:(MKChannel *)channel {
    // 确保数组和字典存在
    if (!_modelItems) {
        _modelItems = [[NSMutableArray alloc] init];
    }
    if (!_userIndexMap) {
        _userIndexMap = [[NSMutableDictionary alloc] init];
    }
    if (!_channelIndexMap) {
        _channelIndexMap = [[NSMutableDictionary alloc] init];
    }
    
    [_modelItems removeAllObjects];
    [_userIndexMap removeAllObjects];
    [_channelIndexMap removeAllObjects];
    
    if (channel) {
        [self addChannelTreeToModel:channel indentLevel:0];
        NSLog(@"Rebuilt model array with %lu items for channel: %@", (unsigned long)[_modelItems count], [channel channelName]);
    } else {
        NSLog(@"Warning: Trying to rebuild model array with nil channel");
    }
}

- (void) switchToServerMode {
    _viewMode = MUServerViewControllerViewModeServer;
    [self rebuildModelArrayFromChannel:[_serverModel rootChannel]];
}

- (void) switchToChannelMode {
    _viewMode = MUServerViewControllerViewModeChannel;
    MKChannel *currentChannel = [[_serverModel connectedUser] channel];
    [self rebuildModelArrayFromChannel:currentChannel];
}

- (void) addChannelTreeToModel:(MKChannel *)channel indentLevel:(NSInteger)indentLevel {
    if (!channel) {
        NSLog(@"Warning: Trying to add nil channel to model");
        return;
    }
    
    // 添加频道
    [_channelIndexMap setObject:[NSNumber numberWithUnsignedInteger:[_modelItems count]] 
                         forKey:[NSNumber numberWithUnsignedInteger:[channel channelId]]];
    [_modelItems addObject:[MUChannelNavigationItem navigationItemWithObject:channel indentLevel:indentLevel]];
    
    NSLog(@"Added channel: %@ at index %lu with indent level %ld", 
          [channel channelName], (unsigned long)[_modelItems count]-1, (long)indentLevel);

    // 添加该频道中的用户
    NSArray *users = [channel users];
    for (MKUser *user in users) {
        [_userIndexMap setObject:[NSNumber numberWithUnsignedInteger:[_modelItems count]] 
                          forKey:[NSNumber numberWithUnsignedInteger:[user session]]];
        [_modelItems addObject:[MUChannelNavigationItem navigationItemWithObject:user indentLevel:indentLevel+1]];
        NSLog(@"Added user: %@ at index %lu with indent level %ld", 
              [user userName], (unsigned long)[_modelItems count]-1, (long)indentLevel+1);
    }
    
    // 递归添加子频道
    NSArray *subChannels = [channel channels];
    for (MKChannel *chan in subChannels) {
        [self addChannelTreeToModel:chan indentLevel:indentLevel+1];
    }
}

#pragma mark - Table view data source

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger count = [_modelItems count];
    NSLog(@"Table view requesting number of rows: %ld", (long)count);
    return count;
}

- (void) tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    MUChannelNavigationItem *navItem = [_modelItems objectAtIndex:[indexPath row]];
    id object = [navItem object];
    
    // 设置现代化的cell背景色
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            cell.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0];
        } else {
            cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        }
    } else {
        cell.backgroundColor = [UIColor whiteColor];
    }
    
    // 为验证的根频道设置特殊背景色
    if ([object class] == [MKChannel class]) {
        MKChannel *chan = object;
        if (chan == [_serverModel rootChannel] && [_serverModel serverCertificatesTrusted]) {
            if (@available(iOS 13.0, *)) {
                cell.backgroundColor = [UIColor systemGreenColor];
            } else {
                cell.backgroundColor = [MUColor verifiedCertificateChainColor];
            }
        }
    }
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"ChannelNavigationCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        if (@available(iOS 7, *)) {
            cell = [[MUServerTableViewCell alloc] initWithReuseIdentifier:CellIdentifier];
        } else {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
        }
    }

    // 检查索引是否有效
    if (indexPath.row >= [_modelItems count]) {
        NSLog(@"Warning: Index %ld is out of bounds for model items array (count: %lu)", 
              (long)indexPath.row, (unsigned long)[_modelItems count]);
        cell.textLabel.text = @"Error";
        return cell;
    }

    MUChannelNavigationItem *navItem = [_modelItems objectAtIndex:[indexPath row]];
    id object = [navItem object];

    MKUser *connectedUser = [_serverModel connectedUser];

    // 设置现代化字体
    cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    
    if ([object class] == [MKChannel class]) {
        MKChannel *chan = object;
        
        // 使用现代化的系统图标
        if (@available(iOS 13.0, *)) {
            UIImage *channelIcon = [UIImage systemImageNamed:@"number"];
            cell.imageView.image = [channelIcon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            cell.imageView.tintColor = [UIColor systemBlueColor];
        } else {
            cell.imageView.image = [UIImage imageNamed:@"channel"];
        }
        
        cell.textLabel.text = [chan channelName];
        
        // 重新获取当前用户和频道信息以确保是最新的
        MKUser *connectedUser = [_serverModel connectedUser];
        MKChannel *currentChannel = [connectedUser channel];
        
        // 设置文本颜色 - 比较频道ID而不是对象引用
        if (@available(iOS 13.0, *)) {
            if ([chan channelId] == [currentChannel channelId]) {
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
                
                // 添加调试信息
                NSLog(@"Current channel: %@ (ID: %lu)", [chan channelName], (unsigned long)[chan channelId]);
            } else {
                cell.textLabel.textColor = [UIColor labelColor];
                cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            }
        } else {
            if ([chan channelId] == [currentChannel channelId]) {
                cell.textLabel.textColor = [MUColor selectedTextColor];
            } else {
                cell.textLabel.textColor = [UIColor blackColor];
            }
        }
        
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryView = nil; // 清除频道的附加视图
        
    } else if ([object class] == [MKUser class]) {
        MKUser *user = object;
        
        cell.textLabel.text = [user userName];
        
        // 设置用户头像图标 - 始终使用头像，只在说话时变色
        MKTalkState talkState = [user talkState];
        UIColor *iconColor = [UIColor systemGrayColor]; // 默认灰色
        
        if (@available(iOS 13.0, *)) {
            // 始终使用头像图标
            UIImage *userIcon = [UIImage systemImageNamed:@"person.fill"];
            cell.imageView.image = [userIcon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            
            // 只在说话时改变头像颜色
            if (talkState == MKTalkStateTalking) {
                iconColor = [UIColor systemGreenColor]; // 说话时绿色头像
            } else if (talkState == MKTalkStateWhispering) {
                iconColor = [UIColor systemOrangeColor]; // 耳语时橙色头像
            } else if (talkState == MKTalkStateShouting) {
                iconColor = [UIColor systemRedColor]; // 大声说话时红色头像
            }
            
            cell.imageView.tintColor = iconColor;
            
        } else {
            // iOS 12 及以下版本 - 使用传统图标
            NSString *talkImageName = @"talking_off"; // 默认图标
            
            if (talkState == MKTalkStateTalking) {
                talkImageName = @"talking_on";
            } else if (talkState == MKTalkStateWhispering) {
                talkImageName = @"talking_whisper";
            } else if (talkState == MKTalkStateShouting) {
                talkImageName = @"talking_alt";
            }
            
            cell.imageView.image = [UIImage imageNamed:talkImageName];
        }
        
        // 创建状态指示器视图（在用户名右侧显示）
        UIView *statusView = [self createStatusViewForUser:user];
        cell.accessoryView = statusView;
        
        // 设置文本颜色
        if (@available(iOS 13.0, *)) {
            if (user == connectedUser) {
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            } else {
                cell.textLabel.textColor = [UIColor labelColor];
            }
        } else {
            if (user == connectedUser) {
                cell.textLabel.textColor = [MUColor selectedTextColor];
            } else {
                cell.textLabel.textColor = [UIColor blackColor];
            }
        }
        
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    cell.indentationLevel = [navItem indentLevel];
    cell.indentationWidth = 20.0;

    return cell;
}

// 新增方法：为用户创建状态指示器视图
- (UIView *) createStatusViewForUser:(MKUser *)user {
    NSMutableArray *statusIcons = [[NSMutableArray alloc] init];
    
    if (@available(iOS 13.0, *)) {
        // 检查各种状态并添加相应图标
        
        // 1. 自己静音 - 红色麦克风+斜线
        if ([user isSelfMuted]) {
            UIImageView *mutedIcon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"mic.slash.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            mutedIcon.tintColor = [UIColor systemRedColor];
            mutedIcon.frame = CGRectMake(0, 0, 16, 16);
            mutedIcon.contentMode = UIViewContentModeScaleAspectFit;
            [statusIcons addObject:mutedIcon];
        }
        
        // 2. 被强制静音 - 黄色麦克风+斜线
        else if ([user isMuted]) {
            UIImageView *forceMutedIcon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"mic.slash.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            forceMutedIcon.tintColor = [UIColor systemYellowColor];
            forceMutedIcon.frame = CGRectMake(0, 0, 16, 16);
            forceMutedIcon.contentMode = UIViewContentModeScaleAspectFit;
            [statusIcons addObject:forceMutedIcon];
        }
        
        // 3. 自己耳聋 - 红色扬声器+斜线 和 红色麦克风+斜线
        if ([user isSelfDeafened]) {
            // 扬声器+斜线
            UIImageView *deafenedIcon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"speaker.slash.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            deafenedIcon.tintColor = [UIColor systemRedColor];
            deafenedIcon.frame = CGRectMake(0, 0, 16, 16);
            deafenedIcon.contentMode = UIViewContentModeScaleAspectFit;
            [statusIcons addObject:deafenedIcon];
            
            // 如果没有自己静音的图标，添加麦克风+斜线（因为耳聋包含静音）
            BOOL hasMutedIcon = NO;
            for (UIView *view in statusIcons) {
                if ([view isKindOfClass:[UIImageView class]]) {
                    UIImageView *imgView = (UIImageView *)view;
                    if ([imgView.image isEqual:[[UIImage systemImageNamed:@"mic.slash.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]]) {
                        hasMutedIcon = YES;
                        break;
                    }
                }
            }
            
            if (!hasMutedIcon) {
                UIImageView *mutedIcon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"mic.slash.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
                mutedIcon.tintColor = [UIColor systemRedColor];
                mutedIcon.frame = CGRectMake(0, 0, 16, 16);
                mutedIcon.contentMode = UIViewContentModeScaleAspectFit;
                [statusIcons addObject:mutedIcon];
            }
        }
        
        // 4. 被强制耳聋 - 黄色扬声器+斜线
        else if ([user isDeafened]) {
            UIImageView *forceDeafenedIcon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"speaker.slash.fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            forceDeafenedIcon.tintColor = [UIColor systemYellowColor];
            forceDeafenedIcon.frame = CGRectMake(0, 0, 16, 16);
            forceDeafenedIcon.contentMode = UIViewContentModeScaleAspectFit;
            [statusIcons addObject:forceDeafenedIcon];
        }
    }
    
    // 如果没有状态图标，返回nil
    if ([statusIcons count] == 0) {
        return nil;
    }
    
    // 创建容器视图来放置所有状态图标
    CGFloat iconSpacing = 4.0; // 图标之间的间距
    CGFloat iconSize = 16.0;
    CGFloat totalWidth = iconSize * [statusIcons count] + iconSpacing * ([statusIcons count] - 1);
    
    UIView *containerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, totalWidth, iconSize)];
    
    for (NSInteger i = 0; i < [statusIcons count]; i++) {
        UIImageView *iconView = [statusIcons objectAtIndex:i];
        CGFloat xPosition = i * (iconSize + iconSpacing);
        iconView.frame = CGRectMake(xPosition, 0, iconSize, iconSize);
        [containerView addSubview:iconView];
    }
    
    return containerView;
}

#pragma mark - Table view delegate

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    MUChannelNavigationItem *navItem = [_modelItems objectAtIndex:[indexPath row]];
    id object = [navItem object];
    if ([object class] == [MKChannel class]) {
        MKChannel *targetChannel = object;
        
        // 记录切换前的频道
        MKUser *connectedUser = [_serverModel connectedUser];
        MKChannel *previousChannel = [connectedUser channel];
        
        NSLog(@"Attempting to join channel: %@ (ID: %lu)", [targetChannel channelName], (unsigned long)[targetChannel channelId]);
        NSLog(@"Current channel: %@ (ID: %lu)", [previousChannel channelName], (unsigned long)[previousChannel channelId]);
        
        // 执行频道切换
        [_serverModel joinChannel:targetChannel];
        
        // 立即更新界面
        [self delayedUpdateAfterChannelChange];
        
        // 添加轻微的触觉反馈
        if (@available(iOS 10.0, *)) {
            UIImpactFeedbackGenerator *feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedbackGenerator impactOccurred];
        }
    }
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 50.0f; // 稍微增加行高以获得更好的现代外观
}

// 添加 section 间距
- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 10.0;
}

- (CGFloat) tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 10.0;
}

- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init]; // 透明的头部视图
}

- (UIView *) tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [[UIView alloc] init]; // 透明的脚部视图
}

#pragma mark - MKServerModel delegate

- (void) serverModel:(MKServerModel *)model joinedServerAsUser:(MKUser *)user {
    [self rebuildModelArrayFromChannel:[model rootChannel]];
    [self.tableView reloadData];
}

- (void) serverModel:(MKServerModel *)model userJoined:(MKUser *)user {
}

- (void) serverModel:(MKServerModel *)model userDisconnected:(MKUser *)user {
}

- (void) serverModel:(MKServerModel *)model userLeft:(MKUser *)user {
    NSInteger idx = [self indexForUser:user];
    if (idx != NSNotFound) {
        if (_viewMode == MUServerViewControllerViewModeServer) {
            [self rebuildModelArrayFromChannel:[model rootChannel]];
        } else if (_viewMode) {
            [self switchToChannelMode];
        }
        [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:idx inSection:0]] withRowAnimation:UITableViewRowAnimationFade];
    }
}

- (void) serverModel:(MKServerModel *)model userTalkStateChanged:(MKUser *)user {
    NSInteger userIndex = [self indexForUser:user];
    if (userIndex == NSNotFound) {
        return;
    }

    UITableViewCell *cell = [[self tableView] cellForRowAtIndexPath:[NSIndexPath indexPathForRow:userIndex inSection:0]];

    MKTalkState talkState = [user talkState];
    
    if (@available(iOS 13.0, *)) {
        // 更新头像颜色（只根据说话状态）
        UIColor *iconColor = [UIColor systemGrayColor]; // 默认灰色
        
        if (talkState == MKTalkStateTalking) {
            iconColor = [UIColor systemGreenColor]; // 说话时绿色头像
        } else if (talkState == MKTalkStateWhispering) {
            iconColor = [UIColor systemOrangeColor]; // 耳语时橙色头像
        } else if (talkState == MKTalkStateShouting) {
            iconColor = [UIColor systemRedColor]; // 大声说话时红色头像
        }
        
        UIImage *userIcon = [UIImage systemImageNamed:@"person.fill"];
        cell.imageView.image = [userIcon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        cell.imageView.tintColor = iconColor;
        
        // 更新状态指示器
        cell.accessoryView = [self createStatusViewForUser:user];
        
    } else {
        // iOS 12 及以下版本
        NSString *talkImageName = @"talking_off";
        
        if (talkState == MKTalkStateTalking) {
            talkImageName = @"talking_on";
        } else if (talkState == MKTalkStateWhispering) {
            talkImageName = @"talking_whisper";
        } else if (talkState == MKTalkStateShouting) {
            talkImageName = @"talking_alt";
        }

        cell.imageView.image = [UIImage imageNamed:talkImageName];
    }
}

// 添加新的委托方法来处理静音状态变化
- (void) serverModel:(MKServerModel *)model userSelfMuteDeafenStateChanged:(MKUser *)user {
    [self reloadUser:user];
}

- (void) serverModel:(MKServerModel *)model userMuteStateChanged:(MKUser *)user {
    [self reloadUser:user];
}

// 修改 serverModel:userMoved:toChannel:fromChannel:byUser: 方法

- (void) serverModel:(MKServerModel *)model userMoved:(MKUser *)user toChannel:(MKChannel *)chan fromChannel:(MKChannel *)prevChan byUser:(MKUser *)mover {
    
    if (_viewMode == MUServerViewControllerViewModeServer) {
        [self.tableView beginUpdates];
        
        // 如果是当前用户移动，需要更新频道的高亮状态
        if (user == [model connectedUser]) {
            // 更新之前的频道显示
            if (prevChan != nil) {
                [self reloadChannel:prevChan];
            }
            // 更新新的频道显示
            [self reloadChannel:chan];
        }
    
        // 检查用户是否是第一次加入频道
        if (prevChan != nil) {
            NSInteger prevIdx = [self indexForUser:user];
            if (prevIdx != NSNotFound) {
                [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:prevIdx inSection:0]] withRowAnimation:UITableViewRowAnimationFade];
            }
        }

        // 重建模型数组
        [self rebuildModelArrayFromChannel:[model rootChannel]];
        
        // 插入用户到新位置
        NSInteger newIdx = [self indexForUser:user];
        if (newIdx != NSNotFound) {
            [self.tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:newIdx inSection:0]] withRowAnimation:UITableViewRowAnimationFade];
        }
        
        [self.tableView endUpdates];
        
        // 如果是当前用户移动，滚动到新位置
        if (user == [model connectedUser]) {
            NSInteger channelIdx = [self indexForChannel:chan];
            if (channelIdx != NSNotFound) {
                [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:channelIdx inSection:0] 
                                     atScrollPosition:UITableViewScrollPositionMiddle 
                                             animated:YES];
            }
        }
        
    } else if (_viewMode == MUServerViewControllerViewModeChannel) {
        NSInteger userIdx = [self indexForUser:user];
        MKChannel *curChan = [[_serverModel connectedUser] channel];
        
        if (user == [model connectedUser]) {
            // 当前用户切换频道，重新加载整个频道视图
            [self switchToChannelMode];
            [self.tableView reloadData];
        } else {
            // 其他用户移动
            if ([chan channelId] == [curChan channelId]) {
                // 用户移动到当前频道
                [self rebuildModelArrayFromChannel:curChan];
                NSInteger newIdx = [self indexForUser:user];
                if (newIdx != NSNotFound) {
                    [self.tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:newIdx inSection:0]] withRowAnimation:UITableViewRowAnimationFade];
                }
            } else if ([prevChan channelId] == [curChan channelId]) {
                // 用户从当前频道移出
                if (userIdx != NSNotFound) {
                    [self rebuildModelArrayFromChannel:curChan];
                    [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:userIdx inSection:0]] withRowAnimation:UITableViewRowAnimationFade];
                }
            }
        }
    }
}

// 添加一个新的方法来更新频道的显示状态
- (void) updateChannelHighlightStates {
    MKUser *connectedUser = [_serverModel connectedUser];
    MKChannel *currentChannel = [connectedUser channel];
    
    // 遍历所有可见的cell，更新频道的高亮状态
    NSArray *visibleIndexPaths = [self.tableView indexPathsForVisibleRows];
    for (NSIndexPath *indexPath in visibleIndexPaths) {
        if (indexPath.row < [_modelItems count]) {
            MUChannelNavigationItem *navItem = [_modelItems objectAtIndex:indexPath.row];
            id object = [navItem object];
            
            if ([object class] == [MKChannel class]) {
                MKChannel *channel = object;
                UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
                
                // 更新频道的文本颜色和字体
                if (@available(iOS 13.0, *)) {
                    if (channel == currentChannel) {
                        cell.textLabel.textColor = [UIColor systemBlueColor];
                        cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
                    } else {
                        cell.textLabel.textColor = [UIColor labelColor];
                        cell.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
                    }
                } else {
                    if (channel == currentChannel) {
                        cell.textLabel.textColor = [MUColor selectedTextColor];
                    } else {
                        cell.textLabel.textColor = [UIColor blackColor];
                    }
                }
            }
        }
    }
}

// 添加一个延迟更新方法，确保界面完全更新
- (void) delayedUpdateAfterChannelChange {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateChannelHighlightStates];
        [self.tableView reloadData];
    });
}
@end