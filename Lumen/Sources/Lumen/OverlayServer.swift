import Foundation

/// Unix domain socket server the ai-suggest zsh plugin talks to
/// (fire-and-forget, one JSON message per connection — see
/// _ai_suggest_overlay_send in ai-suggest.plugin.zsh) to show, update, or
/// hide the native suggestion panel.
///
/// Uses raw POSIX sockets rather than Network.framework: a plain
/// accept-loop on a background thread is simple to reason about for this
/// "read one JSON blob per connection, then close" protocol, and keeps this
/// file's correctness independent of Network.framework's less-documented
/// Unix-domain-socket entry points.
final class OverlayServer {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var running = false

    /// Delivered on the main queue — callers (SwiftUI/AppKit state) never
    /// need to hop threads themselves.
    var onMessage: (([String: Any]) -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        guard !running else { return }

        // Clean up a stale socket file left behind by a previous run that
        // didn't exit cleanly (e.g. force-killed) — bind() would otherwise
        // fail with "address already in use".
        unlink(socketPath)

        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            debugLog("Lumen: overlay socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        guard bindUnixSocket(fd: fd, path: socketPath) else {
            close(fd)
            return
        }

        guard listen(fd, 8) == 0 else {
            debugLog("Lumen: overlay listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        running = true

        DispatchQueue(label: "ai-suggest.overlay-server").async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    private func bindUnixSocket(fd: Int32, path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1 // room for NUL
        guard pathBytes.count <= maxLen else {
            debugLog("Lumen: overlay socket path too long: \(path)")
            return false
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let charPtr = rawPtr.bindMemory(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                charPtr[i] = CChar(bitPattern: byte)
            }
            charPtr[pathBytes.count] = 0
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, addrSize)
            }
        }
        guard result == 0 else {
            debugLog("Lumen: overlay bind() failed: \(String(cString: strerror(errno)))")
            return false
        }
        return true
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                // EINTR from stop()'s close(), or a transient error — keep
                // going as long as we're still supposed to be running.
                if running { usleep(10_000) }
                continue
            }
            handleClient(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onMessage?(json)
        }
    }
}
