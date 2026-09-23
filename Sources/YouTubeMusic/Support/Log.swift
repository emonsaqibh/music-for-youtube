import Foundation

/// Appends to ~/Library/Logs/MusicForYouTube/app.log (MusicForYouTube-Dev for the dev build).
///
/// Playback problems in this app usually happen inside WebKit, several layers away from
/// anything a breakpoint can see, so a durable log of what the bridge reported is the
/// most useful debugging tool there is.
enum Log {
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let queue = DispatchQueue(label: "dev.fringecore.ytmusic.log")

    static let fileURL: URL = {
        // The dev build runs alongside the installed beta, so it keeps a log of its own.
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/MusicForYouTube\(isDev ? "-Dev" : "")", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "app.log")
    }()

    static func write(_ message: String) {
        let line = "\(stamp()) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            if handle == nil {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: fileURL)
                try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    static func reset() {
        queue.sync {
            try? handle?.close()
            handle = nil
            try? Data().write(to: fileURL)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
