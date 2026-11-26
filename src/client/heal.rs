//! Emilli Remote (REMOTE-UX-1): the picture heals itself, on the helper's side.
//!
//! Pure decisions, no I/O and no crates: the session loop (`io_loop.rs`) feeds the numbers it already
//! has, once a second and on each probe from the store PC, and sends what this returns with messages
//! every store PC understands (image quality, fps cap, codec preference, refresh). Times are
//! milliseconds on a clock the caller gives, so the tests run on a virtual one.
//!
//! States, each from a number the program measures:
//! - blurry: the store PC's bitrate target against the base bitrate of the resolution (`r`) below
//!   what that codec needs for sharp text (VP9 0.50, AV1 0.20, about kbit/s per megapixel / 1000),
//!   in 10 of the last 15 seconds;
//! - stuck low: the line is fine for 20 s but the target stays at 0.8 of the quality's own, with no
//!   full frame for 20 s (a still screen after a slow moment keeps the lowered bitrate);
//! - laggy: the probe round trip's median of five at max(400 ms, lowest + 250 ms), 10 of 15 seconds;
//! - frozen: no probe for 3 s, or a probe that took 2 s or more.
//! Steps, one at a time, each held 20 s: laggy -> slow (10 fps, low quality); blurry -> AV1, else
//! sharp (10 fps, best quality) when the line has room; stuck low -> the quality sent again with a
//! fresh full frame. A step is taken back after 60 s of a good line, mode first, then the codec;
//! a step that has to come back within 120 s of its undo waits twice as long next time (to 600 s).
//! At most 6 steps in 10 minutes, 2 of them codec steps. A dimension the helper chose in the menus is
//! pinned and never changed.

use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    Vp8,
    Vp9,
    Av1,
    H264,
    H265,
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Normal,
    /// 10 fps at the best quality: sharp text on a line that has room.
    Sharp,
    /// 10 fps at the low quality: the session keeps up on a thin line.
    Slow,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// Send the quality in force again and ask for a full frame.
    Resharpen,
    /// Ask for this mode (`Normal` = the helper's own quality and fps).
    SetMode(Mode),
    /// Prefer AV1 (`true`) or the helper's own codec preference again (`false`).
    SetAv1(bool),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Pins {
    pub codec: bool,
    pub quality: bool,
    pub off: bool,
}

/// The numbers of one second.
#[derive(Clone, Copy, Debug)]
pub struct Tick {
    pub now: u64,
    /// Frames drawn in the last second (the display in view).
    pub fps: u32,
    pub codec: Codec,
    /// The base bitrate of the picture's resolution, kbit/s (0: not known yet).
    pub base_kbps: u32,
    /// The ratio of the quality in force (balanced 0.67, best 1.5, low 0.5, custom as set).
    pub quality_ratio: f32,
    pub av1_offered: bool,
    /// The helper clicked, scrolled or typed in this second.
    pub input: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Ok,
    Blurry,
    StuckLow,
    Laggy,
    Frozen,
}

const HOLD: u64 = 20_000;
const SETTLE: u64 = 5_000;
const NEED_OK: u64 = 60_000;
const NEED_OK_MAX: u64 = 600_000;
const BOUNCE: u64 = 120_000;
const WINDOW: usize = 15;
const IN_WINDOW: usize = 10;
const CAP_WINDOW: u64 = 600_000;
const CAP_ALL: usize = 6;
const CAP_CODEC: usize = 2;
const AV1_TRIAL: u64 = 60_000;
const SHOW_AFTER: u64 = 10_000;

/// What a codec needs, as a share of the base bitrate, for text that reads sharp on a still screen
/// (REMOTE-BLUR and REMOTE-153 measurements at 1080p; the hardware ones by codec efficiency).
pub fn blurry_limit(c: Codec) -> f32 {
    match c {
        Codec::Av1 => 0.20,
        Codec::Vp9 | Codec::Other => 0.50,
        Codec::Vp8 | Codec::H264 => 0.55,
        Codec::H265 => 0.45,
    }
}

/// The hardware encoders get more bits than the base for the same picture.
fn hw_factor(c: Codec, base_kbps: u32) -> f32 {
    match c {
        Codec::H264 => 2.0,
        Codec::H265 if (base_kbps as f32) * 1.5 < 2000.0 => 1.5,
        _ => 1.0,
    }
}

pub struct Heal {
    pins: Pins,
    mode: Mode,
    av1: bool,
    codec_before: Codec,
    av1_since: u64,
    av1_heavy: bool,
    probes: VecDeque<(u64, u32)>,
    lows: VecDeque<(u64, u32)>,
    target_kbps: u32,
    last_probe: u64,
    last_key: u64,
    frozen_starts: VecDeque<u64>,
    frozen_since: Option<u64>,
    blurry: VecDeque<bool>,
    laggy: VecDeque<bool>,
    choppy: VecDeque<bool>,
    stuck: VecDeque<bool>,
    healthy_since: Option<u64>,
    ok_since: Option<u64>,
    last_change: u64,
    last_resharpen: Option<u64>,
    changes: VecDeque<(u64, bool)>,
    need_ok_mode: u64,
    need_ok_codec: u64,
    undone_mode: Option<(Mode, u64)>,
    undone_av1: Option<u64>,
    state: State,
    r: f32,
    d5: u32,
    d0: u32,
    shown: Option<(&'static str, u64)>,
    paused: bool,
    started: u64,
}

impl Heal {
    pub fn new(now: u64, pins: Pins) -> Self {
        Heal {
            pins,
            mode: Mode::Normal,
            av1: false,
            codec_before: Codec::Other,
            av1_since: 0,
            av1_heavy: false,
            probes: VecDeque::new(),
            lows: VecDeque::new(),
            target_kbps: 0,
            last_probe: now,
            last_key: now,
            frozen_starts: VecDeque::new(),
            frozen_since: None,
            blurry: VecDeque::new(),
            laggy: VecDeque::new(),
            choppy: VecDeque::new(),
            stuck: VecDeque::new(),
            healthy_since: None,
            ok_since: None,
            last_change: 0,
            last_resharpen: None,
            changes: VecDeque::new(),
            need_ok_mode: NEED_OK,
            need_ok_codec: NEED_OK,
            undone_mode: None,
            undone_av1: None,
            state: State::Ok,
            r: 0.0,
            d5: 0,
            d0: 0,
            shown: None,
            paused: false,
            started: now,
        }
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn av1(&self) -> bool {
        self.av1
    }

    pub fn state(&self) -> State {
        self.state
    }

    /// The helper's own choices. A dimension that becomes pinned drops our change in it (the
    /// helper's choice has already been sent).
    pub fn set_pins(&mut self, pins: Pins) {
        if pins.codec || pins.off {
            self.av1 = false;
        }
        if pins.quality || pins.off {
            self.mode = Mode::Normal;
        }
        self.pins = pins;
    }

    /// A probe came back from the store PC: its round trip and the encoder's target.
    pub fn on_probe(&mut self, now: u64, delay_ms: u32, target_kbps: u32) {
        self.last_probe = now;
        if target_kbps > 0 {
            self.target_kbps = target_kbps;
        }
        self.probes.push_back((now, delay_ms));
        while self.probes.len() > 5 {
            self.probes.pop_front();
        }
        self.lows.push_back((now, delay_ms));
        while self.lows.front().map(|l| now.saturating_sub(l.0) > 120_000).unwrap_or(false) {
            self.lows.pop_front();
        }
        if delay_ms >= 2000 {
            self.frozen_episode(now);
        } else if delay_ms < 1000 {
            self.frozen_since = None;
        }
    }

    pub fn on_key_frame(&mut self, now: u64) {
        self.last_key = now;
    }

    fn frozen_episode(&mut self, now: u64) {
        if self.frozen_since.is_none() {
            self.frozen_since = Some(now);
            self.frozen_starts.push_back(now);
        }
    }

    fn median5(&self) -> u32 {
        let mut v: Vec<u32> = self.probes.iter().map(|p| p.1).collect();
        if v.is_empty() {
            return 0;
        }
        v.sort_unstable();
        v[v.len() / 2]
    }

    fn push(w: &mut VecDeque<bool>, v: bool) -> usize {
        w.push_back(v);
        while w.len() > WINDOW {
            w.pop_front();
        }
        w.iter().filter(|b| **b).count()
    }

    fn clear_windows(&mut self) {
        self.blurry.clear();
        self.laggy.clear();
        self.choppy.clear();
        self.stuck.clear();
    }

    fn can_change(&mut self, now: u64, codec: bool) -> bool {
        if now.saturating_sub(self.last_change) < HOLD && self.last_change > 0 {
            return false;
        }
        while self.changes.front().map(|c| now.saturating_sub(c.0) > CAP_WINDOW).unwrap_or(false) {
            self.changes.pop_front();
        }
        let all = self.changes.len();
        let codecs = self.changes.iter().filter(|c| c.1).count();
        let ok = all < CAP_ALL && (!codec || codecs < CAP_CODEC);
        self.paused = !ok;
        ok
    }

    fn changed(&mut self, now: u64, codec: bool) {
        self.last_change = now;
        self.changes.push_back((now, codec));
        self.ok_since = None;
        self.clear_windows();
    }

    fn show(&mut self, key: &'static str, now: u64) {
        self.shown = Some((key, now));
    }

    /// One second: the state, and at most one step.
    pub fn tick(&mut self, t: &Tick) -> Option<Action> {
        let now = t.now;
        self.d5 = self.median5();
        self.d0 = self.lows.iter().map(|l| l.1).min().unwrap_or(0);
        let sp = now.saturating_sub(self.last_probe);
        if sp >= 3000 {
            self.frozen_episode(now);
        }
        while self.frozen_starts.front().map(|s| now.saturating_sub(*s) > 120_000).unwrap_or(false) {
            self.frozen_starts.pop_front();
        }
        let base = t.base_kbps as f32 * hw_factor(t.codec, t.base_kbps);
        self.r = if base > 0.0 { self.target_kbps as f32 / base } else { 0.0 };
        let lag_line = std::cmp::max(400, self.d0 + 250);
        let good_line = std::cmp::max(250, self.d0 + 100);
        let probes_known = !self.probes.is_empty();
        let frozen_now = self.frozen_since.is_some();
        let frozen = frozen_now
            && (self.frozen_starts.len() >= 2
                || self.frozen_since.map(|s| now.saturating_sub(s) >= 5000).unwrap_or(false));
        let settled = now.saturating_sub(self.last_change) >= SETTLE || self.last_change == 0;
        let judged = settled && now.saturating_sub(self.started) >= SETTLE;
        let laggy_n = if judged { Self::push(&mut self.laggy, probes_known && self.d5 >= lag_line) } else { 0 };
        let healthy = probes_known && !frozen_now && self.d5 <= good_line;
        let blur_now = t.base_kbps > 0
            && self.target_kbps > 0
            && self.r < blurry_limit(t.codec)
            && now.saturating_sub(self.last_key) >= 15_000
            && !frozen_now
            && self.d5 < lag_line;
        let blurry_n = if judged { Self::push(&mut self.blurry, blur_now) } else { 0 };
        if healthy {
            self.healthy_since.get_or_insert(now);
        } else {
            self.healthy_since = None;
        }
        let stuck_now = healthy
            && self.healthy_since.map(|s| now.saturating_sub(s) >= 20_000).unwrap_or(false)
            && t.base_kbps > 0
            && self.target_kbps > 0
            && self.r <= 0.8 * t.quality_ratio
            && now.saturating_sub(self.last_key) >= 20_000;
        let stuck = judged && Self::push(&mut self.stuck, stuck_now) >= IN_WINDOW;
        // Too heavy for this store PC: during the AV1 trial, few frames reach the helper while
        // they use the session and the line has no queue.
        let choppy_n = if judged && self.av1 && t.input {
            Self::push(&mut self.choppy, t.fps >= 1 && t.fps <= 7 && healthy)
        } else {
            self.choppy.iter().filter(|b| **b).count()
        };

        // A fresh picture is the cheapest step; while it cannot be sent again (once a minute) a
        // picture that stays blurry gets the next step.
        let resharpen_due = self.last_resharpen.map(|r| now.saturating_sub(r) >= 60_000).unwrap_or(true);
        self.state = if frozen {
            State::Frozen
        } else if laggy_n >= IN_WINDOW {
            State::Laggy
        } else if stuck && resharpen_due && !self.pins.quality {
            State::StuckLow
        } else if blurry_n >= IN_WINDOW {
            State::Blurry
        } else if stuck {
            State::StuckLow
        } else {
            State::Ok
        };
        let line_ok = healthy && self.state == State::Ok;
        if line_ok {
            self.ok_since.get_or_insert(now);
        } else {
            self.ok_since = None;
        }

        if self.pins.off {
            if self.state != State::Ok {
                self.show("emilli_heal_pinned", now);
            }
            return None;
        }

        // The AV1 trial: too heavy, back for the rest of the session.
        if self.av1 && now.saturating_sub(self.av1_since) <= AV1_TRIAL && choppy_n >= 5 {
            self.av1 = false;
            self.av1_heavy = true;
            self.changed(now, true);
            self.show("emilli_heal_av1_heavy", now);
            return Some(Action::SetAv1(false));
        }

        match self.state {
            State::Frozen => {
                self.show("emilli_heal_frozen", now);
                if self.mode != Mode::Slow && !self.pins.quality && self.can_change(now, false) {
                    return Some(self.set_mode(now, Mode::Slow));
                }
            }
            State::Laggy => {
                if self.pins.quality {
                    self.show("emilli_heal_pinned", now);
                } else {
                    self.show("emilli_heal_watch_lag", now);
                    if self.mode == Mode::Sharp && self.can_change(now, false) {
                        return Some(self.set_mode(now, Mode::Normal));
                    }
                    if self.mode == Mode::Normal && self.can_change(now, false) {
                        self.show("emilli_heal_slow", now);
                        return Some(self.set_mode(now, Mode::Slow));
                    }
                }
            }
            State::StuckLow => {
                if self.pins.quality {
                    self.show("emilli_heal_pinned", now);
                } else if resharpen_due && self.can_change(now, false) {
                    self.last_resharpen = Some(now);
                    self.changed(now, false);
                    self.show("emilli_heal_resharpen", now);
                    return Some(Action::Resharpen);
                }
            }
            State::Blurry => {
                let av1_ok = !self.av1 && t.codec != Codec::Av1 && t.av1_offered && !self.av1_heavy;
                if self.pins.codec && self.pins.quality {
                    self.show("emilli_heal_pinned", now);
                } else if av1_ok && !self.pins.codec {
                    if self.can_change(now, true) {
                        self.bounce_codec(now);
                        self.av1 = true;
                        self.codec_before = t.codec;
                        self.av1_since = now;
                        self.changed(now, true);
                        self.show("emilli_heal_av1", now);
                        return Some(Action::SetAv1(true));
                    }
                    self.show("emilli_heal_watch_blur", now);
                } else if self.mode == Mode::Normal && !self.pins.quality && healthy {
                    if self.can_change(now, false) {
                        self.show("emilli_heal_sharp", now);
                        return Some(self.set_mode(now, Mode::Sharp));
                    }
                    self.show("emilli_heal_watch_blur", now);
                } else {
                    self.show("emilli_heal_no_room", now);
                }
            }
            State::Ok => {
                let ok_for = self.ok_since.map(|s| now.saturating_sub(s)).unwrap_or(0);
                if self.mode != Mode::Normal && ok_for >= self.need_ok_mode && self.can_change(now, false) {
                    let from = self.mode;
                    let a = self.set_mode(now, Mode::Normal);
                    self.undone_mode = Some((from, now));
                    self.home_or_step(now);
                    return Some(a);
                }
                if self.mode == Mode::Normal
                    && self.av1
                    && ok_for >= self.need_ok_codec
                    && self.r >= 1.3 * blurry_limit(self.codec_before)
                    && self.can_change(now, true)
                {
                    self.av1 = false;
                    self.undone_av1 = Some(now);
                    self.changed(now, true);
                    self.home_or_step(now);
                    return Some(Action::SetAv1(false));
                }
            }
        }
        None
    }

    fn set_mode(&mut self, now: u64, m: Mode) -> Action {
        if m != Mode::Normal {
            if let Some((was, at)) = self.undone_mode {
                if was == m && now.saturating_sub(at) <= BOUNCE {
                    self.need_ok_mode = (self.need_ok_mode * 2).min(NEED_OK_MAX);
                }
            }
        }
        self.mode = m;
        self.changed(now, false);
        Action::SetMode(m)
    }

    fn bounce_codec(&mut self, now: u64) {
        if let Some(at) = self.undone_av1 {
            if now.saturating_sub(at) <= BOUNCE {
                self.need_ok_codec = (self.need_ok_codec * 2).min(NEED_OK_MAX);
            }
        }
    }

    fn home_or_step(&mut self, now: u64) {
        if self.mode == Mode::Normal && !self.av1 {
            self.show("emilli_heal_home", now);
        } else {
            self.show("emilli_heal_step_back", now);
        }
    }

    /// The one line for the helper (a translation key), or none.
    pub fn status(&self, now: u64) -> Option<&'static str> {
        if self.paused {
            return Some("emilli_heal_paused");
        }
        if self.mode == Mode::Slow && !matches!(self.state, State::Frozen) {
            return Some("emilli_heal_slow");
        }
        if self.mode == Mode::Sharp {
            return Some("emilli_heal_sharp");
        }
        if let Some((key, at)) = self.shown {
            let lasting = matches!(key, "emilli_heal_av1" | "emilli_heal_frozen");
            if now.saturating_sub(at) <= SHOW_AFTER || (lasting && (self.av1 || self.state == State::Frozen)) {
                return Some(key);
            }
        }
        if self.av1 {
            return Some("emilli_heal_av1");
        }
        None
    }

    /// The numbers behind the last decision, for the log.
    pub fn describe(&self, now: u64) -> String {
        format!(
            "st={:?} mode={:?} av1={} r={:.2} target={} d5={} d0={} sp={} sk={} need_ok={}/{} pins={}{}{}",
            self.state,
            self.mode,
            self.av1,
            self.r,
            self.target_kbps,
            self.d5,
            self.d0,
            now.saturating_sub(self.last_probe),
            now.saturating_sub(self.last_key),
            self.need_ok_mode / 1000,
            self.need_ok_codec / 1000,
            if self.pins.codec { "c" } else { "-" },
            if self.pins.quality { "q" } else { "-" },
            if self.pins.off { "off" } else { "" },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: u32 = 2073; // 1920x1080

    struct Sim {
        h: Heal,
        now: u64,
        codec: Codec,
        quality: f32,
        av1_offered: bool,
        actions: Vec<(u64, Action)>,
    }

    impl Sim {
        fn new(pins: Pins) -> Self {
            Sim { h: Heal::new(0, pins), now: 0, codec: Codec::Vp9, quality: 0.67, av1_offered: true, actions: vec![] }
        }
        /// Seconds of one line: probe delay and the encoder's target ratio, one probe a second.
        fn run(&mut self, secs: u64, delay: u32, ratio: f32) {
            self.run_with(secs, delay, ratio, 20, false);
        }
        fn run_with(&mut self, secs: u64, delay: u32, ratio: f32, fps: u32, input: bool) {
            for _ in 0..secs {
                self.now += 1000;
                self.h.on_probe(self.now, delay, (ratio * BASE as f32) as u32);
                let t = Tick { now: self.now, fps, codec: self.codec, base_kbps: BASE, quality_ratio: self.quality, av1_offered: self.av1_offered, input };
                if let Some(a) = self.h.tick(&t) {
                    self.actions.push((self.now, a));
                    // a codec change and a refresh each bring a full frame
                    if matches!(a, Action::SetAv1(_) | Action::Resharpen) {
                        self.h.on_key_frame(self.now);
                    }
                    match a {
                        Action::SetAv1(true) => self.codec = Codec::Av1,
                        Action::SetAv1(false) => self.codec = Codec::Vp9,
                        Action::SetMode(Mode::Slow) => self.quality = 0.5,
                        Action::SetMode(Mode::Sharp) => self.quality = 1.5,
                        Action::SetMode(Mode::Normal) => self.quality = 0.67,
                        Action::Resharpen => {}
                    }
                }
            }
        }
        /// Seconds with no probe at all (a stalled line).
        fn stall(&mut self, secs: u64) {
            for _ in 0..secs {
                self.now += 1000;
                let t = Tick { now: self.now, fps: 0, codec: self.codec, base_kbps: BASE, quality_ratio: self.quality, av1_offered: self.av1_offered, input: false };
                if let Some(a) = self.h.tick(&t) {
                    self.actions.push((self.now, a));
                }
            }
        }
    }

    #[test]
    fn a_good_line_changes_nothing() {
        let mut s = Sim::new(Pins::default());
        s.run(600, 40, 0.67);
        assert!(s.actions.is_empty(), "{:?}", s.actions);
        assert_eq!(s.h.status(s.now), None);
    }

    #[test]
    fn a_slow_line_goes_slow_then_back_after_a_good_minute() {
        let mut s = Sim::new(Pins::default());
        s.run(30, 40, 0.67);
        s.run(60, 700, 0.34);
        let first = s.actions.first().copied().expect("a step on the slow line");
        assert_eq!(first.1, Action::SetMode(Mode::Slow));
        assert!(first.0 - 30_000 <= 20_000, "step after {} ms", first.0 - 30_000);
        let before = s.actions.len();
        s.run(59, 40, 0.67);
        assert_eq!(s.actions.len(), before, "nothing back within the first minute: {:?}", s.actions);
        s.run(15, 40, 0.67);
        assert_eq!(s.actions.last().unwrap().1, Action::SetMode(Mode::Normal));
    }

    #[test]
    fn blurry_on_a_good_line_tries_av1_and_comes_back_when_the_budget_is_back() {
        let mut s = Sim::new(Pins::default());
        s.run(20, 40, 0.67);
        // a line with a little queue (320 ms, not slow), VP9 under 0.50: blurry
        s.run(30, 320, 0.30);
        assert_eq!(s.actions[0].1, Action::SetAv1(true));
        // AV1 at 0.30 is not blurry; nothing else happens while the line stays so (a minute; after
        // two the 320 ms are the line's own round trip and the low budget reads as stuck low)
        s.run(60, 320, 0.30);
        assert_eq!(s.actions.len(), 1, "{:?}", s.actions);
        // the budget comes back: AV1 is taken back after a good minute (0.67 >= 1.3 x 0.50)
        s.run(70, 40, 0.67);
        assert_eq!(s.actions.last().unwrap().1, Action::SetAv1(false));
    }

    #[test]
    fn without_av1_a_blurry_picture_on_a_good_line_goes_sharp() {
        let mut s = Sim::new(Pins::default());
        s.av1_offered = false;
        s.run(20, 40, 0.67);
        s.run(60, 40, 0.30);
        // first a fresh picture at the quality in force (the cheaper step), then sharp
        assert_eq!(s.actions[0].1, Action::Resharpen, "{:?}", s.actions);
        assert!(s.actions.iter().any(|a| a.1 == Action::SetMode(Mode::Sharp)), "{:?}", s.actions);
    }

    #[test]
    fn a_still_screen_left_low_gets_a_fresh_picture_once_a_minute_at_most() {
        let mut s = Sim::new(Pins::default());
        s.run(20, 40, 0.67);
        // the line is fine, the target stays at 0.52 (under 0.8 x 0.67), no full frame
        s.run(100, 40, 0.52);
        let res: Vec<_> = s.actions.iter().filter(|a| a.1 == Action::Resharpen).collect();
        assert!(!res.is_empty(), "{:?}", s.actions);
        for w in res.windows(2) {
            assert!(w[1].0 - w[0].0 >= 60_000);
        }
    }

    #[test]
    fn a_full_frame_after_the_fresh_picture_ends_stuck_low() {
        let mut s = Sim::new(Pins::default());
        s.run(20, 40, 0.67);
        s.run(45, 40, 0.52);
        let n = s.actions.len();
        assert!(n >= 1);
        s.h.on_key_frame(s.now);
        s.run(15, 40, 0.67);
        assert_eq!(s.actions.len(), n);
    }

    #[test]
    fn two_stalls_go_slow_without_a_codec_change() {
        let mut s = Sim::new(Pins::default());
        s.run(30, 40, 0.67);
        s.stall(4);
        s.run(10, 40, 0.67);
        s.stall(4);
        s.run(3, 40, 0.67);
        assert!(s.actions.iter().any(|a| a.1 == Action::SetMode(Mode::Slow)), "{:?}", s.actions);
        assert!(!s.actions.iter().any(|a| matches!(a.1, Action::SetAv1(_))));
    }

    #[test]
    fn changes_are_twenty_seconds_apart_and_at_most_six_in_ten_minutes() {
        let mut s = Sim::new(Pins::default());
        s.run(20, 40, 0.67);
        for _ in 0..6 {
            s.run(60, 900, 0.30);
            s.run(90, 40, 0.67);
        }
        for w in s.actions.windows(2) {
            assert!(w[1].0 - w[0].0 >= HOLD, "{:?}", s.actions);
        }
        for (i, a) in s.actions.iter().enumerate() {
            let n = s.actions[i..].iter().filter(|b| b.0 - a.0 <= CAP_WINDOW).count();
            assert!(n <= CAP_ALL, "{} changes within 10 minutes from {}", n, a.0);
        }
    }

    #[test]
    fn a_step_that_comes_back_soon_waits_twice_as_long_next_time() {
        let mut s = Sim::new(Pins::default());
        s.run(20, 40, 0.67);
        s.run(40, 900, 0.30); // slow
        s.run(75, 40, 0.67); // back after 60 s
        assert_eq!(s.actions.last().unwrap().1, Action::SetMode(Mode::Normal));
        s.run(40, 900, 0.30); // slow again within 120 s: bounce
        let n = s.actions.len();
        s.run(100, 40, 0.67);
        assert_eq!(s.actions.len(), n, "not back after 100 s: {:?}", s.actions);
        s.run(30, 40, 0.67);
        assert_eq!(s.actions.last().unwrap().1, Action::SetMode(Mode::Normal));
    }

    #[test]
    fn a_pinned_codec_is_never_changed_and_a_pinned_quality_neither() {
        let mut s = Sim::new(Pins { codec: true, quality: true, off: false });
        s.run(20, 40, 0.67);
        s.run(120, 900, 0.30);
        s.run(120, 40, 0.30);
        assert!(s.actions.is_empty(), "{:?}", s.actions);
        assert_eq!(s.h.status(s.now), Some("emilli_heal_pinned"));
    }

    #[test]
    fn off_does_nothing() {
        let mut s = Sim::new(Pins { codec: false, quality: false, off: true });
        s.run(20, 40, 0.67);
        s.run(120, 900, 0.30);
        s.stall(6);
        assert!(s.actions.is_empty());
    }

    #[test]
    fn pinning_in_the_menu_drops_our_change() {
        let mut s = Sim::new(Pins::default());
        s.run(20, 40, 0.67);
        s.run(30, 320, 0.30);
        assert!(s.h.av1());
        s.h.set_pins(Pins { codec: true, quality: false, off: false });
        assert!(!s.h.av1());
    }

    #[test]
    fn av1_too_heavy_goes_back_and_is_not_tried_again() {
        let mut s = Sim::new(Pins::default());
        s.run(20, 40, 0.67);
        s.run(30, 320, 0.30);
        assert_eq!(s.actions[0].1, Action::SetAv1(true));
        s.run_with(40, 40, 0.30, 4, true); // few frames while the helper works, line fine
        assert!(s.actions.iter().any(|a| a.1 == Action::SetAv1(false)), "{:?}", s.actions);
        let n = s.actions.iter().filter(|a| a.1 == Action::SetAv1(true)).count();
        s.run(120, 40, 0.30);
        assert_eq!(s.actions.iter().filter(|a| a.1 == Action::SetAv1(true)).count(), n);
    }
}
