#import "FISampleDecoder.h"
#import "FISampleBuffer.h"
#import "FIError.h"

@implementation FISampleDecoder

+ (FISampleBuffer*) decodeSampleAtPath: (NSString*) path error: (NSError**) error
{
    FI_INIT_ERROR_IF_NULL(error);

    // Read sample data
    AudioStreamBasicDescription format = {0};
    NSData *sampleData = [self readSampleDataAtPath:path fileFormat:&format error:error];
    if (!sampleData) {
        return nil;
    }

    // Check sample format
    if (![self checkFormatSanity:format error:error]) {
        return nil;
    }

    // Create sample buffer
    NSError *bufferError = nil;
    FISampleBuffer *buffer = [[FISampleBuffer alloc]
        initWithData:sampleData sampleRate:format.mSampleRate
        sampleFormat:FISampleFormatMake(format.mChannelsPerFrame, format.mBitsPerChannel)
        error:&bufferError];

    if (!buffer) {
        *error = [NSError errorWithDomain:FIErrorDomain
            code:FIErrorCannotCreateBuffer userInfo:@{
            NSLocalizedDescriptionKey : @"Cannot create sound buffer",
            NSUnderlyingErrorKey : bufferError
        }];
        return nil;
    }

    return buffer;
}

+ (BOOL) checkFormatSanity: (AudioStreamBasicDescription) format error: (NSError**) error
{
    NSParameterAssert(error);

    if (!TestAudioFormatNativeEndian(format)) {
        *error = [FIError
            errorWithMessage:@"Invalid sample endianity, only native endianity supported"
            code:FIErrorInvalidSampleFormat];
        return NO;
    }

    if (format.mChannelsPerFrame != 1 && format.mChannelsPerFrame != 2) {
        *error = [FIError
            errorWithMessage:@"Invalid number of sound channels, only mono and stereo supported"
            code:FIErrorInvalidSampleFormat];
        return NO;
    }

    if (format.mBitsPerChannel != 8 && format.mBitsPerChannel != 16) {
        *error = [FIError
            errorWithMessage:@"Invalid sample resolution, only 8-bit and 16-bit supported"
            code:FIErrorInvalidSampleFormat];
        return NO;
    }

    return YES;
}

+ (NSData*) readSampleDataAtPath: (NSString*) path fileFormat: (AudioStreamBasicDescription*) fileFormat error: (NSError**) error
{
    NSParameterAssert(fileFormat);
    NSParameterAssert(error);

    if (!path) {
        return nil;
    }

    OSStatus errcode = noErr;
    UInt32 propertySize;
    AudioFileID fileId = 0;

    NSURL *fileURL = [NSURL fileURLWithPath:path];
    errcode = AudioFileOpenURL((__bridge CFURLRef) fileURL, kAudioFileReadPermission, 0, &fileId);
    if (errcode) {
        *error = [FIError
            errorWithMessage:@"Can’t read file"
            code:FIErrorCannotReadFile];
        return nil;
    }

    propertySize = sizeof(*fileFormat);
    errcode = AudioFileGetProperty(fileId, kAudioFilePropertyDataFormat, &propertySize, fileFormat);
    if (errcode) {
        *error = [FIError
            errorWithMessage:@"Can’t read file format"
            code:FIErrorInvalidSampleFormat];
        AudioFileClose(fileId);
        return nil;
    }

    if (fileFormat->mFormatID != kAudioFormatLinearPCM) {
        *error = [FIError
            errorWithMessage:@"Audio format not linear PCM"
            code:FIErrorInvalidSampleFormat];
        AudioFileClose(fileId);
        return nil;
    }

    UInt64 fileSize = 0;
    propertySize = sizeof(fileSize);
    errcode = AudioFileGetProperty(fileId, kAudioFilePropertyAudioDataByteCount, &propertySize, &fileSize);
    if (errcode) {
        *error = [FIError
            errorWithMessage:@"Can’t read audio data byte count"
            code:FIErrorInvalidSampleFormat];
        AudioFileClose(fileId);
        return nil;
    }

    UInt32 dataSize = (UInt32) fileSize;
    void *data = malloc(dataSize);
    if (!data) {
        *error = [FIError
            errorWithMessage:@"Can’t allocate memory for audio data"
            code:FIErrorCannotAllocateMemory];
        AudioFileClose(fileId);
        return nil;
    }

    errcode = AudioFileReadBytes(fileId, false, 0, &dataSize, data);
    if (errcode) {
        *error = [FIError
            errorWithMessage:@"Can’t read audio data from file"
            code:FIErrorInvalidSampleFormat];
        AudioFileClose(fileId);
        free(data);
        return nil;
    }

    AudioFileClose(fileId);
    return [NSData dataWithBytesNoCopy:data length:dataSize freeWhenDone:YES];
}
// http://stackoverflow.com/questions/2130831/decoding-ima4-audio-format
//
//File structure
//
//Apple IMA4 file are made of packet of 34 bytes. This is the packet unit used to build the file.
//Each 34 bytes packet has two parts:
//the first 2 bytes contain the preamble: an initial predictor and a step index
//the 32 bytes left contain the sound nibbles (a nibble of 4 bits is used to retrieve a 16 bits sample)
//Each packet has 32 bytes of compressed data, that represent 64 samples of 16 bits.
//If the sound file is stereo, the packets are interleaved (one for the left, one for the right); there must be an even number of packets.
//
//Decoding
//
//Each packet of 34 bytes will lead to the decompression of 64 samples of 16 bits. So the size of the uncompressed data is 128 bytes per packet.

//+ (void) decodeIMA4Package:(UInt8 *)packet toOutput:(short *)output
//{
//    int ima_index_table[] = {
//        -1, -1, -1, -1, 2, 4, 6, 8,
//        -1, -1, -1, -1, 2, 4, 6, 8
//    };  // Index table from [Multimedia Wiki][2]
//    int ima_step_table[] = {
//        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
//        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
//        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
//        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
//        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
//        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
//        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
//        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
//        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
//    }; // Step table from [Multimedia Wiki][2]
//    //byte[] packet = ... // A packet of 34 bytes compressed
//    //short[] output = ... // The output buffer of 128 bytes
//    int preamble = (packet[0] << 8) | packet[1];
//    int predictor = preamble & 0xFF80; // See [Multimedia Wiki][2]
//    int step_index = preamble & 0x007F; // See [Multimedia Wiki][2]
//    int i;
//    int j = 0;
//    int step = ima_step_table[step_index];
//    for(i = 2; i < 34; i++) {
//        UInt8 data = packet[i];
//        int lower_nibble = data & 0x0F;
//        int upper_nibble = (data & 0xF0) >> 4;
//        
//        // Decode the lower nibble
//        step_index += ima_index_table[lower_nibble];
//        int diff = ((signed)lower_nibble + 0.5f) * step / 4;
//        predictor += diff;
//        int step = ima_step_table[step_index];
//        
//        // Clamp the predictor value to stay in range
//        if (predictor > 65535)
//            output[j++] = 65535;
//        else if (predictor < -65536)
//            output[j++] = -65536;
//        else
//            output[j++] = (short) predictor;
//        
//        // Decode the uppper nibble
//        step_index += ima_index_table[upper_nibble];
//        diff = ((signed)upper_nibble + 0.5f) * step / 4;
//        predictor += diff;
//        step = ima_step_table[step_index];
//        
//        // Clamp the predictor value to stay in range
//        if (predictor > 65535)
//            output[j++] = 65535;
//        else if (predictor < -65536)
//            output[j++] = -65536;
//        else
//            output[j++] = (short) predictor;
//    }
//}

@end
