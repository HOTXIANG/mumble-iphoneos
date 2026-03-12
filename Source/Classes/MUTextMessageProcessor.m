// Copyright 2013 The 'Mumble for iOS' Developers. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#import "MUTextMessageProcessor.h"

static NSString *MUEscapeHTMLText(NSString *string) {
    if (string == nil) {
        return @"";
    }
    NSMutableString *result = [NSMutableString stringWithString:string];
    [result replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [result length])];
    [result replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [result length])];
    [result replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [result length])];
    return result;
}

static NSString *MUEscapeHTMLTextPreservingNewlines(NSString *string) {
    NSString *escaped = MUEscapeHTMLText(string);
    return [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"<br />"];
}

static NSString *MUEscapeHTMLAttribute(NSString *string) {
    NSMutableString *result = [NSMutableString stringWithString:MUEscapeHTMLText(string)];
    [result replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, [result length])];
    return result;
}

@implementation MUTextMessageProcessor

// processedHTMLFromPlainTextMessage converts the plain text-formatted text message
// in plain to a HTML message that can be sent to another Mumble client.
+ (NSString *) processedHTMLFromPlainTextMessage:(NSString *)plain {
    // Use NSDataDetectors to detect any links in the message and
    // automatically convert them to <a>-tags.
    NSError *err = nil;
    NSDataDetector *linkDetector = [NSDataDetector dataDetectorWithTypes:(NSTextCheckingTypeLink &NSTextCheckingAllSystemTypes) error:&err];
    if (err == nil && linkDetector != nil) {
        NSMutableString *output = [NSMutableString stringWithCapacity:[plain length]*2];
        NSArray *matches = [linkDetector matchesInString:plain options:0 range:NSMakeRange(0, [plain length])];
        NSUInteger lastIndex = 0;
        
        [output appendString:@"<p>"];

        for (NSTextCheckingResult *match in matches) {
            NSRange urlRange = [match range];
            NSRange beforeUrlRange = NSMakeRange(lastIndex, urlRange.location-lastIndex);

            // Extract the string that is in front of the URL part and output
            // it to 'output'.
            NSString *beforeURL = [plain substringWithRange:beforeUrlRange];
            if (beforeURL == nil) {
                return nil;
            }
            [output appendString:MUEscapeHTMLTextPreservingNewlines(beforeURL)];
            
            // Extract the URL and format it as a HTML a-tag.
            NSString *url = [plain substringWithRange:urlRange];
            NSString *anchor = [NSString stringWithFormat:@"<a href=\"%@\">%@</a>", MUEscapeHTMLAttribute(url), MUEscapeHTMLText(url)];
            if (anchor == nil) {
                return nil;
            }
            [output appendString:anchor];

            // Update the lastIndex to keep track of 
            lastIndex = urlRange.location + urlRange.length;
        }

        // Ensure that any remaining parts of the string are added to the output buffer.
        NSString *lastChunk = [plain substringWithRange:NSMakeRange(lastIndex, [plain length]-lastIndex)];
        if (lastChunk == nil) {
            return nil;
        }
        [output appendString:MUEscapeHTMLTextPreservingNewlines(lastChunk)];

        [output appendString:@"</p>"];

        return output;
    }
    
    return [NSString stringWithFormat:@"<p>%@</p>", MUEscapeHTMLTextPreservingNewlines(plain)];
}

@end
