import ArgumentParser
import Foundation
import Virtualization

struct Run: AsyncParsableCommand {
    static var configuration = CommandConfiguration(abstract: "run vm")

    @Argument(help: "vm name", completion: .custom(completeVMName))
    var name: String

    @Flag(name: .short, help: "run vm in background")
    var detached: Bool = false

    @Flag(help: "open UI window")
    var gui: Bool = false

    @Option(help: "attach disk image in read only mode, e.g. --mount=\"debian.iso\"", completion: .file())
    var mount: Path?

    func validate() throws {
        if detached {
            if gui || mount != nil {
                throw ValidationError("-d must not be used with --gui and --mount")
            }
            let logFile = Path("~/Library/Logs/vz.log")
            if logFile.exists() && !logFile.writable() {  // freopen() creates file if not exists
                throw ValidationError("detach mode log file is not writable, file=\(logFile)")
            }
        }
        let dir = Home.shared.vmDir(name)
        if !dir.initialized() {
            throw ValidationError("vm not initialized, name=\(name)")
        }
        if dir.pid() != nil {
            throw ValidationError("vm is running, name=\(name)")
        }
        let config = try dir.loadConfig()
        switch config.os {
        case .linux:
            if let _ = config.rosetta, VZLinuxRosettaDirectoryShare.availability != .installed {
                throw ValidationError("rosetta is not available on host")
            }
            if let mount = mount, !mount.exists() {
                throw ValidationError("mount file not exits, mount=\(mount)")
            }
        case .macOS:
            if !gui {
                // sonoma screen share high performance mode doesn't work with NAT, so better use vm view than standard mode
                throw ValidationError("macOS must be used with gui")
            }
            if mount != nil {
                // macOS can only mount dmg files, created by https://support.apple.com/en-gb/guide/disk-utility/dskutl11888/mac
                // not useful, can be substituted with shared folder
                throw ValidationError("macOS does not support mount")
            }
            if let _ = config.rosetta {
                throw ValidationError("macOS does not support rosetta")
            }
        }
    }

    func run() throws {
        let dir = Home.shared.vmDir(name)
        let config = try dir.loadConfig()

        // must hold lock reference, otherwise fd will be deallocated, and release all locks
        let lock = dir.lock()
        if lock == nil {
            Logger.error("vm is already running, name=\(name)")
            throw ExitCode.failure
        }

        if detached == true {
            try runInBackground()
        }

        let virtualMachine: VZVirtualMachine = try createVirtualMachine(dir, config)
        let vm = VM(virtualMachine)

        // must hold signals reference, otherwise it will de deallocated
        var signals: [DispatchSourceSignal] = []
        signals.append(handleSignal(SIGINT, vm))
        signals.append(handleSignal(SIGTERM, vm))

        Task {
            await vm.start()
        }

        if gui {
            let automaticallyReconfiguresDisplay = config.os == .macOS
            runUI(vm, automaticallyReconfiguresDisplay)
        } else {
            dispatchMain()
        }
    }

    private func createVirtualMachine(_ dir: VMDirectory, _ config: VMConfig) throws -> VZVirtualMachine {
        if config.os == .linux {
            var linux = Linux(dir, config)
            linux.gui = gui
            linux.mount = mount
            return try linux.createVirtualMachine()
        } else {
            let macOS = MacOS(dir, config)
            return try macOS.createVirtualMachine()
        }
    }

    private func runInBackground() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
        let logFile = Path("~/Library/Logs/vz.log")
        task.arguments = ["run", name]
        task.standardOutput = FileHandle(forWritingAtPath: logFile.path)
        task.standardError = FileHandle(forWritingAtPath: logFile.path)
        task.launch()
        throw CleanExit.message("vm launched in background, check log in \(logFile)")
    }

    private func runUI(_ vm: VM, _ automaticallyReconfiguresDisplay: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSMakeRect(0, 0, 1024, 768),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false, screen: nil)
        window.title = name
        window.delegate = vm

        let menu = NSMenu()
        let menuItem = NSMenuItem()
        let subMenu = NSMenu()
        subMenu.addItem(
            NSMenuItem(
                title: "Stop \(name)...",
                action: #selector(NSWindow.close), keyEquivalent: "q"))
        menuItem.submenu = subMenu
        menu.addItem(menuItem)
        app.mainMenu = menu

        let machineView = VZVirtualMachineView(frame: window.contentLayoutRect)
        machineView.capturesSystemKeys = true
        machineView.automaticallyReconfiguresDisplay = automaticallyReconfiguresDisplay
        machineView.virtualMachine = vm.machine
        machineView.autoresizingMask = [.width, .height]

        window.contentView?.addSubview(machineView)
        window.makeKeyAndOrderFront(nil)

        app.run()
    }

    private func handleSignal(_ sig: Int32, _ vm: VM) -> DispatchSourceSignal {
        signal(sig, SIG_IGN)
        let signal = DispatchSource.makeSignalSource(signal: sig)
        signal.setEventHandler {
            Task {
                try await vm.stop()
            }
        }
        signal.activate()
        return signal
    }
}

func completeVMName(_ arguments: [String]) -> [String] {
    return Home.shared.vmDirs().map({ $0.name })
}
