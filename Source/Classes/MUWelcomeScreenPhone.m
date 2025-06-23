// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUWelcomeScreenPhone.h"

#import "MUPublicServerListController.h"
#import "MUFavouriteServerListController.h"
#import "MULanServerListController.h"
#import "MUPreferencesViewController.h"
#import "MUServerRootViewController.h"
#import "MUNotificationController.h"
#import "MULegalViewController.h"
#import "MUImage.h"
#import "MUBackgroundView.h"

@interface MUWelcomeScreenPhone () {
    NSInteger    _aboutWebsiteButton;
    NSInteger    _aboutContribButton;
    NSInteger    _aboutLegalButton;
}
@end

#define MUMBLE_LAUNCH_IMAGE_CREATION 0

@implementation MUWelcomeScreenPhone

- (id) init {
    // 使用 InsetGrouped 样式以获得现代化的卡片式外观
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        // ...existing code...
    }
    return self;
}

- (void) viewDidLoad {
    [super viewDidLoad];
    
    // 设置背景色 - 深色模式使用深灰色而不是纯黑色
    [self updateBackgroundColor];
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
            [self updateNavigationBarAppearance];
        }
    }
}

- (void) updateNavigationBarAppearance {
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithDefaultBackground];
        
        // 根据当前主题设置导航栏背景色
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            appearance.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
        } else {
            appearance.backgroundColor = [UIColor systemGroupedBackgroundColor];
        }
        
        // 移除阴影以获得无缝外观
        appearance.shadowColor = nil;

        self.navigationController.navigationBar.standardAppearance = appearance;
        self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
        if (@available(iOS 15.0, *)) {
            self.navigationController.navigationBar.compactScrollEdgeAppearance = appearance;
        }
    }
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    self.navigationItem.title = @"Mumble";
    self.navigationController.toolbarHidden = YES;
    
    // 更新背景色
    [self updateBackgroundColor];

    // 配置导航栏外观 - 禁用大标题以减少额头空间
    [self updateNavigationBarAppearance];
    
    if (@available(iOS 13.0, *)) {
        // 禁用大标题以减少额头空间
        self.navigationController.navigationBar.prefersLargeTitles = NO;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    }

    // 启用滚动
    self.tableView.scrollEnabled = YES;
    self.tableView.showsVerticalScrollIndicator = NO;
    
    // 设置导航栏为紧凑模式
    if (@available(iOS 11.0, *)) {
        self.navigationController.navigationBar.prefersLargeTitles = NO;
    }
    
#if MUMBLE_LAUNCH_IMAGE_CREATION != 1
    UIBarButtonItem *about = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"About", nil)
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(aboutClicked:)];
    [self.navigationItem setRightBarButtonItem:about];
    
    UIBarButtonItem *prefs = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Preferences", nil)
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(prefsClicked:)];
    [self.navigationItem setLeftBarButtonItem:prefs];
#endif
}

#pragma mark -
#pragma mark TableView

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 2; // 一个用于logo，一个用于菜单项
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
#if MUMBLE_LAUNCH_IMAGE_CREATION == 1
    return 1;
#endif
    if (section == 0)
        return 0; // Logo section 没有行
    if (section == 1)
        return 3; // 菜单项
    return 0;
}

- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        // 创建一个紧凑的 Logo 头部
        UIView *headerContainer = [[UIView alloc] init];
        
        // 设置 header 背景色与整体背景一致
        if (@available(iOS 13.0, *)) {
            if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                headerContainer.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
            } else {
                headerContainer.backgroundColor = [UIColor systemGroupedBackgroundColor];
            }
        } else {
            headerContainer.backgroundColor = [UIColor groupTableViewBackgroundColor];
        }
        
        UIImage *logoImage = [UIImage imageNamed:@"WelcomeScreenIcon"];
        UIImageView *logoImageView = [[UIImageView alloc] initWithImage:logoImage];
        logoImageView.contentMode = UIViewContentModeScaleAspectFit;
        logoImageView.translatesAutoresizingMaskIntoConstraints = NO;
        
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = @"Welcome to Mumble";
        titleLabel.font = [UIFont boldSystemFontOfSize:22];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.numberOfLines = 1;
        if (@available(iOS 13.0, *)) {
            titleLabel.textColor = [UIColor labelColor];
        }

        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = @"Low latency, high quality voice chat";
        subtitleLabel.font = [UIFont systemFontOfSize:15];
        if (@available(iOS 13.0, *)) {
            subtitleLabel.textColor = [UIColor secondaryLabelColor];
        } else {
            subtitleLabel.textColor = [UIColor grayColor];
        }
        subtitleLabel.textAlignment = NSTextAlignmentCenter;
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        subtitleLabel.numberOfLines = 2;
        subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;

        [headerContainer addSubview:logoImageView];
        [headerContainer addSubview:titleLabel];
        [headerContainer addSubview:subtitleLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            // Logo 约束 - 减小顶部间距
            [logoImageView.topAnchor constraintEqualToAnchor:headerContainer.topAnchor constant:20],
            [logoImageView.centerXAnchor constraintEqualToAnchor:headerContainer.centerXAnchor],
            [logoImageView.heightAnchor constraintEqualToConstant:50], // 进一步减小 logo 尺寸
            [logoImageView.widthAnchor constraintEqualToConstant:50],

            // 标题约束 - 减小间距
            [titleLabel.topAnchor constraintEqualToAnchor:logoImageView.bottomAnchor constant:12],
            [titleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor constant:16],
            [titleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor constant:-16],

            // 副标题约束 - 增加间距和底部空间
            [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6],
            [subtitleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.leadingAnchor constant:16],
            [subtitleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.trailingAnchor constant:-16],
            [subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:headerContainer.bottomAnchor constant:-20] // 确保有足够的底部空间
        ]];
        
        return headerContainer;
    }
    return nil;
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return 160; // 增加头部高度以容纳副标题
    }
    return UITableViewAutomaticDimension;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) {
        return NSLocalizedString(@"Connect to Server", nil);
    }
    return nil;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 50.0; // 稍微增加行高以获得更好的触摸体验
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"welcomeItem"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"welcomeItem"];
    }
    
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    
    // 设置 cell 背景色以创建层次感
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            // 深色模式：使用比背景更亮的颜色
            cell.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0]; // #2C2C2E
        } else {
            // 浅色模式：使用标准的次级背景色
            cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        }
    } else {
        cell.backgroundColor = [UIColor whiteColor];
    }
    
    NSString *text = @"";
    NSString *symbolName = @"";
    
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            text = NSLocalizedString(@"Public Servers", nil);
            symbolName = @"globe";
        } else if (indexPath.row == 1) {
            text = NSLocalizedString(@"Favourite Servers", nil);
            symbolName = @"star.fill";
        } else if (indexPath.row == 2) {
            text = NSLocalizedString(@"LAN Servers", nil);
            symbolName = @"wifi";
        }
    }

    if (@available(iOS 14.0, *)) {
        UIListContentConfiguration *content = [cell defaultContentConfiguration];
        content.text = text;
        content.textProperties.font = [UIFont systemFontOfSize:17];
        if (@available(iOS 13.0, *)) {
            UIImage *image = [UIImage systemImageNamed:symbolName];
            content.image = [image imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium]];
            content.imageProperties.tintColor = [UIColor systemBlueColor];
        }
        cell.contentConfiguration = content;
    } else {
        // Fallback on earlier versions
        cell.textLabel.text = text;
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        if (@available(iOS 13.0, *)) {
            UIImage *image = [UIImage systemImageNamed:symbolName];
            cell.imageView.image = image;
            cell.imageView.tintColor = [UIColor systemBlueColor];
        }
    }

    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    /* Servers section. */
    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            MUPublicServerListController *serverList = [[MUPublicServerListController alloc] init];
            [self.navigationController pushViewController:serverList animated:YES];
        } else if (indexPath.row == 1) {
            MUFavouriteServerListController *favList = [[MUFavouriteServerListController alloc] init];
            [self.navigationController pushViewController:favList animated:YES];
        } else if (indexPath.row == 2) {
            MULanServerListController *lanList = [[MULanServerListController alloc] init];
            [self.navigationController pushViewController:lanList animated:YES];
        }
    }
    // Deselect row for a cleaner transition
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void) aboutClicked:(id)sender {
#ifdef MUMBLE_BETA_DIST
    NSString *aboutTitle = [NSString stringWithFormat:@"Mumble %@ (%@)",
                            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"],
                            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MumbleGitRevision"]];
#else
    NSString *aboutTitle = [NSString stringWithFormat:@"Mumble %@",
                            [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]];
#endif
    NSString *aboutMessage = NSLocalizedString(@"Low latency, high quality voice chat", nil);
    
    UIAlertController* aboutAlert = [UIAlertController alertControllerWithTitle:aboutTitle message:aboutMessage preferredStyle:UIAlertControllerStyleAlert];
    
    [aboutAlert addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                    style:UIAlertActionStyleCancel
                                                  handler:nil]];
    [aboutAlert addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Website", nil)
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://www.mumble.info/"] options:@{} completionHandler:nil];
    }]];
    [aboutAlert addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Legal", nil)
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction * _Nonnull action) {
        MULegalViewController *legalView = [[MULegalViewController alloc] init];
        UINavigationController *navController = [[UINavigationController alloc] init];
        [navController pushViewController:legalView animated:NO];
        [[self navigationController] presentViewController:navController animated:YES completion:nil];
    }]];
    [aboutAlert addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Support", nil)
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/mumble-voip/mumble-iphoneos/issues"] options:@{} completionHandler:nil];
    }]];
    
    [self presentViewController:aboutAlert animated:YES completion:nil];
}

- (void) prefsClicked:(id)sender {
    MUPreferencesViewController *prefs = [[MUPreferencesViewController alloc] init];
    [self.navigationController pushViewController:prefs animated:YES];
}

@end
