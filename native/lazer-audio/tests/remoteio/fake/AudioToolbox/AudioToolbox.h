/* Fake AudioToolbox for the RemoteIO contract test.
 *
 * Only what `output_remoteio.cpp` touches is declared. The implementation lives
 * in `remoteio_contract.cpp`, so the production backend can be compiled and
 * exercised on any host, with no iOS SDK and no audio device — the same trick
 * `tests/aaudio/fake/aaudio/AAudio.h` plays for the Android backend.
 */
#ifndef LAZER_FAKE_AUDIOTOOLBOX_H
#define LAZER_FAKE_AUDIOTOOLBOX_H

#include <cstdint>

using OSStatus = int32_t;
using UInt32 = uint32_t;
using Float64 = double;
using AudioUnit = struct OpaqueAudioComponentInstance *;
using AudioComponent = struct OpaqueAudioComponent *;
using AudioComponentInstance = AudioUnit;
using AudioUnitPropertyID = UInt32;
using AudioUnitScope = UInt32;
using AudioUnitElement = UInt32;
using AudioFormatID = UInt32;
using AudioFormatFlags = UInt32;
using AudioUnitRenderActionFlags = UInt32;

constexpr OSStatus noErr = 0;

constexpr AudioFormatID kAudioFormatLinearPCM = 0x6C70636D;  // 'lpcm'
constexpr AudioFormatFlags kAudioFormatFlagIsFloat = 1U << 0;
constexpr AudioFormatFlags kAudioFormatFlagIsPacked = 1U << 3;

constexpr UInt32 kAudioUnitType_Output = 0x61756F75;          // 'auou'
constexpr UInt32 kAudioUnitSubType_RemoteIO = 0x72696F63;      // 'rioc'
constexpr UInt32 kAudioUnitManufacturer_Apple = 0x6170706C;    // 'appl'

constexpr AudioUnitScope kAudioUnitScope_Global = 0;
constexpr AudioUnitScope kAudioUnitScope_Input = 1;
constexpr AudioUnitScope kAudioUnitScope_Output = 2;

constexpr AudioUnitPropertyID kAudioOutputUnitProperty_EnableIO = 2003;
constexpr AudioUnitPropertyID kAudioUnitProperty_StreamFormat = 8;
constexpr AudioUnitPropertyID kAudioUnitProperty_MaximumFramesPerSlice = 14;
constexpr AudioUnitPropertyID kAudioUnitProperty_SetRenderCallback = 23;

struct AudioComponentDescription {
    UInt32 componentType;
    UInt32 componentSubType;
    UInt32 componentManufacturer;
    UInt32 componentFlags;
    UInt32 componentFlagsMask;
};

struct AudioStreamBasicDescription {
    Float64 mSampleRate;
    AudioFormatID mFormatID;
    AudioFormatFlags mFormatFlags;
    UInt32 mBytesPerPacket;
    UInt32 mFramesPerPacket;
    UInt32 mBytesPerFrame;
    UInt32 mChannelsPerFrame;
    UInt32 mBitsPerChannel;
    UInt32 mReserved;
};

struct AudioBuffer {
    UInt32 mNumberChannels;
    UInt32 mDataByteSize;
    void *mData;
};

struct AudioBufferList {
    UInt32 mNumberBuffers;
    AudioBuffer mBuffers[1];
};

struct AudioTimeStamp;

using AURenderCallback = OSStatus (*)(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames,
    AudioBufferList *ioData);

struct AURenderCallbackStruct {
    AURenderCallback inputProc;
    void *inputProcRefCon;
};

AudioComponent AudioComponentFindNext(AudioComponent inComponent,
    const AudioComponentDescription *inDesc);
OSStatus AudioComponentInstanceNew(AudioComponent inComponent, AudioUnit *outInstance);
OSStatus AudioComponentInstanceDispose(AudioUnit inUnit);
OSStatus AudioUnitSetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, const void *inData, UInt32 inDataSize);
OSStatus AudioUnitGetProperty(AudioUnit inUnit, AudioUnitPropertyID inID, AudioUnitScope inScope,
    AudioUnitElement inElement, void *outData, UInt32 *ioDataSize);
OSStatus AudioUnitInitialize(AudioUnit inUnit);
OSStatus AudioUnitUninitialize(AudioUnit inUnit);
OSStatus AudioUnitReset(AudioUnit inUnit, AudioUnitScope inScope, AudioUnitElement inElement);
OSStatus AudioOutputUnitStart(AudioUnit inUnit);
OSStatus AudioOutputUnitStop(AudioUnit inUnit);

#endif  // LAZER_FAKE_AUDIOTOOLBOX_H
