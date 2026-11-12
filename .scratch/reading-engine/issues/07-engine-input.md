# 07: Engine input is what changes what is heard

**What to build:** The engine's input is **Instrument**, **Targets**, **Calibration**, mode and locked **String**. Precision is a display preference; `TunerConfig.guided` goes in favour of `mode == .guided`.

**Blocked by:** 06

**Status:** ready-for-agent

- [x] Toggling precision does not change the session's generation, proven by a test.
- [x] There is one way to say the tuner is in guided mode.
- [x] Preferences written by the current build still load.
- [x] The suite is green.
