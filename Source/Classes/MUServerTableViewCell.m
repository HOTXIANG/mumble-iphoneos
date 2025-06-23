// Copyright 2014 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUServerTableViewCell.h"

@implementation MUServerTableViewCell

- (id) initWithReuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        // 设置现代化的选择样式
        if (@available(iOS 13.0, *)) {
            self.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            self.selectionStyle = UITableViewCellSelectionStyleGray;
        }
    }
    return self;
}

- (void) layoutSubviews {
    [super layoutSubviews];

    // 现代化的圆角和阴影效果
    if (@available(iOS 13.0, *)) {
        self.layer.cornerRadius = 12.0;
        self.layer.masksToBounds = NO;
        
        // 只在浅色模式下添加轻微阴影
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight) {
            self.layer.shadowColor = [UIColor blackColor].CGColor;
            self.layer.shadowOpacity = 0.08;
            self.layer.shadowOffset = CGSizeMake(0, 1);
            self.layer.shadowRadius = 2.0;
        } else {
            self.layer.shadowOpacity = 0;
        }
    }

    // 移除默认分隔线的插入
    self.separatorInset = UIEdgeInsetsMake(0, 0, 0, 0);

    // 调整图标位置
    CGRect imageFrame = self.imageView.frame;
    imageFrame.origin.x = 16 + self.indentationLevel * self.indentationWidth;
    imageFrame.size.width = 24;
    imageFrame.size.height = 24;
    // 垂直居中
    imageFrame.origin.y = (CGRectGetHeight(self.frame) - imageFrame.size.height) / 2;
    self.imageView.frame = imageFrame;

    // 调整文本标签位置
    CGRect textFrame = self.textLabel.frame;
    textFrame.origin.x = CGRectGetMaxX(imageFrame) + 12;
    textFrame.size.width = CGRectGetWidth(self.frame) - textFrame.origin.x - 16;
    self.textLabel.frame = textFrame;
    
    // 设置文本样式
    if (@available(iOS 13.0, *)) {
        self.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    } else {
        self.textLabel.font = [UIFont systemFontOfSize:17];
    }
}

- (void) setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    
    // 自定义选择动画
    if (selected && animated) {
        [UIView animateWithDuration:0.1 animations:^{
            self.transform = CGAffineTransformMakeScale(0.98, 0.98);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.1 animations:^{
                self.transform = CGAffineTransformIdentity;
            }];
        }];
    }
}

- (void) setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    
    // 高亮状态的视觉效果
    if (@available(iOS 13.0, *)) {
        if (highlighted) {
            self.alpha = 0.8;
        } else {
            [UIView animateWithDuration:0.2 animations:^{
                self.alpha = 1.0;
            }];
        }
    }
}

@end
