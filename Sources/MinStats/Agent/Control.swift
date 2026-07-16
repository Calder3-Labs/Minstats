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
        // 1. Pid-reuse interlock: keep only pids whose *current* name still
        //    matches what the client saw; report the rest without touching them.
        var results: [KillResultDTO] = []
        var live: [pid_t] = []
        for pid in pids {
            guard let current = ProcessSampler.displayName(for: pid) else {
                results.append(KillResultDTO(pid: pid, status: .gone, reason: "process has exited"))
                continue
            }
            guard current == expectedName else {
                results.append(KillResultDTO(
                    pid: pid, status: .denied,
                    reason: "pid is now \(current), not \(expectedName)"
                ))
                continue
            }
            live.append(pid)
        }

        // 2. A group is one .app bundle: a main application process plus its
        //    helper children (a browser's renderers, say). Quit the *app* once,
        //    as a genuine Cmd-Q, and let macOS tear the helpers down with it.
        //    Signalling the helpers ourselves is what crashed individual Brave
        //    tabs with "Error code 15" (SIGTERM) while the browser stayed up —
        //    so when an app owns the group we deliberately never touch the
        //    leftover pids.
        let apps = live.compactMap { pid in
            NSRunningApplication(processIdentifier: pid).map { (pid: pid, app: $0) }
        }

        if apps.isEmpty {
            // No application here — plain processes (daemons, CLI tools like
            // `yes`). Signal each on its own; there's nothing to Cmd-Q.
            results.append(contentsOf: live.map { signalProcess(pid: $0, mode: mode) })
            return results
        }

        let appPids = Set(apps.map(\.pid))
        for (pid, app) in apps {
            // terminate() is a real Cmd-Q, so the app gets to save and clean up;
            // forceTerminate() is the SIGKILL-equivalent for a wedged app.
            let ok = mode == .force ? app.forceTerminate() : app.terminate()
            results.append(ok
                ? KillResultDTO(pid: pid, status: .terminating)
                : KillResultDTO(pid: pid, status: .denied, reason: "the app refused to quit"))
        }
        // The helpers exit with the app they belong to — reported, never signalled.
        for pid in live where !appPids.contains(pid) {
            results.append(KillResultDTO(pid: pid, status: .terminating, reason: "quits with \(expectedName)"))
        }
        return results
    }

    private static func signalProcess(pid: pid_t, mode: KillMode) -> KillResultDTO {
        let sig = mode == .force ? SIGKILL : SIGTERM
        guard Darwin.kill(pid, sig) == 0 else {
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
