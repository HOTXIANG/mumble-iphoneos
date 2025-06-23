// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUPreferencesViewController.h"
#import "MUApplicationDelegate.h"
#import "MUCertificatePreferencesViewController.h"
#import "MUAudioTransmissionPreferencesViewController.h"
#import "MUAdvancedAudioPreferencesViewController.h"
#import "MURemoteControlPreferencesViewController.h"
#import "MUCertificateController.h"
#import "MUTableViewHeaderLabel.h"
#import "MURemoteControlServer.h"
#import "MUColor.h"
#import "MUImage.h"
#import "MUBackgroundView.h"

#import <MumbleKit/MKCertificate.h>

@interface MUPreferencesViewController () {
    UITextField *_activeTextField;
}
- (void) audioVolumeChanged:(UISlider *)volumeSlider;
- (void) forceTCPChanged:(UISwitch *)tcpSwitch;
@end

@implementation MUPreferencesViewController

#pragma mark -
#pragma mark Initialization

- (id) init {
    // 使用 InsetGrouped 样式以与其他界面保持一致
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.preferredContentSize = CGSizeMake(320, 480);
    }
    return self;
}

- (void) dealloc {
    [[NSUserDefaults standardUserDefaults] synchronize];
    MUApplicationDelegate *delegate = [[UIApplication sharedApplication] delegate];
    [delegate reloadPreferences];
}

#pragma mark -
#pragma mark Looks

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
    
    // 设置背景色 - 与其他界面一致
    [self updateBackgroundColor];
    
    // 配置现代化的表格视图外观
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    self.navigationItem.title = NSLocalizedString(@"Preferences", nil);
    
    // 更新背景色
    [self updateBackgroundColor];
    
    // 移除旧的背景视图设置
    // self.tableView.backgroundView = [MUBackgroundView backgroundView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Audio
    if (section == 0) {
        return 3;
    // Network
    } else if (section == 1) {
#ifdef ENABLE_REMOTE_CONTROL
        return 3;
#else
        return 2;
#endif
    }

    return 0;
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"PreferencesCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleGray;
    cell.accessoryType = UITableViewCellAccessoryNone;
    
    // Audio section
    if ([indexPath section] == 0) {
        // Volume
        if ([indexPath row] == 0) {
            UISlider *volSlider = [[UISlider alloc] init];
            [volSlider setMinimumTrackTintColor:[UIColor blackColor]];
            [volSlider setMaximumValue:1.0f];
            [volSlider setMinimumValue:0.0f];
            [volSlider setValue:[[NSUserDefaults standardUserDefaults] floatForKey:@"AudioOutputVolume"]];
            [[cell textLabel] setText:NSLocalizedString(@"Volume", nil)];
            [cell setAccessoryView:volSlider];
            [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
            [volSlider addTarget:self action:@selector(audioVolumeChanged:) forControlEvents:UIControlEventValueChanged];
        }
        // Transmit method
        if ([indexPath row] == 1) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"AudioTransmitCell"];
            if (cell == nil)
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"AudioTransmitCell"];
            cell.textLabel.text = NSLocalizedString(@"Transmission", nil);
            NSString *xmit = [[NSUserDefaults standardUserDefaults] stringForKey:@"AudioTransmitMethod"];
            if ([xmit isEqualToString:@"vad"]) {
                cell.detailTextLabel.text = NSLocalizedString(@"Voice Activated", @"Voice activated transmission mode");
            } else if ([xmit isEqualToString:@"ptt"]) {
                cell.detailTextLabel.text = NSLocalizedString(@"Push-to-talk", @"Push-to-talk transmission mode");
            } else if ([xmit isEqualToString:@"continuous"]) {
                cell.detailTextLabel.text = NSLocalizedString(@"Continuous", @"Continuous transmission mode");
            }
            cell.detailTextLabel.textColor = [MUColor selectedTextColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
             cell.selectionStyle = UITableViewCellSelectionStyleGray;
            return cell;
        } else if ([indexPath row] == 2) {
            cell.textLabel.text = NSLocalizedString(@"Advanced", nil);
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }

    // Network
    } else if ([indexPath section] == 1) {
        if ([indexPath row] == 0) {
            UISwitch *tcpSwitch = [[UISwitch alloc] init];
            [tcpSwitch setOn:[[NSUserDefaults standardUserDefaults] boolForKey:@"NetworkForceTCP"]];
            [[cell textLabel] setText:NSLocalizedString(@"Force TCP", nil)];
            [cell setAccessoryView:tcpSwitch];
            [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
            [tcpSwitch setOnTintColor:[UIColor blackColor]];
            [tcpSwitch addTarget:self action:@selector(forceTCPChanged:) forControlEvents:UIControlEventValueChanged];
        } else if ([indexPath row] == 1) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PrefCertificateCell"];
            if (cell == nil)
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"PrefCertificateCell"];
            MKCertificate *cert = [MUCertificateController defaultCertificate];
            cell.textLabel.text = NSLocalizedString(@"Certificate", nil);
            cell.detailTextLabel.text = cert ? [cert subjectName] : NSLocalizedString(@"None", @"None (No certificate chosen)");
            cell.detailTextLabel.textColor = [MUColor selectedTextColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleGray;
            return cell;
        } else if ([indexPath row] == 2) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RemoteControlCell"];
            if (cell == nil)
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"RemoteControlCell"];
            cell.textLabel.text = NSLocalizedString(@"Remote Control", nil);
            BOOL isOn = [[MURemoteControlServer sharedRemoteControlServer] isRunning];
            if (isOn) {
                cell.detailTextLabel.text = NSLocalizedString(@"On", nil);
            } else {
                cell.detailTextLabel.text = NSLocalizedString(@"Off", nil);
            }
            cell.detailTextLabel.textColor = [MUColor selectedTextColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleGray;
            return cell;
        }
    }

    // 确保所有 cell 都有正确的背景色
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            cell.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0]; // #2C2C2E
        } else {
            cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        }
    } else {
        cell.backgroundColor = [UIColor whiteColor];
    }
    
    return cell;
}

- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return [MUTableViewHeaderLabel labelWithText:NSLocalizedString(@"Audio", nil)];
    } else if (section == 1) {
        return [MUTableViewHeaderLabel labelWithText:NSLocalizedString(@"Network", nil)];
    }

    return nil;
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [MUTableViewHeaderLabel defaultHeaderHeight];
}

#pragma mark -
#pragma mark Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) { // Audio
        if (indexPath.row == 1) { // Transmission
            MUAudioTransmissionPreferencesViewController *audioXmit = [[MUAudioTransmissionPreferencesViewController alloc] init];
            [self.navigationController pushViewController:audioXmit animated:YES];
        } else if (indexPath.row == 2) { // Advanced
            MUAdvancedAudioPreferencesViewController *advAudio = [[MUAdvancedAudioPreferencesViewController alloc] init];
            [self.navigationController pushViewController:advAudio animated:YES];
        }
    } else if ([indexPath section] == 1) { // Network
        if ([indexPath row] == 1) { // Certificates
            MUCertificatePreferencesViewController *certPref = [[MUCertificatePreferencesViewController alloc] init];
            [self.navigationController pushViewController:certPref animated:YES];
        }
        if ([indexPath row] == 2) { // Remote Control
            MURemoteControlPreferencesViewController *remoteControlPref = [[MURemoteControlPreferencesViewController alloc] init];
            [self.navigationController pushViewController:remoteControlPref animated:YES];
        }
    }
}

- (void) audioVolumeChanged:(UISlider *)volumeSlider {
    [[NSUserDefaults standardUserDefaults] setFloat:[volumeSlider value] forKey:@"AudioOutputVolume"];
}

- (void) forceTCPChanged:(UISwitch *)tcpSwitch {
    [[NSUserDefaults standardUserDefaults] setBool:[tcpSwitch isOn] forKey:@"NetworkForceTCP"];
}

@end

