import Foundation
import Darwin
import TappityTapShared

// Client side of the Unix-socket JSON-line protocol. Auto-reconnects every
// second when disconnected so the helper can be restarted independently.

final class IPCClient {
    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "tappitytap.ipc.client")
    private let sendLock = NSLock()
    private var running = false

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onMessage: ((ServerMessage) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() {
        running = true
        queue.async { [weak self] in self?.runLoop() }
    }

    func stop() {
        running = false
        sendLock.lock(); defer { sendLock.unlock() }
        if fd >= 0 { close(fd); fd = -1 }
    }

    func send<T: Encodable>(_ msg: T) {
        let data = encodeLine(msg)
        sendLock.lock()
        let curFD = fd
        sendLock.unlock()
        guard curFD >= 0 else { return }
        _ = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            return write(curFD, ptr.baseAddress, ptr.count)
        }
    }

    private func runLoop() {
        while running {
            let newFD = socket(AF_UNIX, SOCK_STREAM, 0)
            if newFD < 0 { sleep(1); continue }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
            path.withCString { src in
                withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                    _ = strlcpy(UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self), src, sunPathCapacity)
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(newFD, $0, len)
                }
            }
            if connectResult != 0 {
                close(newFD)
                sleep(1)
                continue
            }

            sendLock.lock()
            fd = newFD
            sendLock.unlock()
            onConnect?()

            readLoop(fd: newFD)

            sendLock.lock()
            if fd == newFD { fd = -1 }
            sendLock.unlock()
            close(newFD)
            onDisconnect?()
        }
    }

    private func readLoop(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while running {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                return read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                if let msg = try? decodeLine(line, as: ServerMessage.self) {
                    onMessage?(msg)
                }
            }
        }
    }
}
