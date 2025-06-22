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
    // 使用 InsetGrouped 样式以获得现代化的卡片式外观 (需要 iOS 13+)
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        // ...
    }
    return self;
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    self.navigationItem.title = @"Mumble";
    self.navigationController.toolbarHidden = YES;
    
    // Set the background to the standard dark gray for dark mode.
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // InsetGrouped 样式也会自动处理分隔线。
    self.tableView.scrollEnabled = NO;
    
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
    return 1;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
#if MUMBLE_LAUNCH_IMAGE_CREATION == 1
    return 1;
#endif
    if (section == 0)
        return 3;
    return 0;
}

- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        UIView *headerContainer = [[UIView alloc] init];
        
        UIImage *logoImage = [UIImage imageNamed:@"WelcomeScreenIcon"];
        UIImageView *logoImageView = [[UIImageView alloc] initWithImage:logoImage];
        logoImageView.contentMode = UIViewContentModeScaleAspectFit;
        logoImageView.translatesAutoresizingMaskIntoConstraints = NO;
        
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = @"Welcome to Mumble";
        titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.adjustsFontForContentSizeCategory = YES;
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = @"Low latency, high quality voice chat";
        subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        subtitleLabel.textColor = [UIColor secondaryLabelColor];
        subtitleLabel.textAlignment = NSTextAlignmentCenter;
        subtitleLabel.adjustsFontForContentSizeCategory = YES;
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        [headerContainer addSubview:logoImageView];
        [headerContainer addSubview:titleLabel];
        [headerContainer addSubview:subtitleLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [logoImageView.topAnchor constraintEqualToAnchor:headerContainer.topAnchor constant:20],
            [logoImageView.centerXAnchor constraintEqualToAnchor:headerContainer.centerXAnchor],
            [logoImageView.heightAnchor constraintEqualToConstant:100],
            [logoImageView.widthAnchor constraintEqualToConstant:100],

            [titleLabel.topAnchor constraintEqualToAnchor:logoImageView.bottomAnchor constant:16],
            [titleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.leadingAnchor],
            [titleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.trailingAnchor],

            [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
            [subtitleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.leadingAnchor],
            [subtitleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.trailingAnchor],
            [subtitleLabel.bottomAnchor constraintEqualToAnchor:headerContainer.bottomAnchor constant:-20]
        ]];
        
        return headerContainer;
    }
    return nil;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 44.0;
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"welcomeItem"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"welcomeItem"];
    }
    
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    
    NSString *text = @"";
    NSString *symbolName = @"";
    
    if (indexPath.section == 0) {
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
        content.image = [UIImage systemImageNamed:symbolName];
        cell.contentConfiguration = content;
    } else {
        // Fallback on earlier versions
        cell.textLabel.text = text;
        cell.imageView.image = [UIImage systemImageNamed:symbolName];
    }

    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    /* Servers section. */
    if (indexPath.section == 0) {
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
