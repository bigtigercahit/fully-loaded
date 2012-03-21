//
//  FullyLoaded.m
//  FullyLoaded
//
//  Created by Anoop Ranganath on 1/1/11.
//  Copyright 2011 Anoop Ranganath. All rights reserved.
//
//  
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//  
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//  
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.


#import "FullyLoaded.h"
#import "SynthesizeSingleton.h"


// users can define their own concurrency rules
#ifndef kFullyLoadedMaxConnections
#define kFullyLoadedMaxConnections 2
#endif


#if FullyLoadedErrorLog
#define FLError(...) NSLog(@"FullyLoaded error: " __VA_ARGS__)
#else
#define FLError(...) ((void)0)
#endif

#if FullyLoadedVerboseLog
#define FLLog(...) NSLog(@"FullyLoaded: " __VA_ARGS__)
#else
#define FLLog(...) ((void)0)
#endif


static NSString * const FLIdleRunloopNotification = @"FLIdleRunloopNotification";


// encapsulates the result created in the urlQueue thread to pass to main thread. 
@interface FLResponse : NSObject

@property (nonatomic, retain) NSURL *url;
@property (nonatomic, retain) UIImage *image;
@property (nonatomic, retain) NSData *data;
@property (nonatomic, retain) NSError *error;

@end


@implementation FLResponse

@synthesize
url     = _url,
image   = _image,
data    = _data,
error   = _error;


- (void)dealloc {
    
    self.url = nil;
    self.image = nil;
    self.data = nil;
    self.error = nil;
    
    [super dealloc];
}

@end


@interface FullyLoaded()

@property (nonatomic, retain) NSString *imageCachePath;
@property (nonatomic, retain) NSMutableDictionary *imageCache;  // maps urls to images
@property (nonatomic, retain) NSMutableArray *urlQueue;         // urls that have not yet been requested
@property (nonatomic, retain) NSMutableSet *pendingURLSet;      // urls in the queue, plus requested urls
@property (nonatomic, retain) NSOperationQueue *responseQueue;  // operation queue for NSURLConnection

@property (nonatomic) int connectionCount; // number of connected urls
@property (nonatomic) BOOL suspended;

- (void)dequeueNextURL;

- (void)cacheImage:(UIImage *)image data:(NSData *)data url:(NSURL *)url;
- (UIImage *)cachedImageForURL:(NSURL *)url;
- (void)handleResponse:(FLResponse *)response;

@end


@implementation FullyLoaded

SYNTHESIZE_SINGLETON_FOR_CLASS(FullyLoaded);

@synthesize
imageCachePath  = _imageCachePath,
imageCache      = _imageCache,
urlQueue        = _urlQueue,
pendingURLSet   = _pendingURLSet,
responseQueue   = _responseQueue,
connectionCount = _connectionCount,
suspended       = _suspended;


// clear cache on launch for debugging
#if 0
+ (void)initialize {
    [[self sharedFullyLoaded] clearCache];
}
#endif


- (void)dealloc {
    self.imageCachePath = nil;
    self.imageCache = nil;
    self.urlQueue = nil;
    self.pendingURLSet = nil;
    self.responseQueue = nil;
    [super dealloc];
}


- (id)init {
    self = [super init];
    if (self) {
        self.imageCachePath     = [NSTemporaryDirectory() stringByAppendingPathComponent:@"images"];
        self.imageCache         = [NSMutableDictionary dictionary];
        self.urlQueue           = [NSMutableArray array];
        self.pendingURLSet      = [NSMutableSet set];
        self.responseQueue      = [[NSOperationQueue new] autorelease];
        
        NSNotificationCenter *c = [NSNotificationCenter defaultCenter];
        
        // listen for the idle notification to resume downloads
        [c addObserver:self selector:@selector(resume) name:FLIdleRunloopNotification object:nil];
        
        // note (itsbonczek): iOS sometimes removes old files from /tmp while the app is suspended. When a UIImage loses
        // it's file data, it will try to attempt to restore it from disk. However, if the image happens to have been
        // deleted, UIImage can't restore itself and UIImageView will end up showing a black image. To combat this
        // we delete the in-memory cache whenever the app is backgrounded.
        [c addObserver:self
              selector:@selector(clearMemoryCache)
                  name:UIApplicationDidEnterBackgroundNotification
                object:nil];
    }
    return self;
}


#pragma mark - FullyLoaded


- (BOOL)connectionsAvailable {
    return self.connectionCount < kFullyLoadedMaxConnections;
}


- (NSString *)pathForURL:(NSURL*)url {
    NSString *hostPath = [self.imageCachePath stringByAppendingPathComponent:url.host];
    return [hostPath stringByAppendingPathComponent:url.path];	
}


// principal caching operation: first write to disk, then store in dictionary
// data is passed as a separate argument for efficiency, in the case where we already have data and image objects
- (void)cacheImage:(UIImage *)image data:(NSData *)data url:(NSURL *)url {
    
    NSString *path = [self pathForURL:url];
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSError *error = nil;
    
    [self.imageCache setObject:image forKey:url];
    FLLog(@"cached:          %@", url);
    
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    
    if (error) {
        FLError(@"creating directory: %@\n%@", dir, error);
        return;
    }
    
    [data writeToFile:path options:NSDataWritingAtomic error:&error];
    
    if (error) {
        FLError(@"writing to file: %@\n%@", path, error);
    }
}


- (void)fetchURL:(NSURL *)url {
    
    NSAssert(url, @"nil url");
    
    NSURLRequest *request = [[[NSURLRequest alloc] initWithURL:url] autorelease];
    
    // preflight check
    if (![NSURLConnection canHandleRequest:request]) {
        // handle error now so that the caller is in the same stack (helps debugging with breakpoints)
        FLResponse *r =[[FLResponse new] autorelease];
        r.url = url;
        // not sure what we could do here to be more descriptive
        // perhaps a 
        r.error = [NSError errorWithDomain:NSURLErrorDomain
                                      code:NSURLErrorUnknown
                                  userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                            @"NSURLConnection cannot handle request",   NSLocalizedDescriptionKey,
                                            url,                                        @"url",
                                            nil]];
        [self handleResponse:r];
        return;
    }
    
    [NSURLConnection sendAsynchronousRequest:request
                                       queue:self.responseQueue
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
                               
                               // TODO: catch exceptions and convert to errors?
                               @autoreleasepool {
                                   FLResponse *r = [[FLResponse new] autorelease];
                                   
                                   // save the original url; response.URL might be a redirect, or nil on error
                                   r.url = url;
                                   r.error = error;
                                   r.data = data;
                                   
                                   if (!r.error) {
                                       r.image = [UIImage imageWithData:r.data];
                                   }
                                   
                                   [self performSelectorOnMainThread:@selector(handleResponse:)
                                                          withObject:r
                                                       waitUntilDone:NO];
                               }
                           }];    
}


- (void)fetchOrEnqueueURL:(NSURL *)url {
    
    NSAssert(![self.pendingURLSet containsObject:url], @"pendingURLSet already contains url: %@", url);
    
    [self.pendingURLSet addObject:url];
    
    if (self.connectionsAvailable) {
        [self fetchURL:url];
    }
    else {
        [self.urlQueue addObject:url];
    }
}


- (void)dequeueNextURL {
    
    NSAssert(self.connectionsAvailable, @"exceeded max connection count: %d", self.connectionCount);
    
    if (!self.urlQueue.count) return;
    
    NSURL *url = [self.urlQueue lastObject]; // FILO: last request is most likely to be still relevant
    [url retain];
    [self.urlQueue removeLastObject];
    [self fetchURL:url];
    [url release];
}


- (void)handleResponse:(FLResponse *)response {
    
    NSAssert(response.url, @"nil url"); // matches assertion in fetchURL
    
    if (response.error) {
        FLError(@"connection: %@\n%@", response.url, response.error);
    }
    else if (!response.image) {
        // although the download completed, the imageWithData call failed; perhaps bad/damaged image on server
        FLError(@"nil image: %@", response.url);
    }
    else {
        [self cacheImage:response.image data:response.data url:response.url];
        [[NSNotificationCenter defaultCenter] postNotificationName:FLImageLoadedNotification object:response.url];
    }
    
    [self.pendingURLSet removeObject:response.url];
    [self dequeueNextURL];
}


- (void)clearMemoryCache {
    FLLog(@"clearing memory cache");
    [self.imageCache removeAllObjects];
}


- (void)clearCache {
    [self clearMemoryCache];
    
    FLLog(@"clearing disk cache");
    
    NSFileManager *m = [NSFileManager defaultManager];
    
    if (![m fileExistsAtPath:self.imageCachePath]) {
        FLLog(@"no existing disk cache");
        return;
    }
    
    NSError *error = nil;
    [m removeItemAtPath:self.imageCachePath error:&error];
    
    if (error) {
        FLError(@"could not clear disk cache: %@", error);
    }
}


- (void)suspend {
    FLLog(@"suspend");
    
    self.suspended = YES;
    self.responseQueue.suspended = YES;
    
    // whenever the run loop becomes idle, this notification will get posted, and the queue will resume downloading
    NSNotification *n = [NSNotification notificationWithName:FLIdleRunloopNotification object:self];
    [[NSNotificationQueue defaultQueue] enqueueNotification:n postingStyle:NSPostWhenIdle];	
}


// called manually or in response to the idle run loop notification
- (void)resume {
    FLLog(@"resume");
    
    self.suspended = NO;
    self.responseQueue.suspended = NO;
    
    if (self.connectionsAvailable) {
        [self dequeueNextURL];
    }
}


- (UIImage *)cachedImageForURL:(NSURL *)url {
        
    if (!url) {
        FLLog(@"nil url");
        return nil;
    }
    
    UIImage *image = [self.imageCache objectForKey:url];
    if (image) {
        FLLog(@"from memory:     %@", url);
        return image;
    }
    
    image = [UIImage imageWithContentsOfFile:[self pathForURL:url]];
    
    if (image) {
        FLLog(@"from disk:       %@", url);
        [self.imageCache setObject:image forKey:url];
        return image;
    }
    
    return nil;
}


- (UIImage *)imageForURL:(NSURL *)url {
        
    if (!url) {
        FLLog(@"nil url");
        return nil;
    }
    
    UIImage *image = [self cachedImageForURL:url];
    if (image) {
        return image;
    }
    
    if (![self.pendingURLSet containsObject:url]) {
        [self fetchOrEnqueueURL:url];
    }
    return nil;
}


// MARK: cache insertion


- (void)cacheImage:(UIImage *)image forURL:(NSURL *)url {
    [self cacheImage:image data:UIImageJPEGRepresentation(image, 0.8f) url:url];
}


// MARK: url string wrappers


- (UIImage *)imageForURLString:(NSString *)urlString {
    return [self imageForURL:[NSURL URLWithString:urlString]];
}


- (UIImage *)cachedImageForURLString:(NSString *)urlString {
    return [self cachedImageForURL:[NSURL URLWithString:urlString]];
}


- (void)cacheImage:(UIImage *)image forURLString:(NSString *)urlString {
    [self cacheImage:image forURL:[NSURL URLWithString:urlString]];
}




@end
