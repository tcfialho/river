// SPDX-FileCopyrightText: © 2022 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const posix = std.posix;

var original_rlimit: ?posix.rlimit = null;

pub fn setup() void {
    // Ignore SIGPIPE so we don't get killed when writing to a socket that
    // has had its read end closed by another process.
    const sig_ign = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_ign, null);

    // Most unix systems have a default limit of 1024 file descriptors and it
    // seems unlikely for this default to be universally raised due to the
    // broken behavior of select() on fds with value >1024. However, it is
    // unreasonable to use such a low limit for a process such as river which
    // uses many fds in its communication with wayland clients and the kernel.
    //
    // There is however an advantage to having a relatively low limit: it helps
    // to catch any fd leaks. Therefore, don't use some crazy high limit that
    // can never be reached before the system runs out of memory. This can be
    // raised further if anyone reaches it in practice.
    if (posix.getrlimit(.NOFILE)) |original| {
        original_rlimit = original;
        const new: posix.rlimit = .{
            .cur = @min(4096, original.max),
            .max = original.max,
        };
        if (posix.setrlimit(.NOFILE, new)) {
            std.log.info("raised file descriptor limit of the river process to {d}", .{new.cur});
        } else |_| {
            std.log.err("setrlimit failed, using system default file descriptor limit of {d}", .{
                original.cur,
            });
        }
    } else |_| {
        std.log.err("getrlimit failed, using system default file descriptor limit ", .{});
    }

    setupScheduling();
}

const SCHED_RR: c_int = 2;
const SCHED_OTHER: c_int = 0;
const PRIO_PROCESS: c_int = 0;
const sched_param = extern struct { sched_priority: c_int };
extern fn sched_setscheduler(pid: posix.pid_t, policy: c_int, param: *const sched_param) c_int;
extern fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;

fn setupScheduling() void {
    const rt_param: sched_param = .{ .sched_priority = 1 };
    if (sched_setscheduler(0, SCHED_RR, &rt_param) == 0) {
        std.log.info("running with SCHED_RR priority 1", .{});
        return;
    }
    // Fallback: negative nice. Also needs privilege (limits.conf nice cap),
    // so this may fail too — river then just runs at default priority.
    if (setpriority(PRIO_PROCESS, 0, -10) == 0) {
        std.log.info("running with nice -10", .{});
    } else {
        std.log.info("no scheduling privilege, running at default priority " ++
            "(grant rtprio via /etc/security/limits.conf, see PERF-AUDIT)", .{});
    }
}

pub fn cleanupChild() void {
    if (std.c.setsid() < 0) unreachable;
    if (posix.system.sigprocmask(posix.SIG.SETMASK, &posix.sigemptyset(), null) < 0) unreachable;

    const sig_dfl = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sig_dfl, null);

    // Children must not inherit river's RT scheduling.
    const other_param: sched_param = .{ .sched_priority = 0 };
    _ = sched_setscheduler(0, SCHED_OTHER, &other_param);
    _ = setpriority(PRIO_PROCESS, 0, 0);

    if (original_rlimit) |original| {
        posix.setrlimit(.NOFILE, original) catch {
            std.log.err("failed to restore original file descriptor limit for " ++
                "child process, setrlimit failed", .{});
        };
    }
}
