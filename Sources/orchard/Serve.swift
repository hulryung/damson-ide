import Darwin
import Dispatch
import Foundation
import OrchardRuntime
import OrchardTerminals

private var headlessHost: OrchardRuntimeHost?
private var headlessSignalSources: [DispatchSourceSignal] = []

/// Starts the runtime control plane without creating NSApplication or attaching a
/// terminal view. Damson sessions are created only when a terminal RPC requests one.
func serve(dataDirectory: URL?) -> Never {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    Task { @MainActor in
        do {
            let resolvedData = dataDirectory ?? OrchardRuntimeHost.defaultDataDirectory()
            // The absolute path of this very binary — `serve` IS the CLI, so a
            // worker PTY gets a command it can run without a PATH entry (T35).
            let cliCommand = OrchardCLIPath.resolve()
            let terminalFactory = DamsonTerminalFactory.make(
                context: TerminalHostContext(cliCommand: cliCommand,
                                             dataPath: resolvedData.path))
            let host = try OrchardRuntimeHost(terminalFactory: terminalFactory,
                                              cliCommand: cliCommand,
                                              dataDirectory: dataDirectory,
                                              mode: .headless)
            let metadata = try host.startSocketServer()
            headlessHost = host
            FileHandle.standardError.write(Data(
                "orchard: headless runtime \(metadata.runtimeId) listening at \(metadata.socketPath)\n".utf8))

            let stop: @Sendable () -> Void = {
                Task { @MainActor in
                    host.shutdown()
                    exit(0)
                }
            }
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            interrupt.setEventHandler(handler: stop)
            terminate.setEventHandler(handler: stop)
            interrupt.resume()
            terminate.resume()
            headlessSignalSources = [interrupt, terminate]
        } catch {
            FileHandle.standardError.write(Data("orchard: \(error)\n".utf8))
            exit(69)
        }
    }
    // Agent readiness uses Foundation timers. `dispatchMain()` services the GCD
    // queue but not the main RunLoop, so a headless shell could never advance from
    // `.starting` and worker-start always timed out. The run loop also drains the
    // main dispatch queue, including the signal sources above.
    while true {
        RunLoop.main.run()
    }
}
