//
//  LFHardwareAudioEncoder.m
//  LFLiveKit
//
//  Created by 倾慕 on 16/5/2.
//  Copyright © 2016年 倾慕. All rights reserved.
//

#import "LFHardwareAudioEncoder.h"

@interface LFHardwareAudioEncoder (){
    AudioConverterRef m_converter;
    char *aacBuf;
    char *leftBuf;
    NSInteger leftLength;
}
@property (nonatomic, strong) LFLiveAudioConfiguration *configuration;
@property (nonatomic, weak) id<LFAudioEncodingDelegate> aacDeleage;

@end

@implementation LFHardwareAudioEncoder

- (instancetype)initWithAudioStreamConfiguration:(LFLiveAudioConfiguration *)configuration {
    if (self = [super init]) {
        NSLog(@"USE LFHardwareAudioEncoder");
        _configuration = configuration;
        if (!leftBuf) {
            leftBuf = malloc(_configuration.bufferLength);
        }
        
        if (!aacBuf) {
            aacBuf = malloc(_configuration.bufferLength);
        }
    }
    return self;
}

- (void)dealloc {
    if (aacBuf) free(aacBuf);
    if (leftBuf) free(leftBuf);
}

#pragma mark -- LFAudioEncoder
- (void)setDelegate:(id<LFAudioEncodingDelegate>)delegate {
    _aacDeleage = delegate;
}

- (void)encodeAudioData:(AudioBufferList)inBufferList timeStamp:(uint64_t)timeStamp {
    if (![self createAudioConvert]) {
        return;
    }
    
    AudioBuffer inBuffer = inBufferList.mBuffers[0];
    
    if(leftLength + inBuffer.mDataByteSize >= _configuration.bufferLength){
        ///<  发送
        char *sendBuf = malloc(_configuration.bufferLength);
        memset(sendBuf, 0, _configuration.bufferLength);
        memcpy(sendBuf, leftBuf, leftLength);
        memcpy(sendBuf + leftLength, inBuffer.mData, _configuration.bufferLength - leftLength);
        inBuffer.mDataByteSize = (UInt32)_configuration.bufferLength;
        
        
        [self encodeBuffer:sendBuf timeStamp:timeStamp];
        free(sendBuf);
        
        memset(leftBuf, 0, _configuration.bufferLength);
        memcpy(leftBuf, inBuffer.mData + (_configuration.bufferLength - leftLength), inBuffer.mDataByteSize - (_configuration.bufferLength - leftLength));
        leftLength = inBuffer.mDataByteSize - (_configuration.bufferLength - leftLength);
        
    }else{
        ///< 积累
        memcpy(leftBuf+leftLength, inBuffer.mData, inBuffer.mDataByteSize);
        leftLength = leftLength + inBuffer.mDataByteSize;
    }
}

- (void)encodeBuffer:(char*)buf timeStamp:(uint64_t)timeStamp{
    
    AudioBuffer inBuffer;
    inBuffer.mNumberChannels = 1;
    inBuffer.mData = buf;
    inBuffer.mDataByteSize = (UInt32)_configuration.bufferLength;
    
    AudioBufferList buffers;
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0] = inBuffer;
    
    // 初始化一个输出缓冲列表
    AudioBufferList outBufferList;
    outBufferList.mNumberBuffers = 1;
    outBufferList.mBuffers[0].mNumberChannels = inBuffer.mNumberChannels;
    outBufferList.mBuffers[0].mDataByteSize = inBuffer.mDataByteSize;   // 设置缓冲区大小
    outBufferList.mBuffers[0].mData = aacBuf;           // 设置AAC缓冲区
    UInt32 outputDataPacketSize = 1;
    if (AudioConverterFillComplexBuffer(m_converter, inputDataProc, &buffers, &outputDataPacketSize, &outBufferList, NULL) != noErr) {
        return;
    }
    
    LFAudioFrame *audioFrame = [LFAudioFrame new];
    audioFrame.timestamp = timeStamp;
    audioFrame.data = [NSData dataWithBytes:aacBuf length:outBufferList.mBuffers[0].mDataByteSize];
    
    char exeData[2];
    exeData[0] = _configuration.asc[0];
    exeData[1] = _configuration.asc[1];
    audioFrame.audioInfo = [NSData dataWithBytes:exeData length:2];
    if (self.aacDeleage && [self.aacDeleage respondsToSelector:@selector(audioEncoder:audioFrame:)]) {
        [self.aacDeleage audioEncoder:self audioFrame:audioFrame];
    }
}

- (void)stopEncoder {

}

#pragma mark -- CustomMethod
- (BOOL)createAudioConvert { //根据输入样本初始化一个编码转换器
    if (m_converter != nil) {
        return TRUE;
    }

    AudioStreamBasicDescription inputFormat = {0};
    inputFormat.mSampleRate = _configuration.audioSampleRate;
    inputFormat.mFormatID = kAudioFormatLinearPCM;
    inputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    inputFormat.mChannelsPerFrame = (UInt32)_configuration.numberOfChannels;
    inputFormat.mFramesPerPacket = 1;
    inputFormat.mBitsPerChannel = 16;
    inputFormat.mBytesPerFrame = inputFormat.mBitsPerChannel / 8 * inputFormat.mChannelsPerFrame;
    inputFormat.mBytesPerPacket = inputFormat.mBytesPerFrame * inputFormat.mFramesPerPacket;

    AudioStreamBasicDescription outputFormat; // 这里开始是输出音频格式
    memset(&outputFormat, 0, sizeof(outputFormat));
    outputFormat.mSampleRate = inputFormat.mSampleRate;       // 采样率保持一致
    outputFormat.mFormatID = kAudioFormatMPEG4AAC;            // AAC编码 kAudioFormatMPEG4AAC kAudioFormatMPEG4AAC_HE_V2
    outputFormat.mChannelsPerFrame = (UInt32)_configuration.numberOfChannels;;
    outputFormat.mFramesPerPacket = 1024;                     // AAC一帧是1024个字节

    const OSType subtype = kAudioFormatMPEG4AAC;
    AudioClassDescription requestedCodecs[2] = {
        {
            kAudioEncoderComponentType,
            subtype,
            kAppleSoftwareAudioCodecManufacturer
        },
        {
            kAudioEncoderComponentType,
            subtype,
            kAppleHardwareAudioCodecManufacturer
        }
    };
    OSStatus result = AudioConverterNewSpecific(&inputFormat, &outputFormat, 2, requestedCodecs, &m_converter);
    if (result != noErr) return NO;

    return YES;
}

- (AudioClassDescription *)getAudioClassDescriptionWithType:(UInt32)type fromManufacturer:(UInt32)manufacturer { // 获得相应的编码器
    static AudioClassDescription audioDesc;

    UInt32 encoderSpecifier = type, size = 0;
    OSStatus status;

    memset(&audioDesc, 0, sizeof(audioDesc));
    status = AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size);
    if (status) {
        return nil;
    }

    uint32_t count = size / sizeof(AudioClassDescription);
    AudioClassDescription descs[count];
    AudioFormatGetProperty(kAudioFormatProperty_Encoders, sizeof(encoderSpecifier), &encoderSpecifier, &size, descs);
    for (uint32_t i = 0; i < count; i++) {
        if ((type == descs[i].mSubType) && (manufacturer == descs[i].mManufacturer)) {
            memcpy(&audioDesc, &descs[i], sizeof(audioDesc));
            break;
        }
    }
    return &audioDesc;
}

#pragma mark -- AudioCallBack
OSStatus inputDataProc(AudioConverterRef inConverter, UInt32 *ioNumberDataPackets, AudioBufferList *ioData, AudioStreamPacketDescription * *outDataPacketDescription, void *inUserData) { //<span style="font-family: Arial, Helvetica, sans-serif;">AudioConverterFillComplexBuffer 编码过程中，会要求这个函数来填充输入数据，也就是原始PCM数据</span>
    AudioBufferList bufferList = *(AudioBufferList *)inUserData;
    ioData->mBuffers[0].mNumberChannels = 1;
    ioData->mBuffers[0].mData = bufferList.mBuffers[0].mData;
    ioData->mBuffers[0].mDataByteSize = bufferList.mBuffers[0].mDataByteSize;
    return noErr;
}

/**
 *  Add ADTS header at the beginning of each and every AAC packet.
 *  This is needed as MediaCodec encoder generates a packet of raw
 *  AAC data.
 *
 *  Note the packetLen must count in the ADTS header itself.
 *  See: http://wiki.multimedia.cx/index.php?title=ADTS
 *  Also: http://wiki.multimedia.cx/index.php?title=MPEG-4_Audio#Channel_Configurations
 **/
- (NSData *)adtsData:(NSInteger)channel rawDataLength:(NSInteger)rawDataLength {
    int adtsLength = 7;
    char *packet = malloc(sizeof(char) * adtsLength);
    // Variables Recycled by addADTStoPacket
    int profile = 2;  //AAC LC
    //39=MediaCodecInfo.CodecProfileLevel.AACObjectELD;
    int freqIdx = 4;  //44.1KHz
    int chanCfg = (int)channel;  //MPEG-4 Audio Channel Configuration. 1 Channel front-center
    NSUInteger fullLength = adtsLength + rawDataLength;
    // fill in ADTS data
    packet[0] = (char)0xFF;     // 11111111     = syncword
    packet[1] = (char)0xF9;     // 1111 1 00 1  = syncword MPEG-2 Layer CRC
    packet[2] = (char)(((profile-1)<<6) + (freqIdx<<2) +(chanCfg>>2));
    packet[3] = (char)(((chanCfg&3)<<6) + (fullLength>>11));
    packet[4] = (char)((fullLength&0x7FF) >> 3);
    packet[5] = (char)(((fullLength&7)<<5) + 0x1F);
    packet[6] = (char)0xFC;
    NSData *data = [NSData dataWithBytesNoCopy:packet length:adtsLength freeWhenDone:YES];
    return data;
}

@end
