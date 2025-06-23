// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUPublicServerList.h"
#import "MUPublicServerListController.h"
#import "MUCountryServerListController.h"
#import "MUTableViewHeaderLabel.h"
#import "MUImage.h"
#import "MUBackgroundView.h"

@interface MUPublicServerListController () {
    MUPublicServerList        *_serverList;
}
@end

@implementation MUPublicServerListController

- (id) init {
    // 使用 InsetGrouped 样式以与欢迎界面保持一致
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _serverList = [[MUPublicServerList alloc] init];
    }
    return self;
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

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self updateBackgroundColor];
        }
    }
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:YES];

    self.navigationItem.title = NSLocalizedString(@"Public Servers", nil);
    
    // 设置背景色 - 与欢迎界面一致
    [self updateBackgroundColor];
    
    // 移除旧的背景视图设置
    // self.tableView.backgroundView = [MUBackgroundView backgroundView];
    
    if (@available(iOS 7, *)) {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        self.tableView.separatorInset = UIEdgeInsetsZero;
    } else {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    }

    // 配置现代化的表格视图外观
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }

    if (![_serverList isParsed]) {
        UIActivityIndicatorView *activityIndicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        UIBarButtonItem *barActivityIndicator = [[UIBarButtonItem alloc] initWithCustomView:activityIndicatorView];
        self.navigationItem.rightBarButtonItem = barActivityIndicator;
        [activityIndicatorView startAnimating];
    }
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:YES];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if ([self->_serverList isParsed]) {
            self.navigationItem.rightBarButtonItem = nil;
            return;
        }
        [self->_serverList parse];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.rightBarButtonItem = nil;
            [self.tableView reloadData];
        });
    });
}

#pragma mark -
#pragma mark UITableView data source

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return [_serverList numberOfContinents];
}

- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    MUTableViewHeaderLabel *label = [[MUTableViewHeaderLabel alloc] init];
    
    // 使用正确的方法名 - continentNameAtIndex 而不是 continentAtIndex
    NSString *continentName = [_serverList continentNameAtIndex:section];
    [label setText:continentName];
    
    // 设置文字颜色以适应主题
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            [label setTextColor:[UIColor secondaryLabelColor]]; // 深色模式使用次级标签颜色
        } else {
            [label setTextColor:[UIColor secondaryLabelColor]]; // 浅色模式也使用次级标签颜色（黑色系）
        }
    } else {
        [label setTextColor:[UIColor blackColor]]; // iOS 12 及以下使用黑色
    }
    
    // 设置背景色与整体背景一致
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            [label setBackgroundColor:[UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0]];
        } else {
            [label setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
        }
    } else {
        [label setBackgroundColor:[UIColor groupTableViewBackgroundColor]];
    }
    
    return label;
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return [MUTableViewHeaderLabel defaultHeaderHeight];
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_serverList numberOfCountriesAtContinentIndex:section];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 50.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"countryItem"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"countryItem"];
    }

    [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
    
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
    
    // 设置文字颜色以适应主题
    if (@available(iOS 13.0, *)) {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    
    NSDictionary *countryInfo = [_serverList countryAtIndexPath:indexPath];
    cell.textLabel.text = [countryInfo objectForKey:@"name"];
    NSInteger numServers = [[countryInfo objectForKey:@"servers"] count];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%li %@", (long int)numServers, numServers > 1 ? @"servers" : @"server"];
    cell.selectionStyle = UITableViewCellSelectionStyleGray;

    return cell;
}

#pragma mark -
#pragma mark UITableView delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *countryInfo = [_serverList countryAtIndexPath:indexPath];
    NSString *countryName = [countryInfo objectForKey:@"name"];
    NSArray *countryServers = [countryInfo objectForKey:@"servers"];

    MUCountryServerListController *countryController = [[MUCountryServerListController alloc] initWithName:countryName serverList:countryServers];
    [[self navigationController] pushViewController:countryController animated:YES];
}

@end
