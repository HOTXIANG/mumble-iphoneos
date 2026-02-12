// Copyright 2009-2012 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import <TargetConditionals.h>
#if TARGET_OS_IOS

@interface MUImage : NSObject
+ (UIImage *) tableViewCellImageFromImage:(UIImage *)srcImage;
+ (UIImage *) imageNamed:(NSString *)imageName;
+ (UIImage *) clearColorImage;
@end

#endif // TARGET_OS_IOS
