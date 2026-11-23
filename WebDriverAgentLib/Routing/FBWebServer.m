/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBWebServer.h"

#import "FBHTTPServer.h"
#if !TARGET_OS_WATCH
#import "FBInputTCPServer.h"
#endif
#import "FBMjpegServer.h"
#import "FBTCPSocket.h"

#import "FBCommandHandler.h"
#import "FBCommandStatus.h"
#import "FBErrorBuilder.h"
#import "FBExceptionHandler.h"
#import "FBResponsePayload.h"
#import "FBRouteRequest.h"
#import "FBRuntimeUtils.h"
#import "FBSession.h"
#import "FBUnknownCommands.h"
#import "FBConfiguration.h"
#import "FBLogger.h"

#import "XCUIDevice+FBHelpers.h"

static NSString *const FBServerURLBeginMarker = @"ServerURLHere->";
static NSString *const FBServerURLEndMarker = @"<-ServerURLHere";

@interface FBWebServer ()
@property (nonatomic, strong) FBExceptionHandler *exceptionHandler;
@property (nonatomic, strong) FBHTTPServer *server;
@property (nonatomic, nullable) FBTCPSocket *screenshotsBroadcaster;
@property (nonatomic, nullable, strong) FBMjpegServer *mjpegServer;
@property (nonatomic, nullable) FBTCPSocket *inputSocket;
#if !TARGET_OS_WATCH
@property (nonatomic, nullable, strong) FBInputTCPServer *inputServer;
#endif
@property (atomic, assign) BOOL keepAlive;
@end

@implementation FBWebServer

- (void)dealloc
{
  [self stopScreenshotsBroadcaster];
}

+ (NSArray<Class<FBCommandHandler>> *)collectCommandHandlerClasses
{
  NSArray *handlersClasses = FBClassesThatConformsToProtocol(@protocol(FBCommandHandler));
  NSMutableArray *handlers = [NSMutableArray array];
  for (Class aClass in handlersClasses) {
    if ([aClass respondsToSelector:@selector(shouldRegisterAutomatically)]) {
      if (![aClass shouldRegisterAutomatically]) {
        continue;
      }
    }
    [handlers addObject:aClass];
  }
  return handlers.copy;
}

- (void)startServing
{
  [FBLogger logFmt:@"Built at %s %s", __DATE__, __TIME__];
  self.exceptionHandler = [FBExceptionHandler new];
  if (![self startHTTPServer]) {
    return;
  }
  [self initScreenshotsBroadcaster];
  [self initInputServer];

  self.keepAlive = YES;
  NSRunLoop *runLoop = [NSRunLoop mainRunLoop];
  while (self.keepAlive &&
         [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
}

- (BOOL)startHTTPServer
{
  self.server = [[FBHTTPServer alloc] init];
  [self.server setRouteQueue:dispatch_get_main_queue()];
  [self.server setDefaultHeader:@"Server" value:@"WebDriverAgent/1.0"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Origin" value:@"*"];
  [self.server setDefaultHeader:@"Access-Control-Allow-Headers" value:@"Content-Type, X-Requested-With"];

  [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(sessionWasKilled:)
                                              name:FBSessionWasKilledNotification
                                            object:nil];

  [self registerRouteHandlers:[self.class collectCommandHandlerClasses]];
  [self registerServerKeyRouteHandlers];

  NSRange serverPortRange = FBConfiguration.sharedInstance.bindingPortRange;
  NSString *bindingIP = FBConfiguration.sharedInstance.bindingIPAddress;
  if (bindingIP != nil) {
    [self.server setInterface:bindingIP];
    [FBLogger logFmt:@"Using custom binding IP address: %@", bindingIP];
  }

  NSError *error;
  BOOL serverStarted = NO;

  for (NSUInteger index = 0; index < serverPortRange.length; index++) {
    NSInteger port = serverPortRange.location + index;
    [self.server setPort:(UInt16)port];

    serverStarted = [self attemptToStartServer:self.server onPort:port withError:&error];
    if (serverStarted) {
      break;
    }

    [FBLogger logFmt:@"Failed to start web server on port %ld with error %@", (long)port, [error description]];
  }

  if (!serverStarted) {
    [FBLogger logFmt:@"Last attempt to start web server failed with error %@", [error description]];
    id<FBWebServerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(webServer:didFailToStartWithError:)]) {
      [delegate webServer:self didFailToStartWithError:(NSError * _Nonnull)error];
      return NO;
    }
    abort();
  }

  NSString *serverHost = bindingIP ?: ([XCUIDevice sharedDevice].fb_wifiIPAddress ?: @"127.0.0.1");
  [FBLogger logFmt:@"%@http://%@:%d%@", FBServerURLBeginMarker, serverHost, [self.server port], FBServerURLEndMarker];
  return YES;
}

- (void)initScreenshotsBroadcaster
{
  [self readMjpegSettingsFromEnv];
  self.mjpegServer = [[FBMjpegServer alloc] init];
  self.screenshotsBroadcaster = [[FBTCPSocket alloc]
                                 initWithPort:(uint16_t)FBConfiguration.sharedInstance.mjpegServerPort];
  // Bind to the same address as the HTTP server when USE_IP is set.
  // nil (the default) keeps listening on all interfaces.
  self.screenshotsBroadcaster.interface = FBConfiguration.sharedInstance.bindingIPAddress;
  self.mjpegServer.socket = self.screenshotsBroadcaster;
  self.screenshotsBroadcaster.delegate = self.mjpegServer;
  NSError *error;
  if (![self.screenshotsBroadcaster startWithError:&error]) {
    [FBLogger logFmt:@"Cannot init screenshots broadcaster service on port %@. Original error: %@", @(FBConfiguration.sharedInstance.mjpegServerPort), error.description];
    [self.mjpegServer stopStreaming];
    self.mjpegServer = nil;
    self.screenshotsBroadcaster = nil;
  }
}

/**
 Optional low-latency input channel used by MyPhone for Mac. Only started when the
 MYPHONE_INPUT_TOKEN environment variable is set; it is bound to 127.0.0.1 only
 (MYPHONE_INPUT_PORT, default 9300).
 */
- (void)initInputServer
{
#if !TARGET_OS_WATCH
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *token = env[@"MYPHONE_INPUT_TOKEN"];
  if (token.length < 16) {
    return;
  }
  NSInteger port = [env[@"MYPHONE_INPUT_PORT"] integerValue] ?: 9300;
  if (port <= 0 || port > UINT16_MAX) {
    return;
  }
  self.inputServer = [[FBInputTCPServer alloc] initWithToken:token];
  self.inputSocket = [[FBTCPSocket alloc] initWithPort:(uint16_t)port];
  self.inputSocket.interface = @"127.0.0.1";
  self.inputServer.socket = self.inputSocket;
  self.inputSocket.delegate = self.inputServer;
  NSError *error;
  if (![self.inputSocket startWithError:&error]) {
    [FBLogger logFmt:@"Cannot start the input server on port %ld. Original error: %@", (long)port, error.description];
    [self stopInputServer];
    return;
  }
  [FBLogger logFmt:@"MyPhone input server listening on 127.0.0.1:%ld", (long)port];
#endif
}

- (void)stopInputServer
{
  self.inputSocket.delegate = nil;
  [self.inputSocket stop];
  self.inputSocket = nil;
#if !TARGET_OS_WATCH
  self.inputServer = nil;
#endif
}

- (void)stopScreenshotsBroadcaster
{
  if (nil == self.screenshotsBroadcaster) {
    self.mjpegServer = nil;
    return;
  }

  id<FBTCPSocketDelegate> delegate = self.screenshotsBroadcaster.delegate;
  if ([(NSObject *)delegate respondsToSelector:@selector(stopStreaming)]) {
    [(FBMjpegServer *)delegate stopStreaming];
  }
  self.screenshotsBroadcaster.delegate = nil;
  [self.screenshotsBroadcaster stop];
  self.screenshotsBroadcaster = nil;
  self.mjpegServer = nil;
}

- (void)readMjpegSettingsFromEnv
{
  NSDictionary *env = NSProcessInfo.processInfo.environment;
  NSString *scalingFactor = [env objectForKey:@"MJPEG_SCALING_FACTOR"];
  if (scalingFactor != nil && [scalingFactor length] > 0) {
    FBConfiguration.sharedInstance.mjpegScalingFactor = [scalingFactor floatValue];
  }
  NSString *screenshotQuality = [env objectForKey:@"MJPEG_SERVER_SCREENSHOT_QUALITY"];
  if (screenshotQuality != nil && [screenshotQuality length] > 0) {
    FBConfiguration.sharedInstance.mjpegServerScreenshotQuality = [screenshotQuality integerValue];
  }
}

- (void)sessionWasKilled:(NSNotification *)notification
{
  FBSession *session = notification.object;
  if (![session isKindOfClass:FBSession.class]) {
    return;
  }
  // Same "invalid session id" shape a still-queued request would eventually get anyway, once
  // -routeQueue drains and FBRoute.decorateRequest: finds the session gone - just delivered now
  // instead of after however long the request would otherwise have been stuck waiting.
  NSString *message = [NSString stringWithFormat:@"Session %@ was deleted while this request was still pending", session.identifier];
  id<FBResponsePayload> payload = FBResponseWithStatus([FBCommandStatus noSuchDriverErrorWithMessage:message
                                                                                            traceback:nil]);
  RouteResponse *response = [RouteResponse new];
  [payload dispatchWithResponse:response];
  [self.server abandonPendingRequestsForSessionID:session.identifier withResponse:response];
}

- (void)stopServing
{
  [NSNotificationCenter.defaultCenter removeObserver:self name:FBSessionWasKilledNotification object:nil];
  [FBSession.activeSession kill];
  [self stopScreenshotsBroadcaster];
  [self stopInputServer];
  if (self.server.isRunning) {
    [self.server stop:NO];
  }
  self.server = nil;
  self.exceptionHandler = nil;
  self.keepAlive = NO;
}

- (BOOL)attemptToStartServer:(FBHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
{
  server.port = (UInt16)port;
  NSError *innerError = nil;
  BOOL started = [server start:&innerError];
  if (!started) {
    if (!error) {
      return NO;
    }

    NSString *description = @"Unknown Error when Starting server";
    if ([innerError.domain isEqualToString:NSPOSIXErrorDomain] && innerError.code == EADDRINUSE) {
      description = [NSString stringWithFormat:@"Unable to start web server on port %ld", (long)port];
    }
    return
    [[[[FBErrorBuilder builder]
       withDescription:description]
      withInnerError:innerError]
     buildError:error];
  }
  return YES;
}

- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses
{
  __weak typeof(self) weakSelf = self;
  for (Class<FBCommandHandler> commandHandler in commandHandlerClasses) {
    NSArray *routes = [commandHandler routes];
    for (FBRoute *route in routes) {
      [self.server handleMethod:route.verb withPath:route.path standalone:route.isStandalone block:^(RouteRequest *request, RouteResponse *response) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (nil == strongSelf) {
          return;
        }
        NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:request.body options:NSJSONReadingMutableContainers error:NULL];
        FBRouteRequest *routeParams = [FBRouteRequest
          routeRequestWithURL:request.url
          parameters:request.params
          arguments:arguments ?: @{}
        ];

        [FBLogger verboseLog:routeParams.description];

        @try {
          [route mountRequest:routeParams intoResponse:response];
        }
        @catch (NSException *exception) {
          [strongSelf handleException:exception forResponse:response];
        }
      }];
    }
  }
}

- (void)handleException:(NSException *)exception forResponse:(RouteResponse *)response
{
  [self.exceptionHandler handleException:exception forResponse:response];
}

- (void)registerServerKeyRouteHandlers
{
  [self.server handleMethod:@"GET" withPath:@"/health" standalone:YES block:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"<!DOCTYPE html><html><title>Health Check</title><body><p>I-AM-ALIVE</p></body></html>"];
  }];

  // Deprecated: no longer needed since appium-xcuitest-driver handles calibration
  // itself (https://github.com/appium/appium-xcuitest-driver/pull/2948). Kept for
  // backward compatibility; will be removed in a future major release.
  NSString *calibrationPage = @"<html>"
  "<title>{\"x\":null,\"y\":null}</title>"
  "<header>"
  "<script>document.addEventListener(\"click\",function(e){document.title=JSON.stringify({x:e.clientX,y:e.clientY})})</script>"
  "</header>"
  "</html>";
  [self.server get:@"/calibrate" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [FBLogger logFmt:@"The /calibrate endpoint is deprecated and will be removed in a future release"];
    [response respondWithString:calibrationPage];
  }];

  __weak typeof(self) weakSelf = self;
  [self.server get:@"/wda/shutdown" withBlock:^(RouteRequest *request, RouteResponse *response) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (nil == strongSelf) {
      return;
    }
    [response respondWithString:@"Shutting down"];
    // Deferred so the "Shutting down" response is written to the client before
    // webServerDidRequestShutdown: tears down the server's socket out from under it.
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf.delegate webServerDidRequestShutdown:strongSelf];
    });
  }];

  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
