//
//  SQRLDownloadOperation.m
//  Squirrel
//
//  Created by Keith Duncan on 25/09/2013.
//  Copyright (c) 2013 GitHub. All rights reserved.
//

#import "SQRLDownloadOperation.h"

#import "EXTKeyPathCoding.h"
#import "EXTScope.h"

#import "SQRLDownloadController.h"
#import "SQRLResumableDownload.h"

@interface SQRLDownloadOperation () <NSURLConnectionDataDelegate>
@property (atomic, assign) BOOL isExecuting;
@property (atomic, assign) BOOL isFinished;

// Request the operation was initialised with
@property (nonatomic, copy, readonly) NSURLRequest *request;

// Serial queue for managing operation state
@property (nonatomic, strong, readonly) NSOperationQueue *controlQueue;

// Download controller for resumable state
@property (nonatomic, strong, readonly) SQRLDownloadController *downloadController;
// Download retrieved from the download controller, resume state
@property (nonatomic, strong) SQRLResumableDownload *download;

// Connection to retreive the remote object
@property (nonatomic, strong) NSURLConnection *connection;

// Latest response received from connection
@property (nonatomic, strong) NSURLResponse *response;

@property (readwrite, copy, atomic) NSURL * (^completionProvider)(NSURLResponse **, NSError **);
@end

@implementation SQRLDownloadOperation

- (instancetype)initWithRequest:(NSURLRequest *)request downloadController:(SQRLDownloadController *)downloadController {
	NSParameterAssert(request != nil);
	NSParameterAssert(downloadController != nil);

	self = [self init];
	if (self == nil) return nil;

	_request = [request copy];

	_controlQueue = [[NSOperationQueue alloc] init];
	_controlQueue.maxConcurrentOperationCount = 1;
	_controlQueue.name = @"com.github.Squirrel.SQRLDownloadOperation.controlQueue";

	_downloadController = downloadController;

	_completionProvider = [^ NSURL * (NSURLResponse **responseProvider, NSError **errorRef) {
		if (errorRef != NULL) *errorRef = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
		return nil;
	} copy];

	return self;
}

- (NSURL *)completionProvider:(NSURLResponse **)responseRef error:(NSError **)errorRef {
	return self.completionProvider(responseRef, errorRef);
}

#pragma mark Operation

- (BOOL)isConcurrent {
	return YES;
}

- (void)start {
	[self.controlQueue addOperationWithBlock:^{
		if (self.isCancelled) {
			[self finish];
			return;
		}

		[self willChangeValueForKey:@keypath(self, isExecuting)];
		self.isExecuting = YES;
		[self didChangeValueForKey:@keypath(self, isExecuting)];

		[self startDownload];
	}];
}

- (void)cancel {
	[super cancel];

	[self.controlQueue addOperationWithBlock:^{
		if (self.connection == nil) return;

		[self finish];
	}];
}

- (void)finish {
	[self.connection cancel];

	[self willChangeValueForKey:@keypath(self, isExecuting)];
	self.isExecuting = NO;
	[self didChangeValueForKey:@keypath(self, isExecuting)];

	[self willChangeValueForKey:@keypath(self, isFinished)];
	self.isFinished = YES;
	[self didChangeValueForKey:@keypath(self, isFinished)];
}

- (void)completeWithError:(NSError *)error {
	self.completionProvider = ^ NSURL * (NSURLResponse **responseRef, NSError **errorRef) {
		if (errorRef != NULL) *errorRef = error;
		return nil;
	};
	[self finish];
}

#pragma mark Download

- (void)startDownload {
	NSError *error = nil;
	self.download = [self.downloadController downloadForRequest:self.request error:&error];
	if (self.download == nil) {
		[self completeWithError:error];
		return;
	}

	[self startRequest:[self.class requestWithOriginalRequest:self.request download:self.download]];
}

+ (NSURLRequest *)requestWithOriginalRequest:(NSURLRequest *)originalRequest download:(SQRLResumableDownload *)download {
	NSHTTPURLResponse *response = download.response;
	NSString *ETag = [self ETagFromResponse:response];
	if (ETag == nil) return originalRequest;

	NSURL *downloadLocation = download.fileURL;

	NSNumber *alreadyDownloadedSize = nil;
	NSError *alreadyDownloadedSizeError = nil;
	BOOL getAlreadyDownloadedSize = [downloadLocation getResourceValue:&alreadyDownloadedSize forKey:NSURLFileSizeKey error:&alreadyDownloadedSizeError];
	if (!getAlreadyDownloadedSize) return originalRequest;

	NSMutableURLRequest *newRequest = [originalRequest mutableCopy];
	[newRequest setValue:ETag forHTTPHeaderField:@"If-Range"];
	[newRequest setValue:[NSString stringWithFormat:@"%llu-", alreadyDownloadedSize.unsignedLongLongValue] forHTTPHeaderField:@"Range"];
	return newRequest;
}

+ (NSString *)ETagFromResponse:(NSHTTPURLResponse *)response {
	NSDictionary *headers = response.allHeaderFields;
	for (NSString *header in headers) {
		if ([header caseInsensitiveCompare:@"ETag"] != NSOrderedSame) continue;
		return headers[header];
	}
	return nil;
}

- (void)startRequest:(NSURLRequest *)request {
	self.connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
	self.connection.delegateQueue = self.controlQueue;
	[self.connection start];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	[self completeWithError:error];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	self.response = response;

	// Can only resume HTTP responses which indicate whether we can resume
	if (![response isKindOfClass:NSHTTPURLResponse.class]) {
		[self removeDownloadFile];
		return;
	}

	NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

	/*
		First truncate the file if necessary, then record the new ETag.

		This ensures old data doesn't get associated with a new ETag if we were
		to crash between setting the ETag and clearing the file.
	 */

	if (httpResponse.statusCode == /* OK */ 200) {
		[self removeDownloadFile];
	} else if (httpResponse.statusCode == /* Partial Content */ 206) {
		// This is the response we need to know we can append to our already
		// downloaded bytes, great success!
	}

	[self recordDownloadWithResponse:httpResponse];
}

- (void)recordDownloadWithResponse:(NSHTTPURLResponse *)response {
	SQRLResumableDownload *newDownload = [[SQRLResumableDownload alloc] initWithResponse:response fileURL:self.download.fileURL];

	[self.downloadController setDownload:newDownload forRequest:self.request];
	self.download = newDownload;
}

- (void)removeDownloadFile {
	NSError *error = nil;
	BOOL remove = [NSFileManager.defaultManager removeItemAtURL:self.download.fileURL error:&error];
	if (!remove) {
		if (![error.domain isEqualToString:NSCocoaErrorDomain] || error.code != NSFileNoSuchFileError) {
			[self completeWithError:error];
		}

		return;
	}
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
	NSOutputStream *outputStream = [NSOutputStream outputStreamWithURL:self.download.fileURL append:YES];

	[outputStream open];
	@onExit {
		[outputStream close];
	};

	uint8_t const *bytes = data.bytes;
	size_t length = data.length;
	while (1) {
		NSInteger written = [outputStream write:bytes maxLength:length];
		if (written == -1) {
			NSError *streamError = outputStream.streamError;
			if ([streamError.domain isEqualToString:NSPOSIXErrorDomain] && streamError.code == EINTR) continue;

			[self completeWithError:streamError];
			return;
		}

		if ((NSUInteger)written == length) {
			return;
		}

		bytes += written;
		length -= written;
	}
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	NSURLResponse *response = self.response;
	NSURL *localURL = self.download.fileURL;

	self.completionProvider = ^ NSURL * (NSURLResponse **responseRef, NSError **errorRef) {
		if (responseRef != NULL) *responseRef = response;
		return localURL;
	};
	[self finish];
}

@end
