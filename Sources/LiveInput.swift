import AVFoundation
import Foundation

final class LiveInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let capture = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let worker = Process()
    private let input = Pipe()
    private let messages = Pipe()
    private let samples = DispatchQueue(label: "dictation.audio")
    private let onUpdate: (String) -> Void
    private let onLevel: (Bool) -> Void
    private let onEnd: (Result<String, Error>) -> Void
    private var accepting = true
    private var lastSignal = Date.distantPast
    private var displayedSignal: Bool?
    private var readError: String?
    private var runtimeObserver: NSObjectProtocol?
    private(set) var name = ""
    private static func error(_ text: String) -> NSError {
        NSError(domain: "LiveInput", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    init(update: @escaping (String) -> Void, level: @escaping (Bool) -> Void, end: @escaping (Result<String, Error>) -> Void) {
        onUpdate = update
        onLevel = level
        onEnd = end
    }

    func start(node: URL, script: URL) throws {
        guard let mic = AVCaptureDevice.default(for: .audio) else { throw Self.error("找不到默认麦克风，请检查系统声音输入。") }
        name = mic.localizedName
        let device = try AVCaptureDeviceInput(device: mic)
        guard capture.canAddInput(device) else { throw Self.error("无法打开" + name) }
        capture.addInput(device)
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        output.setSampleBufferDelegate(self, queue: samples)
        guard capture.canAddOutput(output) else { throw Self.error("无法读取麦克风声音。") }
        capture.addOutput(output)
        worker.executableURL = node
        worker.arguments = [script.path, "--live"]
        worker.standardInput = input
        worker.standardOutput = messages
        try worker.run()
        runtimeObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: capture, queue: .main) { [weak self] n in
            guard let self else { return }
            let detail = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "麦克风已断开"
            self.samples.async { self.readError = detail }
            self.finish()
        }
        DispatchQueue.global(qos: .userInitiated).async { self.readResults() }
        capture.startRunning()
        if !capture.isRunning {
            samples.async { self.readError = "麦克风未启动，请检查麦克风权限和系统声音输入。" }
            finish()
        }
    }

    private func readResults() {
        var pending = Data()
        var final: String?
        let handle = messages.fileHandleForReading
        while true {
            let bytes = handle.availableData
            if bytes.isEmpty { break }
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let data = pending[..<newline]
                let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
                pending.removeSubrange(...newline)
                if let text = msg?["partial"] { DispatchQueue.main.async { self.onUpdate(text) } }
                if let text = msg?["final"] { final = text }
            }
        }
        worker.waitUntilExit()
        DispatchQueue.main.async {
            self.finish()
            self.samples.async {
                let result: Result<String, Error>
                if let problem = self.readError { result = .failure(Self.error(problem)) }
                else if self.worker.terminationStatus == 0, let final { result = .success(final) }
                else { result = .failure(Self.error("实时识别未完成，请从 Releases 重新安装完整的 App。")) }
                DispatchQueue.main.async { self.onEnd(result) }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting, let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        let count = data.count
        guard count > 0 else { return }
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard status == noErr else { return }
        let peak = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            bytes.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
        }
        let now = Date()
        if peak > 130 { lastSignal = now }
        let audible = now.timeIntervalSince(lastSignal) < 0.55
        if audible != displayedSignal {
            displayedSignal = audible
            DispatchQueue.main.async { self.onLevel(audible) }
        }
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { accepting = false }
    }

    func finish() {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver); self.runtimeObserver = nil }
        if capture.isRunning { capture.stopRunning() }
        samples.async {
            self.accepting = false
            try? self.input.fileHandleForWriting.close()
        }
    }
}
