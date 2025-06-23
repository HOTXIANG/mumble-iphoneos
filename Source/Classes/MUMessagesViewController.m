// Copyright 2009-2011 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

@import CoreServices;
@import UserNotifications;

#import <MumbleKit/MKServerModel.h>
#import <MumbleKit/MKTextMessage.h>

#import "MUMessagesViewController.h"
#import "MUTextMessage.h"
#import "MUTextMessageProcessor.h"
#import "MUMessageBubbleTableViewCell.h"
#import "MUMessageRecipientViewController.h"
#import "MUMessageAttachmentViewController.h"
#import "MUImageViewController.h"
#import "MUMessagesDatabase.h"
#import "MUDataURL.h"
#import "MUColor.h"
#import "MUImage.h"
#import "MUBackgroundView.h"

static UIView *MUMessagesViewControllerFindUIView(UIView *rootView, NSString *prefix) {
    for (UIView *subview in [rootView subviews]) {
        if ([[subview description] hasPrefix:prefix]) {
            return subview;
        }
        UIView *candidate = MUMessagesViewControllerFindUIView(subview, prefix);
        if (candidate) {
            return candidate;
        }
    }
    return nil;
}

@interface MUConsistentTextField : UITextField
@end

@implementation MUConsistentTextField

- (CGRect) textRectForBounds:(CGRect)bounds {
    return [self editingRectForBounds:bounds];
}

- (CGRect) editingRectForBounds:(CGRect)bounds {
    NSInteger padding = 13;

    CGRect leftRect = [super leftViewRectForBounds:bounds];
    CGRect rect = [super editingRectForBounds:bounds];

    NSInteger minx = leftRect.size.width + padding; // 'at least'

    if (rect.origin.x < minx) {
        NSInteger delta = minx - rect.origin.x;
        rect.origin.x += delta;
        if (@available(iOS 7, *)) {} else {
            rect.size.width -= delta;
        }
    }

    return rect;
}

@end

@interface MUMessageReceiverButton : UIControl {
    NSString *_str;
}
@end

@implementation MUMessageReceiverButton

- (id) initWithText:(NSString *)str {
    if ((self = [super initWithFrame:CGRectZero])) {
        [self setOpaque:NO];
        if ([str length] >= 15) {
            _str = [NSString stringWithFormat:@"%@...", [str substringToIndex:11]];
        } else {
            _str = [str copy];
        }
        CGSize size = [_str sizeWithAttributes:@{ NSFontAttributeName : [UIFont boldSystemFontOfSize:14.0f] }];
        if (@available(iOS 7, *)) {} else {
            size.width += 6*2;
        }
        [self setFrame:CGRectMake(0, 0, size.width, size.height)];
    }
    return self;
}

- (void) drawRect:(CGRect)rect {
    rect = self.bounds;
    CGFloat radius = 12.0f; // 增加圆角半径

    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextClearRect(context, rect);

    CGContextSetLineWidth(context, 1.0f);

    UIColor *fillColor;
    if (@available(iOS 13.0, *)) {
        if (self.highlighted) {
            fillColor = [UIColor tertiarySystemFillColor];
        } else {
            fillColor = [UIColor systemBlueColor];
        }
    } else {
        if (self.highlighted) {
            fillColor = [UIColor lightGrayColor];
        } else {
            fillColor = [UIColor colorWithRed:0.0 green:0.478 blue:1.0 alpha:1.0]; // 系统蓝色
        }
    }
    
    [fillColor setFill];
    
    // 使用 UIBezierPath 绘制更现代的圆角矩形
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
    [path fill];
    
    rect.origin.x = radius;
    rect.size.width -= radius;
    
    [[UIColor whiteColor] set];
    [_str drawInRect:rect withAttributes:@{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:14.0f],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    }];
}

- (void) setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setNeedsDisplay];
}

@end

@interface MUMessagesViewController () <UITableViewDelegate, UITableViewDataSource, MKServerModelDelegate, UITextFieldDelegate, MUMessageBubbleTableViewCellDelegate, MUMessageRecipientViewControllerDelegate> {
    MKServerModel            *_model;
    UITableView              *_tableView;
    UIView                   *_textBarView;
    MUConsistentTextField    *_textField;
    BOOL                     _autoCorrectGuard;
    MUMessagesDatabase       *_msgdb;

    MKChannel                *_channel;
    MKChannel                *_tree;
    MKUser                   *_user;
}
- (void) setReceiverName:(NSString *)receiver andImage:(NSString *)imageName;
@end

@implementation MUMessagesViewController

- (id) initWithServerModel:(MKServerModel *)model {
    if ((self = [super init])) {
        _model = model;
        [_model addDelegate:self];
        _msgdb = [[MUMessagesDatabase alloc] init];
    }
    return self;
}

- (void) dealloc {
    [_model removeDelegate:self];
}

- (void) clearAllMessages {
    _msgdb = [[MUMessagesDatabase alloc] init];
    [_tableView reloadData];
}

- (void) updateBackgroundColors {
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            self.view.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
            if (_tableView) {
                _tableView.backgroundColor = [UIColor colorWithRed:0.11 green:0.11 blue:0.12 alpha:1.0];
            }
        } else {
            self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
            if (_tableView) {
                _tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
            }
        }
    } else {
        self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
        if (_tableView) {
            _tableView.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
        }
    }
}

- (void) setupModernTextBar {
    if (!_textBarView) {
        return;
    }
    
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            _textBarView.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.18 alpha:1.0];
        } else {
            _textBarView.backgroundColor = [UIColor systemBackgroundColor];
        }
        
        // 添加顶部分隔线
        // 先移除之前的分隔线（如果存在）
        for (UIView *subview in _textBarView.subviews) {
            if ([subview isKindOfClass:[UIView class]] && subview.frame.size.height < 1.0) {
                [subview removeFromSuperview];
            }
        }
        
        UIView *separatorLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _textBarView.frame.size.width, 0.5)];
        separatorLine.backgroundColor = [UIColor separatorColor];
        separatorLine.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_textBarView addSubview:separatorLine];
        
    } else {
        // iOS 12 及以下版本
        _textBarView.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    }
}

// 添加主题变化监听
- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            [self updateBackgroundColors];
            [self setupModernTextBar];
            
            if (_textField) {
                if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                    _textField.backgroundColor = [UIColor secondarySystemBackgroundColor];
                    _textField.textColor = [UIColor labelColor];
                } else {
                    _textField.backgroundColor = [UIColor secondarySystemBackgroundColor];
                    _textField.textColor = [UIColor labelColor];
                }
            }
        }
    }
}

#pragma mark - View lifecycle

- (void) viewDidLoad {
    [super viewDidLoad];
}

- (void) setReceiverName:(NSString *)receiver andImage:(NSString *)imageName {
    MUMessageReceiverButton *receiverView = [[MUMessageReceiverButton alloc] initWithText:receiver];
    [receiverView addTarget:self action:@selector(showRecipientPicker:) forControlEvents:UIControlEventTouchUpInside];

    CGRect paddedRect = CGRectMake(0, 0, CGRectGetWidth(receiverView.frame) + 16, CGRectGetHeight(receiverView.frame));
    UIView *paddedView = [[UIView alloc] initWithFrame:paddedRect];
    [paddedView addSubview:receiverView];
    paddedRect.origin.x += 8;
    [receiverView setFrame:paddedRect];
    _textField.leftView = paddedView;

    // 现代化右侧图标
    UIImageView *imgView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:imageName]];
    if (@available(iOS 13.0, *)) {
        imgView.tintColor = [UIColor secondaryLabelColor];
        // 使用模板渲染模式以支持颜色变化
        imgView.image = [imgView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    
    CGRect paddedFrame = CGRectMake(0, 0, CGRectGetWidth(imgView.frame) + 12, CGRectGetHeight(imgView.frame));
    UIView *paddedView2 = [[UIView alloc] initWithFrame:paddedFrame];
    [paddedView2 addSubview:imgView];
    imgView.frame = CGRectMake(6, 0, imgView.frame.size.width, imgView.frame.size.height);
    _textField.rightView = paddedView2;
    _textField.rightViewMode = UITextFieldViewModeAlways;
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    // 初始化背景颜色
    [self updateBackgroundColors];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    [_tableView reloadData];
}

- (void)viewIsAppearing:(BOOL)animated {
    [super viewIsAppearing:animated];
    
    CGFloat textBarHeight = 44;
    
    UIEdgeInsets viewSafeAreaInsets = self.view.safeAreaInsets;
    
    CGFloat bottomInset = viewSafeAreaInsets.bottom;
    
    CGRect viewFrame = self.view.frame;

    CGRect tableViewFrame = CGRectMake(0, 0, viewFrame.size.width, viewFrame.size.height-textBarHeight-bottomInset);
    _tableView = [[UITableView alloc] initWithFrame:tableViewFrame style:UITableViewStylePlain];

    // 现代化背景设计
    [self updateBackgroundColors];
    
    [_tableView setSeparatorStyle:UITableViewCellSeparatorStyleNone];
    [_tableView setAutoresizingMask:UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleWidth];
    [_tableView setDelegate:self];
    [_tableView setDataSource:self];
    [self.view addSubview:_tableView];

    UISwipeGestureRecognizer *swipeGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(hideKeyboard:)];
    [swipeGesture setDirection:UISwipeGestureRecognizerDirectionDown];
    [self.view addGestureRecognizer:swipeGesture];

    swipeGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(showKeyboard:)];
    [swipeGesture setDirection:UISwipeGestureRecognizerDirectionUp];
    [self.view addGestureRecognizer:swipeGesture];

    CGRect textBarFrame = CGRectMake(0, tableViewFrame.size.height, tableViewFrame.size.width, textBarHeight);
    _textBarView = [[UIView alloc] initWithFrame:textBarFrame];
    [_textBarView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin];
    
    // 现代化文本输入栏设计
    [self setupModernTextBar];

    int textFieldMargin = 8; // 增加边距
    _textField = [[MUConsistentTextField alloc] initWithFrame:CGRectMake(textFieldMargin, textFieldMargin, tableViewFrame.size.width-2*textFieldMargin, textBarHeight-2*textFieldMargin)];
    _textField.leftViewMode = UITextFieldViewModeAlways;
    _textField.rightViewMode = UITextFieldViewModeAlways;
    _textField.borderStyle = UITextBorderStyleRoundedRect;
    
    // 现代化文本框样式
    if (@available(iOS 13.0, *)) {
        _textField.backgroundColor = [UIColor secondarySystemBackgroundColor];
        _textField.textColor = [UIColor labelColor];
        _textField.layer.cornerRadius = 18;
        _textField.layer.borderWidth = 0;
        // 设置占位符颜色
        _textField.attributedPlaceholder = [[NSAttributedString alloc] 
            initWithString:NSLocalizedString(@"Type a message...", @"Message input placeholder")
            attributes:@{NSForegroundColorAttributeName: [UIColor tertiaryLabelColor]}];
    } else {
        _textField.textColor = [UIColor blackColor];
        _textField.placeholder = NSLocalizedString(@"Type a message...", @"Message input placeholder");
    }
    
    _textField.font = [UIFont systemFontOfSize:16.0]; // 稍大的字体
    _textField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _textField.returnKeyType = UIReturnKeySend;
    [_textField setDelegate:self];
    [_textBarView addSubview:_textField];
    [self.view addSubview:_textBarView];
    
    [self setReceiverName:[[[_model connectedUser] channel] channelName] andImage:@"channelmsg"];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_textField resignFirstResponder];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void) scrollViewDidScroll:(UIScrollView *)scrollView {
    if ([[UIMenuController sharedMenuController] isMenuVisible]) {
        [[UIMenuController sharedMenuController] setMenuVisible:NO animated:YES];
    }
}

#pragma mark - Table view data source

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [_msgdb count];
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"MUMessageViewCell";
    MUMessageBubbleTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[MUMessageBubbleTableViewCell alloc] initWithReuseIdentifier:CellIdentifier];
    }

    MUTextMessage *txtMsg = [_msgdb messageAtIndex:[indexPath row]];
    [cell setHeading:[txtMsg heading]];
    [cell setMessage:[txtMsg message]];
    [cell setShownImages:[txtMsg embeddedImages]];
    [cell setDate:[txtMsg date]];
    if ([txtMsg hasAttachments]) {
        NSString *footer = nil;
        if ([txtMsg numberOfAttachments] > 1) {
            footer = [NSString stringWithFormat:NSLocalizedString(@"%li attachments", nil), (long int)[txtMsg numberOfAttachments]];
        } else {
            footer = NSLocalizedString(@"1 attachment", nil);
        }
        [cell setFooter:footer];
    } else {
        [cell setFooter:nil];
    }
    [cell setRightSide:[txtMsg isSentBySelf]];
    [cell setSelected:NO];
    [cell setDelegate:self];
    if (@available(iOS 7, *)) {
        [cell setBackgroundColor:[UIColor clearColor]];
    }
    return cell;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    MUTextMessage *txtMsg = [_msgdb messageAtIndex:[indexPath row]];
    if (txtMsg == nil)
        return 0.0f;
    NSString *footer = nil;
    if ([txtMsg hasAttachments]) {
        if ([txtMsg numberOfAttachments] > 1) {
            footer = [NSString stringWithFormat:NSLocalizedString(@"%li attachments", nil), (long int)[txtMsg numberOfAttachments]];
        } else {
            footer = NSLocalizedString(@"1 attachment", nil);
        }
    }
    return [MUMessageBubbleTableViewCell heightForCellWithHeading:[txtMsg heading] message:[txtMsg message] images:[txtMsg embeddedImages] footer:footer date:[txtMsg date]];
}

#pragma mark - UIKeyboard notifications, UIView gesture recognizer

- (void) showKeyboard:(id)sender {
    [_textField becomeFirstResponder];
}

- (void) hideKeyboard:(id)sender {
    [_textField resignFirstResponder];
}

- (void) keyboardWillShow:(NSNotification *)notification {
    NSDictionary *userInfo = [notification userInfo];
    if (_autoCorrectGuard)
        return;
    
    // Make the keyboard background completely black on iOS 7.
    if (@available(iOS 7, *)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100000), dispatch_get_main_queue(), ^{
            for (UIWindow *win in [[UIApplication sharedApplication] windows]) {
                if ([[win description] hasPrefix:@"<UITextEffectsWindow"]) {
                    UIView *possibleUIKBBackdropView = MUMessagesViewControllerFindUIView(win, @"<UIKBBackdropView");
                    if (possibleUIKBBackdropView) {
                        for (UIView *subview in [possibleUIKBBackdropView subviews]) {
                            if ([[subview description] hasPrefix:@"<UIView"]) {
                                [subview setBackgroundColor:[UIColor blackColor]];
                            }
                        }
                    }
                }
            }
        });
    }

    NSValue *val = [userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey];
    NSTimeInterval t;
    [val getValue:&t];
    
    val = [userInfo objectForKey:UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationCurve c;
    [val getValue:&c];
    
    val = [userInfo objectForKey:UIKeyboardFrameEndUserInfoKey];
    CGRect r;
    [val getValue:&r];
    r = [self.view convertRect:r fromView:nil];

    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:t];
    [UIView setAnimationCurve:c];
    _tableView.contentInset = UIEdgeInsetsMake(0.0f, 0.0f, r.size.height, 0.0f);
    _tableView.scrollIndicatorInsets = _tableView.contentInset;
    _textBarView.frame = CGRectMake(0, r.origin.y-44.0f, _tableView.frame.size.width, 44.0f);
    [UIView commitAnimations];

    if ([_msgdb count] > 0)
        [_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[_msgdb count]-1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

- (void) keyboardWillHide:(NSNotification *)notification {
    NSDictionary *userInfo = [notification userInfo];
    if (_autoCorrectGuard)
        return;
    
    NSValue *val = [userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey];
    NSTimeInterval t;
    [val getValue:&t];
    
    val = [userInfo objectForKey:UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationCurve c;
    [val getValue:&c];
    
    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationDuration:t];
    [UIView setAnimationCurve:c];
    _tableView.contentInset = UIEdgeInsetsZero;
    _tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
    _textBarView.frame = CGRectMake(0, _tableView.frame.size.height, _tableView.frame.size.width, 44.0f);
    [UIView commitAnimations];

    if ([_msgdb count] > 0)
        [_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[_msgdb count]-1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}

- (BOOL) textFieldShouldReturn:(UITextField *)textField {
    if ([[textField text] length] == 0)
        return NO;

    // Hack alert!
    _autoCorrectGuard = YES;
    [textField resignFirstResponder];
    [textField becomeFirstResponder];
    _autoCorrectGuard = NO;

    NSString *originalStr = [textField text];
    if ([originalStr length] > 0) {
        NSString *htmlText = [MUTextMessageProcessor processedHTMLFromPlainTextMessage:originalStr];
        if (htmlText != nil) {
            MKTextMessage *txtMsg = [MKTextMessage messageWithHTML:htmlText];
            NSString *destName = nil;
            if (txtMsg != nil) {
                if (_tree == nil && _channel == nil && _user == nil) {
                    [_model sendTextMessage:txtMsg toChannel:[[_model connectedUser] channel]];
                    destName = [[[_model connectedUser] channel] channelName];
                } else if (_user != nil) {
                    [_model sendTextMessage:txtMsg toUser:_user];
                    destName = [_user userName];
                } else if (_channel != nil) {
                    [_model sendTextMessage:txtMsg toChannel:_channel];
                    destName = [_channel channelName];
                } else if (_tree != nil) {
                    [_model sendTextMessage:txtMsg toTree:_tree];
                    destName = [_tree channelName];
                }
            
                if (destName != nil) {
                    [_msgdb addMessage:txtMsg withHeading:[NSString stringWithFormat:NSLocalizedString(@"To %@", @"Message recipient title"), destName] andSentBySelf:YES];
                
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[_msgdb count]-1 inSection:0];
                    [_tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
                    [_tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
                }
            }
        }
    }

    [textField setText:nil];

    return NO;
}

#pragma mark - Actions

- (void) showRecipientPicker:(id)sender {
    MUMessageRecipientViewController *recipientViewController = [[MUMessageRecipientViewController alloc] initWithServerModel:_model];
    [recipientViewController setDelegate:self];
    UINavigationController *navCtrl = [[UINavigationController alloc] initWithRootViewController:recipientViewController];

    [self presentViewController:navCtrl animated:YES completion:nil];
}

#pragma mark - MUMessageBubbleTableViewCellDelegate

- (void) messageBubbleTableViewCellRequestedCopy:(MUMessageBubbleTableViewCell *)cell {
    NSIndexPath *indexPath = [_tableView indexPathForCell:cell];
    MUTextMessage *txtMsg = [_msgdb messageAtIndex:[indexPath row]];
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    [pasteboard setValue:[txtMsg message] forPasteboardType:(NSString *) kUTTypeUTF8PlainText];
}

- (void) messageBubbleTableViewCellRequestedDeletion:(MUMessageBubbleTableViewCell *)cell {
    NSIndexPath *indexPath = [_tableView indexPathForCell:cell];
    [_msgdb clearMessageAtIndex:[indexPath row]];
    [_tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
}

- (void) messageBubbleTableViewCellRequestedAttachmentViewer:(MUMessageBubbleTableViewCell *)cell {
    NSIndexPath *indexPath = [_tableView indexPathForCell:cell];
    MUTextMessage *txtMsg = [_msgdb messageAtIndex:[indexPath row]];
    if ([txtMsg hasAttachments]) {
        [cell setSelected:YES];
        if ([[txtMsg embeddedLinks] count] > 0) {
            MUMessageAttachmentViewController *attachmentViewController = [[MUMessageAttachmentViewController alloc] initWithImages:[txtMsg embeddedImages] andLinks:[txtMsg embeddedLinks]];
            [self.navigationController pushViewController:attachmentViewController animated:YES];
        } else {
            MUImageViewController *imgViewController = [[MUImageViewController alloc] initWithImages:[txtMsg embeddedImages]];
            [self.navigationController pushViewController:imgViewController animated:YES];
        }
    }
}

#pragma mark - MUMessageRecipientTableViewControllerDelegate

- (void) messageRecipientViewController:(MUMessageRecipientViewController *)viewCtrlr didSelectChannel:(MKChannel *)channel {
    _tree = nil;
    _channel = channel;
    _user = nil;
    
    [self setReceiverName:[channel channelName] andImage:@"channelmsg"];
}

- (void) messageRecipientViewController:(MUMessageRecipientViewController *)viewCtrlr didSelectUser:(MKUser *)user {
    _tree = nil;
    _channel = nil;
    _user = user;
    
    [self setReceiverName:[user userName] andImage:@"usermsg"];
}

- (void) messageRecipientViewControllerDidSelectCurrentChannel:(MUMessageRecipientViewController *)viewCtrlr {
    _tree = nil;
    _channel = nil;
    _user = nil;

    [self setReceiverName:[[[_model connectedUser] channel] channelName] andImage:@"channelmsg"];
}

#pragma mark - MKServerModel delegate

- (void) serverModel:(MKServerModel *)model joinedServerAsUser:(MKUser *)user withWelcomeMessage:(MKTextMessage *)msg {
   [_msgdb addMessage:msg withHeading:NSLocalizedString(@"Welcome Message", @"Title for welcome message") andSentBySelf:NO];
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[_msgdb count]-1 inSection:0];
    [_tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
    if (![_tableView isDragging] && ![[UIMenuController sharedMenuController] isMenuVisible]) {
        [_tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
    }
}

- (void) serverModel:(MKServerModel *)model userMoved:(MKUser *)user toChannel:(MKChannel *)chan fromChannel:(MKChannel *)prevChan byUser:(MKUser *)mover {
    if (user == [_model connectedUser]) {
        // Are we in 'send to default channel mode'?
        if (_user == nil && _channel == nil && _tree == nil) {
            [self setReceiverName:[[[_model connectedUser] channel] channelName] andImage:@"channelmsg"];
        }
    }
}

- (void) serverModel:(MKServerModel *)model userLeft:(MKUser *)user {
    if (user == _user) {
        _user = nil;
    }

    [self setReceiverName:[[[_model connectedUser] channel] channelName] andImage:@"channelmsg"];
}

- (void) serverModel:(MKServerModel *)model channelRenamed:(MKChannel *)channel {
    if (channel == _tree) {
        [self setReceiverName:[channel channelName] andImage:@"channelmsg"];
    } else if (channel == _channel) {
         [self setReceiverName:[channel channelName] andImage:@"channelmsg"];
    } else if (_channel == nil && _tree == nil && _user == nil && [[_model connectedUser] channel] == channel) {
        [self setReceiverName:[[[_model connectedUser] channel] channelName] andImage:@"channelmsg"];
    }
}

- (void) serverModel:(MKServerModel *)model channelRemoved:(MKChannel *)channel {
    if (channel == _tree) {
        _tree = nil;
        [self setReceiverName:[[[_model connectedUser] channel] channelName] andImage:@"channelmsg"];
    } else if (channel == _channel) {
        _channel = nil;
        [self setReceiverName:[[[_model connectedUser] channel] channelName] andImage:@"channelmsg"];
    }
}

- (void) serverModel:(MKServerModel *)model textMessageReceived:(MKTextMessage *)msg fromUser:(MKUser *)user {
    NSString *heading = NSLocalizedString(@"Server Message", @"A message sent from the server itself");
    if (user != nil) {
        heading = [NSString stringWithFormat:NSLocalizedString(@"From %@", @"Message sender title"), [user userName]];
    }
    [_msgdb addMessage:msg withHeading:heading andSentBySelf:NO];
    
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[_msgdb count]-1 inSection:0];
    [_tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
    if (![_tableView isDragging] && ![[UIMenuController sharedMenuController] isMenuVisible]) {
        [_tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
    }
   
    UIApplication *app = [UIApplication sharedApplication];
    if ([app applicationState] == UIApplicationStateBackground) {
        NSMutableCharacterSet *trimSet = [[NSMutableCharacterSet alloc] init];
        [trimSet formUnionWithCharacterSet:[NSCharacterSet whitespaceCharacterSet]];
        [trimSet formUnionWithCharacterSet:[NSCharacterSet newlineCharacterSet]];
    
        NSString *msgText = [[msg plainTextString] stringByTrimmingCharactersInSet:trimSet];
        NSUInteger numImages = [[msg embeddedImages] count];
        if ([msgText length] == 0) {
            if (numImages == 0) {
                msgText = NSLocalizedString(@"(Empty body)", nil);
            } else if (numImages == 1) {
                msgText = NSLocalizedString(@"(Message with image attachment)", nil);
            } else if (numImages > 1) {
                msgText = NSLocalizedString(@"(Message with image attachments)", nil);
            }
        } else {
            msgText = [msg plainTextString];
        }
        
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.body = msgText;
        if (user) {
            content.title = [user userName];
        }
        
        UNNotificationRequest *notificationReq = [UNNotificationRequest requestWithIdentifier:@"info.mumble.Mumble.TextMessageNotification"
                                                                                     content:content
                                                                                     trigger:nil];
        [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:notificationReq withCompletionHandler:nil];
        [app setApplicationIconBadgeNumber:[app applicationIconBadgeNumber]+1];
    }
}

@end
