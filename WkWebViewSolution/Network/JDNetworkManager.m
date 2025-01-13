//
//  JDNetworkManager.m
//  JDBJDModule
/*
 MIT License

Copyright (c) 2022 JD.com, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
 */

#import "JDNetworkManager.h"
#import "JDSafeDictionary.h"
#import <WebKit/Webkit.h>
@interface JDNetworkCallBackWorker ()
@property (nonatomic, copy) JDNetResponseCallback responseCallback;
@property (nonatomic, copy) JDNetDataCallback dataCallback;
@property (nonatomic, copy) JDNetSuccessCallback successCallback;
@property (nonatomic, copy) JDNetFailCallback failCallback;
@property (nonatomic, copy) JDNetRedirectCallback redirectCallback;
@property (nonatomic, copy) JDNetProgressCallBack progressCallBack;
@end
@implementation JDNetworkCallBackWorker
- (instancetype)initWithResponseCallback:(JDNetResponseCallback)responseCallback
                            dataCallback:(JDNetDataCallback)dataCallback
                         successCallback:(JDNetSuccessCallback)successCallback
                            failCallback:(JDNetFailCallback)failCallback
                        redirectCallback:(JDNetRedirectCallback)redirectCallback {
    self = [super init];
    if (self) {
        _responseCallback = responseCallback;
        _dataCallback = dataCallback;
        _successCallback = successCallback;
        _failCallback = failCallback;
        _redirectCallback = redirectCallback;
    }
    return self;
}
@end

@interface JDNetworkManager ()<NSURLSessionTaskDelegate, NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *URLSession;
@property (nonatomic, strong) NSOperationQueue *requestCallbackQueue;
@property (nonatomic, strong) JDSafeDictionary *taskToCallBackWorkerMap;
@property (nonatomic, strong) JDSafeDictionary *taskidToDataTaskMap;
@end

@implementation JDNetworkManager

+ (void)start {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        __unused JDNetworkManager *manager = [JDNetworkManager shareManager];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
        __unused NSOperationQueue *operationQueue = manager.requestCallbackQueue;
        __unused JDSafeDictionary *operationMap = manager.taskToCallBackWorkerMap;
        __unused JDSafeDictionary *dataTaskMap = manager.taskidToDataTaskMap;
#pragma clang diagnostic pop
    });
}

+ (instancetype)shareManager {
    static JDNetworkManager *_shareManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _shareManager = [[JDNetworkManager alloc] init];
    });
    return _shareManager;
}

- (void)configURLSession:(NSURLSessionConfiguration *)urlSessionConfiguration {
    urlSessionConfiguration.HTTPShouldUsePipelining = YES;
    urlSessionConfiguration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _URLSession = [NSURLSession sessionWithConfiguration:urlSessionConfiguration
                                                delegate:self
                                           delegateQueue:self.requestCallbackQueue];
}

- (void)cancelWithRequestIdentifier:(RequestTaskIdentifier)requestTaskIdentifier {
    if (requestTaskIdentifier < 0) {
        return;
    }
    
    [self.taskToCallBackWorkerMap removeObjectForKey:@(requestTaskIdentifier)];
    NSURLSessionDataTask *dataTask = [self.taskidToDataTaskMap objectForKey:@(requestTaskIdentifier)];
    if (dataTask) {
        [dataTask cancel];
        [self.taskidToDataTaskMap removeObjectForKey:@(requestTaskIdentifier)];
    }
    
}

- (RequestTaskIdentifier)startWithRequest:(NSURLRequest *)request
                         responseCallback:(JDNetResponseCallback)responseCallback
                             dataCallback:(JDNetDataCallback)dataCallback
                          successCallback:(JDNetSuccessCallback)successCallback
                             failCallback:(JDNetFailCallback)failCallback
                         redirectCallback:(JDNetRedirectCallback)redirectCallback {
    return [self startWithRequest:request
                 responseCallback:responseCallback
                 progressCallBack:nil
                     dataCallback:dataCallback
                  successCallback:successCallback
                     failCallback:failCallback
                 redirectCallback:redirectCallback];
}


- (RequestTaskIdentifier)startWithRequest:(NSURLRequest *)request
                         responseCallback:(JDNetResponseCallback)responseCallback
                         progressCallBack:(JDNetProgressCallBack)progressCallBack
                             dataCallback:(JDNetDataCallback)dataCallback
                          successCallback:(JDNetSuccessCallback)successCallback
                             failCallback:(JDNetFailCallback)failCallback
                         redirectCallback:(JDNetRedirectCallback)redirectCallback {

    if (!self.URLSession) {
        @synchronized (self) {
            [self configURLSession:[NSURLSessionConfiguration defaultSessionConfiguration]];
        }
    }

    NSURLSessionDataTask *dataTask = [self.URLSession dataTaskWithRequest:request];
    JDNetworkCallBackWorker *cbworker = [[JDNetworkCallBackWorker alloc]
                                         initWithResponseCallback:responseCallback
                                         dataCallback:dataCallback
                                         successCallback:successCallback
                                         failCallback:failCallback
                                         redirectCallback:redirectCallback];
    cbworker.progressCallBack = progressCallBack;
    [self.taskToCallBackWorkerMap setObject:cbworker forKey:@(dataTask.taskIdentifier)];
    [self.taskidToDataTaskMap setObject:dataTask forKey:@(dataTask.taskIdentifier)];
    [dataTask resume];
    return dataTask.taskIdentifier;
    
}

#pragma mark - lazy

- (NSOperationQueue *)requestCallbackQueue {
    if (!_requestCallbackQueue) {
        _requestCallbackQueue = [NSOperationQueue new];
        _requestCallbackQueue.maxConcurrentOperationCount = 1;
        _requestCallbackQueue.name = @"com.jd.networkcallback";
    }
    return _requestCallbackQueue;
}

- (JDSafeDictionary *)taskToCallBackWorkerMap {
    if (!_taskToCallBackWorkerMap) {
        _taskToCallBackWorkerMap = [JDSafeDictionary new];
    }
    return _taskToCallBackWorkerMap;
}

- (JDSafeDictionary *)taskidToDataTaskMap {
    if (!_taskidToDataTaskMap) {
        _taskidToDataTaskMap = [JDSafeDictionary new];
    }
    return _taskidToDataTaskMap;
}

#pragma mark - <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSHTTPURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler{
    [self syncCookieToWKWithResponse:response];
    JDNetworkCallBackWorker *cbworker = [self.taskToCallBackWorkerMap objectForKey:@(dataTask.taskIdentifier)];
    if (cbworker) {
        cbworker.responseCallback(response);
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data{
    JDNetworkCallBackWorker *cbworker = [self.taskToCallBackWorkerMap objectForKey:@(dataTask.taskIdentifier)];
    if (cbworker) {
        cbworker.dataCallback(data);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error{
    JDNetworkCallBackWorker *cbworker = [self.taskToCallBackWorkerMap objectForKey:@(task.taskIdentifier)];
    if (!cbworker) return;
    if (error) {
        cbworker.failCallback(error);
    } else {
        cbworker.successCallback();
    }
    
    [self.taskToCallBackWorkerMap removeObjectForKey:@(task.taskIdentifier)];
    [self.taskidToDataTaskMap removeObjectForKey:@(task.taskIdentifier)];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler{
    [self syncCookieToWKWithResponse:response];
    JDNetworkCallBackWorker *cbworker = [self.taskToCallBackWorkerMap objectForKey:@(task.taskIdentifier)];
    void(^redirectDecisionCallback)(BOOL) = ^(BOOL canPass) {
        if (canPass) {
            completionHandler(request);
        } else {
            [task cancel];
        }
    };
    if (cbworker) {
        cbworker.redirectCallback(response, request, [redirectDecisionCallback copy]);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend{
    JDNetworkCallBackWorker *cbworker = [self.taskToCallBackWorkerMap objectForKey:@(task.taskIdentifier)];
    if (cbworker.progressCallBack) {
        cbworker.progressCallBack(task.countOfBytesSent,task.countOfBytesExpectedToSend);
    }
}

-(void)syncCookieToWKWithResponse:(NSHTTPURLResponse *)response {
    NSArray <NSHTTPCookie *>*responseCookies = [NSHTTPCookie cookiesWithResponseHeaderFields:[response allHeaderFields] forURL:response.URL];
    if ([responseCookies isKindOfClass:[NSArray class]] && responseCookies.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [responseCookies enumerateObjectsUsingBlock:^(NSHTTPCookie * _Nonnull cookie, NSUInteger idx, BOOL * _Nonnull stop) {
                // 同步到WKWebView
                if (@available(iOS 11.0, *)) {
                    [[WKWebsiteDataStore defaultDataStore].httpCookieStore setCookie:cookie completionHandler:nil];
                } else {
                    // Fallback on earlier versions
                }
            }];
        });
    }
}

@end
