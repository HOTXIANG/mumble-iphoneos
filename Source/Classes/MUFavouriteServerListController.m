// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUFavouriteServerListController.h"

#import "MUDatabase.h"
#import "MUFavouriteServer.h"
#import "MUFavouriteServerEditViewController.h"
#import "MUTableViewHeaderLabel.h"
#import "MUConnectionController.h"
#import "MUServerCell.h"
#import "MUBackgroundView.h"

@interface MUFavouriteServerListController () {
    NSMutableArray     *_favouriteServers;
    BOOL               _editMode;
    MUFavouriteServer  *_editedServer;
}
- (void) reloadFavourites;
- (void) deleteFavouriteAtIndexPath:(NSIndexPath *)indexPath;
- (void) connectToFavouriteServer:(MUFavouriteServer *)favServ;
@end

@implementation MUFavouriteServerListController

#pragma mark -
#pragma mark Initialization

- (id) init {
    // 使用现代的 UITableViewStyleInsetGrouped 样式
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        // ...
    }
    
    return self;
}

- (void) dealloc {
    [MUDatabase storeFavourites:_favouriteServers];
}

- (BOOL) shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
    // On iPad, we support all interface orientations.
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        return YES;
    }
    
    return toInterfaceOrientation == UIInterfaceOrientationPortrait;
}

- (void) updateBackgroundColor {
    if (@available(iOS 13.0, *)) {
        // 深色模式使用深灰色，浅色模式使用系统默认
        UIColor *backgroundColor = [UIColor systemGroupedBackgroundColor];
        
        // 如果是深色模式，使用自定义的深灰色
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]; // 深灰色 #1C1C1E
        }
        
        self.view.backgroundColor = backgroundColor;
        self.tableView.backgroundColor = backgroundColor;
    } else {
        self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
        self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    }
}

// 正确的方式来监听主题变化
- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self updateBackgroundColor];
        }
    }
}

- (void) viewDidLoad {
    [super viewDidLoad];
    
    // 配置现代化的表格视图外观
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    
    // 设置表格视图样式以支持圆角
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone; // 去除分隔线以突出圆角效果
    
    // 设置背景色 - 与欢迎界面一致
    [self updateBackgroundColor];
    
    // 设置空状态视图
    [self setupEmptyStateView];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    self.navigationItem.title = NSLocalizedString(@"Favourite Servers", nil);
    
    // 现代化导航栏样式 - 禁用大标题保持一致性
    if (@available(iOS 13.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles = NO;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }
    
    // 更新背景色 - 与欢迎界面一致
    [self updateBackgroundColor];
    
    // 添加按钮
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addButtonClicked:)];
    self.navigationItem.rightBarButtonItem = addButton;

    [self reloadFavourites];
    [self updateEmptyStateVisibility];
}

- (void) setupEmptyStateView {
    UIView *emptyView = [[UIView alloc] init];
    
    UIImageView *imageView = [[UIImageView alloc] init];
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:@"star.circle"];
        imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        imageView.tintColor = [UIColor systemGrayColor];
    } else {
        imageView.image = [UIImage imageNamed:@"star"];
        imageView.tintColor = [UIColor grayColor];
    }
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = NSLocalizedString(@"No Favourite Servers", nil);
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    if (@available(iOS 13.0, *)) {
        titleLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        titleLabel.textColor = [UIColor grayColor];
    }
    titleLabel.textAlignment = NSTextAlignmentCenter;
    
    UILabel *messageLabel = [[UILabel alloc] init];
    messageLabel.text = NSLocalizedString(@"Tap the + button to add your first favourite server", nil);
    messageLabel.font = [UIFont systemFontOfSize:16];
    if (@available(iOS 13.0, *)) {
        messageLabel.textColor = [UIColor tertiaryLabelColor];
    } else {
        messageLabel.textColor = [UIColor lightGrayColor];
    }
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    
    [emptyView addSubview:imageView];
    [emptyView addSubview:titleLabel];
    [emptyView addSubview:messageLabel];
    
    // 使用 Auto Layout
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    
    [NSLayoutConstraint activateConstraints:@[
        [imageView.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
        [imageView.centerYAnchor constraintEqualToAnchor:emptyView.centerYAnchor constant:-60],
        [imageView.widthAnchor constraintEqualToConstant:80],
        [imageView.heightAnchor constraintEqualToConstant:80],
        
        [titleLabel.topAnchor constraintEqualToAnchor:imageView.bottomAnchor constant:20],
        [titleLabel.leadingAnchor constraintEqualToAnchor:emptyView.leadingAnchor constant:20],
        [titleLabel.trailingAnchor constraintEqualToAnchor:emptyView.trailingAnchor constant:-20],
        
        [messageLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
        [messageLabel.leadingAnchor constraintEqualToAnchor:emptyView.leadingAnchor constant:20],
        [messageLabel.trailingAnchor constraintEqualToAnchor:emptyView.trailingAnchor constant:-20]
    ]];
    
    self.tableView.backgroundView = emptyView;
}

- (void) updateEmptyStateVisibility {
    self.tableView.backgroundView.hidden = [_favouriteServers count] > 0;
    self.tableView.separatorStyle = [_favouriteServers count] > 0 ? UITableViewCellSeparatorStyleSingleLine : UITableViewCellSeparatorStyleNone;
}

- (void) reloadFavourites {
    _favouriteServers = [MUDatabase fetchAllFavourites];
    [_favouriteServers sortUsingSelector:@selector(compare:)];
    [self.tableView reloadData];
}

#pragma mark -
#pragma mark Table view data source

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_favouriteServers count];
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MUFavouriteServer *favServ = [_favouriteServers objectAtIndex:[indexPath row]];
    MUServerCell *cell = (MUServerCell *)[tableView dequeueReusableCellWithIdentifier:[MUServerCell reuseIdentifier]];
    if (cell == nil) {
        cell = [[MUServerCell alloc] init];
    }
    [cell populateFromFavouriteServer:favServ];
    
    // 现代化的选择样式
    if (@available(iOS 13.0, *)) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone; // 禁用默认选择样式以保持圆角
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
    }
    
    // 添加长按手势识别器
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.5;
    [cell addGestureRecognizer:longPress];
    
    return (UITableViewCell *) cell;
}

- (BOOL) tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

// 配置左滑删除按钮
- (UISwipeActionsConfiguration *) tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:NSLocalizedString(@"Delete", nil)
                                                                             handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        [self showDeleteConfirmationForIndexPath:indexPath completion:completionHandler];
    }];
    
    if (@available(iOS 13.0, *)) {
        deleteAction.image = [UIImage systemImageNamed:@"trash"];
    }
    
    UIContextualAction *editAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                             title:NSLocalizedString(@"Edit", nil)
                                                                           handler:^(UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        MUFavouriteServer *favServ = [self->_favouriteServers objectAtIndex:indexPath.row];
        [self presentEditDialogForFavourite:favServ];
        completionHandler(YES);
    }];
    
    editAction.backgroundColor = [UIColor systemBlueColor];
    if (@available(iOS 13.0, *)) {
        editAction.image = [UIImage systemImageNamed:@"pencil"];
    }
    
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, editAction]];
    
    // 设置为不会完全显示操作，保持部分圆角效果
    configuration.performsFirstActionWithFullSwipe = NO;
    
    return configuration;
}

// 兼容 iOS 10 及以下版本的删除方法
- (void) tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        if (@available(iOS 11.0, *)) {
            // iOS 11+ 使用滑动操作
            return;
        } else {
            // iOS 10 及以下使用传统删除确认
            [self showDeleteConfirmationForIndexPath:indexPath completion:nil];
        }
    }
}

- (void) showDeleteConfirmationForIndexPath:(NSIndexPath *)indexPath completion:(void (^)(BOOL))completion {
    NSString *title = NSLocalizedString(@"Delete Favourite", nil);
    NSString *msg = NSLocalizedString(@"Are you sure you want to delete this favourite server?", nil);
    
    UIAlertController* alertCtrl = [UIAlertController alertControllerWithTitle:title
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
    
    [alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                                   style:UIAlertActionStyleCancel
                                                 handler:^(UIAlertAction * _Nonnull action) {
        if (completion) completion(NO);
    }]];
    
    [alertCtrl addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Delete", nil)
                                                   style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction * _Nonnull action) {
        [self deleteFavouriteAtIndexPath:indexPath];
        if (completion) completion(YES);
    }]];
    
    [self presentViewController:alertCtrl animated:YES completion:nil];
}

#pragma mark -
#pragma mark Table view delegate

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    // 自定义选择动画
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    
    // 添加轻微的缩放动画效果
    [UIView animateWithDuration:0.1 animations:^{
        cell.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            cell.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            // 直接连接到服务器
            MUFavouriteServer *favServ = [self->_favouriteServers objectAtIndex:[indexPath row]];
            [self connectToFavouriteServer:favServ];
        }];
    }];
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 70.0; // 增加行高以容纳圆角设计
}

// 添加 section 间距
- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 10.0; // 添加顶部间距
}

- (CGFloat) tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 10.0; // 添加底部间距
}

- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [[UIView alloc] init]; // 透明的头部视图
}

- (UIView *) tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [[UIView alloc] init]; // 透明的脚部视图
}

#pragma mark -
#pragma mark Gesture recognizers

- (void) handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint point = [gestureRecognizer locationInView:self.tableView];
        NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
        
        if (indexPath) {
            MUFavouriteServer *favServ = [_favouriteServers objectAtIndex:indexPath.row];
            [self presentEditDialogForFavourite:favServ];
            
            // 提供触觉反馈
            if (@available(iOS 10.0, *)) {
                UIImpactFeedbackGenerator *feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [feedbackGenerator impactOccurred];
            }
        }
    }
}

#pragma mark -
#pragma mark Server connection

- (void) connectToFavouriteServer:(MUFavouriteServer *)favServ {
    NSString *userName = [favServ userName];
    if (userName == nil || [userName length] == 0) {
        userName = [[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultUserName"];
    }
    
    MUConnectionController *connCtrlr = [MUConnectionController sharedController];
    [connCtrlr connetToHostname:[favServ hostName]
                           port:[favServ port]
                       withUsername:userName
                    andPassword:[favServ password]
       withParentViewController:self];
}

- (void) deleteFavouriteAtIndexPath:(NSIndexPath *)indexPath {
    // Drop it from the database
    MUFavouriteServer *favServ = [_favouriteServers objectAtIndex:[indexPath row]];
    [MUDatabase deleteFavourite:favServ];
    
    // And remove it from our locally sorted array
    [_favouriteServers removeObjectAtIndex:[indexPath row]];
    [self.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
    
    [self updateEmptyStateVisibility];
}

#pragma mark -
#pragma Modal edit dialog

- (void) presentNewFavouriteDialog {
    UINavigationController *modalNav = [[UINavigationController alloc] init];
    
    MUFavouriteServerEditViewController *editView = [[MUFavouriteServerEditViewController alloc] init];
    
    _editMode = NO;
    _editedServer = nil;
    
    [editView setTarget:self];
    [editView setDoneAction:@selector(doneButtonClicked:)];
    [modalNav pushViewController:editView animated:NO];
    
    if (@available(iOS 13.0, *)) {
        modalNav.modalPresentationStyle = UIModalPresentationFormSheet;
    } else {
        modalNav.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    
    [self presentViewController:modalNav animated:YES completion:nil];
}

- (void) presentEditDialogForFavourite:(MUFavouriteServer *)favServ {
    UINavigationController *modalNav = [[UINavigationController alloc] init];
    
    MUFavouriteServerEditViewController *editView = [[MUFavouriteServerEditViewController alloc] initInEditMode:YES withContentOfFavouriteServer:favServ];
    
    _editMode = YES;
    _editedServer = favServ;
    
    [editView setTarget:self];
    [editView setDoneAction:@selector(doneButtonClicked:)];
    [modalNav pushViewController:editView animated:NO];
    
    if (@available(iOS 13.0, *)) {
        modalNav.modalPresentationStyle = UIModalPresentationFormSheet;
    } else {
        modalNav.modalPresentationStyle = UIModalPresentationFormSheet;
    }
    
    [self presentViewController:modalNav animated:YES completion:nil];
}

#pragma mark -
#pragma mark Add button target

//
// Action for someone clicking the '+' button on the Favourite Server listing.
//
- (void) addButtonClicked:(id)sender {
    [self presentNewFavouriteDialog];
}

#pragma mark -
#pragma mark Done button target (from Edit View)

// Called when someone clicks 'Done' in a FavouriteServerEditViewController.
- (void) doneButtonClicked:(id)sender {
    MUFavouriteServerEditViewController *editView = sender;
    MUFavouriteServer *newServer = [editView copyFavouriteFromContent];
    [MUDatabase storeFavourite:newServer];

    [self reloadFavourites];
    [self updateEmptyStateVisibility];
}

@end
