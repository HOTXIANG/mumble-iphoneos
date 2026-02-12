#if TARGET_OS_IOS
// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUAudioTransmissionPreferencesViewController.h"
#import "MUVoiceActivitySetupViewController.h"
#import "MUAudioBarViewCell.h"
#import "MUColor.h"
#import "MUImage.h"

@interface MUAudioTransmissionPreferencesViewController () {
}
@end

@implementation MUAudioTransmissionPreferencesViewController

- (id) init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.preferredContentSize = CGSizeMake(320, 480);
    }
    return self;
}

- (void) didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

#pragma mark - View lifecycle

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    self.title = NSLocalizedString(@"Transmission", nil);
    
    if (@available(iOS 7, *)) {
        // fixme(mkrautz): usually we want a single line separator on iOS 7, but
        // in this case, we embed an image in a table view cell, and want the separators
        // to not appear when the image is shown. This was the easiest way to achieve that.
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.tableView.separatorInset = UIEdgeInsetsZero;
    } else {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    }
    
    self.tableView.scrollEnabled = NO;
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void) viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

#pragma mark - Table view data source

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"AudioTransmitMethod"];
    if (section == 0) {
        return 3;
    } else if (section == 1) {
        if ([current isEqualToString:@"ptt"] || [current isEqualToString:@"vad"]) {
            return 1;
        }
    }
    return 0;
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"AudioXmitOptionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"AudioTransmitMethod"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor blackColor];
    cell.selectionStyle = UITableViewCellSelectionStyleGray;
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = NSLocalizedString(@"Voice Activated", nil);
            if ([current isEqualToString:@"vad"]) {
                cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"GrayCheckmark"]];
                cell.textLabel.textColor = [MUColor selectedTextColor];
            }
        } else if (indexPath.row == 1) {
            cell.textLabel.text = NSLocalizedString(@"Push-to-talk", nil);
            if ([current isEqualToString:@"ptt"]) {
                cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"GrayCheckmark"]];
                cell.textLabel.textColor = [MUColor selectedTextColor];
            }
        } else if (indexPath.row == 2) {
            cell.textLabel.text = NSLocalizedString(@"Continuous", nil);
            if ([current isEqualToString:@"continuous"]) {
                cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"GrayCheckmark"]];
                cell.textLabel.textColor = [MUColor selectedTextColor];
            }
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            if ([current isEqualToString:@"ptt"]) {
                UITableViewCell *pttCell = [tableView dequeueReusableCellWithIdentifier:@"AudioXmitPTTCell"];
                if (pttCell == nil) {
                    pttCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"AudioXmitPTTCell"];
                }
                UIImageView *mouthView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"talkbutton_off"]];
                [mouthView setContentMode:UIViewContentModeCenter];
                [mouthView setOpaque:NO];
                [pttCell setBackgroundView:mouthView];
                pttCell.selectionStyle = UITableViewCellSelectionStyleNone;
                pttCell.textLabel.text = nil;
                pttCell.accessoryView = nil;
                pttCell.accessoryType = UITableViewCellAccessoryNone;
                pttCell.backgroundColor = [UIColor clearColor];
                return pttCell;
            } else if ([current isEqualToString:@"vad"]) {
                cell.accessoryView = nil;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.textLabel.text = NSLocalizedString(@"Voice Activity Configuration", nil);
                cell.selectionStyle = UITableViewCellSelectionStyleGray;
            }
        }
    }

    return cell;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"AudioTransmitMethod"];
    if ([indexPath section] == 1 && [indexPath row] == 0) {
        if ([current isEqualToString:@"ptt"]) {
            return 100.0f;
        }
    }
    return 44.0f;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *current = [[NSUserDefaults standardUserDefaults] stringForKey:@"AudioTransmitMethod"];
    UITableViewCell *cell = nil;

    // Transmission setting change
    if (indexPath.section == 0) {
        for (int i = 0; i < 3; i++) {
            cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]];
            cell.accessoryView = nil;
            cell.textLabel.textColor = [UIColor blackColor];
        }

        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        
        if (indexPath.row == 0) {
            [[NSUserDefaults standardUserDefaults] setObject:@"vad" forKey:@"AudioTransmitMethod"];
        } else if (indexPath.row == 1) {
            [[NSUserDefaults standardUserDefaults] setObject:@"ptt" forKey:@"AudioTransmitMethod"];
        } else if (indexPath.row == 2) {
            [[NSUserDefaults standardUserDefaults] setObject:@"continuous" forKey:@"AudioTransmitMethod"];
        }

        [self.tableView reloadSectionIndexTitles];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationFade];
        
        cell = [self.tableView cellForRowAtIndexPath:indexPath];
        cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"GrayCheckmark"]];
        cell.textLabel.textColor = [MUColor selectedTextColor];
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            if ([current isEqualToString:@"vad"]) {
                MUVoiceActivitySetupViewController *vadSetup = [[MUVoiceActivitySetupViewController alloc] init];
                [self.navigationController pushViewController:vadSetup animated:YES];
            }
        }	
    }
}

@end
#endif // TARGET_OS_IOS
