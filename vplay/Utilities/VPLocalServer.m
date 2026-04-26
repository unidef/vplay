#import "VPLocalServer.h"
#import <Network/Network.h>

@interface VPLocalServer ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURL *> *roots; // token -> directory
@property (nonatomic) uint16_t port;
@property (nonatomic, strong) nw_listener_t listener;
@end

@implementation VPLocalServer

+ (instancetype)shared {
    static VPLocalServer *server; static dispatch_once_t once;
    dispatch_once(&once, ^{ server = [VPLocalServer new]; });
    return server;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("vplay.localserver", DISPATCH_QUEUE_SERIAL);
        _roots = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)startIfNeeded {
    if (self.port) return YES;
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_endpoint_t loopback = nw_endpoint_create_host("127.0.0.1", "0");   // loopback only: never reachable from the network
    nw_parameters_set_local_endpoint(params, loopback);
    nw_listener_t listener = nw_listener_create(params);
    if (!listener) return NO;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block uint16_t port = 0;
    __weak typeof(self) weakSelf = self;
    nw_listener_set_queue(listener, self.queue);
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf serve:connection];
    });
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        if (state == nw_listener_state_ready) { port = nw_listener_get_port(listener); dispatch_semaphore_signal(ready); }
        else if (state == nw_listener_state_failed || state == nw_listener_state_cancelled) dispatch_semaphore_signal(ready);
    });
    nw_listener_start(listener);
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    if (!port) { nw_listener_cancel(listener); return NO; }
    self.listener = listener;
    self.port = port;
    return YES;
}

- (NSURL *)publishDirectory:(NSURL *)directory fileName:(NSString *)fileName {
    if (![self startIfNeeded]) return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    dispatch_sync(self.queue, ^{ self.roots[token] = directory; });
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/%@/%@", self.port, token, fileName]];
}

- (void)unpublishDirectory:(NSURL *)directory {
    dispatch_async(self.queue, ^{
        for (NSString *token in [self.roots allKeysForObject:directory]) [self.roots removeObjectForKey:token];
    });
}

#pragma mark - Connection handling

- (void)serve:(nw_connection_t)connection {
    nw_connection_set_queue(connection, self.queue);
    nw_connection_start(connection);
    [self receiveRequest:connection buffer:[NSMutableData data]];
}

- (void)receiveRequest:(nw_connection_t)connection buffer:(NSMutableData *)buffer {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 1, 65536, ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
                [buffer appendBytes:bytes length:size]; return true;
            });
        }
        NSData *terminator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        if ([buffer rangeOfData:terminator options:0 range:NSMakeRange(0, buffer.length)].location != NSNotFound) {
            [weakSelf respondTo:[[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] connection:connection];
        } else if (error || (complete && !content) || buffer.length > 65536) {
            nw_connection_cancel(connection);
        } else {
            [weakSelf receiveRequest:connection buffer:buffer];
        }
    });
}

- (void)send:(NSString *)status headers:(NSDictionary *)headers body:(NSData *)body connection:(nw_connection_t)connection {
    NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %@\r\n", status];
    for (NSString *key in headers) [head appendFormat:@"%@: %@\r\n", key, headers[key]];
    [head appendString:@"Connection: close\r\n\r\n"];
    NSMutableData *data = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body) [data appendData:body];
    dispatch_data_t payload = dispatch_data_create(data.bytes, data.length, self.queue, ^{ (void)data; });
    nw_connection_send(connection, payload, NW_CONNECTION_FINAL_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        nw_connection_cancel(connection);
    });
}

- (void)respondTo:(NSString *)request connection:(nw_connection_t)connection {
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    NSArray *parts = [lines.firstObject componentsSeparatedByString:@" "];
    if (parts.count < 2 || ![@[@"GET", @"HEAD"] containsObject:parts[0]]) {
        [self send:@"405 Method Not Allowed" headers:@{@"Content-Length":@"0"} body:nil connection:connection]; return;
    }
    BOOL headOnly = [parts[0] isEqual:@"HEAD"];
    NSString *path = [parts[1] stringByRemovingPercentEncoding];
    NSArray *components = [path componentsSeparatedByString:@"/"];   // "", token, name
    NSURL *root = components.count == 3 ? self.roots[components[1]] : nil;
    NSString *name = components.count == 3 ? components[2] : nil;
    if (!root || !name.length || [name containsString:@".."]) {
        [self send:@"404 Not Found" headers:@{@"Content-Length":@"0"} body:nil connection:connection]; return;
    }
    NSData *file = [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:name] options:NSDataReadingMappedIfSafe error:nil];
    if (!file) { [self send:@"404 Not Found" headers:@{@"Content-Length":@"0"} body:nil connection:connection]; return; }
    NSString *type = [name hasSuffix:@".m3u8"] ? @"application/vnd.apple.mpegurl" : ([name hasSuffix:@".ts"] ? @"video/MP2T" : @"application/octet-stream");
    NSString *range = nil;
    for (NSString *line in lines) if ([line.lowercaseString hasPrefix:@"range:"]) range = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSData *body = file; NSString *status = @"200 OK";
    NSMutableDictionary *headers = [@{@"Content-Type":type, @"Accept-Ranges":@"bytes", @"Cache-Control":@"no-cache"} mutableCopy];
    if ([range hasPrefix:@"bytes="]) {
        NSArray *bounds = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
        long long total = (long long)file.length, start = [bounds[0] length] ? [bounds[0] longLongValue] : -1;
        long long end = bounds.count > 1 && [bounds[1] length] ? [bounds[1] longLongValue] : total - 1;
        if (start < 0) { start = MAX(0, total - end); end = total - 1; }
        end = MIN(end, total - 1);
        if (start > end || start >= total) { [self send:@"416 Range Not Satisfiable" headers:@{@"Content-Length":@"0", @"Content-Range":[NSString stringWithFormat:@"bytes */%lld", total]} body:nil connection:connection]; return; }
        body = [file subdataWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1))];
        status = @"206 Partial Content";
        headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, total];
    }
    headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
    [self send:status headers:headers body:headOnly ? nil : body connection:connection];
}
@end
