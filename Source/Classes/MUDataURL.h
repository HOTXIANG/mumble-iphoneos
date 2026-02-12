// Copyright 2009-2012 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

@interface MUDataURL : NSObject
+ (NSData *) dataFromDataURL:(NSString *)dataURL;
#if TARGET_OS_IOS
+ (UIImage *) imageFromDataURL:(NSString *)dataURL;
#endif
@end
