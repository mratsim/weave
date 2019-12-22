# Changelog


### v0.2.0 - December 2019

Weave `EventNotifier` has been rewritten and formally verified.
Combined with using raw Linux futex to workaround a condition variable bug
in glibc and musl, Weave backoff system is now deadlock-free.

Backoff has been renamed from `WV_EnableBackoff` to `WV_Backoff`.
It is now enabled by default.

Weave now supports Windows.

### v0.1.0 - December 2019

Initial release
