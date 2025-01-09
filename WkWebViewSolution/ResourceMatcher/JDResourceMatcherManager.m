//
//  JDSchemeHandleManager.m
//  JDHybrid
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

#import "JDResourceMatcherManager.h"
#import "JDUtils.h"
#import "JDNetworkResourceMatcher.h"
#import "JDPreloadHtmlMatcher.h"
#import "JDResourceMatcherIterator.h"
#import <os/lock.h>
#import "JDUtils.h"

@interface JDResourceMatcherManager ()<JDResourceMatcherIteratorProtocol, JDResourceMatcherIteratorDataSource>

@property(nonatomic, strong) JDResourceMatcherIterator *iterator;

@property(nonatomic, strong) JDNetworkResourceMatcher *defaultNetworkResourceMatcher;

@end

@implementation JDResourceMatcherManager{
    os_unfair_lock _taskMaplock;
    NSHashTable *_taskHashTable;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _taskMaplock = OS_UNFAIR_LOCK_INIT;
        _taskHashTable = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

#pragma mark - WKURLSchemeHandler
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask API_AVAILABLE(ios(LimitVersion)){
    os_unfair_lock_lock(&_taskMaplock);
    [_taskHashTable addObject:urlSchemeTask];
    os_unfair_lock_unlock(&_taskMaplock);
    
    JDCacheLog(@"Hybrid拦截到，url: %@", urlSchemeTask.request.URL.absoluteString);
    [self.iterator startWithUrlSchemeTask:urlSchemeTask];
}


- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask API_AVAILABLE(ios(LimitVersion)){
    os_unfair_lock_lock(&_taskMaplock);
    [_taskHashTable removeObject:urlSchemeTask];
    os_unfair_lock_unlock(&_taskMaplock);
}

#pragma mark - JDResourceMatcherIteratorProtocol
- (void)didReceiveResponse:(NSURLResponse *)response urlSchemeTask:(nonnull id<WKURLSchemeTask>)urlSchemeTask {
    if (![self isAliveWithURLSchemeTask:urlSchemeTask]) {
        return;
    }
    @try {
        JDCacheLog(@"Hybrid返回response，url: %@", urlSchemeTask.request.URL.absoluteString);
        [urlSchemeTask didReceiveResponse:response];
    } @catch (NSException *exception) {} @finally {}
}

- (void)didReceiveData:(NSData *)data urlSchemeTask:(nonnull id<WKURLSchemeTask>)urlSchemeTask{
    if (![self isAliveWithURLSchemeTask:urlSchemeTask]) {
        return;
    }
    @try {
        JDCacheLog(@"Hybrid返回data，length: %ld, url: %@", data.length, urlSchemeTask.request.URL.absoluteString);
        [urlSchemeTask didReceiveData:data];
    } @catch (NSException *exception) {} @finally {}
}

- (void)didFinishWithUrlSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask{
    if (![self isAliveWithURLSchemeTask:urlSchemeTask]) {
        return;
    }
    @try {
        JDCacheLog(@"Hybrid返回Finish，url: %@", urlSchemeTask.request.URL.absoluteString);
        [urlSchemeTask didFinish];
    } @catch (NSException *exception) {} @finally {}
}

- (void)didFailWithError:(NSError *)error urlSchemeTask:(nonnull id<WKURLSchemeTask>)urlSchemeTask{
    if (![self isAliveWithURLSchemeTask:urlSchemeTask]) {
        return;
    }
    @try {
        JDCacheLog(@"Hybrid返回error，url: %@", urlSchemeTask.request.URL.absoluteString);
        [urlSchemeTask didFailWithError:error];
    } @catch (NSException *exception) {} @finally {}
}

- (void)didRedirectWithResponse:(NSURLResponse *)response newRequest:(NSURLRequest *)redirectRequest redirectDecision:(JDNetRedirectDecisionCallback)redirectDecisionCallback urlSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    if (![JDUtils isEqualURLA:urlSchemeTask.request.mainDocumentURL.absoluteString withURLB:response.URL.absoluteString]) {
        redirectDecisionCallback(YES);
        return;
    }
    redirectDecisionCallback(NO);
    if ([self isAliveWithURLSchemeTask:urlSchemeTask]){
        NSString *s1 = @"didPerform";
        NSString *s2 = @"Redirection:";
        NSString *s3 = @"newRequest:";
        SEL sel = NSSelectorFromString([NSString stringWithFormat:@"_%@%@%@", s1, s2, s3]);
        if ([urlSchemeTask respondsToSelector:sel]) {
            @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [urlSchemeTask performSelector:sel withObject:response withObject:redirectRequest];
#pragma clang diagnostic pop
            } @catch (NSException *exception) {
            } @finally {}
        }
    }
    [self redirectWithRequest:redirectRequest];
}

#pragma mark - JDResourceMatcherIteratorDataSource
- (nonnull NSArray<id<JDResourceMatcherImplProtocol>> *)liveResMatchers {
    NSMutableArray *matchersM = [NSMutableArray arrayWithCapacity:0];
    if ([self.delegate respondsToSelector:@selector(liveMatchers)]) {
        NSArray *customMatchers = [self.delegate liveMatchers];
        if (JDValidArr(customMatchers)) {
            [matchersM addObjectsFromArray:customMatchers];
        }
    }
    [matchersM addObject:self.defaultNetworkResourceMatcher];
    return [matchersM copy];
}


// 判断urlSchemeTask是否被释放
- (BOOL)isAliveWithURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    BOOL urlSchemeTaskAlive = NO;
    @try {
        os_unfair_lock_lock(&_taskMaplock);
        urlSchemeTaskAlive = [_taskHashTable containsObject:urlSchemeTask];
        os_unfair_lock_unlock(&_taskMaplock);
    } @catch (NSException *exception) {
        JDCacheLog(@"isAliveWithURLSchemeTask 执行异常");
    } @finally {}
    return urlSchemeTaskAlive;
}

- (void)redirectWithRequest:(NSURLRequest *)redirectRequest {
    if ([self.delegate respondsToSelector:@selector(redirectWithRequest:)]) {
        [self.delegate redirectWithRequest:redirectRequest];
    }
}

- (JDResourceMatcherIterator *)iterator {
    if (!_iterator) {
        _iterator = [[JDResourceMatcherIterator alloc] init];
        _iterator.iteratorDelagate = self;
        _iterator.iteratorDataSource = self;
    }
    return _iterator;
}

- (JDNetworkResourceMatcher *)defaultNetworkResourceMatcher {
    if (!_defaultNetworkResourceMatcher) {
        _defaultNetworkResourceMatcher = [JDNetworkResourceMatcher new];
    }
    return _defaultNetworkResourceMatcher;
}

@end
