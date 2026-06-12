import AppKit
import Foundation

// Debug entry point: print the AeroSpace snapshot as JSON and exit.
if CommandLine.arguments.contains("--dump") {
    do {
        let snapshot = try AeroSpaceClient.discover().fetchSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(snapshot), encoding: .utf8)!)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

if let flagIndex = CommandLine.arguments.firstIndex(of: "--dump-images"),
   CommandLine.arguments.indices.contains(flagIndex + 1) {
    // SCContentFilter needs a window-server connection (M0 finding).
    _ = NSApplication.shared
    let dir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 1
    Task.detached {
        exitCode = await DumpImagesCommand.run(outputDir: dir)
        done.signal()
    }
    done.wait()
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
