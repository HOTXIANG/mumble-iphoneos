#if TARGET_OS_IOS
// Copyright 2009-2010 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUCertificateCreationProgressView.h"
#import "MUImage.h"
#import "MUColor.h"

@interface MUCertificateCreationProgressView () {
    UIImageView                       *_backgroundImage;
    UIActivityIndicatorView           *_activityIndicator;
    UILabel                           *_nameLabel;
    UILabel                           *_emailLabel;
    UILabel                           *_pleaseWaitLabel;
    
    NSString                          *_identityName;
    NSString                          *_emailAddress;
    id                                 _delegate;
}
@end

@implementation MUCertificateCreationProgressView

- (id) initWithName:(NSString *)name email:(NSString *)email {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _identityName = name;
        _emailAddress = email;
    }
    return self;
}

- (void) loadView {
    UIView *rootView = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    rootView.backgroundColor = [UIColor systemBackgroundColor];

    _backgroundImage = [[UIImageView alloc] initWithFrame:CGRectZero];
    _backgroundImage.translatesAutoresizingMaskIntoConstraints = NO;
    _backgroundImage.contentMode = UIViewContentModeScaleAspectFill;
    [rootView addSubview:_backgroundImage];

    UIStackView *stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.alignment = UIStackViewAlignmentCenter;
    stackView.spacing = 12.0;
    stackView.layoutMarginsRelativeArrangement = YES;
    stackView.layoutMargins = UIEdgeInsetsMake(24.0, 24.0, 24.0, 24.0);
    [rootView addSubview:stackView];

    if (@available(iOS 13.0, *)) {
        _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    } else {
        _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    }
    _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    [stackView addArrangedSubview:_activityIndicator];

    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _nameLabel.textAlignment = NSTextAlignmentCenter;
    _nameLabel.numberOfLines = 0;
    [stackView addArrangedSubview:_nameLabel];

    _emailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _emailLabel.textAlignment = NSTextAlignmentCenter;
    _emailLabel.numberOfLines = 0;
    _emailLabel.textColor = [UIColor secondaryLabelColor];
    [stackView addArrangedSubview:_emailLabel];

    _pleaseWaitLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _pleaseWaitLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pleaseWaitLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _pleaseWaitLabel.textAlignment = NSTextAlignmentCenter;
    _pleaseWaitLabel.numberOfLines = 0;
    [stackView addArrangedSubview:_pleaseWaitLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_backgroundImage.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
        [_backgroundImage.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
        [_backgroundImage.topAnchor constraintEqualToAnchor:rootView.topAnchor],
        [_backgroundImage.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
        [stackView.centerXAnchor constraintEqualToAnchor:rootView.centerXAnchor],
        [stackView.centerYAnchor constraintEqualToAnchor:rootView.centerYAnchor],
        [stackView.leadingAnchor constraintGreaterThanOrEqualToAnchor:rootView.leadingAnchor constant:24.0],
        [stackView.trailingAnchor constraintLessThanOrEqualToAnchor:rootView.trailingAnchor constant:-24.0],
    ]];

    self.view = rootView;
}

- (void) viewDidLoad {
    [super viewDidLoad];

    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        [self.view setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    }

    // fixme(mkrautz): This is esentially what a MUBackgroundView does.
    if (@available(iOS 7, *)) {
        _backgroundImage.backgroundColor = [MUColor backgroundViewiOS7Color];
    } else {
        _backgroundImage.image = [MUImage imageNamed:@"BackgroundTextureBlackGradient"];
    }
    
    // Unset text shadows for iOS 7.
    if (@available(iOS 7, *)) {
        _nameLabel.shadowOffset = CGSizeZero;
        _emailLabel.shadowOffset = CGSizeZero;
        _pleaseWaitLabel.shadowOffset = CGSizeZero;
    }
}

- (void) viewWillAppear:(BOOL)animated {
    [[self navigationItem] setTitle:NSLocalizedString(@"Generating Certificate", @"Title for certificate generator view controller")];
    [[self navigationItem] setHidesBackButton:YES];

    [_nameLabel setText:_identityName];

    if (_emailAddress != nil && _emailAddress.length > 0) {
        [_emailLabel setText:[NSString stringWithFormat:@"<%@>", _emailAddress]];
    } else {
        [_emailLabel setText:nil];
    }

    [_pleaseWaitLabel setText:NSLocalizedString(@"Please Wait...", @"'Please Wait' text for certificate generation")];
    [_activityIndicator startAnimating];
}

@end
#endif // TARGET_OS_IOS
