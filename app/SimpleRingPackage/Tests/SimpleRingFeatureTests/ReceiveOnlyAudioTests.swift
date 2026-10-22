import Testing
@testable import RingClient

struct ReceiveOnlyAudioTests {
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

    @Test func audioBecomesReceiveOnlyAndVideoIsUntouched() {
        let lines = LiveViewSession.receiveOnlyAudio(answer.joined(separator: "\r\n")).components(separatedBy: "\r\n")
        #expect(lines[3] == "a=sendonly")
        #expect(lines[6] == "a=sendonly")
        #expect(lines.count == answer.count)
    }

    @Test func handlesBareNewlines() {
        let lines = LiveViewSession.receiveOnlyAudio(answer.joined(separator: "\n")).components(separatedBy: "\n")
        #expect(lines[3] == "a=sendonly")
    }
}
