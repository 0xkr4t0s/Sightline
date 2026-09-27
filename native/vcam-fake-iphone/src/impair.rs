//! Network impairment inside the fake iPhone, so soak runs need no `tc netem` or sudo
//! (task 2.7, NFR-REL-003).
//!
//! `--loss PCT` drops each outgoing datagram, and each incoming one before it is opened, with
//! probability PCT/100. `--jitter MS` holds each outgoing datagram that survives for a uniform
//! random 0..=MS (microsecond steps); held datagrams go out when due, so later ones can overtake
//! earlier ones. `--seed N` makes every decision reproducible: the send and receive paths draw
//! from separate SplitMix64 streams, so the n-th datagram on each path gets the same fate on
//! every run with that seed, however the two paths interleave. Without `--seed` a random seed is
//! used and reported in `FAKE_IPHONE_DONE`.

use std::cmp::Reverse;
use std::collections::BinaryHeap;
use std::time::{Duration, Instant};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// Usage text for the impairment flags.
pub(crate) const USAGE: &str = "[--loss PCT (0..100)] [--jitter MS (0..10000)] [--seed N]";

const MAX_JITTER_MS: u32 = 10_000;
/// Stream selectors mixed into the seed so the two paths draw independent sequences.
const SEND_STREAM: u64 = 0x5E4D_0000_0000_0001;
const RECV_STREAM: u64 = 0x2EC7_0000_0000_0002;

#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub(crate) struct ImpairArgs {
    loss_pct: f64,
    jitter_ms: u32,
    seed: Option<u64>,
}

impl ImpairArgs {
    /// Parses one impairment flag; false if `flag` isn't one.
    pub(crate) fn parse(
        &mut self,
        flag: &str,
        value: impl FnOnce() -> Result<String>,
    ) -> Result<bool> {
        match flag {
            "--loss" => {
                let pct: f64 = value()?.trim().parse()?;
                if !(0.0..=100.0).contains(&pct) {
                    return Err("--loss must be in [0, 100]".into());
                }
                self.loss_pct = pct;
            }
            "--jitter" => {
                let ms: u32 = value()?.trim().parse()?;
                if ms > MAX_JITTER_MS {
                    return Err(format!("--jitter must be in [0, {MAX_JITTER_MS}]").into());
                }
                self.jitter_ms = ms;
            }
            "--seed" => self.seed = Some(value()?.trim().parse()?),
            _ => return Ok(false),
        }
        Ok(true)
    }

    /// The impairment for one run; `fallback_seed` is used when `--seed` wasn't given.
    pub(crate) fn build(&self, fallback_seed: u64) -> Impairment {
        Impairment::new(
            self.loss_pct,
            Duration::from_millis(u64::from(self.jitter_ms)),
            self.seed.unwrap_or(fallback_seed),
        )
    }
}

/// SplitMix64 (Steele, Lea, Flood 2014): tiny, fast and fully determined by its seed.
#[derive(Debug, Clone)]
struct SplitMix64(u64);

impl SplitMix64 {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1) from the top 53 bits.
    fn next_unit(&mut self) -> f64 {
        const SCALE: f64 = 1.0 / (1u64 << 53) as f64;
        (self.next_u64() >> 11) as f64 * SCALE
    }
}

/// What happens to one outgoing datagram.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Fate {
    Drop,
    Now,
    After(Duration),
}

/// Datagram counts for `FAKE_IPHONE_DONE`.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Counters {
    /// Outgoing datagrams offered to the impairment (sent, held or dropped).
    pub(crate) out: u64,
    pub(crate) dropped_out: u64,
    /// Outgoing datagrams held for a non-zero delay.
    pub(crate) delayed: u64,
    /// Incoming datagrams received from the socket (kept or dropped).
    pub(crate) incoming: u64,
    pub(crate) dropped_in: u64,
}

#[derive(Debug)]
pub(crate) struct Impairment {
    loss_pct: f64,
    /// Drop probability in [0, 1].
    loss: f64,
    jitter_us: u64,
    seed: u64,
    send_rng: SplitMix64,
    recv_rng: SplitMix64,
    /// Held datagrams by due time; the counter keeps equal due times in send order.
    held: BinaryHeap<Reverse<(Instant, u64, Vec<u8>)>>,
    held_count: u64,
    counters: Counters,
}

impl Impairment {
    pub(crate) fn new(loss_pct: f64, jitter: Duration, seed: u64) -> Self {
        Self {
            loss_pct,
            loss: loss_pct / 100.0,
            jitter_us: u64::try_from(jitter.as_micros()).unwrap_or(u64::MAX),
            seed,
            send_rng: SplitMix64(seed ^ SEND_STREAM),
            recv_rng: SplitMix64(seed ^ RECV_STREAM),
            held: BinaryHeap::new(),
            held_count: 0,
            counters: Counters::default(),
        }
    }

    pub(crate) fn counters(&self) -> Counters {
        self.counters
    }

    /// Decides the next outgoing datagram's fate. Both draws are taken for every datagram, so
    /// the loss decisions for a seed don't depend on `--jitter` and vice versa.
    pub(crate) fn outgoing(&mut self) -> Fate {
        let lost = self.send_rng.next_unit() < self.loss;
        let delay_us = self.send_rng.next_u64() % self.jitter_us.saturating_add(1);
        self.counters.out += 1;
        if lost {
            self.counters.dropped_out += 1;
            Fate::Drop
        } else if delay_us == 0 {
            Fate::Now
        } else {
            self.counters.delayed += 1;
            Fate::After(Duration::from_micros(delay_us))
        }
    }

    /// True if the next incoming datagram is to be dropped unread.
    pub(crate) fn incoming_dropped(&mut self) -> bool {
        self.counters.incoming += 1;
        let lost = self.recv_rng.next_unit() < self.loss;
        if lost {
            self.counters.dropped_in += 1;
        }
        lost
    }

    /// Holds a datagram until `due`.
    pub(crate) fn hold(&mut self, due: Instant, datagram: Vec<u8>) {
        self.held_count += 1;
        self.held.push(Reverse((due, self.held_count, datagram)));
    }

    /// When the earliest held datagram is due.
    pub(crate) fn next_due(&self) -> Option<Instant> {
        self.held.peek().map(|Reverse((due, _, _))| *due)
    }

    /// The earliest held datagram if it is due at `now`.
    pub(crate) fn pop_due(&mut self, now: Instant) -> Option<Vec<u8>> {
        if self.next_due()? > now {
            return None;
        }
        self.held.pop().map(|Reverse((_, _, datagram))| datagram)
    }

    /// ` loss_pct= jitter_ms= seed= udp_out= dropped_out= delayed= udp_in= dropped_in=`.
    pub(crate) fn summary(&self) -> String {
        let c = self.counters();
        format!(
            " loss_pct={} jitter_ms={} seed={} udp_out={} dropped_out={} delayed={} udp_in={} dropped_in={}",
            self.loss_pct,
            self.jitter_us / 1000,
            self.seed,
            c.out,
            c.dropped_out,
            c.delayed,
            c.incoming,
            c.dropped_in
        )
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)] // test code: a panic is a test failure

    use super::*;

    const N: usize = 10_000;

    fn parse(args: &[&str]) -> Result<ImpairArgs> {
        let mut impair = ImpairArgs::default();
        for pair in args.chunks(2) {
            assert!(
                impair.parse(pair[0], || Ok(pair[1].to_owned()))?,
                "{pair:?}"
            );
        }
        Ok(impair)
    }

    fn decisions(seed: u64) -> (Vec<Fate>, Vec<bool>) {
        let mut impair = parse(&["--loss", "2", "--jitter", "10", "--seed", &seed.to_string()])
            .unwrap()
            .build(u64::MAX);
        let out = (0..N).map(|_| impair.outgoing()).collect();
        let incoming = (0..N).map(|_| impair.incoming_dropped()).collect();
        (out, incoming)
    }

    #[test]
    fn flags_parse_with_ranges_and_other_flags_pass_through() {
        assert_eq!(
            parse(&["--loss", "2.5", "--jitter", "10", "--seed", "7"]).unwrap(),
            ImpairArgs {
                loss_pct: 2.5,
                jitter_ms: 10,
                seed: Some(7)
            }
        );
        let err = |args: &[&str]| parse(args).unwrap_err().to_string();
        assert_eq!(err(&["--loss", "101"]), "--loss must be in [0, 100]");
        assert_eq!(err(&["--loss", "-1"]), "--loss must be in [0, 100]");
        assert_eq!(
            err(&["--jitter", "10001"]),
            "--jitter must be in [0, 10000]"
        );
        assert!(parse(&["--jitter", "-1"]).is_err());
        assert!(parse(&["--seed", "x"]).is_err());
        let mut other = ImpairArgs::default();
        assert!(!other.parse("--lens", || Ok("50".to_owned())).unwrap());
        // No --seed: the caller's random fallback is used and reported.
        let impair = ImpairArgs::default().build(99);
        assert!(
            impair.summary().contains(" seed=99 "),
            "{}",
            impair.summary()
        );
    }

    #[test]
    fn decisions_repeat_for_a_seed_and_differ_between_seeds() {
        let (out1, in1) = decisions(1);
        assert_eq!(decisions(1), (out1.clone(), in1.clone()));
        let (out2, in2) = decisions(2);
        assert_ne!(out1, out2);
        assert_ne!(in1, in2);
        // The two paths are separate streams, not the same sequence.
        let dropped_out: Vec<bool> = out1.iter().map(|f| *f == Fate::Drop).collect();
        assert_ne!(dropped_out, in1);
        // Each path's decisions don't depend on how sends and receives interleave.
        let mut impair = parse(&["--loss", "2", "--jitter", "10", "--seed", "1"])
            .unwrap()
            .build(0);
        let (mut out, mut incoming) = (Vec::new(), Vec::new());
        for i in 0..2 * N {
            if (i % 3 == 0 && incoming.len() < N) || out.len() == N {
                incoming.push(impair.incoming_dropped());
            } else {
                out.push(impair.outgoing());
            }
        }
        assert_eq!((out, incoming), (out1, in1));
    }

    #[test]
    fn measured_loss_is_within_one_point_of_two_percent_on_both_paths() {
        for seed in [1, 3, 42] {
            let (out, incoming) = decisions(seed);
            let lost_out = out.iter().filter(|f| **f == Fate::Drop).count();
            let lost_in = incoming.iter().filter(|d| **d).count();
            for (path, lost) in [("send", lost_out), ("receive", lost_in)] {
                let pct = 100.0 * lost as f64 / N as f64;
                println!("seed {seed} {path}: {lost} of {N} dropped = {pct:.2} %");
                assert!((1.0..=3.0).contains(&pct), "seed {seed} {path}: {pct} %");
            }
        }
        let mut none = ImpairArgs::default().build(1);
        assert!((0..N).all(|_| none.outgoing() == Fate::Now && !none.incoming_dropped()));
        let mut all = parse(&["--loss", "100"]).unwrap().build(1);
        assert!((0..N).all(|_| all.outgoing() == Fate::Drop && all.incoming_dropped()));
    }

    #[test]
    fn jitter_delays_stay_within_zero_to_ms_and_spread_uniformly() {
        let mut impair = parse(&["--jitter", "10", "--seed", "5"]).unwrap().build(0);
        let delays: Vec<Duration> = (0..N)
            .map(|_| match impair.outgoing() {
                Fate::After(d) => d,
                Fate::Now => Duration::ZERO,
                Fate::Drop => panic!("no loss requested"),
            })
            .collect();
        let max = delays.iter().max().unwrap();
        let mean_ms = delays.iter().sum::<Duration>().as_secs_f64() * 1000.0 / N as f64;
        println!("jitter 10 ms: mean {mean_ms:.3} ms, max {max:?}");
        assert!(*max <= Duration::from_millis(10), "{max:?}");
        assert!(*max >= Duration::from_micros(9_900), "{max:?}");
        assert!((4.5..=5.5).contains(&mean_ms), "{mean_ms}");
        let c = impair.counters();
        assert_eq!((c.out, c.dropped_out), (N as u64, 0));
        assert_eq!(
            c.delayed,
            delays.iter().filter(|d| !d.is_zero()).count() as u64
        );
    }

    #[test]
    fn held_datagrams_leave_when_due_in_due_order() {
        let mut impair = ImpairArgs::default().build(0);
        let t = Instant::now();
        let ms = Duration::from_millis;
        assert_eq!(impair.next_due(), None);
        impair.hold(t + ms(5), vec![1]);
        impair.hold(t + ms(1), vec![2]);
        impair.hold(t + ms(3), vec![3]);
        assert_eq!(impair.next_due(), Some(t + ms(1)));
        assert_eq!(impair.pop_due(t), None, "nothing due yet");
        assert_eq!(impair.pop_due(t + ms(3)), Some(vec![2]));
        assert_eq!(impair.pop_due(t + ms(3)), Some(vec![3]));
        assert_eq!(impair.pop_due(t + ms(3)), None);
        assert_eq!(impair.pop_due(t + ms(9)), Some(vec![1]));
        assert_eq!(impair.pop_due(t + ms(9)), None);
    }

    #[test]
    fn summary_reports_settings_and_counters() {
        let mut impair = parse(&["--loss", "100", "--jitter", "10", "--seed", "3"])
            .unwrap()
            .build(0);
        impair.outgoing();
        impair.incoming_dropped();
        assert_eq!(
            impair.summary(),
            " loss_pct=100 jitter_ms=10 seed=3 udp_out=1 dropped_out=1 delayed=0 udp_in=1 dropped_in=1"
        );
    }
}
