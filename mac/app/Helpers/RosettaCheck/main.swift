// PEAK Rosetta Check: an Intel-only (x86_64) helper inside PEAK (Modded).app.
// Opening it through LaunchServices on an Apple Silicon Mac without Rosetta makes macOS itself show
// "To open this app, you need to install Rosetta" with an Install button. With Rosetta present it just exits.
// No sudo, no softwareupdate, nothing installed by us.
import Foundation
exit(0)
