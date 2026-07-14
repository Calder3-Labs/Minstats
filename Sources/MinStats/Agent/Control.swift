import AppKit
import Darwin
import Foundation
import MinStatsProtocol

/// The control actions the agent can perform on this Mac.
///
/// Everything here runs unprivileged, as the logged-in user — deliberately.
/// That's enough to quit the user's own apps and ask the system to restart,
/// and it is NOT enough to touch root-owned processes or force anything. A
/// privileged helper would close that gap at the cost of a large security
/// surface on a personal utility; the gap is the better trade, so failures
/// are reported honestly rather than escalated.
@MainActor
enum Control {
    /// Terminates every pid in a group, one result per pid.
    ///
    /// `expectedName` is a safety interlock against pid reuse: the client's
    /// pids came from a sample that may be seconds old, and a pid that exited
    /// since then can be recycled onto an unrelated process. Each pid's
    /// *current* name is re-resolved and must still match, or it's refused —
    /// otherwise "quit Claude" could land on whatever inherited that pid.
    static func kill(pids: [pid_t], expectedName: String, mode: KillMode) -> [KillResultDTO] {
        pids.map { pid in
            guard let current = ProcessSampler.displayName(for: pid) else {
                return KillResultDTO(pid: pid, status: .gone, reason: "process has exited")
            }
            guard current == expectedName else {
                return KillResultDTO(
                    pid: pid, status: .denied,
                    reason: "pid is now \(current), not \(expectedName)"
                )
            }
            return terminate(pid: pid, mode: mode)
        }
    }

    private static func terminate(pid: pid_t, mode: KillMode) -> KillResultDTO {
        // Prefer the AppKit path for real apps: terminate() is a genuine Cmd-Q,
        // so the app gets to save and clean up. SIGTERM would skip all that.
        if let app = NSRunningApplication(processIdentifier: pid) {
            let ok = mode == .force ? app.forceTerminate() : app.terminate()
            return ok
                ? KillResultDTO(pid: pid, status: .terminating)
                : KillResultDTO(pid: pid, status: .denied, reason: "the app refused to quit")
        }

        // Non-app processes (helpers, daemons, CLI tools) have no NSRunningApplication.
        let signal = mode == .force ? SIGKILL : SIGTERM
        guard Darwin.kill(pid, signal) == 0 else {
            switch errno {
            case EPERM:
                return KillResultDTO(pid: pid, status: .denied, reason: "not owned by your user")
            case ESRCH:
                return KillResultDTO(pid: pid, status: .gone, reason: "process has exited")
            default:
                return KillResultDTO(pid: pid, status: .denied, reason: "kill failed (errno \(errno))")
            }
        }
        return KillResultDTO(pid: pid, status: .terminating)
    }

    /// Asks the system to restart. This is a *request*, not a command: an
    /// unprivileged restart goes through System Events and any app with
    /// unsaved changes can veto it. There's no honest way to report success —
    /// the client should treat the Mac going offline as the confirmation.
    ///
    /// (`shutdown -r now` would be authoritative but needs root, which this
    /// agent deliberately doesn't have.)
    static func requestRestart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to restart"]
        // Fire and forget: the reply must reach the phone before the Mac goes
        // down, so we never wait on this.
        try? process.run()
    }
}
