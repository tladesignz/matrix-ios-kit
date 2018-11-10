/*
 Copyright 2015 OpenMarket Ltd
 Copyright 2018 New Vector Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXKAttachment.h"

#import "MXMediaManager.h"
#import "MXKTools.h"
#import "MXEncryptedAttachments.h"

#import <MobileCoreServices/MobileCoreServices.h>

// The size of thumbnail we request from the server
// Note that this is smaller than the ones we upload: when sending, one size
// must fit all, including the web which will want relatively high res thumbnails.
// We, however, are a mobile client and so would prefer smaller thumbnails, which
// we can have if they're being generated by the media repo.
static const int kThumbnailWidth = 320;
static const int kThumbnailHeight = 240;

NSString *const kMXKAttachmentErrorDomain = @"kMXKAttachmentErrorDomain";

@interface MXKAttachment ()
{
    /**
     The information on the encrypted content.
     */
    MXEncryptedContentFile *contentFile;
    
    /**
     The information on the encrypted thumbnail.
     */
    MXEncryptedContentFile *thumbnailFile;
    
    /**
     Observe Attachment download
     */
    id onAttachmentDownloadObs;
    
    /**
     The local path used to store the attachment with its original name
     */
    NSString *documentCopyPath;
    
    /**
     The attachment mimetype.
     */
    NSString *mimetype;
}

@end

@interface MXKAttachment ()
@property (nonatomic) MXSession *sess __attribute__((deprecated("Use [contentURL] instead")));
@end

@implementation MXKAttachment

- (instancetype)initWithEvent:(MXEvent*)event andMediaManager:(MXMediaManager*)mediaManager
{
    self = [super init];
    if (self)
    {
        _mediaManager = mediaManager;
        
        // Make a copy as the data can be read at anytime later
        _eventId = event.eventId;
        _eventRoomId = event.roomId;
        _eventSentState = event.sentState;
        
        NSDictionary *eventContent = event.content;
        
        // Set default thumbnail orientation
        _thumbnailOrientation = UIImageOrientationUp;
        
        if (event.eventType == MXEventTypeSticker)
        {
            _type = MXKAttachmentTypeSticker;
            MXJSONModelSetDictionary(_thumbnailInfo, eventContent[@"info"][@"thumbnail_info"]);
        }
        else
        {
            // Note: mxEvent.eventType is supposed to be MXEventTypeRoomMessage here.
            NSString *msgtype = eventContent[@"msgtype"];
            if ([msgtype isEqualToString:kMXMessageTypeImage])
            {
                _type = MXKAttachmentTypeImage;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeAudio])
            {
                _type = MXKAttachmentTypeAudio;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeVideo])
            {
                _type = MXKAttachmentTypeVideo;
                MXJSONModelSetDictionary(_thumbnailInfo, eventContent[@"info"][@"thumbnail_info"]);
            }
            else if ([msgtype isEqualToString:kMXMessageTypeLocation])
            {
                // Not supported yet
                // _type = MXKAttachmentTypeLocation;
                return nil;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeFile])
            {
                _type = MXKAttachmentTypeFile;
            }
            else
            {
                return nil;
            }
        }
        
        MXJSONModelSetString(_originalFileName, eventContent[@"body"]);
        MXJSONModelSetDictionary(_contentInfo, eventContent[@"info"]);
        MXJSONModelSetMXJSONModel(contentFile, MXEncryptedContentFile, eventContent[@"file"]);
        
        // Retrieve the content url by taking into account the potential encryption.
        if (contentFile)
        {
            _isEncrypted = YES;
            _contentURL = contentFile.url;
            
            MXJSONModelSetMXJSONModel(thumbnailFile, MXEncryptedContentFile, _contentInfo[@"thumbnail_file"]);
        }
        else
        {
            _isEncrypted = NO;
            MXJSONModelSetString(_contentURL, eventContent[@"url"]);
        }
        
        mimetype = nil;
        if (_contentInfo)
        {
            MXJSONModelSetString(mimetype, _contentInfo[@"mimetype"]);
        }
        
        _cacheFilePath = [MXMediaManager cachePathForMatrixContentURI:_contentURL andType:mimetype inFolder:_eventRoomId];
        _downloadId = [MXMediaManager downloadIdForMatrixContentURI:_contentURL inFolder:_eventRoomId];
        
        // Deduce the thumbnail information from the retrieved data.
        _mxcThumbnailURI = [self getThumbnailURI];
        _thumbnailMimeType = [self getThumbnailMimeType];
        _thumbnailCachePath = [self getThumbnailCachePath];
        _thumbnailDownloadId = [self getThumbnailDownloadId];
    }
    return self;
}

- (instancetype)initWithEvent:(MXEvent *)mxEvent andMatrixSession:(MXSession*)mxSession
{
    self = [super init];
    self.sess = mxSession;
    if (self)
    {
        _mediaManager = mxSession.mediaManager;
        // Make a copy as the data can be read at anytime later
        _eventId = mxEvent.eventId;
        _eventRoomId = mxEvent.roomId;
        _eventSentState = mxEvent.sentState;
        
        NSDictionary *eventContent = mxEvent.content;
        
        // Set default thumbnail orientation
        _thumbnailOrientation = UIImageOrientationUp;
        
        if (mxEvent.eventType == MXEventTypeSticker)
        {
            _type = MXKAttachmentTypeSticker;
            MXJSONModelSetDictionary(_thumbnailInfo, eventContent[@"info"][@"thumbnail_info"]);
        }
        else
        {
            // Note: mxEvent.eventType is supposed to be MXEventTypeRoomMessage here.
            NSString *msgtype = eventContent[@"msgtype"];
            if ([msgtype isEqualToString:kMXMessageTypeImage])
            {
                _type = MXKAttachmentTypeImage;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeAudio])
            {
                _type = MXKAttachmentTypeAudio;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeVideo])
            {
                _type = MXKAttachmentTypeVideo;
                MXJSONModelSetDictionary(_thumbnailInfo, eventContent[@"info"][@"thumbnail_info"]);
            }
            else if ([msgtype isEqualToString:kMXMessageTypeLocation])
            {
                // Not supported yet
                // _type = MXKAttachmentTypeLocation;
                return nil;
            }
            else if ([msgtype isEqualToString:kMXMessageTypeFile])
            {
                _type = MXKAttachmentTypeFile;
            }
            else
            {
                return nil;
            }
        }
        
        MXJSONModelSetString(_originalFileName, eventContent[@"body"]);
        MXJSONModelSetDictionary(_contentInfo, eventContent[@"info"]);
        MXJSONModelSetMXJSONModel(thumbnailFile, MXEncryptedContentFile, _contentInfo[@"thumbnail_file"]);
        MXJSONModelSetMXJSONModel(contentFile, MXEncryptedContentFile, eventContent[@"file"]);
        
        // Retrieve the content url by taking into account the potential encryption.
        if (contentFile)
        {
            _isEncrypted = YES;
            _contentURL = contentFile.url;
        }
        else
        {
            _isEncrypted = NO;
            MXJSONModelSetString(_contentURL, eventContent[@"url"]);
        }
        
        // Note: When the attachment uploading is in progress, the upload id is stored in the content url (nasty trick).
        // Check whether the attachment is currently uploading.
        if ([_contentURL hasPrefix:kMXMediaUploadIdPrefix])
        {
            // In this case we consider the upload id as the absolute url.
            _actualURL = _contentURL;
        }
        else
        {
            // Prepare the absolute URL from the mxc: content URL
            _actualURL = [mxSession.matrixRestClient urlOfContent:_contentURL];
        }
        
        mimetype = nil;
        if (_contentInfo)
        {
            MXJSONModelSetString(mimetype, _contentInfo[@"mimetype"]);
        }
        
        _cacheFilePath = [MXMediaManager cachePathForMatrixContentURI:_contentURL andType:mimetype inFolder:_eventRoomId];
        _downloadId = [MXMediaManager downloadIdForMatrixContentURI:_contentURL inFolder:_eventRoomId];
        
        // Deduce the thumbnail information from the retrieved data.
        _thumbnailURL = [self getThumbnailUrlForSize:CGSizeMake(kThumbnailWidth, kThumbnailHeight)];
        _thumbnailMimeType = [self getThumbnailMimeType];
        _thumbnailCachePath = [self getThumbnailCachePath];
        _cacheThumbnailPath = _thumbnailCachePath;
        _thumbnailDownloadId = [self getThumbnailDownloadId];
    }
    return self;
}

- (void)dealloc
{
    [self destroy];
}

- (void)destroy
{
    if (onAttachmentDownloadObs)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadObs];
        onAttachmentDownloadObs = nil;
    }
    
    // Remove the temporary file created to prepare attachment sharing
    if (documentCopyPath)
    {
        [[NSFileManager defaultManager] removeItemAtPath:documentCopyPath error:nil];
        documentCopyPath = nil;
    }
    
    _previewImage = nil;
}

// TODO: MEDIA: Remove this deprecated method "getThumbnailUrlForSize:"
- (NSString *)getThumbnailUrlForSize:(CGSize)size
{
    if (thumbnailFile && thumbnailFile.url)
    {
        // there's an encrypted thumbnail: we just return the mxc url
        // since it will have to be decrypted before downloading anyway,
        // so the URL is really just a key into the cache.
        return thumbnailFile.url;
    }
    
    if (_type == MXKAttachmentTypeVideo || _type == MXKAttachmentTypeSticker)
    {
        if (_contentInfo)
        {
            // Look for a clear video thumbnail url
            NSString *unencrypted_thumb_url = _contentInfo[@"thumbnail_url"];
            
            // Note: When the uploading is in progress, the upload id is stored in the content url (nasty trick).
            // Prepare the absolute URL from the mxc: content URL, only if the thumbnail is not currently uploading.
            if (![unencrypted_thumb_url hasPrefix:kMXMediaUploadIdPrefix])
            {
                unencrypted_thumb_url = [self.sess.matrixRestClient urlOfContent:unencrypted_thumb_url];
            }
            
            return unencrypted_thumb_url;
        }
    }
    
    // Consider the case of the unencrypted url
    if (!_isEncrypted && _contentURL && ![_contentURL hasPrefix:kMXMediaUploadIdPrefix])
    {
        return [self.sess.matrixRestClient urlOfContentThumbnail:_contentURL
                                                   toFitViewSize:size
                                                      withMethod:MXThumbnailingMethodScale];
    }
    
    return nil;
}

- (NSString *)getThumbnailURI
{
    if (thumbnailFile)
    {
        // there's an encrypted thumbnail: we return the mxc url
        return thumbnailFile.url;
    }
    
    // Look for a clear thumbnail url
    return _contentInfo[@"thumbnail_url"];
}

- (NSString *)getThumbnailMimeType
{
    if (thumbnailFile)
    {
        return thumbnailFile.mimetype;
    }
    
    return _thumbnailInfo[@"mimetype"];
}

- (NSString*)getThumbnailCachePath
{
    if (_mxcThumbnailURI)
    {
        return [MXMediaManager cachePathForMatrixContentURI:_mxcThumbnailURI andType:_thumbnailMimeType inFolder:_eventRoomId];
    }
    // In case of an unencrypted image, consider the thumbnail URI deduced from the content URL, except if
    // the attachment is currently uploading.
    // Note: When the uploading is in progress, the upload id is stored in the content url (nasty trick).
    else if (_type == MXKAttachmentTypeImage && !_isEncrypted && _contentURL && ![_contentURL hasPrefix:kMXMediaUploadIdPrefix])
    {
        return [MXMediaManager thumbnailCachePathForMatrixContentURI:_contentURL
                                                             andType:@"image/jpeg"
                                                            inFolder:_eventRoomId
                                                       toFitViewSize:CGSizeMake(kThumbnailWidth, kThumbnailHeight)
                                                          withMethod:MXThumbnailingMethodScale];
        
        
    }
    return nil;
}

- (NSString *)getThumbnailDownloadId
{
    if (_mxcThumbnailURI)
    {
        return [MXMediaManager downloadIdForMatrixContentURI:_mxcThumbnailURI inFolder:_eventRoomId];
    }
    // In case of an unencrypted image, consider the thumbnail URI deduced from the content URL, except if
    // the attachment is currently uploading.
    // Note: When the uploading is in progress, the upload id is stored in the content url (nasty trick).
    else if (_type == MXKAttachmentTypeImage && !_isEncrypted && _contentURL && ![_contentURL hasPrefix:kMXMediaUploadIdPrefix])
    {
        return [MXMediaManager thumbnailDownloadIdForMatrixContentURI:_contentURL
                                                             inFolder:_eventRoomId
                                                        toFitViewSize:CGSizeMake(kThumbnailWidth, kThumbnailHeight)
                                                           withMethod:MXThumbnailingMethodScale];
    }
    return nil;
}

- (UIImage *)getCachedThumbnail
{
    if (_thumbnailCachePath)
    {
        UIImage *thumb = [MXMediaManager getFromMemoryCacheWithFilePath:_thumbnailCachePath];
        if (thumb) return thumb;
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:_thumbnailCachePath])
        {
            return [MXMediaManager loadThroughCacheWithFilePath:_thumbnailCachePath];
        }
    }
    return nil;
}

- (void)getThumbnail:(void (^)(UIImage *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    // Check whether a thumbnail is defined.
    if (!_thumbnailCachePath)
    {
        // there is no thumbnail: if we're an image, return the full size image. Otherwise, nothing we can do.
        if (_type == MXKAttachmentTypeImage)
        {
            [self getImage:onSuccess failure:onFailure];
        }
        return;
    }
    
    // Check the current memory cache.
    UIImage *thumb = [MXMediaManager getFromMemoryCacheWithFilePath:_thumbnailCachePath];
    if (thumb)
    {
        onSuccess(thumb);
        return;
    }
    
    if (thumbnailFile)
    {
        MXWeakify(self);
        
        void (^decryptAndCache)(void) = ^{
            MXStrongifyAndReturnIfNil(self);
            NSInputStream *instream = [[NSInputStream alloc] initWithFileAtPath:self.thumbnailCachePath];
            NSOutputStream *outstream = [[NSOutputStream alloc] initToMemory];
            NSError *err = [MXEncryptedAttachments decryptAttachment:self->thumbnailFile inputStream:instream outputStream:outstream];
            if (err) {
                NSLog(@"Error decrypting attachment! %@", err.userInfo);
                if (onFailure) onFailure(err);
                return;
            }
            
            UIImage *img = [UIImage imageWithData:[outstream propertyForKey:NSStreamDataWrittenToMemoryStreamKey]];
            // Save this image to in-memory cache.
            [MXMediaManager cacheImage:img withCachePath:self.thumbnailCachePath];
            onSuccess(img);
        };
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:_thumbnailCachePath])
        {
            decryptAndCache();
        }
        else
        {
            [_mediaManager downloadMediaFromMatrixContentURI:_mxcThumbnailURI
                                                    withType:_thumbnailMimeType
                                                    inFolder:_eventRoomId
                                                     success:^(NSString *outputFilePath) {
                                                         decryptAndCache();
                                                     }
                                                     failure:^(NSError *error) {
                                                         if (onFailure) onFailure(error);
                                                     }];
        }
    }
    else
    {
        if ([[NSFileManager defaultManager] fileExistsAtPath:_thumbnailCachePath])
        {
            onSuccess([MXMediaManager loadThroughCacheWithFilePath:_thumbnailCachePath]);
        }
        else if (_mxcThumbnailURI)
        {
            [_mediaManager downloadMediaFromMatrixContentURI:_mxcThumbnailURI
                                                    withType:_thumbnailMimeType
                                                    inFolder:_eventRoomId
                                                     success:^(NSString *outputFilePath) {
                                                         // Here outputFilePath = thumbnailCachePath
                                                         onSuccess([MXMediaManager loadThroughCacheWithFilePath:outputFilePath]);
                                                     }
                                                     failure:^(NSError *error) {
                                                         if (onFailure) onFailure(error);
                                                     }];
        }
        else
        {
            // Here _thumbnailCachePath is defined, so a thumbnail is available.
            // Because _mxcThumbnailURI is null, this means we have to consider the content uri (see getThumbnailCachePath).
            [_mediaManager downloadThumbnailFromMatrixContentURI:_contentURL
                                                         withType:@"image/jpeg"
                                                        inFolder:_eventRoomId
                                                   toFitViewSize:CGSizeMake(kThumbnailWidth, kThumbnailHeight)
                                                      withMethod:MXThumbnailingMethodScale
                                                         success:^(NSString *outputFilePath) {
                                                             // Here outputFilePath = thumbnailCachePath
                                                             onSuccess([MXMediaManager loadThroughCacheWithFilePath:outputFilePath]);
                                                         } failure:^(NSError *error) {
                                                             if (onFailure) onFailure(error);
                                                         }];
        }
    }
}

- (void)getImage:(void (^)(UIImage *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    [self getAttachmentData:^(NSData *data) {
        
        UIImage *img = [UIImage imageWithData:data];
        if (onSuccess) onSuccess(img);
        
    } failure:^(NSError *error) {
        
        if (onFailure) onFailure(error);
        
    }];
}

- (void)getAttachmentData:(void (^)(NSData *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    [self prepare:^{
        MXStrongifyAndReturnIfNil(self);
        if (self.isEncrypted)
        {
            // decrypt the encrypted file
            NSInputStream *instream = [[NSInputStream alloc] initWithFileAtPath:self.cacheFilePath];
            NSOutputStream *outstream = [[NSOutputStream alloc] initToMemory];
            NSError *err = [MXEncryptedAttachments decryptAttachment:self->contentFile inputStream:instream outputStream:outstream];
            if (err)
            {
                NSLog(@"Error decrypting attachment! %@", err.userInfo);
                return;
            }
            onSuccess([outstream propertyForKey:NSStreamDataWrittenToMemoryStreamKey]);
        }
        else
        {
            onSuccess([NSData dataWithContentsOfFile:self.cacheFilePath]);
        }
    } failure:^(NSError *error) {
        
        if (onFailure) onFailure(error);
        
    }];
}

- (void)decryptToTempFile:(void (^)(NSString *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    [self prepare:^{
        MXStrongifyAndReturnIfNil(self);
        NSString *tempPath = [self getTempFile];
        if (!tempPath)
        {
            if (onFailure) onFailure([NSError errorWithDomain:kMXKAttachmentErrorDomain code:0 userInfo:@{@"err": @"error_creating_temp_file"}]);
            return;
        }
        
        NSInputStream *inStream = [NSInputStream inputStreamWithFileAtPath:self.cacheFilePath];
        NSOutputStream *outStream = [NSOutputStream outputStreamToFileAtPath:tempPath append:NO];
        
        NSError *err = [MXEncryptedAttachments decryptAttachment:self->contentFile inputStream:inStream outputStream:outStream];
        if (err) {
            if (onFailure) onFailure(err);
            return;
        }
        onSuccess(tempPath);
    } failure:^(NSError *error) {
        if (onFailure) onFailure(error);
    }];
}

- (NSString *)getTempFile
{
    // create a file with an appropriate extension because iOS detects based on file extension
    // all over the place
    NSString *ext = [MXTools fileExtensionFromContentType:mimetype];
    NSString *filenameTemplate = [NSString stringWithFormat:@"attatchment.XXXXXX%@", ext];
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:filenameTemplate];
    
    const char *templateCstr = [template fileSystemRepresentation];
    char *tempPathCstr = (char *)malloc(strlen(templateCstr) + 1);
    strcpy(tempPathCstr, templateCstr);
    
    int fd = mkstemps(tempPathCstr, (int)ext.length);
    if (!fd)
    {
        return nil;
    }
    close(fd);
    
    NSString *tempPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:tempPathCstr
                                                                                     length:strlen(tempPathCstr)];
    free(tempPathCstr);
    return tempPath;
}

- (void)prepare:(void (^)(void))onAttachmentReady failure:(void (^)(NSError *error))onFailure
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:_cacheFilePath])
    {
        // Done
        if (onAttachmentReady)
        {
            onAttachmentReady ();
        }
    }
    else
    {
        // Trigger download if it is not already in progress
        MXMediaLoader* loader = [MXMediaManager existingDownloaderWithIdentifier:_downloadId];
        if (!loader)
        {
            loader = [_mediaManager downloadMediaFromMatrixContentURI:_contentURL
                                                             withType:mimetype
                                                             inFolder:_eventRoomId];
        }
        
        if (loader)
        {
            MXWeakify(self);
            
            // Add observers
            onAttachmentDownloadObs = [[NSNotificationCenter defaultCenter] addObserverForName:kMXMediaLoaderStateDidChangeNotification object:loader queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
                
                MXStrongifyAndReturnIfNil(self);
                MXMediaLoader *loader = (MXMediaLoader*)notif.object;
                switch (loader.state) {
                    case MXMediaLoaderStateDownloadCompleted:
                        [[NSNotificationCenter defaultCenter] removeObserver:self->onAttachmentDownloadObs];
                        self->onAttachmentDownloadObs = nil;
                        if (onAttachmentReady)
                        {
                            onAttachmentReady ();
                        }
                        break;
                    case MXMediaLoaderStateDownloadFailed:
                        [[NSNotificationCenter defaultCenter] removeObserver:self->onAttachmentDownloadObs];
                        self->onAttachmentDownloadObs = nil;
                        if (onFailure)
                        {
                            onFailure (loader.error);
                        }
                        break;
                    default:
                        break;
                }
            }];
        }
        else if (onFailure)
        {
            onFailure (nil);
        }
    }
}

- (void)save:(void (^)(void))onSuccess failure:(void (^)(NSError *error))onFailure
{
    if (_type == MXKAttachmentTypeImage || _type == MXKAttachmentTypeVideo)
    {
        MXWeakify(self);
        if (self.isEncrypted) {
            [self decryptToTempFile:^(NSString *path) {
                MXStrongifyAndReturnIfNil(self);
                NSURL* url = [NSURL fileURLWithPath:path];
                
                [MXMediaManager saveMediaToPhotosLibrary:url
                                                  isImage:(self.type == MXKAttachmentTypeImage)
                                                  success:^(NSURL *assetURL){
                                                      if (onSuccess)
                                                      {
                                                          [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                                                          onSuccess();
                                                      }
                                                  }
                                                  failure:onFailure];
            } failure:onFailure];
        }
        else
        {
            [self prepare:^{
                MXStrongifyAndReturnIfNil(self);
                NSURL* url = [NSURL fileURLWithPath:self.cacheFilePath];
                
                [MXMediaManager saveMediaToPhotosLibrary:url
                                                  isImage:(self.type == MXKAttachmentTypeImage)
                                                  success:^(NSURL *assetURL){
                                                      if (onSuccess)
                                                      {
                                                          onSuccess();
                                                      }
                                                  }
                                                  failure:onFailure];
            } failure:onFailure];
        }
    }
    else
    {
        // Not supported
        if (onFailure)
        {
            onFailure(nil);
        }
    }
}

- (void)copy:(void (^)(void))onSuccess failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    [self prepare:^{
        MXStrongifyAndReturnIfNil(self);
        if (self.type == MXKAttachmentTypeImage)
        {
            [self getImage:^(UIImage *img) {
                [[UIPasteboard generalPasteboard] setImage:img];
                if (onSuccess)
                {
                    onSuccess();
                }
            } failure:^(NSError *error) {
                if (onFailure) onFailure(error);
            }];
        }
        else
        {
            MXWeakify(self);
            [self getAttachmentData:^(NSData *data) {
                if (data)
                {
                    MXStrongifyAndReturnIfNil(self);
                    NSString* UTI = (__bridge_transfer NSString *) UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[self.cacheFilePath pathExtension] , NULL);
                    
                    if (UTI)
                    {
                        [[UIPasteboard generalPasteboard] setData:data forPasteboardType:UTI];
                        if (onSuccess)
                        {
                            onSuccess();
                        }
                    }
                }
            } failure:^(NSError *error) {
                if (onFailure) onFailure(error);
            }];
        }
        
        // Unexpected error
        if (onFailure)
        {
            onFailure(nil);
        }
        
    } failure:onFailure];
}

- (void)prepareShare:(void (^)(NSURL *fileURL))onReadyToShare failure:(void (^)(NSError *error))onFailure
{
    MXWeakify(self);
    void (^haveFile)(NSString *) = ^(NSString *path) {
        // Prepare the file URL by considering the original file name (if any)
        NSURL *fileUrl;
        MXStrongifyAndReturnIfNil(self);
        // Check whether the original name retrieved from event body has extension
        if (self.originalFileName && [self.originalFileName pathExtension].length)
        {
            // Copy the cached file to restore its original name
            // Note:  We used previously symbolic link (instead of copy) but UIDocumentInteractionController failed to open Office documents (.docx, .pptx...).
            self->documentCopyPath = [[MXMediaManager getCachePath] stringByAppendingPathComponent:self.originalFileName];
            
            [[NSFileManager defaultManager] removeItemAtPath:self->documentCopyPath error:nil];
            if ([[NSFileManager defaultManager] copyItemAtPath:path toPath:self->documentCopyPath error:nil])
            {
                fileUrl = [NSURL fileURLWithPath:self->documentCopyPath];
            }
        }
        
        if (!fileUrl)
        {
            // Use the cached file by default
            fileUrl = [NSURL fileURLWithPath:path];
        }
        
        onReadyToShare (fileUrl);
    };
    
    if (self.isEncrypted)
    {
        [self decryptToTempFile:^(NSString *path) {
            haveFile(path);
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        } failure:onFailure];
    }
    else
    {
        // First download data if it is not already done
        [self prepare:^{
            haveFile(self.cacheFilePath);
        } failure:onFailure];
    }
}

- (void)onShareEnded
{
    // Remove the temporary file created to prepare attachment sharing
    if (documentCopyPath)
    {
        [[NSFileManager defaultManager] removeItemAtPath:documentCopyPath error:nil];
        documentCopyPath = nil;
    }
}

@end
