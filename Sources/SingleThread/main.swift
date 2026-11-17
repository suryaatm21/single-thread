import AppKit

if let code = CLI.run(Array(CommandLine.arguments.dropFirst())) {
    exit(code)
}

let app = NSApplication.shared
// Menu-bar only: no Dock icon, never steals focus from the terminals.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
