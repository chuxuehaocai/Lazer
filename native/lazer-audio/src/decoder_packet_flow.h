#ifndef LAZER_AUDIO_DECODER_PACKET_FLOW_H
#define LAZER_AUDIO_DECODER_PACKET_FLOW_H

namespace lazer::audio {

enum class DecoderStep { Ready, Again, End, Failed };
enum class DecoderFlowResult { Complete, Cancelled, Failed, Stalled };

/* A send-side Again never consumes the packet. Drain pending frames, then submit the same packet
 * again. Keeping this small state machine separate makes the backpressure contract testable without
 * a particular codec or its current internal queue depth. The callbacks retain their error details. */
template <typename Send, typename Receive, typename Cancelled>
DecoderFlowResult pumpDecoderPacket(Send send, Receive receive, Cancelled cancelled) {
    while (!cancelled()) {
        const DecoderStep sent = send();
        if (sent == DecoderStep::Failed) return DecoderFlowResult::Failed;
        if (sent == DecoderStep::End) return DecoderFlowResult::Complete;
        bool progressed = false;
        while (!cancelled()) {
            const DecoderStep frame = receive();
            if (frame == DecoderStep::Failed) return DecoderFlowResult::Failed;
            if (frame == DecoderStep::End) return DecoderFlowResult::Complete;
            if (frame == DecoderStep::Again) break;
            progressed = true;
        }
        if (cancelled()) return DecoderFlowResult::Cancelled;
        if (sent == DecoderStep::Ready) return DecoderFlowResult::Complete;
        /* FFmpeg promises that send and receive cannot both return EAGAIN without progress. */
        if (!progressed) return DecoderFlowResult::Stalled;
    }
    return DecoderFlowResult::Cancelled;
}

}  // namespace lazer::audio

#endif
