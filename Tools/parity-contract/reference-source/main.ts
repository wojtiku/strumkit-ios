import './style.css';
import { mountUI, type UIState } from './ui';
import { TunerAudio } from './audio';
import { TunerTracker, TUNINGS } from './tuning';
import { TunerPresentation } from './presentation';
import { TuningFeedback } from './feedback';

if (__LOCAL_DIAGNOSTICS__ && new URLSearchParams(location.search).get('presentation') === 'webtuna') {
  void import('./webtuna-test').then(module => module.mountWebTunaTest());
} else {
const ui = mountUI();
const audio = new TunerAudio();
const tracker = new TunerTracker();
const presentation = new TunerPresentation();
const feedback = new TuningFeedback();
const state: UIState = {
  running: false, audioSource: null, status: 'Tap to tune. Your microphone audio stays on this device.',
  note: '—', frequency: null, cents: null, selected: null, inTune: false,
  level: 0, tuning: 'standard', auto: true, indicatorGreen: false, soundEnabled: true,
};
let session = 0;
let mode: 'microphone' | 'recording' | 'tone' | null = null;
const render = () => ui.update(state);
function clearReading() {
  tracker.reset();
  presentation.reset();
  feedback.clearReading();
  state.note = state.auto ? '—' : TUNINGS[state.tuning][tracker.selected].note;
  state.frequency = null;
  state.cents = null;
  state.inTune = false;
  state.indicatorGreen = false;
  state.level = 0;
  state.selected = state.auto ? null : tracker.selected;
}
function stop(status = 'Stopped. Tap to tune when you’re ready.') {
  session++;
  audio.stop();
  feedback.reset();
  mode = null;
  state.audioSource = null;
  state.running = false;
  state.status = status;
  clearReading();
  render();
}
async function start(kind: 'microphone' | 'recording' | 'tone', fileOrIndex?: File | number) {
  stop();
  const id = session;
  mode = kind;
  state.audioSource = kind;
  state.running = true;
  state.status = kind === 'microphone' ? 'Waiting for microphone permission…' : kind === 'recording' ? 'Loading recording…' : 'Playing reference tone. Microphone is off.';
  render();
  try {
    const started = kind === 'microphone' ? await audio.microphone()
      : kind === 'recording' ? await audio.recording(fileOrIndex as File)
      : await audio.tone(TUNINGS[state.tuning][fileOrIndex as number].frequency);
    if (id !== session || !started) return;
    state.status = kind === 'microphone' ? 'Listening. Pluck one open string and let it ring.'
      : kind === 'recording' ? `Analyzing ${(fileOrIndex as File).name} silently…`
      : 'Playing reference tone. Tap to tune to resume microphone.';
    render();
  } catch (error) {
    if (id === session) stop(error instanceof Error ? error.message : 'Unable to start audio. Please try again.');
  }
}
audio.onFrame = frame => {
  if (!state.running || mode === 'tone') return;
  state.level = Math.min(1, Math.sqrt(frame.rms) * 3);
  const tracked = tracker.push(frame.pitch, frame.time);
  if (feedback.observe(tracked) && state.soundEnabled) audio.playBell();
  const reading = presentation.push(tracked, frame.time);
  if (reading === undefined) return;
  if (reading) {
    state.frequency = reading.frequency;
    state.cents = reading.cents;
    state.note = reading.note;
    state.selected = reading.index;
    state.inTune = reading.inTune;
    state.indicatorGreen = reading.inTune || feedback.green(reading);
    state.status = reading.inTune ? 'In tune. Nicely done.' : Math.abs(reading.cents) <= 5 ? 'Hold the note…' : reading.cents < 0 ? 'Too low — tighten the string gently.' : 'Too high — loosen the string gently.';
  } else {
    state.frequency = null;
    state.cents = null;
    state.inTune = false;
    state.indicatorGreen = false;
    state.note = state.auto ? '—' : TUNINGS[state.tuning][tracker.selected].note;
    state.selected = state.auto ? null : tracker.selected;
    state.status = frame.rms < 0.000015 ? 'Listening. Pluck one open string.' : 'Finding a clear note. Play one string at a time.';
  }
  render();
};
audio.onEnded = () => stop(mode === 'recording' ? 'Recording finished. Load another or tap to tune.' : mode === 'tone' ? 'Reference tone finished. Tap to tune.' : 'Microphone disconnected. Tap to tune to reconnect.');
ui.onStart(() => { void start('microphone'); });
ui.onStop(() => stop());
ui.onAuto(auto => {
  if (!auto && state.selected !== null) tracker.selected = state.selected;
  state.auto = tracker.auto = auto;
  clearReading(); render();
});
ui.onString(index => {
  state.auto = tracker.auto = false;
  tracker.selected = index;
  clearReading(); render();
});
ui.onTuning(tuning => {
  if (!TUNINGS[tuning]) return;
  state.tuning = tracker.tuning = tuning;
  feedback.reset();
  clearReading(); render();
});
ui.onTone(index => { void start('tone', index); });
ui.onFile(file => { void start('recording', file); });
ui.onSound(enabled => { state.soundEnabled = enabled; if (!enabled) audio.stopBell(); render(); });
window.addEventListener('pagehide', () => audio.stop());
window.addEventListener('pageshow', event => {
  if (event.persisted) stop('Welcome back. Tap to tune to restart the microphone.');
});
render();
}
