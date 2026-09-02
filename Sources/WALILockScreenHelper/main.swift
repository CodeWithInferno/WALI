import Foundation
import WALILockScreenHelperRuntime

do {
    try LockScreenHelperService().run()
} catch {
    FileHandle.standardError.write(Data("WALI Lock Screen Helper could not start.\n".utf8))
    exit(EXIT_FAILURE)
}
