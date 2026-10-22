import Testing
@testable import RingClient

struct AudioModeSDPTests {
    let answer = [
        "v=0",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=mid:0",
        "a=sendrecv",
        "m=video 9 UDP/TLS/RTP/SAVPF 96",
        "a=mid:1",
        "a=sendonly",
        "",
    ]

    @Test func offMakesOnlyAudioInactive() {
        let sdp = LiveViewSession.applyAudioMode(.off, to: answer.joined(separator: "\r\n"))
        let lines = sdp.components(separatedBy: "\r\n")
        #expect(lines[3] == "a=inactive")
        #expect(lines[6] == "a=sendonly")  // video untouched
    }

    @Test func listenMakesRingSendOnly() {
        let sdp = LiveViewSession.applyAudioMode(.listen, to: answer.joined(separator: "\r\n"))
        #expect(sdp.components(separatedBy: "\r\n")[3] == "a=sendonly")
    }

    @Test func talkLeavesAnswerUnchanged() {
        let original = answer.joined(separator: "\r\n")
        #expect(LiveViewSession.applyAudioMode(.talk, to: original) == original)
    }

    @Test func handlesBareNewlines() {
        let sdp = LiveViewSession.applyAudioMode(.off, to: answer.joined(separator: "\n"))
        #expect(sdp.components(separatedBy: "\n")[3] == "a=inactive")
    }
}
