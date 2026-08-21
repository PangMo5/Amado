# Caffeinate

Caffeinate is one of Amado's three primary workflows: keep a MacBook running
after its built-in display is closed while background work, servers, downloads,
and remote access continue. **Off** remains the default and preserves normal
macOS lid-close sleep. When Caffeinate is enabled, choose explicitly whether
the login session locks.

## Enable it

1. Open **Amado › Settings › General › Caffeinate**.
2. Set **When the lid closes** to **Stay awake and lock** or **Stay awake, keep
   unlocked**.
3. macOS opens **General › Login Items & Extensions**. Approve **Amado Power
   Helper** with an administrator account.
4. Return to Amado and choose **Try Again**.

The mode is remembered. On later launches Amado silently reacquires the
Caffeinate lease when the approved helper is available. Settings shows the live
status separately from the saved mode, so an approval or helper failure is
never presented as active.

## Locking policy

**Stay awake and lock** is the safe awake policy. Amado watches the kernel's
physical lid state and locks only on an open-to-closed transition while the
helper lease is active.

**Stay awake and lock** locks the login session and requests system display
sleep. The Power Helper keeps the computer itself awake while all active
displays sleep.

**Stay awake, keep unlocked** keeps the Mac awake and leaves the login session
unlocked. Amado sets only the built-in panel's backlight to zero and restores
its previous brightness when the lid opens. The display remains logically
connected because Amado deliberately does not request system display sleep:
macOS can turn that request into a session lock when the password delay is
immediate. Use the unlocked policy only when the machine's physical and remote
access are already controlled.

When proximity Auto-lock is enabled, selecting this policy asks whether to
pause it. Choosing the pause option stops proximity monitoring for as long as
Caffeinate remains set to **Stay awake, keep unlocked**. Choosing to keep
Auto-lock on allows it to lock the session without putting the Mac to sleep.

## Why a helper is required

An ordinary IOKit assertion, including the mechanism used by `caffeinate`, can
prevent idle sleep but cannot override the sleep forced by closing a MacBook
lid. The system-wide `pmset disablesleep` setting can override it and requires
root privileges.

Amado bundles a narrow root LaunchDaemon and registers it with `SMAppService`:

- macOS keeps the helper visible and revocable in **Login Items & Extensions**;
- both XPC peers require the same Developer ID team and expected bundle IDs;
- the helper accepts only on/off lease requests, never a command or path from
  the app;
- Amado also holds a normal idle-sleep assertion while the lease is active;
- losing the XPC connection removes the lease and runs
  `pmset -a disablesleep 0`; a helper restart also begins by restoring normal
  sleep.

This fail-safe means quitting or crashing Amado does not intentionally leave a
global sleep override behind.

## Safety and responsibility

Caffeinate intentionally overrides normal lid-close sleep. The computer,
network services, and workloads continue running even though the built-in
display is closed. This can increase heat and battery use; battery exhaustion
can interrupt work and cause data loss. Amado does not silently disable the
feature at a battery or temperature threshold.

Use Caffeinate only on a hard, stable work surface with good ventilation.
Never leave the running Mac in a bag, bedding, on a pillow, under a blanket, or
in another enclosed space. Keep the ambient temperature within the range
specified for the Mac and stop Caffeinate if the case becomes unusually hot,
fans run unexpectedly, or the environment can no longer provide ventilation.
See [Apple's Mac laptop temperature and ventilation guidance][apple-thermal].

By enabling Caffeinate, the user accepts responsibility for the operating
environment, workload, battery level, physical security, and timely shutdown
of the override. To the extent permitted by applicable law, Amado and its
contributors are not liable for battery depletion, interrupted work, data
loss, hardware damage, overheating, or injury resulting from use of the
feature. The warranty and liability terms in sections 6 and 7 of the
[Mozilla Public License 2.0](../LICENSE) also apply.

[apple-thermal]: https://support.apple.com/102336
