# 07: Engine input is what changes what is heard

**What to build:** The engine's input is **Instrument**, **Targets**, **Calibration**, mode and locked **String**. Precision is a display preference; `TunerConfig.guided` goes in favour of `mode == .guided`.

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] Toggling precision does not change the session's generation, proven by a test.
- [ ] There is one way to say the tuner is in guided mode.
- [ ] Preferences written by the current build still load.
- [ ] The suite is green.
