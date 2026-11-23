/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBInputTCPServer.h"

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import "FBKeyboard.h"
#import "FBLogger.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIApplication.h"
#import "XCUIDevice+FBHelpers.h"
#import "XCUIDevice.h"
#import "XCUIElement+FBTyping.h"

static const NSUInteger kMaxLineLength = 16 * 1024;
static const double kMaxCoordinate = 20000.0;
static const double kMaxSwipeDurationMs = 10000.0;

@interface FBInputClientState : NSObject
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, assign) BOOL authenticated;
@end

@implementation FBInputClientState
- (instancetype)init
{
  if ((self = [super init])) {
    _buffer = [NSMutableData data];
  }
  return self;
}
@end

@interface FBInputTCPServer ()
@property (nonatomic, copy) NSString *token;
@property (nonatomic, strong) NSMapTable<id, FBInputClientState *> *clients;
@end

@implementation FBInputTCPServer

- (instancetype)initWithToken:(NSString *)token
{
  if ((self = [super init])) {
    _token = [token copy];
    _clients = [NSMapTable strongToStrongObjectsMapTable];
  }
  return self;
}

#pragma mark - FBTCPSocketDelegate

- (void)didClientConnect:(nw_connection_t)newClient
{
  @synchronized (self.clients) {
    [self.clients setObject:[FBInputClientState new] forKey:newClient];
  }
  [FBLogger log:@"InputTCP: client connected"];
}

- (void)didClientDisconnect:(nw_connection_t)client
{
  @synchronized (self.clients) {
    [self.clients removeObjectForKey:client];
  }
  nw_connection_cancel(client);
  [FBLogger log:@"InputTCP: client disconnected"];
}

- (void)client:(nw_connection_t)client didReceiveData:(NSData *)data
{
  NSMutableArray<NSData *> *lines = [NSMutableArray array];
  BOOL overflow = NO;
  FBInputClientState *state;
  @synchronized (self.clients) {
    state = [self.clients objectForKey:client];
    if (nil == state) {
      return;
    }
    [state.buffer appendData:data];
    while (YES) {
      NSRange newline = [state.buffer rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                          options:0
                                            range:NSMakeRange(0, state.buffer.length)];
      if (newline.location == NSNotFound) {
        break;
      }
      [lines addObject:[state.buffer subdataWithRange:NSMakeRange(0, newline.location)]];
      [state.buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
    }
    overflow = state.buffer.length > kMaxLineLength;
  }
  if (overflow) {
    [FBLogger log:@"InputTCP: line too long, closing the connection"];
    [self didClientDisconnect:client];
    return;
  }
  for (NSData *line in lines) {
    if (line.length == 0 || line.length > kMaxLineLength) {
      continue;
    }
    if (![self handleLine:line state:state client:client]) {
      [self didClientDisconnect:client];
      return;
    }
  }
}

#pragma mark - Dispatch

/// Returns NO when the connection must be closed.
- (BOOL)handleLine:(NSData *)line state:(FBInputClientState *)state client:(nw_connection_t)client
{
  id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
  if (![object isKindOfClass:NSDictionary.class]) {
    return state.authenticated;
  }
  NSDictionary *msg = object;
  NSString *type = [msg[@"type"] isKindOfClass:NSString.class] ? msg[@"type"] : nil;
  if (nil == type) {
    return state.authenticated;
  }

  if (!state.authenticated) {
    NSString *token = [msg[@"token"] isKindOfClass:NSString.class] ? msg[@"token"] : @"";
    if (![type isEqualToString:@"auth"] || ![self isToken:token]) {
      [FBLogger log:@"InputTCP: authentication failed"];
      return NO;
    }
    state.authenticated = YES;
    return YES;
  }

  if ([type isEqualToString:@"info"]) {
    [self sendInfoToClient:client];
    return YES;
  }

  // XCTest event synthesis needs the main thread.
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([type isEqualToString:@"tap"]) {
      [self handleTap:msg];
    } else if ([type isEqualToString:@"swipe"]) {
      [self handleSwipe:msg];
    } else if ([type isEqualToString:@"button"]) {
      [self handleButton:msg];
    } else if ([type isEqualToString:@"keys"]) {
      [self handleKeys:msg];
    } else if ([type isEqualToString:@"typeKey"]) {
      [self handleTypeKey:msg];
    }
  });
  return YES;
}

- (BOOL)isToken:(NSString *)candidate
{
  NSData *a = [candidate dataUsingEncoding:NSUTF8StringEncoding];
  NSData *b = [self.token dataUsingEncoding:NSUTF8StringEncoding];
  const uint8_t *x = a.bytes;
  const uint8_t *y = b.bytes;
  NSUInteger diff = a.length ^ b.length;
  for (NSUInteger i = 0; i < b.length; i++) {
    diff |= (i < a.length ? x[i] : 0) ^ y[i];
  }
  return diff == 0;
}

- (void)sendInfoToClient:(nw_connection_t)client
{
  FBTCPSocket *socket = self.socket;
  if (nil == socket) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    // The frame of the foreground app is in the points of its current interface orientation,
    // which is the coordinate space the synthesized touches use.
    XCUIApplication *app = XCUIApplication.fb_activeApplication;
    CGSize size = app.frame.size;
    NSDictionary *info = @{@"width": @(size.width),
                           @"height": @(size.height),
                           @"scale": @(UIScreen.mainScreen.scale),
                           @"orientation": @((NSInteger)app.interfaceOrientation)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
    NSMutableData *reply = [json mutableCopy];
    [reply appendBytes:"\n" length:1];
    [socket writeData:reply toClient:client];
  });
}

#pragma mark - Validation

/// Reads a finite, bounded number; returns NO when it is missing or out of range.
static BOOL FBReadNumber(NSDictionary *msg, NSString *key, double min, double max, double *out)
{
  id value = msg[key];
  if (![value isKindOfClass:NSNumber.class]) {
    return NO;
  }
  double number = [value doubleValue];
  if (!isfinite(number) || number < min || number > max) {
    return NO;
  }
  *out = number;
  return YES;
}

/// A touch event record in the interface orientation the sender last saw (1-4), or the foreground app's.
static XCSynthesizedEventRecord *FBMakeRecord(NSString *name, NSDictionary *msg)
{
  double orientation = 0;
  if (!FBReadNumber(msg, @"orientation", 1, 4, &orientation)) {
    orientation = (double)XCUIApplication.fb_activeApplication.interfaceOrientation;
  }
  return [[XCSynthesizedEventRecord alloc] initWithName:name interfaceOrientation:(long long)orientation];
}

#pragma mark - Handlers

- (void)handleTap:(NSDictionary *)msg
{
  double x, y;
  if (!FBReadNumber(msg, @"x", 0, kMaxCoordinate, &x) || !FBReadNumber(msg, @"y", 0, kMaxCoordinate, &y)) {
    return;
  }
  XCSynthesizedEventRecord *record = FBMakeRecord(@"MyPhone tap", msg);
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(x, y) offset:0.0];
  [path liftUpAtOffset:0.05];
  [record addPointerEventPath:path];
  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    [FBLogger logFmt:@"InputTCP: tap failed: %@", error.localizedDescription];
  }
}

- (void)handleSwipe:(NSDictionary *)msg
{
  double fromX, fromY, toX, toY;
  if (!FBReadNumber(msg, @"fromX", 0, kMaxCoordinate, &fromX) ||
      !FBReadNumber(msg, @"fromY", 0, kMaxCoordinate, &fromY) ||
      !FBReadNumber(msg, @"toX", 0, kMaxCoordinate, &toX) ||
      !FBReadNumber(msg, @"toY", 0, kMaxCoordinate, &toY)) {
    return;
  }
  double durationMs = 200.0;
  if (msg[@"duration"] && !FBReadNumber(msg, @"duration", 1, kMaxSwipeDurationMs, &durationMs)) {
    return;
  }
  double duration = durationMs / 1000.0;
  XCSynthesizedEventRecord *record = FBMakeRecord(@"MyPhone swipe", msg);
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:CGPointMake(fromX, fromY) offset:0.0];
  [path moveToPoint:CGPointMake(toX, toY) atOffset:duration];
  [path liftUpAtOffset:duration + 0.01];
  [record addPointerEventPath:path];
  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    [FBLogger logFmt:@"InputTCP: swipe failed: %@", error.localizedDescription];
  }
}

- (void)handleButton:(NSDictionary *)msg
{
  NSString *name = [msg[@"name"] isKindOfClass:NSString.class] ? msg[@"name"] : nil;
  if (nil == name || name.length > 32) {
    return;
  }
  NSError *error;
  if (![XCUIDevice.sharedDevice fb_pressButton:name forDuration:nil error:&error]) {
    [FBLogger logFmt:@"InputTCP: button '%@' failed: %@", name, error.localizedDescription];
  }
}

- (void)handleKeys:(NSDictionary *)msg
{
  NSArray *value = [msg[@"value"] isKindOfClass:NSArray.class] ? msg[@"value"] : nil;
  if (value.count == 0 || value.count > 256) {
    return;
  }
  for (id item in value) {
    if (![item isKindOfClass:NSString.class]) {
      return;
    }
  }
  NSString *text = [value componentsJoinedByString:@""];
  NSError *error;
  if (!FBTypeText(text, 60, &error)) {
    // Never log the text itself.
    [FBLogger logFmt:@"InputTCP: typing failed: %@", error.localizedDescription];
  }
}

- (void)handleTypeKey:(NSDictionary *)msg
{
#if (!TARGET_OS_TV && __clang_major__ >= 15)
  NSString *keyName = [msg[@"key"] isKindOfClass:NSString.class] ? msg[@"key"] : nil;
  if (nil == keyName || keyName.length > 32) {
    return;
  }
  double flags = 0;
  if (msg[@"modifierFlags"] && !FBReadNumber(msg, @"modifierFlags", 0, 0xFFFF, &flags)) {
    return;
  }
  NSString *keyValue = [FBKeyboard keyValueForName:keyName] ?: keyName;
  [XCUIApplication.fb_activeApplication typeKey:keyValue modifierFlags:(XCUIKeyModifierFlags)(NSUInteger)flags];
#endif
}

@end
