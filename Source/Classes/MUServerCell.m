// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUServerCell.h"
#import "MUColor.h"
#import "MUFavouriteServer.h"

@interface MUServerCell () {
    NSString        *_displayname;
    NSString        *_hostname;
    NSString        *_port;
    NSString        *_username;
    MKServerPinger  *_pinger;
}
- (UIImage *) drawPingImageWithPingValue:(NSUInteger)pingMs andUserCount:(NSUInteger)userCount isFull:(BOOL)isFull;
@end

@implementation MUServerCell

+ (NSString *) reuseIdentifier {
    return @"ServerCell";
}

- (id) init {
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:[MUServerCell reuseIdentifier]];
}

- (void) populateFromDisplayName:(NSString *)displayName hostName:(NSString *)hostName port:(NSString *)port {
    _displayname = [displayName copy];

    _port = [port copy];

    _pinger = nil;

    if ([hostName length] > 0) {
        _hostname = [hostName copy];
        _pinger = [[MKServerPinger alloc] initWithHostname:_hostname port:_port];
        [_pinger setDelegate:self];
    } else {
        _hostname = NSLocalizedString(@"(No Server)", nil);
    }

    self.textLabel.text = _displayname;
    self.detailTextLabel.text = [NSString stringWithFormat:@"%@:%@", _hostname, _port];
    self.imageView.image = [self drawPingImageWithPingValue:999 andUserCount:0 isFull:NO];
}

- (void) populateFromFavouriteServer:(MUFavouriteServer *)favServ {
    _displayname = [[favServ displayName] copy];

    _hostname = [[favServ hostName] copy];

    _port = [NSString stringWithFormat:@"%lu", (unsigned long)[favServ port]];

    if ([[favServ userName] length] > 0) {
        _username = [[favServ userName] copy];
    } else {
        _username = [[[NSUserDefaults standardUserDefaults] objectForKey:@"DefaultUserName"] copy];
    }

    _pinger = nil;
    if ([_hostname length] > 0) {
        _pinger = [[MKServerPinger alloc] initWithHostname:_hostname port:_port];
        [_pinger setDelegate:self]; 
    } else {
        _hostname = NSLocalizedString(@"(No Server)", nil);
    }
    
    self.textLabel.text = _displayname;
    self.detailTextLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%@ on %@:%@", @"username on hostname:port"),
                                    _username, _hostname, _port];
    self.imageView.image = [self drawPingImageWithPingValue:999 andUserCount:0 isFull:NO];
}

- (void) setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
}

- (void) layoutSubviews {
    [super layoutSubviews];
    
    // 现代化的圆角效果
    if (@available(iOS 13.0, *)) {
        // 设置整个 cell 的圆角
        self.layer.cornerRadius = 12.0;
        self.layer.masksToBounds = YES;
        
        // 根据主题设置背景色 - 创建层次感
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            // 深色模式：使用比背景更亮的颜色
            self.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0]; // #2C2C2E
        } else {
            // 浅色模式：使用标准的次级背景色
            self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        }
        
        // 确保在编辑状态下也保持圆角
        if (self.isEditing || self.showingDeleteConfirmation) {
            // 编辑状态下也保持圆角
            self.layer.cornerRadius = 12.0;
            self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
        }
    } else {
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
        self.backgroundColor = [UIColor whiteColor];
    }
    
    // 调整延迟和人数显示的样式
    [self setupStatusLabels];
}

- (void) setupStatusLabels {
    // 查找延迟和人数标签（假设它们是 cell 的子视图）
    for (UIView *subview in self.contentView.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            
            // 如果是延迟或人数标签，给它们添加圆角背景
            if ([label.text containsString:@"ms"] || [label.text containsString:@"users"] || 
                [label.text containsString:@"延迟"] || [label.text containsString:@"人"]) {
                
                // 创建圆角背景
                label.layer.cornerRadius = 8.0;
                label.layer.masksToBounds = YES;
                label.textAlignment = NSTextAlignmentCenter;
                
                if (@available(iOS 13.0, *)) {
                    if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                        // 深色模式：使用更暗的背景色来突出显示
                        label.backgroundColor = [UIColor colorWithRed:0.24 green:0.24 blue:0.26 alpha:1.0]; // #3D3D42
                        label.textColor = [UIColor secondaryLabelColor];
                    } else {
                        label.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
                        label.textColor = [UIColor secondaryLabelColor];
                    }
                } else {
                    label.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
                    label.textColor = [UIColor grayColor];
                }
                
                // 添加内边距
                label.layer.borderWidth = 0;
                
                // 设置字体
                label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
            }
        }
    }
}

// 重写编辑状态方法以确保圆角保持
- (void) setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    
    // 在编辑状态改变时重新应用圆角和背景色
    dispatch_async(dispatch_get_main_queue(), ^{
        [self layoutSubviews];
    });
}

// 监听主题变化
- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self layoutSubviews];
        }
    }
}

- (UIImage *) drawPingImageWithPingValue:(NSUInteger)pingMs andUserCount:(NSUInteger)userCount isFull:(BOOL)isFull {
    UIImage *img = nil;
    
    UIColor *pingColor = [MUColor badPingColor];
    if (pingMs <= 125)
        pingColor = [MUColor goodPingColor];
    else if (pingMs > 125 && pingMs <= 250)
        pingColor = [MUColor mediumPingColor];
    else if (pingMs > 250)
        pingColor = [MUColor badPingColor];
    NSString *pingStr = [NSString stringWithFormat:@"%lu\nms", (unsigned long)pingMs];
    if (pingMs >= 999)
        pingStr = @"∞\nms";

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(66.0f, 32.0f), NO, [[UIScreen mainScreen] scale]);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, pingColor.CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, 32.0, 32.0));

    CGContextSetTextDrawingMode(ctx, kCGTextFill);
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    paragraphStyle.alignment = NSTextAlignmentCenter;
    [pingStr drawInRect:CGRectMake(0.0, 0.0, 32.0, 32.0) withAttributes:@{
        NSFontAttributeName : [UIFont boldSystemFontOfSize: 12],
        NSParagraphStyleAttributeName : paragraphStyle,
        NSForegroundColorAttributeName : [UIColor whiteColor]
    }];

    if (!isFull) {
        // Non-full servers get the mild iOS blue color
        CGContextSetFillColorWithColor(ctx, [MUColor userCountColor].CGColor);
    } else {
        // Mark full servers with the same red as we use for
        // 'bad' pings...
        CGContextSetFillColorWithColor(ctx, [MUColor badPingColor].CGColor);
    }
    CGContextFillRect(ctx, CGRectMake(34.0, 0, 32.0, 32.0));

    CGContextSetTextDrawingMode(ctx, kCGTextFill);
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    NSString *usersStr = [NSString stringWithFormat:NSLocalizedString(@"%lu\nppl", @"user count"), (unsigned long)userCount];
    paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineBreakMode = NSLineBreakByTruncatingTail;
    paragraphStyle.alignment = NSTextAlignmentCenter;
    [usersStr drawInRect:CGRectMake(34.0, 0.0, 32.0, 32.0) withAttributes:@{
        NSFontAttributeName : [UIFont boldSystemFontOfSize: 12],
        NSParagraphStyleAttributeName : paragraphStyle,
        NSForegroundColorAttributeName : [UIColor whiteColor]
    }];
    
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    return img;
}

- (void) serverPingerResult:(MKServerPingerResult *)result {
    NSUInteger pingValue = (NSUInteger)(result->ping * 1000.0f);
    NSUInteger userCount = (NSUInteger)(result->cur_users);
    BOOL isFull = result->cur_users == result->max_users;
    self.imageView.image = [self drawPingImageWithPingValue:pingValue andUserCount:userCount isFull:isFull];
}

@end
