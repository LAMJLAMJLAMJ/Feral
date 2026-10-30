#if os(macOS)
import CoreAudio
import FeralCore
import FeralCoreAudio
import FeralIO
import FeralScene
import XCTest

/// Runs the IOProc on hand-made Core Audio buffer lists, mixing mono and interleaved streams the way
/// real devices do (an RME MADIface XT, for example, shows several multichannel streams).
final class IOProcTests: XCTestCase {
    let frames = 32

    /// Device input channel c, sample n.
    func signal(_ c: Int, _ n: Int) -> Float { Float(c + 1) + Float(n) * 0.001 }

    /// A buffer list with one buffer per entry of `layout` (the channels in that buffer).
    func makeList(_ layout: [Int], fill: ((Int, Int) -> Float)?) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: layout.count)
        var channel = 0
        for (b, n) in layout.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: n * frames)
            for f in 0..<frames { for c in 0..<n { data[f * n + c] = fill?(channel + c, f) ?? 7 } }
            list[b] = AudioBuffer(mNumberChannels: UInt32(n), mDataByteSize: UInt32(n * frames * 4), mData: data)
            channel += n
        }
        return list
    }

    /// AudioBufferList.allocate's memory goes back with free(), not deallocate().
    func release(_ list: UnsafeMutableAudioBufferListPointer) {
        for b in list { b.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    /// Device output channel c as rendered, found in whichever buffer holds it.
    func outputChannel(_ list: UnsafeMutableAudioBufferListPointer, _ c: Int) -> [Float] {
        var base = 0
        for b in list {
            let n = Int(b.mNumberChannels)
            if c < base + n {
                let data = b.mData!.assumingMemoryBound(to: Float.self)
                return (0..<frames).map { data[$0 * n + (c - base)] }
            }
            base += n
        }
        fatalError("no channel \(c)")
    }

    func run(engineInputs: Int, engineOutputs: Int, firstInput: Int, firstOutput: Int,
             inputLayout: [Int], outputLayout: [Int], routing: Routing) -> UnsafeMutableAudioBufferListPointer {
        let core = RenderCore(sampleRate: 48_000)
        core.publish(routing)
        let inputMap = AudioEngineIO.channelMap(count: engineInputs, first: firstInput, available: inputLayout.reduce(0, +))
        let outputMap = AudioEngineIO.channelMap(count: engineOutputs, first: firstOutput, available: outputLayout.reduce(0, +))
        let io = feral_io_create(core.pointer, inputMap, Int32(inputMap.count), outputMap, Int32(outputMap.count))!
        defer { feral_io_destroy(io) }
        let input = makeList(inputLayout, fill: signal)
        defer { release(input) }
        let output = makeList(outputLayout, fill: nil)
        for _ in 0..<2 { // the first buffer fades in
            XCTAssertEqual(feral_io_proc(0, nil, input.unsafePointer, nil, output.unsafeMutablePointer, nil,
                                         UnsafeMutableRawPointer(io)), noErr)
        }
        XCTAssertEqual(feral_io_skipped_buffers(io), 0)
        return output
    }

    func testPassthroughAcrossMonoAndInterleavedStreams() throws {
        // Inputs: a stereo stream then a mono one. Outputs: a mono stream then a 3-channel one.
        let output = run(engineInputs: 3, engineOutputs: 4, firstInput: 1, firstOutput: 1,
                         inputLayout: [2, 1], outputLayout: [1, 3],
                         routing: try Routing(routes: [], inputs: 3, outputs: 4))
        defer { release(output) }
        for c in 0..<3 { XCTAssertEqual(outputChannel(output, c), (0..<frames).map { signal(c, $0) }, "output \(c + 1)") }
        XCTAssertEqual(outputChannel(output, 3), [Float](repeating: 0, count: frames), "no input 4: silent")
    }

    func testFirstChannelOffsetsAndUnusedDeviceOutputsAreSilent() throws {
        // A device with 8 outputs in two 4-channel streams; the engine's 2 outputs start at device channel 5.
        let output = run(engineInputs: 1, engineOutputs: 2, firstInput: 2, firstOutput: 5,
                         inputLayout: [4], outputLayout: [4, 4],
                         routing: try Routing(routes: [Route(inputs: "1", outputs: "1-2")], inputs: 1, outputs: 2))
        defer { release(output) }
        let expected = (0..<frames).map { signal(1, $0) } // engine input 1 is device input 2
        XCTAssertEqual(outputChannel(output, 4), expected)
        XCTAssertEqual(outputChannel(output, 5), expected)
        for c in [0, 1, 2, 3, 6, 7] {
            XCTAssertEqual(outputChannel(output, c), [Float](repeating: 0, count: frames), "device output \(c + 1)")
        }
    }

    /// 128 engine outputs on a device with more channels than that, as an RME MADIface XT has.
    func testWideDevice() throws {
        let output = run(engineInputs: 1, engineOutputs: 128, firstInput: 1, firstOutput: 1,
                         inputLayout: [2], outputLayout: [64, 64, 64, 4],
                         routing: try Routing(routes: [Route(inputs: "1", outputs: "1-128")], inputs: 1, outputs: 128))
        defer { release(output) }
        let expected = (0..<frames).map { signal(0, $0) }
        for c in 0..<128 { XCTAssertEqual(outputChannel(output, c), expected, "device output \(c + 1)") }
        for c in 128..<196 { XCTAssertEqual(outputChannel(output, c), [Float](repeating: 0, count: frames)) }
    }

    func testChannelMap() {
        XCTAssertEqual(AudioEngineIO.channelMap(count: 4, first: 1, available: 8), [0, 1, 2, 3])
        XCTAssertEqual(AudioEngineIO.channelMap(count: 4, first: 7, available: 8), [6, 7, -1, -1])
    }

    func testListingDevicesDoesNotFail() throws {
        // CI machines may have no audio devices at all; the list must still come back.
        _ = try AudioDevices.all()
    }
}
#endif
