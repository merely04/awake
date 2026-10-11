import AppKit

let args = Array(CommandLine.arguments.dropFirst())
if args != ["--app"] {
    exit(runCLI(args))
}

// --app — иконка в меню-баре и движок (так стартует launchd).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
