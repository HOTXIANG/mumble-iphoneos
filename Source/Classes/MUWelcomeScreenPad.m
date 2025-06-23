// Copyright 2012-2024 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUWelcomeScreenPad.h"
#import "MUPreferencesViewController.h"
#import "MULegalViewController.h"
#import "MUPopoverBackgroundView.h"
#import "MUPublicServerListController.h"
#import "MUFavouriteServerListController.h"
#import "MULanServerListController.h"

@interface MUWelcomeScreenPad () <UIPopoverControllerDelegate, UITableViewDataSource, UITableViewDelegate> {
    UIPopoverController   *_prefsPopover;
    UITableView           *_tableView;
}
@end

@implementation MUWelcomeScreenPad

- (id) init {
    if ((self = [super init])) {
    }
    return self;
}

- (void) loadView {
    [super loadView];
    // Use systemGroupedBackgroundColor for the correct dark gray in dark mode.
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // Create table view with modern inset grouped style
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    [self.view addSubview:_tableView];

    // Pin the table view to the safe area
    [NSLayoutConstraint activateConstraints:@[
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [_tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

    // Create and assign the modern header view
    _tableView.tableHeaderView = [self createHeaderView];
}

- (UIView *) createHeaderView {
    UIView *headerContainer = [[UIView alloc] init];
    headerContainer.translatesAutoresizingMaskIntoConstraints = NO;

    UIImage *logoImage = [UIImage imageNamed:@"LogoBigShadow"];
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

    // Layout for the header content
    [NSLayoutConstraint activateConstraints:@[
        [logoImageView.topAnchor constraintEqualToAnchor:headerContainer.topAnchor constant:40],
        [logoImageView.centerXAnchor constraintEqualToAnchor:headerContainer.centerXAnchor],
        [logoImageView.heightAnchor constraintEqualToConstant:150],
        [logoImageView.widthAnchor constraintEqualToConstant:150],

        [titleLabel.topAnchor constraintEqualToAnchor:logoImageView.bottomAnchor constant:20],
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.trailingAnchor],

        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:headerContainer.layoutMarginsGuide.trailingAnchor],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:headerContainer.bottomAnchor constant:-20]
    ]];

    // Calculate the size of the header view to properly set it on the table view
    [headerContainer setNeedsLayout];
    [headerContainer layoutIfNeeded];
    CGFloat height = [headerContainer systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].height;
    CGRect frame = headerContainer.frame;
    frame.size.height = height;
    headerContainer.frame = frame;

    return headerContainer;
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationItem.title = @"Mumble";

    // Modern navigation bar appearance for a seamless look
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        // Configure the appearance to be transparent, allowing the background color to show through.
        [appearance configureWithTransparentBackground];
        // Set the background color to match the view's background.
        appearance.backgroundColor = [UIColor systemGroupedBackgroundColor];
        // Remove the shadow/separator line for a seamless transition.
        appearance.shadowColor = nil;

        self.navigationController.navigationBar.standardAppearance = appearance;
        self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
        self.navigationController.navigationBar.compactAppearance = appearance;
    }

    UIBarButtonItem *aboutBtn = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"About", nil) style:UIBarButtonItemStylePlain target:self action:@selector(aboutButtonClicked:)];
    self.navigationItem.rightBarButtonItem = aboutBtn;

    UIBarButtonItem *prefsBtn = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Preferences", nil) style:UIBarButtonItemStylePlain target:self action:@selector(prefsButtonClicked:)];
    self.navigationItem.leftBarButtonItem = prefsBtn;

    [_tableView deselectRowAtIndexPath:[_tableView indexPathForSelectedRow] animated:animated];
}

#pragma mark - TableView

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 3;
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
    UIViewController *nextViewController = nil;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            nextViewController = [[MUPublicServerListController alloc] init];
        } else if (indexPath.row == 1) {
            nextViewController = [[MUFavouriteServerListController alloc] init];
        } else if (indexPath.row == 2) {
            nextViewController = [[MULanServerListController alloc] init];
        }
    }
    if (nextViewController) {
        [self.navigationController pushViewController:nextViewController animated:YES];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Actions

- (void) aboutButtonClicked:(id)sender {
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

- (void) prefsButtonClicked:(id)sender {
    if (_prefsPopover != nil) {
        return;
    }

    MUPreferencesViewController *prefs = [[MUPreferencesViewController alloc] init];
    UINavigationController *navCtrl = [[UINavigationController alloc] initWithRootViewController:prefs];
    UIPopoverController *popOver = [[UIPopoverController alloc] initWithContentViewController:navCtrl];
    popOver.popoverBackgroundViewClass = [MUPopoverBackgroundView class];
    popOver.delegate = self;
    [popOver presentPopoverFromBarButtonItem:sender permittedArrowDirections:UIPopoverArrowDirectionUp animated:YES];

    _prefsPopover = popOver;
}

#pragma mark - UIPopoverControllerDelegate

- (void) popoverControllerDidDismissPopover:(UIPopoverController *)popoverController {
    if (popoverController == _prefsPopover) {
        _prefsPopover = nil;
    }
}

@end
