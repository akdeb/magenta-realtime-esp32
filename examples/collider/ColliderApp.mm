// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Collider: standalone app entry point.
// Reuses RealtimeRunner, AVAudioEngine, CoreMIDI from Magenta RT standalone.
// Adds shared state for MIDI note visualization and audio waveform display.

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <CoreAudio/CoreAudio.h>
#import <CommonCrypto/CommonDigest.h>
#import "ColliderAppController.h"
#import "../common/objc/MagentaSettings.h"
#include <magentart/realtime_runner.h>
#include "../common/cpp/magenta_paths.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <string>
#include <vector>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <opus.h>

using magentart::core::RealtimeRunner;

// ─── ESP32 WebSocket Opus audio stream ──────────────────────────────────────
// The firmware connects as a WebSocket client to ws://<mac-ip>:49320/ws/esp32.
// We publish _elato._tcp over Bonjour and send 48 kHz mono Opus packets.

enum {
    kEsp32WebSocketPort = 49320,
    kEsp32OpusSampleRate = 48000,
    kEsp32OpusFrameMs = 120,
    kEsp32OpusFrameSamples = kEsp32OpusSampleRate * kEsp32OpusFrameMs / 1000,
    kEsp32AudioRingSize = kEsp32OpusFrameSamples * 24,
};

// With a device-side volume slider now driving loudness, the pre-boost only
// needs to add a little presence; keep it small so the limiter stays out of
// the way and complex material (e.g. piano) isn't dynamically squashed.
static constexpr float kEsp32OutputBoostDb = 2.0f;
static constexpr float kEsp32OutputCeiling = 0.89f;
static constexpr float kEsp32LimiterKnee = 0.82f;  // signal is clean below this

// Applies a fixed boost for the small mono speaker, then a soft-knee peak
// limiter that only acts on samples above the knee. Sub-knee samples pass
// through untouched, so it adds no harmonic distortion to quiet/mid passages
// (unlike a full-signal waveshaper, which sounds raspy on music).
static void BoostLimitPCM16InPlace(int16_t* samples, int count) {
    const float gain = std::pow(10.0f, kEsp32OutputBoostDb / 20.0f);
    const float knee = kEsp32LimiterKnee;
    const float ceil = kEsp32OutputCeiling;
    const float range = ceil - knee;

    for (int i = 0; i < count; ++i) {
        float y = ((float)samples[i] / 32768.0f) * gain;
        float a = std::fabs(y);
        if (a > knee) {
            float over = (a - knee) / (1.0f - knee);
            a = knee + range * std::tanh(over);
            y = std::copysign(a, y);
        }
        y = std::max(-ceil, std::min(ceil, y));
        samples[i] = (int16_t)lrintf(y * 32767.0f);
    }
}

@protocol ColliderAudioWebSocketStreamerDelegate <NSObject>
- (void)colliderAudioWebSocketStreamerDidReceiveMicrophoneAudio:(NSData*)data;
@end

@interface ColliderAudioWebSocketStreamer : NSObject <NSNetServiceDelegate>
@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) BOOL streamingEnabled;
@property (nonatomic, readonly) int esp32Volume;  // 0–100, current ESP32 speaker volume
@property (nonatomic, weak) id<ColliderAudioWebSocketStreamerDelegate> delegate;
- (instancetype)initWithPort:(uint16_t)port path:(NSString*)path;
- (BOOL)start;
- (void)stop;
- (void)setStreamingEnabled:(BOOL)enabled;
- (void)suspendStreamingForVoiceCommand;
- (void)pushLeft:(const float*)left right:(const float*)right count:(AVAudioFrameCount)count;
- (void)sendServerMessage:(NSString*)message;
// Stores the volume, persists it, and pushes a VOLUME.UPDATE message to the device.
- (void)setEsp32Volume:(int)volumePercent;
@end

@protocol ColliderVoiceAgentDelegate <NSObject>
- (void)voiceAgentDidStartSpeech;
- (void)voiceAgentDidCommitAudio;
- (void)voiceAgentDidTranscribe:(NSString*)transcript;
- (void)voiceAgentDidFinishWithTranscript:(NSString*)transcript toolCalls:(NSArray*)toolCalls;
- (void)voiceAgentDidFail:(NSString*)message;
@end

@interface ColliderVoiceAgent : NSObject
@property (nonatomic, weak) id<ColliderVoiceAgentDelegate> delegate;
- (void)start;
- (void)stop;
- (void)pushPCM16Audio:(NSData*)data;
@end

@implementation ColliderVoiceAgent {
    NSTask* _task;
    NSFileHandle* _stdinHandle;
    NSMutableData* _stdoutBuffer;
}

- (void)start {
    if (_task && _task.isRunning) return;
    NSString* script = [[NSBundle mainBundle] pathForResource:@"voice_agent" ofType:@"py"];
    if (!script) script = @"/Users/akashdeepdeb/Desktop/Projects/magenta-realtime/examples/collider/voice_agent.py";
    NSPipe* inPipe = [NSPipe pipe];
    NSPipe* outPipe = [NSPipe pipe];
    _stdoutBuffer = [NSMutableData data];
    _task = [[NSTask alloc] init];
    NSArray<NSString*>* pythonCandidates = @[
        @"/opt/homebrew/Caskroom/miniconda/base/bin/python3",
        @"/opt/homebrew/bin/python3",
        @"/usr/local/bin/python3",
    ];
    NSString* pythonPath = nil;
    for (NSString* candidate in pythonCandidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) {
            pythonPath = candidate;
            break;
        }
    }
    if (pythonPath) {
        _task.launchPath = pythonPath;
        _task.arguments = @[script];
    } else {
        _task.launchPath = @"/usr/bin/env";
        _task.arguments = @[@"python3", script];
    }
    _task.standardInput = inPipe;
    _task.standardOutput = outPipe;
    _task.standardError = outPipe;
    _stdinHandle = inPipe.fileHandleForWriting;
    __weak ColliderVoiceAgent* weakSelf = self;
    outPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle* handle) {
        NSData* data = [handle availableData];
        if (data.length > 0) [weakSelf handleOutputData:data];
    };
    @try {
        [_task launch];
        NSLog(@"Collider: voice agent launched");
    } @catch (NSException* e) {
        NSLog(@"Collider: voice agent launch failed: %@", e);
    }
}

- (void)stop {
    if (_task.isRunning) [_task terminate];
    _task = nil;
    _stdinHandle = nil;
}

- (void)pushPCM16Audio:(NSData*)data {
    if (!_task || !_task.isRunning) [self start];
    if (!_stdinHandle || data.length == 0) return;
    @try {
        [_stdinHandle writeData:data];
    } @catch (NSException* e) {
        NSLog(@"Collider: voice agent stdin write failed: %@", e);
    }
}

- (void)handleOutputData:(NSData*)data {
    @synchronized (self) {
        [_stdoutBuffer appendData:data];
        while (true) {
            const uint8_t* bytes = (const uint8_t*)_stdoutBuffer.bytes;
            NSUInteger newline = NSNotFound;
            for (NSUInteger i = 0; i < _stdoutBuffer.length; ++i) {
                if (bytes[i] == '\n') { newline = i; break; }
            }
            if (newline == NSNotFound) break;
            NSData* lineData = [_stdoutBuffer subdataWithRange:NSMakeRange(0, newline)];
            [_stdoutBuffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
            if (lineData.length == 0) continue;
            NSDictionary* event = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            if (![event isKindOfClass:NSDictionary.class]) {
                NSString* line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
                NSLog(@"Collider voice agent: %@", line);
                continue;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleEvent:event];
            });
        }
    }
}

- (void)handleEvent:(NSDictionary*)event {
    NSString* name = event[@"event"];
    if ([name isEqualToString:@"speech_started"]) {
        [self.delegate voiceAgentDidStartSpeech];
    } else if ([name isEqualToString:@"committed"]) {
        [self.delegate voiceAgentDidCommitAudio];
    } else if ([name isEqualToString:@"transcribed"]) {
        NSString* transcript = [event[@"transcript"] isKindOfClass:NSString.class] ? event[@"transcript"] : @"";
        [self.delegate voiceAgentDidTranscribe:transcript];
    } else if ([name isEqualToString:@"result"]) {
        NSString* transcript = [event[@"transcript"] isKindOfClass:NSString.class] ? event[@"transcript"] : @"";
        NSArray* tools = [event[@"tools"] isKindOfClass:NSArray.class] ? event[@"tools"] : @[];
        [self.delegate voiceAgentDidFinishWithTranscript:transcript toolCalls:tools];
    } else if ([name isEqualToString:@"error"]) {
        NSString* message = [event[@"message"] isKindOfClass:NSString.class] ? event[@"message"] : @"Unknown voice agent error";
        NSLog(@"Collider voice agent error: %@", message);
        NSArray* tools = [event[@"tools"] isKindOfClass:NSArray.class] ? event[@"tools"] : @[];
        NSString* transcript = [event[@"transcript"] isKindOfClass:NSString.class] ? event[@"transcript"] : @"";
        if (tools.count > 0) {
            [self.delegate voiceAgentDidFinishWithTranscript:transcript toolCalls:tools];
        } else {
            [self.delegate voiceAgentDidFail:message];
        }
    } else if ([name isEqualToString:@"ready"] || [name isEqualToString:@"agent_loaded"]) {
        NSLog(@"Collider voice agent: %@", event);
    }
}

@end

@implementation ColliderAudioWebSocketStreamer {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSString* _path;
    NSNetService* _service;
    OpusEncoder* _encoder;
    std::thread _acceptThread;
    std::atomic<bool> _running;
    std::atomic<bool> _streamingEnabled;
    std::atomic<int> _listenFd;
    std::atomic<int> _clientFd;
    std::atomic<uint32_t> _writePos;
    std::atomic<uint32_t> _readPos;
    std::atomic<int> _esp32Volume;
    std::vector<uint8_t> _incoming;
    int16_t _ring[kEsp32AudioRingSize];
    uint16_t _port;
    uint64_t _packetsSent;
    double _pcmSquareSum;
    uint64_t _pcmSampleCount;
    CFTimeInterval _lastStatsLogTime;
}

- (instancetype)initWithPort:(uint16_t)port path:(NSString*)path {
    self = [super init];
    if (!self) return nil;
    _port = port;
    _path = [path copy];
    _queue = dispatch_queue_create("com.google.mrt2.collider.esp32-audio", DISPATCH_QUEUE_SERIAL);
    _running.store(false, std::memory_order_relaxed);
    _streamingEnabled.store(false, std::memory_order_relaxed);
    _listenFd.store(-1, std::memory_order_relaxed);
    _clientFd.store(-1, std::memory_order_relaxed);
    _writePos.store(0, std::memory_order_relaxed);
    _readPos.store(0, std::memory_order_relaxed);
    NSNumber* savedVolume = [[NSUserDefaults standardUserDefaults] objectForKey:@"Collider_Esp32Volume"];
    _esp32Volume.store(savedVolume ? std::max(0, std::min(100, savedVolume.intValue)) : 100,
                       std::memory_order_relaxed);
    _packetsSent = 0;
    _pcmSquareSum = 0.0;
    _pcmSampleCount = 0;
    _lastStatsLogTime = 0;

    int opusError = OPUS_OK;
    _encoder = opus_encoder_create(kEsp32OpusSampleRate, 1, OPUS_APPLICATION_AUDIO, &opusError);
    if (!_encoder || opusError != OPUS_OK) {
        NSLog(@"Collider: failed to create Opus encoder: %s", opus_strerror(opusError));
    } else {
        opus_encoder_ctl(_encoder, OPUS_SET_BITRATE(96000));
        opus_encoder_ctl(_encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
        opus_encoder_ctl(_encoder, OPUS_SET_COMPLEXITY(10));
        opus_encoder_ctl(_encoder, OPUS_SET_BANDWIDTH(OPUS_BANDWIDTH_FULLBAND));
        opus_encoder_ctl(_encoder, OPUS_SET_EXPERT_FRAME_DURATION(OPUS_FRAMESIZE_120_MS));
    }
    return self;
}

- (void)dealloc {
    [self stop];
    if (_encoder) opus_encoder_destroy(_encoder);
}

- (BOOL)isRunning {
    return _running.load(std::memory_order_acquire);
}

- (BOOL)streamingEnabled {
    return _streamingEnabled.load(std::memory_order_acquire);
}

- (BOOL)start {
    if (self.isRunning || !_encoder) return self.isRunning;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"Collider: ESP32 WebSocket socket() failed: %s", strerror(errno));
        return NO;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(_port);
    if (bind(fd, (sockaddr*)&addr, sizeof(addr)) < 0 || listen(fd, 1) < 0) {
        NSLog(@"Collider: ESP32 WebSocket bind/listen on %u failed: %s", _port, strerror(errno));
        close(fd);
        return NO;
    }

    _listenFd.store(fd, std::memory_order_release);
    _running.store(true, std::memory_order_release);
    _writePos.store(0, std::memory_order_relaxed);
    _readPos.store(0, std::memory_order_relaxed);
    opus_encoder_ctl(_encoder, OPUS_RESET_STATE);

    _service = [[NSNetService alloc] initWithDomain:@"local."
                                               type:@"_elato._tcp."
                                               name:@"elato"
                                               port:_port];
    _service.delegate = self;
    [_service publish];

    ColliderAudioWebSocketStreamer* streamer = self;
    _acceptThread = std::thread([streamer]() { [streamer acceptLoop]; });

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 20 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    __weak ColliderAudioWebSocketStreamer* weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf drainIncoming];
        [weakSelf encodeAndSendIfReady];
    });
    dispatch_resume(_timer);

    NSLog(@"Collider: ESP32 Opus WebSocket server listening on ws://0.0.0.0:%u%@", _port, _path);
    return YES;
}

- (void)stop {
    if (!self.isRunning) return;
    _running.store(false, std::memory_order_release);
    _streamingEnabled.store(false, std::memory_order_release);

    [self sendServerMessage:@"RESPONSE.COMPLETE"];

    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    [_service stop];
    _service = nil;

    int listenFd = _listenFd.exchange(-1, std::memory_order_acq_rel);
    if (listenFd >= 0) {
        shutdown(listenFd, SHUT_RDWR);
        close(listenFd);
    }
    int clientFd = _clientFd.exchange(-1, std::memory_order_acq_rel);
    if (clientFd >= 0) {
        shutdown(clientFd, SHUT_RDWR);
        close(clientFd);
    }
    if (_acceptThread.joinable()) _acceptThread.join();

    NSLog(@"Collider: ESP32 Opus WebSocket server stopped");
}

- (void)setStreamingEnabled:(BOOL)enabled {
    bool wasEnabled = _streamingEnabled.exchange(enabled, std::memory_order_acq_rel);
    if (enabled == wasEnabled) return;

    if (enabled) {
        _writePos.store(0, std::memory_order_relaxed);
        _readPos.store(0, std::memory_order_relaxed);
        if (_encoder) opus_encoder_ctl(_encoder, OPUS_RESET_STATE);
        [self sendServerMessage:@"RESPONSE.CREATED"];
        NSLog(@"Collider: ESP32 speaker stream enabled");
    } else {
        [self sendServerMessage:@"AUDIO.COMMITTED"];
        NSLog(@"Collider: ESP32 speaker stream disabled");
    }
}

- (void)suspendStreamingForVoiceCommand {
    _streamingEnabled.store(false, std::memory_order_release);
    _writePos.store(0, std::memory_order_relaxed);
    _readPos.store(0, std::memory_order_relaxed);
    if (_encoder) opus_encoder_ctl(_encoder, OPUS_RESET_STATE);
}

- (void)pushLeft:(const float*)left right:(const float*)right count:(AVAudioFrameCount)count {
    if (!self.isRunning || !self.streamingEnabled) return;

    uint32_t w = _writePos.load(std::memory_order_relaxed);
    uint32_t r = _readPos.load(std::memory_order_acquire);
    for (AVAudioFrameCount i = 0; i < count; ++i) {
        float mono = 0.5f * (left[i] + right[i]);
        mono = std::max(-1.0f, std::min(1.0f, mono));
        _pcmSquareSum += (double)mono * (double)mono;
        _pcmSampleCount++;
        _ring[w % kEsp32AudioRingSize] = (int16_t)lrintf(mono * 32767.0f);
        w++;

        if (w - r >= kEsp32AudioRingSize) {
            r = w - kEsp32AudioRingSize + 1;
            _readPos.store(r, std::memory_order_release);
        }
    }
    _writePos.store(w, std::memory_order_release);
}

- (void)acceptLoop {
    while (_running.load(std::memory_order_acquire)) {
        sockaddr_in clientAddr {};
        socklen_t len = sizeof(clientAddr);
        int fd = accept(_listenFd.load(std::memory_order_acquire), (sockaddr*)&clientAddr, &len);
        if (fd < 0) continue;

        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        if (![self completeHandshake:fd]) {
            close(fd);
            continue;
        }

        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        int old = _clientFd.exchange(fd, std::memory_order_acq_rel);
        if (old >= 0) close(old);
        [self sendAuthMessage];
        if (self.streamingEnabled) [self sendServerMessage:@"RESPONSE.CREATED"];
        NSLog(@"Collider: ESP32 WebSocket client connected");
    }
}

- (BOOL)completeHandshake:(int)fd {
    std::string request;
    char buffer[2048];
    while (request.find("\r\n\r\n") == std::string::npos && request.size() < 8192) {
        ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
        if (n <= 0) return NO;
        request.append(buffer, buffer + n);
    }

    std::string path = [_path UTF8String];
    std::string expectedRequestLine = "GET " + path + " ";
    if (request.find(expectedRequestLine) != 0) return NO;

    std::string keyHeader = "Sec-WebSocket-Key:";
    size_t keyStart = request.find(keyHeader);
    if (keyStart == std::string::npos) return NO;
    keyStart += keyHeader.size();
    while (keyStart < request.size() && request[keyStart] == ' ') keyStart++;
    size_t keyEnd = request.find("\r\n", keyStart);
    if (keyEnd == std::string::npos) return NO;

    std::string key = request.substr(keyStart, keyEnd - keyStart);
    std::string acceptSource = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(acceptSource.data(), (CC_LONG)acceptSource.size(), digest);
    NSData* digestData = [NSData dataWithBytes:digest length:sizeof(digest)];
    NSString* accept = [digestData base64EncodedStringWithOptions:0];

    NSString* response = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\n"
         "Upgrade: websocket\r\n"
         "Connection: Upgrade\r\n"
         "Sec-WebSocket-Accept: %@\r\n\r\n", accept];
    const char* bytes = response.UTF8String;
    return send(fd, bytes, strlen(bytes), 0) > 0;
}

- (void)drainIncoming {
    int fd = _clientFd.load(std::memory_order_acquire);
    if (fd < 0) return;
    uint8_t buffer[4096];
    while (true) {
        ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        _incoming.insert(_incoming.end(), buffer, buffer + n);
    }

    while (_incoming.size() >= 2) {
        uint8_t b0 = _incoming[0];
        uint8_t b1 = _incoming[1];
        uint8_t opcode = b0 & 0x0f;
        bool masked = (b1 & 0x80) != 0;
        uint64_t len = b1 & 0x7f;
        size_t offset = 2;
        if (len == 126) {
            if (_incoming.size() < offset + 2) return;
            len = ((uint64_t)_incoming[offset] << 8) | _incoming[offset + 1];
            offset += 2;
        } else if (len == 127) {
            if (_incoming.size() < offset + 8) return;
            len = 0;
            for (int i = 0; i < 8; ++i) len = (len << 8) | _incoming[offset + i];
            offset += 8;
        }
        if (!masked) {
            _incoming.erase(_incoming.begin(), _incoming.begin() + std::min<size_t>(_incoming.size(), offset + (size_t)len));
            continue;
        }
        if (_incoming.size() < offset + 4 + len) return;
        uint8_t mask[4] = { _incoming[offset], _incoming[offset + 1], _incoming[offset + 2], _incoming[offset + 3] };
        offset += 4;
        NSMutableData* payload = [NSMutableData dataWithLength:(NSUInteger)len];
        uint8_t* out = (uint8_t*)payload.mutableBytes;
        for (uint64_t i = 0; i < len; ++i) out[i] = _incoming[offset + (size_t)i] ^ mask[i & 3];
        _incoming.erase(_incoming.begin(), _incoming.begin() + offset + (size_t)len);

        if (opcode == 0x2 && payload.length > 0) {
            id delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(colliderAudioWebSocketStreamerDidReceiveMicrophoneAudio:)]) {
                NSData* copy = [payload copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [delegate colliderAudioWebSocketStreamerDidReceiveMicrophoneAudio:copy];
                });
            }
        } else if (opcode == 0x8) {
            int old = _clientFd.exchange(-1, std::memory_order_acq_rel);
            if (old >= 0) close(old);
            _incoming.clear();
            return;
        }
    }
}

- (void)encodeAndSendIfReady {
    if (!self.streamingEnabled || _clientFd.load(std::memory_order_acquire) < 0 || !_encoder) return;
    uint32_t r = _readPos.load(std::memory_order_relaxed);
    uint32_t w = _writePos.load(std::memory_order_acquire);
    if (w - r < kEsp32OpusFrameSamples) return;

    int16_t chunk[kEsp32OpusFrameSamples];
    for (int i = 0; i < kEsp32OpusFrameSamples; ++i) {
        chunk[i] = _ring[(r + i) % kEsp32AudioRingSize];
    }
    _readPos.store(r + kEsp32OpusFrameSamples, std::memory_order_release);
    BoostLimitPCM16InPlace(chunk, kEsp32OpusFrameSamples);

    uint8_t packet[4096];
    int encoded = opus_encode(_encoder, chunk, kEsp32OpusFrameSamples, packet, sizeof(packet));
    if (encoded < 0) {
        NSLog(@"Collider: Opus encode failed: %s", opus_strerror(encoded));
        return;
    }
    [self sendWebSocketFrameOpcode:0x2 bytes:packet length:(size_t)encoded];

    _packetsSent++;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - _lastStatsLogTime >= 1.0) {
        double rms = _pcmSampleCount ? std::sqrt(_pcmSquareSum / (double)_pcmSampleCount) : 0.0;
        NSLog(@"Collider: ESP32 audio stats packets=%llu lastOpusBytes=%d pcmRms=%.5f",
              (unsigned long long)_packetsSent, encoded, rms);
        _pcmSquareSum = 0.0;
        _pcmSampleCount = 0;
        _lastStatsLogTime = now;
    }
}

- (int)esp32Volume {
    return _esp32Volume.load(std::memory_order_acquire);
}

- (void)setEsp32Volume:(int)volumePercent {
    int v = std::max(0, std::min(100, volumePercent));
    _esp32Volume.store(v, std::memory_order_release);
    [[NSUserDefaults standardUserDefaults] setInteger:v forKey:@"Collider_Esp32Volume"];
    // Serialize the send onto _queue so it can't interleave with the timer's
    // Opus binary frames and corrupt a partially-written WebSocket frame.
    dispatch_async(_queue, ^{
        NSDictionary* payload = @{
            @"type": @"server",
            @"msg": @"VOLUME.UPDATE",
            @"volume_control": @(v)
        };
        NSData* json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (json) [self sendWebSocketFrameOpcode:0x1 bytes:(const uint8_t*)json.bytes length:json.length];
    });
}

- (void)sendServerMessage:(NSString*)message {
    NSDictionary* payload = @{
        @"type": @"server",
        @"msg": message,
        @"volume_control": @(_esp32Volume.load(std::memory_order_acquire))
    };
    NSData* json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    [self sendWebSocketFrameOpcode:0x1 bytes:(const uint8_t*)json.bytes length:json.length];
}

- (void)sendAuthMessage {
    NSDictionary* payload = @{
        @"type": @"auth",
        @"volume_control": @(_esp32Volume.load(std::memory_order_acquire)),
        @"pitch_factor": @1.0,
        @"is_reset": @NO
    };
    NSData* json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    [self sendWebSocketFrameOpcode:0x1 bytes:(const uint8_t*)json.bytes length:json.length];
}

- (void)sendWebSocketFrameOpcode:(uint8_t)opcode bytes:(const uint8_t*)bytes length:(size_t)length {
    int fd = _clientFd.load(std::memory_order_acquire);
    if (fd < 0) return;

    uint8_t header[10];
    size_t headerLen = 0;
    header[headerLen++] = 0x80 | (opcode & 0x0f);
    if (length < 126) {
        header[headerLen++] = (uint8_t)length;
    } else if (length <= 0xffff) {
        header[headerLen++] = 126;
        header[headerLen++] = (uint8_t)((length >> 8) & 0xff);
        header[headerLen++] = (uint8_t)(length & 0xff);
    } else {
        return;
    }

    if (send(fd, header, headerLen, 0) < 0 || send(fd, bytes, length, 0) < 0) {
        int old = _clientFd.exchange(-1, std::memory_order_acq_rel);
        if (old >= 0) close(old);
        NSLog(@"Collider: ESP32 WebSocket client disconnected");
    }
}

@end

// ─── Settings Window Controller ─────────────────────────────────────────────
// Full settings panel: Model, Generation params, Audio I/O, MIDI sources.
// Accessible from app menu (Cmd+,) or from the gear icon in the React UI.

@interface ColliderSettingsController : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, assign) MIDIClientRef midiClient;
@property (nonatomic, assign) MIDIPortRef midiInputPort;
@property (nonatomic, strong) AVAudioEngine* audioEngine;
@property (nonatomic, strong) NSMutableSet<NSNumber*>* connectedSources;
@property (nonatomic, weak) ColliderAppController* appController;
@property (nonatomic, weak) ColliderAudioWebSocketStreamer* audioStreamer;
- (void)refreshMIDISources;
- (void)refreshAll;
@end

@implementation ColliderSettingsController {
    // Model
    NSTextField* _modelNameLabel;
    // Generation
    NSSlider* _temperatureSlider;   NSTextField* _temperatureValue;
    NSSlider* _topkSlider;          NSTextField* _topkValue;
    NSSlider* _cfgMusicCoCaSlider;  NSTextField* _cfgMusicCoCaValue;
    NSSlider* _cfgNotesSlider;      NSTextField* _cfgNotesValue;
    NSSlider* _cfgDrumsSlider;      NSTextField* _cfgDrumsValue;
    NSSlider* _unmaskWidthSlider;   NSTextField* _unmaskWidthValue;
    NSSlider* _volumeSlider;        NSTextField* _volumeValue;
    NSPopUpButton* _bufferSizePopup;
    NSButton* _muteCheckbox;
    NSButton* _drumModeCheckbox;
    // Audio
    NSTextField* _audioDeviceLabel;
    NSTextField* _audioSampleRateLabel;
    NSTextField* _audioBufferSizeLabel;
    NSSlider* _espVolumeSlider;     NSTextField* _espVolumeValue;
    // MIDI
    NSTextField* _midiVirtualLabel;
    NSTableView* _midiTableView;
    NSMutableArray<NSDictionary*>* _midiSources;
    NSButton* _computerKeyboardMidiCheckbox;
}

// ── Helpers for building UI ──

static NSTextField* makeLabel(NSString* text, CGFloat x, CGFloat y, CGFloat w) {
    NSTextField* label = [NSTextField labelWithString:text];
    label.frame = NSMakeRect(x, y, w, 16);
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

static NSTextField* makeValue(CGFloat x, CGFloat y) {
    NSTextField* label = [NSTextField labelWithString:@"—"];
    label.frame = NSMakeRect(x, y, 50, 16);
    label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.alignment = NSTextAlignmentRight;
    return label;
}

static NSSlider* makeSlider(CGFloat x, CGFloat y, CGFloat w, double min, double max, double val, id target, SEL action) {
    NSSlider* slider = [[NSSlider alloc] initWithFrame:NSMakeRect(x, y, w, 20)];
    slider.minValue = min;
    slider.maxValue = max;
    slider.doubleValue = val;
    slider.continuous = YES;
    slider.target = target;
    slider.action = action;
    return slider;
}

- (instancetype)init {
    CGFloat W = 480, H = 740;
    NSRect frame = NSMakeRect(0, 0, W, H);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Settings";
    window.releasedWhenClosed = NO;

    self = [super initWithWindow:window];
    if (!self) return nil;
    _connectedSources = [NSMutableSet set];
    _midiSources = [NSMutableArray array];
    window.delegate = self;

    NSView* c = window.contentView;
    CGFloat pad = 20, col2 = 110, sliderW = 280, valX = W - 70;
    CGFloat y = H - 40;

    // ── Model ──
    NSTextField* modelHeader = [NSTextField labelWithString:@"Model"];
    modelHeader.font = [NSFont boldSystemFontOfSize:13];
    modelHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:modelHeader];
    y -= 28;

    NSButton* loadBtn = [NSButton buttonWithTitle:@"Load Model..." target:self action:@selector(loadModelClicked:)];
    loadBtn.frame = NSMakeRect(pad, y, 120, 24);
    loadBtn.bezelStyle = NSBezelStyleRounded;
    loadBtn.font = [NSFont systemFontOfSize:12];
    [c addSubview:loadBtn];

    _modelNameLabel = [NSTextField labelWithString:@"No model loaded"];
    _modelNameLabel.frame = NSMakeRect(pad + 128, y + 3, W - pad - 148, 16);
    _modelNameLabel.font = [NSFont systemFontOfSize:11];
    _modelNameLabel.textColor = [NSColor secondaryLabelColor];
    _modelNameLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [c addSubview:_modelNameLabel];
    y -= 24;



    NSBox* sep0 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - 2 * pad, 1)];
    sep0.boxType = NSBoxSeparator;
    [c addSubview:sep0];
    y -= 24;

    // ── Generation ──
    NSTextField* genHeader = [NSTextField labelWithString:@"Generation"];
    genHeader.font = [NSFont boldSystemFontOfSize:13];
    genHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:genHeader];
    y -= 26;

    // Volume
    [c addSubview:makeLabel(@"Volume (dB)", pad, y, 90)];
    _volumeSlider = makeSlider(col2, y - 2, sliderW, -60, 12, 0, self, @selector(volumeChanged:));
    [c addSubview:_volumeSlider];
    _volumeValue = makeValue(valX, y); [c addSubview:_volumeValue];
    y -= 26;

    // Temperature
    [c addSubview:makeLabel(@"Temperature", pad, y, 90)];
    _temperatureSlider = makeSlider(col2, y - 2, sliderW, 0, 3, kMagentaDefaultTemperature, self, @selector(temperatureChanged:));
    [c addSubview:_temperatureSlider];
    _temperatureValue = makeValue(valX, y); [c addSubview:_temperatureValue];
    y -= 26;

    // Top-K
    [c addSubview:makeLabel(@"Top-K", pad, y, 90)];
    _topkSlider = makeSlider(col2, y - 2, sliderW, 1, 1024, kMagentaDefaultTopK, self, @selector(topkChanged:));
    [c addSubview:_topkSlider];
    _topkValue = makeValue(valX, y); [c addSubview:_topkValue];
    y -= 26;



    // CFG-MusicCoCa
    [c addSubview:makeLabel(@"CFG-MusicCoCa", pad, y, 90)];
    _cfgMusicCoCaSlider = makeSlider(col2, y - 2, sliderW, 0, 5, kColliderDefaultCfgMusicCoCa, self, @selector(cfgMusicCoCaChanged:));
    [c addSubview:_cfgMusicCoCaSlider];
    _cfgMusicCoCaValue = makeValue(valX, y); [c addSubview:_cfgMusicCoCaValue];
    y -= 26;

    // CFG-Notes
    [c addSubview:makeLabel(@"CFG-Notes", pad, y, 90)];
    _cfgNotesSlider = makeSlider(col2, y - 2, sliderW, 0, 5, kColliderDefaultCfgNotes, self, @selector(cfgNotesChanged:));
    [c addSubview:_cfgNotesSlider];
    _cfgNotesValue = makeValue(valX, y); [c addSubview:_cfgNotesValue];
    y -= 26;

    // CFG-Drums
    [c addSubview:makeLabel(@"CFG-Drums", pad, y, 90)];
    _cfgDrumsSlider = makeSlider(col2, y - 2, sliderW, 0, 5, 1, self, @selector(cfgDrumsChanged:));
    [c addSubview:_cfgDrumsSlider];
    _cfgDrumsValue = makeValue(valX, y); [c addSubview:_cfgDrumsValue];
    y -= 26;

    // Unmask width
    [c addSubview:makeLabel(@"Unmask width", pad, y, 90)];
    _unmaskWidthSlider = makeSlider(col2, y - 2, sliderW, 0, 127, 0, self, @selector(unmaskWidthChanged:));
    [c addSubview:_unmaskWidthSlider];
    _unmaskWidthValue = makeValue(valX, y); [c addSubview:_unmaskWidthValue];
    y -= 30;

    // Buffer size
    [c addSubview:makeLabel(@"Buffer Size", pad, y + 2, 90)];
    _bufferSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(col2, y, 100, 22) pullsDown:NO];
    [_bufferSizePopup addItemsWithTitles:@[@"2048", @"4096", @"8192"]];
    _bufferSizePopup.font = [NSFont systemFontOfSize:11];
    _bufferSizePopup.target = self;
    _bufferSizePopup.action = @selector(bufferSizeChanged:);
    [c addSubview:_bufferSizePopup];

    _muteCheckbox = [NSButton checkboxWithTitle:@"Mute" target:self action:@selector(muteChanged:)];
    _muteCheckbox.frame = NSMakeRect(col2 + 120, y + 1, 60, 18);
    _muteCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_muteCheckbox];

    _drumModeCheckbox = [NSButton checkboxWithTitle:@"Drum Mode" target:self action:@selector(drumModeChanged:)];
    _drumModeCheckbox.frame = NSMakeRect(col2 + 190, y + 1, 100, 18);
    _drumModeCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_drumModeCheckbox];
    y -= 20;

    // Reset defaults
    NSButton* resetBtn = [NSButton buttonWithTitle:@"Reset Defaults" target:self action:@selector(resetDefaults:)];
    resetBtn.frame = NSMakeRect(pad, y, 120, 20);
    resetBtn.bezelStyle = NSBezelStyleInline;
    resetBtn.font = [NSFont systemFontOfSize:11];
    [c addSubview:resetBtn];
    y -= 16;

    NSBox* sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - 2 * pad, 1)];
    sep1.boxType = NSBoxSeparator;
    [c addSubview:sep1];
    y -= 24;

    // ── Audio Output ──
    NSTextField* audioHeader = [NSTextField labelWithString:@"Audio Output"];
    audioHeader.font = [NSFont boldSystemFontOfSize:13];
    audioHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:audioHeader];
    y -= 22;

    [c addSubview:makeLabel(@"Device:", pad, y, 55)];
    _audioDeviceLabel = [NSTextField labelWithString:@"—"];
    _audioDeviceLabel.frame = NSMakeRect(pad + 60, y, 350, 16);
    _audioDeviceLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioDeviceLabel];
    y -= 18;

    [c addSubview:makeLabel(@"Sample Rate:", pad, y, 80)];
    _audioSampleRateLabel = [NSTextField labelWithString:@"—"];
    _audioSampleRateLabel.frame = NSMakeRect(pad + 85, y, 200, 16);
    _audioSampleRateLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioSampleRateLabel];
    y -= 18;

    [c addSubview:makeLabel(@"Buffer Size:", pad, y, 80)];
    _audioBufferSizeLabel = [NSTextField labelWithString:@"—"];
    _audioBufferSizeLabel.frame = NSMakeRect(pad + 85, y, 200, 16);
    _audioBufferSizeLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioBufferSizeLabel];
    y -= 24;

    // ESP32 speaker volume (sent to the device as a VOLUME.UPDATE message)
    [c addSubview:makeLabel(@"ESP32 Volume", pad, y, 90)];
    _espVolumeSlider = makeSlider(col2, y - 2, sliderW, 0, 100, 100, self, @selector(espVolumeChanged:));
    [c addSubview:_espVolumeSlider];
    _espVolumeValue = makeValue(valX, y); [c addSubview:_espVolumeValue];
    y -= 24;

    NSBox* sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - 2 * pad, 1)];
    sep2.boxType = NSBoxSeparator;
    [c addSubview:sep2];
    y -= 24;

    // ── MIDI Input ──
    NSTextField* midiHeader = [NSTextField labelWithString:@"MIDI Input"];
    midiHeader.font = [NSFont boldSystemFontOfSize:13];
    midiHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:midiHeader];
    y -= 20;

    _midiVirtualLabel = [NSTextField labelWithString:@"Virtual port: mr. esp32 Input"];
    _midiVirtualLabel.frame = NSMakeRect(pad, y, 400, 16);
    _midiVirtualLabel.font = [NSFont systemFontOfSize:10];
    _midiVirtualLabel.textColor = [NSColor tertiaryLabelColor];
    [c addSubview:_midiVirtualLabel];
    y -= 20;

    _computerKeyboardMidiCheckbox = [NSButton checkboxWithTitle:@"Use computer keyboard as MIDI input (Ableton layout)"
                                                         target:self
                                                         action:@selector(computerKeyboardMidiChanged:)];
    _computerKeyboardMidiCheckbox.frame = NSMakeRect(pad, y, 400, 18);
    _computerKeyboardMidiCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_computerKeyboardMidiCheckbox];
    y -= 20;

    [c addSubview:makeLabel(@"Connect to MIDI sources (click to toggle):", pad, y, 400)];
    y -= 6;

    NSScrollView* scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(pad, 12, W - 2 * pad, y - 12)];
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSBezelBorder;

    _midiTableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    NSTableColumn* checkCol = [[NSTableColumn alloc] initWithIdentifier:@"connected"];
    checkCol.title = @""; checkCol.width = 30; checkCol.minWidth = 30; checkCol.maxWidth = 30;
    [_midiTableView addTableColumn:checkCol];
    NSTableColumn* nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"Source"; nameCol.width = W - 2 * pad - 50;
    [_midiTableView addTableColumn:nameCol];

    _midiTableView.dataSource = self;
    _midiTableView.delegate = self;
    _midiTableView.headerView = nil;
    _midiTableView.rowHeight = 22;
    _midiTableView.target = self;
    _midiTableView.action = @selector(midiTableClicked:);
    scrollView.documentView = _midiTableView;
    [c addSubview:scrollView];

    return self;
}

// ── Show / refresh ──

- (void)showWindow:(id)sender {
    [self refreshAll];
    [super showWindow:sender];
    [self.window center];
}

- (void)refreshAll {
    [self refreshParams];
    [self refreshAudioInfo];
    [self refreshMIDISources];
    [self refreshModelName];
    BOOL kbdMidi = [[NSUserDefaults standardUserDefaults] boolForKey:@"Collider_ComputerKeyboardMidi"];
    _computerKeyboardMidiCheckbox.state = kbdMidi ? NSControlStateValueOn : NSControlStateValueOff;

    int espVol = _audioStreamer ? _audioStreamer.esp32Volume : 100;
    _espVolumeSlider.doubleValue = espVol;
    _espVolumeValue.stringValue = [NSString stringWithFormat:@"%d%%", espVol];
}

- (void)computerKeyboardMidiChanged:(NSButton*)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [_appController setComputerKeyboardMidiEnabled:enabled];
}

- (void)refreshModelName {
    NSString* modelPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"Collider_ModelPath"];
    _modelNameLabel.stringValue = modelPath ? modelPath.lastPathComponent : @"No model loaded";
}

- (void)refreshParams {
    ColliderAppController* ctrl = _appController;
    if (!ctrl) return;

    _temperatureSlider.doubleValue = [ctrl readParamFromEngine:0];
    _temperatureValue.stringValue = [NSString stringWithFormat:@"%.2f", _temperatureSlider.doubleValue];

    _topkSlider.doubleValue = [ctrl readParamFromEngine:1];
    _topkValue.stringValue = [NSString stringWithFormat:@"%d", (int)_topkSlider.doubleValue];



    _cfgMusicCoCaSlider.doubleValue = [ctrl readParamFromEngine:3];
    _cfgMusicCoCaValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgMusicCoCaSlider.doubleValue];

    _cfgNotesSlider.doubleValue = [ctrl readParamFromEngine:4];
    _cfgNotesValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgNotesSlider.doubleValue];

    _cfgDrumsSlider.doubleValue = [ctrl readParamFromEngine:48];
    _cfgDrumsValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgDrumsSlider.doubleValue];

    _unmaskWidthSlider.doubleValue = [ctrl readParamFromEngine:7];
    _unmaskWidthValue.stringValue = [NSString stringWithFormat:@"%d", (int)_unmaskWidthSlider.doubleValue];

    _volumeSlider.doubleValue = [ctrl readParamFromEngine:5];
    _volumeValue.stringValue = [NSString stringWithFormat:@"%.1f", _volumeSlider.doubleValue];

    float bufVal = [ctrl readParamFromEngine:8];
    [_bufferSizePopup selectItemAtIndex:(bufVal < 0.5 ? 0 : (bufVal < 1.5 ? 1 : 2))];

    _muteCheckbox.state = ([ctrl readParamFromEngine:6] > 0.5) ? NSControlStateValueOn : NSControlStateValueOff;
    _drumModeCheckbox.state = ([ctrl readParamFromEngine:39] > 0.5) ? NSControlStateValueOn : NSControlStateValueOff;
}

// ── Slider / control actions ──

- (void)temperatureChanged:(NSSlider*)sender {
    _temperatureValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:0 value:(float)sender.doubleValue];
}
- (void)topkChanged:(NSSlider*)sender {
    int v = (int)sender.doubleValue;
    _topkValue.stringValue = [NSString stringWithFormat:@"%d", v];
    [_appController applyParamToEngine:1 value:(float)v];
}

- (void)cfgMusicCoCaChanged:(NSSlider*)sender {
    _cfgMusicCoCaValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:3 value:(float)sender.doubleValue];
}
- (void)cfgNotesChanged:(NSSlider*)sender {
    _cfgNotesValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:4 value:(float)sender.doubleValue];
}
- (void)cfgDrumsChanged:(NSSlider*)sender {
    _cfgDrumsValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:48 value:(float)sender.doubleValue];
}
- (void)unmaskWidthChanged:(NSSlider*)sender {
    int v = (int)sender.doubleValue;
    _unmaskWidthValue.stringValue = [NSString stringWithFormat:@"%d", v];
    [_appController applyParamToEngine:7 value:(float)v];
}
- (void)volumeChanged:(NSSlider*)sender {
    _volumeValue.stringValue = [NSString stringWithFormat:@"%.1f", sender.doubleValue];
    [_appController applyParamToEngine:5 value:(float)sender.doubleValue];
}
- (void)espVolumeChanged:(NSSlider*)sender {
    int v = (int)lround(sender.doubleValue);
    _espVolumeValue.stringValue = [NSString stringWithFormat:@"%d%%", v];
    [_audioStreamer setEsp32Volume:v];
}
- (void)bufferSizeChanged:(NSPopUpButton*)sender {
    [_appController applyParamToEngine:8 value:(float)sender.indexOfSelectedItem];
}
- (void)muteChanged:(NSButton*)sender {
    [_appController applyParamToEngine:6 value:(sender.state == NSControlStateValueOn) ? 1.0f : 0.0f];
}
- (void)drumModeChanged:(NSButton*)sender {
    [_appController applyParamToEngine:39 value:(sender.state == NSControlStateValueOn) ? 1.0f : 0.0f];
}


- (void)loadModelClicked:(id)sender {
    [_appController handleLoadModel];
    // Refresh model name after a short delay (loading is async)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshModelName];
    });
}

- (void)resetDefaults:(id)sender {
    [MagentaSettings resetDefaultsOnEngine:_appController.engine
                              prefixString:@"Collider"
                                  cfgNotes:kColliderDefaultCfgNotes
                              cfgMusicCoCa:kColliderDefaultCfgMusicCoCa];
    [self refreshParams];
}

// ── Audio info ──

- (void)refreshAudioInfo {
    if (!_audioEngine) return;
    AVAudioFormat* outputFormat = [_audioEngine.outputNode outputFormatForBus:0];
    double sampleRate = outputFormat.sampleRate;

    AudioDeviceID deviceID = 0;
    UInt32 propSize = sizeof(deviceID);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &propSize, &deviceID);

    NSString* deviceName = @"Unknown";
    if (deviceID != 0) {
        CFStringRef cfName = NULL;
        propSize = sizeof(cfName);
        AudioObjectPropertyAddress nameAddr = {
            kAudioDevicePropertyDeviceNameCFString,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(deviceID, &nameAddr, 0, NULL, &propSize, &cfName) == noErr && cfName) {
            deviceName = (__bridge_transfer NSString*)cfName;
        }
    }

    UInt32 bufferFrames = 0;
    propSize = sizeof(bufferFrames);
    AudioObjectPropertyAddress bufAddr = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (deviceID != 0) {
        AudioObjectGetPropertyData(deviceID, &bufAddr, 0, NULL, &propSize, &bufferFrames);
    }

    _audioDeviceLabel.stringValue = deviceName;
    _audioSampleRateLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz (engine: 48000 Hz)", sampleRate];
    _audioBufferSizeLabel.stringValue = [NSString stringWithFormat:@"%u frames", (unsigned)bufferFrames];
}

// ── MIDI sources ──

- (void)refreshMIDISources {
    [_midiSources removeAllObjects];
    ItemCount sourceCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < sourceCount; ++i) {
        MIDIEndpointRef src = MIDIGetSource(i);
        CFStringRef cfName = NULL;
        MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cfName);
        NSString* name = cfName ? (__bridge_transfer NSString*)cfName : @"Unknown MIDI Source";
        BOOL connected = [_connectedSources containsObject:@((uint32_t)src)];
        [_midiSources addObject:@{ @"name": name, @"endpoint": @((uint32_t)src), @"connected": @(connected) }];
    }
    [_midiTableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_midiSources.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row >= (NSInteger)_midiSources.count) return nil;
    NSDictionary* source = _midiSources[(NSUInteger)row];
    if ([tableColumn.identifier isEqualToString:@"connected"]) {
        NSTextField* cell = [tableView makeViewWithIdentifier:@"checkCell" owner:self];
        if (!cell) { cell = [NSTextField labelWithString:@""]; cell.identifier = @"checkCell"; cell.alignment = NSTextAlignmentCenter; }
        cell.stringValue = [source[@"connected"] boolValue] ? @"\u2713" : @"";
        cell.font = [NSFont systemFontOfSize:14];
        return cell;
    } else {
        NSTextField* cell = [tableView makeViewWithIdentifier:@"nameCell" owner:self];
        if (!cell) { cell = [NSTextField labelWithString:@""]; cell.identifier = @"nameCell"; cell.bordered = NO; cell.editable = NO; cell.drawsBackground = NO; }
        cell.stringValue = source[@"name"];
        cell.font = [NSFont systemFontOfSize:12];
        return cell;
    }
}

- (void)midiTableClicked:(id)sender {
    NSInteger row = _midiTableView.clickedRow;
    if (row < 0 || row >= (NSInteger)_midiSources.count) return;
    NSDictionary* source = _midiSources[(NSUInteger)row];
    MIDIEndpointRef endpoint = (MIDIEndpointRef)[source[@"endpoint"] unsignedIntValue];
    BOOL wasConnected = [source[@"connected"] boolValue];
    if (wasConnected) {
        if (MIDIPortDisconnectSource(_midiInputPort, endpoint) == noErr)
            [_connectedSources removeObject:@((uint32_t)endpoint)];
    } else {
        if (MIDIPortConnectSource(_midiInputPort, endpoint, NULL) == noErr)
            [_connectedSources addObject:@((uint32_t)endpoint)];
    }
    [self refreshMIDISources];
}
@end

// ─── AppDelegate ─────────────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate, ColliderAudioWebSocketStreamerDelegate, ColliderVoiceAgentDelegate>
@end

@implementation AppDelegate {
    RealtimeRunner _engine;
    ColliderSharedState _sharedState;
    AVAudioEngine* _audioEngine;
    AVAudioSourceNode* _sourceNode;
    ColliderAudioWebSocketStreamer* _audioWebSocketStreamer;
    ColliderVoiceAgent* _voiceAgent;
    MIDIClientRef _midiClient;
    MIDIPortRef _midiInputPort;
    MIDIEndpointRef _midiVirtualDest;
    NSWindow* _window;
    ColliderAppController* _controller;
    ColliderSettingsController* _settingsController;
    BOOL _isPlaying;
    BOOL _voiceCommandActive;
    BOOL _resumeSpeakerAfterVoice;
    std::atomic<bool> _localOutputEnabled;
    NSMenuItem* _playStopMenuItem;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // Initialize ML assets from ~/Documents/Magenta/magenta-rt-v2/resources (centralized path) or saved custom folder.
    // Model files should be placed in ~/Documents/Magenta/magenta-rt-v2/models/.
    NSString *customResources = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_CustomResourcesPath"];
    std::string resources = customResources ? customResources.UTF8String : magentart::paths::get_resources_dir();
    if (!_engine.init_assets(resources.c_str())) {
        NSLog(@"Collider: Failed to load static assets from %s", resources.c_str());
    }

    _controller = [[ColliderAppController alloc] init];
    _controller.engine = &_engine;
    _controller.sharedState = &_sharedState;

    // Restore saved parameters immediately so the engine has them from start
    [_controller restoreSavedParams];

    // Start bypassed; user must press Play
    _engine.set_bypass(true);
    _localOutputEnabled.store(false, std::memory_order_relaxed);
    _engine.set_cfg_musiccoca(kColliderDefaultCfgMusicCoCa);
    _engine.set_cfg_notes(kColliderDefaultCfgNotes);

    _audioWebSocketStreamer = [[ColliderAudioWebSocketStreamer alloc] initWithPort:kEsp32WebSocketPort
                                                                               path:@"/ws/esp32"];
    _audioWebSocketStreamer.delegate = self;
    [_audioWebSocketStreamer start];
    _voiceAgent = [[ColliderVoiceAgent alloc] init];
    _voiceAgent.delegate = self;
    [_voiceAgent start];

    // 500×500 window, resizable for testing
    NSRect frame = NSMakeRect(0, 0, 700, 505);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled |
                                                    NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable |
                                                    NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"mr. esp32 by ELATO";
    _window.restorable = NO;
    _window.contentMinSize = NSMakeSize(310, 310);
    _window.contentViewController = _controller;
    [_window center];
    [_window makeKeyAndOrderFront:nil];

    [self setupAudioEngine];
    [self setupMIDI];
    [self setupMenuBar];

    _settingsController = [[ColliderSettingsController alloc] init];
    _settingsController.midiClient = _midiClient;
    _settingsController.midiInputPort = _midiInputPort;
    _settingsController.audioEngine = _audioEngine;
    _settingsController.appController = _controller;
    _settingsController.audioStreamer = _audioWebSocketStreamer;

    [self autoLoadModel];
}

- (void)enterVoiceCommandModeIfNeeded {
    if (_voiceCommandActive) return;
    _voiceCommandActive = YES;
    _resumeSpeakerAfterVoice = _audioWebSocketStreamer.streamingEnabled;
    [_audioWebSocketStreamer suspendStreamingForVoiceCommand];
    _isPlaying = NO;
    _playStopMenuItem.title = @"Play";
    [self updateEngineBypassForOutputStateTriggeringReset:NO];
    [_controller sendStateUpdate:@{
        @"isPlaying": @NO,
        @"speakerStreaming": @NO,
        @"voiceStatus": @"listening",
        @"voiceTranscript": @""
    }];
    NSLog(@"Collider: entered ESP32 voice command mode");
}

- (void)colliderAudioWebSocketStreamerDidReceiveMicrophoneAudio:(NSData*)data {
    [self enterVoiceCommandModeIfNeeded];
    [_voiceAgent pushPCM16Audio:data];
}

- (void)voiceAgentDidStartSpeech {
    [self enterVoiceCommandModeIfNeeded];
}

- (void)voiceAgentDidCommitAudio {
    [_audioWebSocketStreamer sendServerMessage:@"AUDIO.COMMITTED"];
    [_controller sendStateUpdate:@{@"voiceStatus": @"processing"}];
}

- (void)voiceAgentDidTranscribe:(NSString*)transcript {
    [_controller sendStateUpdate:@{@"voiceStatus": @"thinking", @"voiceTranscript": transcript ?: @""}];
}

- (void)voiceAgentDidFinishWithTranscript:(NSString*)transcript toolCalls:(NSArray*)toolCalls {
    NSLog(@"Collider voice command transcript: %@ tools=%@", transcript, toolCalls);
    [_controller sendStateUpdate:@{
        @"voiceStatus": @"done",
        @"voiceToolCalls": toolCalls ?: @[],
        @"voiceTranscript": transcript ?: @""
    }];
    _voiceCommandActive = NO;
    if (_resumeSpeakerAfterVoice) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self->_audioWebSocketStreamer setStreamingEnabled:YES];
            [self updateEngineBypassForOutputStateTriggeringReset:YES];
            [self->_controller sendStateUpdate:@{@"speakerStreaming": @YES, @"voiceStatus": @"idle"}];
        });
    } else {
        [_audioWebSocketStreamer sendServerMessage:@"AUDIO.COMMITTED"];
        [self updateEngineBypassForOutputStateTriggeringReset:NO];
        [_controller sendStateUpdate:@{@"voiceStatus": @"idle"}];
    }
}

- (void)voiceAgentDidFail:(NSString*)message {
    NSLog(@"Collider voice agent failed: %@", message);
    [_controller sendStateUpdate:@{@"voiceStatus": @"error"}];
    [self voiceAgentDidFinishWithTranscript:@"" toolCalls:@[]];
}

// ─── AVAudioEngine ───────────────────────────────────────────────────────────

- (void)setupAudioEngine {
    _audioEngine = [[AVAudioEngine alloc] init];
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:2];

    RealtimeRunner* engine = &_engine;
    ColliderSharedState* shared = &_sharedState;
    ColliderAudioWebSocketStreamer* streamer = _audioWebSocketStreamer;
    std::atomic<bool>* localOutputEnabled = &_localOutputEnabled;

    _sourceNode = [[AVAudioSourceNode alloc]
        initWithFormat:format
        renderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp,
                              AVAudioFrameCount frameCount, AudioBufferList* outputData) {
        float* outL = (float*)outputData->mBuffers[0].mData;
        float* outR = (outputData->mNumberBuffers > 1)
                      ? (float*)outputData->mBuffers[1].mData : outL;

        if (!engine->is_loaded()) {
            memset(outL, 0, frameCount * sizeof(float));
            if (outputData->mNumberBuffers > 1) memset(outR, 0, frameCount * sizeof(float));
            *isSilence = YES;
            return noErr;
        }

        engine->read_audio_stereo(outL, outR, frameCount, false);
        shared->pushAudioSamples(outL, outR, frameCount);
        [streamer pushLeft:outL right:outR count:frameCount];
        if (!localOutputEnabled->load(std::memory_order_relaxed)) {
            memset(outL, 0, frameCount * sizeof(float));
            if (outputData->mNumberBuffers > 1) memset(outR, 0, frameCount * sizeof(float));
            *isSilence = YES;
        }
        return noErr;
    }];

    [_audioEngine attachNode:_sourceNode];
    [_audioEngine connect:_sourceNode to:_audioEngine.mainMixerNode format:format];

    NSError* error = nil;
    if (![_audioEngine startAndReturnError:&error]) {
        NSLog(@"Collider: AVAudioEngine failed to start: %@", error);
    }
}

// ─── CoreMIDI ────────────────────────────────────────────────────────────────

- (void)setupMIDI {
    RealtimeRunner* engine = &_engine;
    ColliderSharedState* shared = &_sharedState;

    OSStatus status = MIDIClientCreateWithBlock(
        CFSTR("mr. esp32"),
        &_midiClient,
        ^(const MIDINotification* notification) {
            if (notification->messageID == kMIDIMsgSetupChanged) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_settingsController refreshMIDISources];
                });
            }
        }
    );
    if (status != noErr) { NSLog(@"Collider: MIDIClientCreate failed: %d", (int)status); return; }

    status = MIDIInputPortCreateWithProtocol(
        _midiClient, CFSTR("mr. esp32 In"), kMIDIProtocol_1_0, &_midiInputPort,
        ^(const MIDIEventList* evtList, void* srcConnRefCon) {
            const MIDIEventPacket* pkt = &evtList->packet[0];
            for (UInt32 i = 0; i < evtList->numPackets; ++i) {
                for (UInt32 w = 0; w < pkt->wordCount; ++w) {
                    uint32_t word = pkt->words[w];
                    uint8_t msgType = (word >> 28) & 0xF;
                    if (msgType == 0x2) {
                        uint8_t statusByte = (word >> 16) & 0xFF;
                        uint8_t statusNibble = statusByte & 0xF0;
                        uint8_t note = (word >> 8) & 0x7F;
                        uint8_t velocity = word & 0x7F;
                        if (statusNibble == 0x90 && velocity > 0) {
                            engine->set_note_on(note);
                            shared->noteOn(note);
                        } else if (statusNibble == 0x80 || (statusNibble == 0x90 && velocity == 0)) {
                            engine->set_note_off(note);
                            shared->noteOff(note);
                        }
                    }
                }
                pkt = MIDIEventPacketNext(pkt);
            }
        }
    );
    if (status != noErr) { NSLog(@"Collider: MIDIInputPortCreate failed: %d", (int)status); return; }

    status = MIDIDestinationCreateWithProtocol(
        _midiClient, CFSTR("mr. esp32 Input"), kMIDIProtocol_1_0, &_midiVirtualDest,
        ^(const MIDIEventList* evtList, void* srcConnRefCon) {
            const MIDIEventPacket* pkt = &evtList->packet[0];
            for (UInt32 i = 0; i < evtList->numPackets; ++i) {
                for (UInt32 w = 0; w < pkt->wordCount; ++w) {
                    uint32_t word = pkt->words[w];
                    uint8_t msgType = (word >> 28) & 0xF;
                    if (msgType == 0x2) {
                        uint8_t statusByte = (word >> 16) & 0xFF;
                        uint8_t statusNibble = statusByte & 0xF0;
                        uint8_t note = (word >> 8) & 0x7F;
                        uint8_t velocity = word & 0x7F;
                        if (statusNibble == 0x90 && velocity > 0) {
                            engine->set_note_on(note);
                            shared->noteOn(note);
                        } else if (statusNibble == 0x80 || (statusNibble == 0x90 && velocity == 0)) {
                            engine->set_note_off(note);
                            shared->noteOff(note);
                        }
                    }
                }
                pkt = MIDIEventPacketNext(pkt);
            }
        }
    );
    if (status != noErr) {
        NSLog(@"Collider: MIDIDestinationCreate failed: %d", (int)status);
    }
}

// ─── Menu bar ────────────────────────────────────────────────────────────────

- (void)setupMenuBar {
    NSMenu* menuBar = [[NSMenu alloc] init];

    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About mr. esp32 by ELATO" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Settings..." action:@selector(menuShowSettings:) keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit mr. esp32 by ELATO" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    [menuBar addItem:appMenuItem];

    NSMenuItem* fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Load Model..." action:@selector(menuLoadModel:) keyEquivalent:@"o"];
    fileMenuItem.submenu = fileMenu;
    [menuBar addItem:fileMenuItem];

    NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;
    [menuBar addItem:editMenuItem];

    NSMenuItem* transportMenuItem = [[NSMenuItem alloc] init];
    NSMenu* transportMenu = [[NSMenu alloc] initWithTitle:@"Transport"];
    _playStopMenuItem = [transportMenu addItemWithTitle:@"Play"
                                                  action:@selector(menuTogglePlayStop:)
                                           keyEquivalent:@" "];
    [transportMenu addItemWithTitle:@"Toggle ESP32 Speaker Stream"
                              action:@selector(menuToggleSpeakerStream:)
                       keyEquivalent:@"s"];
    _isPlaying = NO;
    _localOutputEnabled.store(false, std::memory_order_relaxed);
    transportMenuItem.submenu = transportMenu;
    [menuBar addItem:transportMenuItem];

    [NSApp setMainMenu:menuBar];
}

- (void)updateEngineBypassForOutputStateTriggeringReset:(BOOL)triggerReset {
    BOOL shouldRunEngine = _isPlaying || _audioWebSocketStreamer.streamingEnabled;
    _engine.set_bypass(!shouldRunEngine);
    _localOutputEnabled.store(_isPlaying, std::memory_order_relaxed);
    if (shouldRunEngine && triggerReset) {
        _engine.trigger_reset();
    }
}

- (void)menuTogglePlayStop:(id)sender {
    BOOL wasRunningEngine = _isPlaying || _audioWebSocketStreamer.streamingEnabled;
    if (_isPlaying) {
        _isPlaying = NO;
        _playStopMenuItem.title = @"Play";
    } else {
        _isPlaying = YES;
        _playStopMenuItem.title = @"Pause";
    }
    [self updateEngineBypassForOutputStateTriggeringReset:(!wasRunningEngine && _isPlaying)];
    [_controller sendPlayState:_isPlaying];
}

- (void)menuToggleSpeakerStream:(id)sender {
    BOOL wasRunningEngine = _isPlaying || _audioWebSocketStreamer.streamingEnabled;
    BOOL enabled = !_audioWebSocketStreamer.streamingEnabled;
    [_audioWebSocketStreamer setStreamingEnabled:enabled];
    [self updateEngineBypassForOutputStateTriggeringReset:(!wasRunningEngine && enabled)];
    [_controller sendStateUpdate:@{@"speakerStreaming": @(_audioWebSocketStreamer.streamingEnabled)}];
}

- (void)menuShowSettings:(id)sender {
    if (_controller) {
        [_controller showReactSettings];
    }
}

- (void)menuLoadModel:(id)sender {
    [_controller handleLoadModel];
}

// ─── Auto-load model ─────────────────────────────────────────────────────────

- (void)autoLoadModel {
    NSString* modelPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"Collider_ModelPath"];
    if (!modelPath) return;

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) return;

    NSLog(@"Collider: Auto-loading model from %@", modelPath);
    [_controller setModelLoading:YES];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = self->_engine.load_model(modelPath.UTF8String);
        if (success) {
            NSLog(@"Collider: Model loaded successfully.");

            NSString* parentDir = [modelPath stringByDeletingLastPathComponent];
            NSString* corpusPath = [parentDir stringByAppendingPathComponent:@"corpus.safetensors"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:corpusPath]) {
                self->_engine.load_pca_file(corpusPath.UTF8String);
            }

            [self->_controller restoreSavedParams];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_controller notifyModelLoaded:modelPath.lastPathComponent];
            });
        } else {
            NSLog(@"Collider: Failed to auto-load model from %@", modelPath);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_controller setModelLoading:NO];
                [self->_controller sendStateUpdate:@{@"modelName": @"No model loaded"}];
            });
        }
    });
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)applicationWillTerminate:(NSNotification*)notification {
    [_audioWebSocketStreamer stop];
    [_voiceAgent stop];
    _engine.stop();
    _engine.unload();
    [_audioEngine stop];
    if (_midiVirtualDest) MIDIEndpointDispose(_midiVirtualDest);
    if (_midiInputPort) MIDIPortDispose(_midiInputPort);
    if (_midiClient) MIDIClientDispose(_midiClient);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender { return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

@end

// ─── main ────────────────────────────────────────────────────────────────────

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
