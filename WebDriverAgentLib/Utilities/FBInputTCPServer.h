/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * Derived from the TCP input server in https://github.com/Alexintosh/WebDriverAgent
 * (BSD), reworked for upstream's FBTCPSocket, with loopback binding, token
 * authentication and input validation added.
 */

#import <Foundation/Foundation.h>

#import "FBTCPSocket.h"

NS_ASSUME_NONNULL_BEGIN

/**
 Low-latency input channel for MyPhone for Mac.

 Listens on 127.0.0.1 only (the USB tunnel delivers connections as loopback
 connections) and reads newline-delimited JSON. The first line of every
 connection must be {"type":"auth","token":"<token>"} with the token given in
 the MYPHONE_INPUT_TOKEN environment variable. Later lines:

   {"type":"tap","x":N,"y":N}
   {"type":"swipe","fromX":N,"fromY":N,"toX":N,"toY":N,"duration":ms}
   {"type":"button","name":"home|volumeUp|volumeDown|..."}
   {"type":"keys","value":["text"]}
   {"type":"typeKey","key":"name","modifierFlags":N}
   {"type":"info"}   -> replies with one JSON line: {"width","height","scale"}

 Input messages are fire-and-forget: no reply is sent.
 */
@interface FBInputTCPServer : NSObject <FBTCPSocketDelegate>

/**
 @param token The shared secret. Must be non-empty.
 */
- (instancetype)initWithToken:(NSString *)token;

/// The socket that owns this instance as its delegate; needed for the info reply.
@property (nonatomic, weak, nullable) FBTCPSocket *socket;

@end

NS_ASSUME_NONNULL_END
