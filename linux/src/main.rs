// okminer for Linux: GTK4 front end for the bundled xmrig.

use gtk::prelude::*;
use gtk::{gdk, gio, glib};
use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const APP_ID: &str = "local.okminer";
const DEFAULT_WALLET: &str = "48KJ3jAyp7j7B2oU4p46VN4eDqcF2LGLufPg8ZJgmLeQKAvPa75KUgB5VQsQYbPtL7Fru6o75LMEoeWqcLoAjMP49Vi5iDi";
const DEFAULT_WORKER: &str = "okminer";

// MARK: pools

#[derive(Clone)]
struct Pool {
    name: String,
    url: String, // host:port
    tls: bool,
    stats_page: Option<&'static str>, // + wallet address
}

fn oklahoma() -> Pool {
    Pool {
        name: "oklahoma.li".into(),
        url: "pool.oklahoma.li:3333".into(),
        tls: true,
        stats_page: Some("https://www.oklahoma.li/#/miner/"),
    }
}

fn custom_pool(url: &str, tls: bool) -> Pool {
    let host = strip_scheme(url).split(':').next().unwrap_or(url);
    Pool { name: host.into(), url: url.into(), tls, stats_page: None }
}

fn strip_scheme(url: &str) -> &str {
    url.strip_prefix("stratum+tcp://")
        .or_else(|| url.strip_prefix("stratum+ssl://"))
        .unwrap_or(url)
}

/// host:port, optionally prefixed with stratum+tcp:// or stratum+ssl://
fn pool_looks_valid(url: &str) -> bool {
    let Some((host, port)) = strip_scheme(url).split_once(':') else { return false };
    !host.is_empty()
        && host.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
        && (1..=5).contains(&port.len())
        && port.chars().all(|c| c.is_ascii_digit())
}

fn wallet_looks_valid(w: &str) -> bool {
    if w.is_empty() {
        return true;
    }
    const B58: &str = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    (w.starts_with('4') || w.starts_with('8'))
        && (w.len() == 95 || w.len() == 106)
        && w.chars().all(|c| B58.contains(c))
}

// MARK: settings

/// Saved as key=value lines in ~/.config/okminer/settings.
struct Settings {
    wallet: String,
    worker: String,
    pool: String, // "oklahoma" or "custom"
    custom_pool: String,
    custom_pool_tls: bool,
    threads: u32,
    throttle: u32,
}

impl Settings {
    fn path() -> PathBuf {
        glib::user_config_dir().join("okminer").join("settings")
    }

    fn load() -> Settings {
        let text = std::fs::read_to_string(Self::path()).unwrap_or_default();
        let map: HashMap<&str, &str> = text.lines().filter_map(|l| l.split_once('=')).collect();
        let get = |k: &str| map.get(k).map(|v| v.to_string());
        Settings {
            wallet: get("wallet").unwrap_or_default(),
            worker: get("worker").unwrap_or_else(|| DEFAULT_WORKER.into()),
            pool: get("pool").filter(|p| p == "custom").unwrap_or_else(|| "oklahoma".into()),
            custom_pool: get("custom_pool").unwrap_or_default(),
            custom_pool_tls: get("custom_pool_tls").map_or(true, |v| v == "true"),
            threads: get("threads").and_then(|v| v.parse().ok()).unwrap_or((cores() / 2).max(1)),
            throttle: get("throttle").and_then(|v| v.parse().ok()).unwrap_or(100),
        }
    }

    fn save(&self) {
        let path = Self::path();
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        let text = format!(
            "wallet={}\nworker={}\npool={}\ncustom_pool={}\ncustom_pool_tls={}\nthreads={}\nthrottle={}\n",
            self.wallet, self.worker, self.pool, self.custom_pool, self.custom_pool_tls, self.threads, self.throttle
        );
        let _ = std::fs::write(path, text);
    }
}

fn cores() -> u32 {
    thread::available_parallelism().map_or(1, |n| n.get() as u32)
}

// MARK: throttle

/// XMRig has no throttle, so pause/resume the process with SIGSTOP/SIGCONT
/// every 100 ms, letting it run for `duty` percent of each period.
struct Throttler {
    duty: Arc<AtomicU32>,
    running: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
    pid: i32,
}

impl Throttler {
    fn new(pid: i32, duty: u32) -> Throttler {
        let duty = Arc::new(AtomicU32::new(duty));
        let running = Arc::new(AtomicBool::new(true));
        let (d, r) = (duty.clone(), running.clone());
        let handle = thread::spawn(move || {
            while r.load(Ordering::Relaxed) {
                unsafe { libc::kill(pid, libc::SIGCONT) };
                let on = d.load(Ordering::Relaxed).min(100) as u64;
                thread::sleep(Duration::from_millis(on));
                if on < 100 && r.load(Ordering::Relaxed) {
                    unsafe { libc::kill(pid, libc::SIGSTOP) };
                    thread::sleep(Duration::from_millis(100 - on));
                }
            }
        });
        Throttler { duty, running, handle: Some(handle), pid }
    }

    fn set_duty(&self, percent: u32) {
        self.duty.store(percent, Ordering::Relaxed);
    }

    /// Call before signalling the process to exit.
    fn invalidate(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
        unsafe { libc::kill(self.pid, libc::SIGCONT) };
    }
}

// MARK: miner process + stats

enum Event {
    Line(String),
    Stats { hashrate: Option<f64>, good: u64, uptime: u64 },
    Exited(Option<i32>),
}

#[derive(Clone, Copy, PartialEq)]
enum StatusKind {
    Idle,
    Working,
    Good,
    Warning,
    Error,
}

#[derive(Default)]
struct Miner {
    pid: Option<i32>,
    throttler: Option<Throttler>,
    alive: Option<Arc<AtomicBool>>, // stops the stats poller
    stopping: bool,
    pool_name: String,
    last_error: Option<String>,
    awaiting_first_hashrate: bool,
    inhibit_cookie: Option<u32>,
}

fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut buf);
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

fn xmrig_path() -> Option<PathBuf> {
    let p = std::env::current_exe().ok()?.parent()?.join("xmrig");
    p.exists().then_some(p)
}

/// GET /2/summary from xmrig's local API.
fn fetch_summary(port: u16, token: &str) -> Option<serde_json::Value> {
    let addr: SocketAddr = ([127, 0, 0, 1], port).into();
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_millis(1500)).ok()?;
    s.set_read_timeout(Some(Duration::from_millis(1500))).ok()?;
    write!(s, "GET /2/summary HTTP/1.0\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n").ok()?;
    let mut resp = Vec::new();
    let _ = s.read_to_end(&mut resp); // keep what arrived even if the read times out
    let resp = String::from_utf8_lossy(&resp);
    let body = resp.split_once("\r\n\r\n")?.1;
    serde_json::from_str(body).ok()
}

// MARK: UI

struct Ui {
    window: gtk::ApplicationWindow,
    hashrate: gtk::Label,
    subline: gtk::Label,
    start: gtk::Button,
    dot: gtk::Label,
    status: gtk::Label,
    pool: gtk::DropDown,
    pool_caption: gtk::Label,
    custom_box: gtk::Box,
    custom_entry: gtk::Entry,
    custom_tls: gtk::CheckButton,
    custom_caption: gtk::Label,
    wallet: gtk::Entry,
    wallet_caption: gtk::Label,
    worker: gtk::Entry,
    cores_value: gtk::Label,
    cores: gtk::Scale,
    throttle_value: gtk::Label,
    throttle: gtk::Scale,
    throttle_caption: gtk::Label,
    locked: Vec<gtk::Widget>, // xmrig only reads these at startup
    footer: gtk::Button,
}

struct App {
    app: gtk::Application,
    ui: Ui,
    miner: RefCell<Miner>,
    settings: RefCell<Settings>,
    tx: async_channel::Sender<Event>,
}

impl App {
    fn running(&self) -> bool {
        self.miner.borrow().pid.is_some()
    }

    fn pool(&self) -> Pool {
        let s = self.settings.borrow();
        if s.pool == "custom" {
            custom_pool(s.custom_pool.trim(), s.custom_pool_tls)
        } else {
            oklahoma()
        }
    }

    fn set_status(&self, text: &str, kind: StatusKind) {
        self.ui.status.set_text(text);
        self.ui.status.set_tooltip_text(Some(text));
        for c in ["idle", "working", "good", "warning", "error"] {
            self.ui.dot.remove_css_class(c);
        }
        self.ui.dot.add_css_class(match kind {
            StatusKind::Idle => "idle",
            StatusKind::Working => "working",
            StatusKind::Good => "good",
            StatusKind::Warning => "warning",
            StatusKind::Error => "error",
        });
    }

    fn set_hashrate(&self, h: Option<f64>) {
        let running = self.running();
        let h = if running { h.unwrap_or(0.0) } else { 0.0 };
        let (value, unit) = if h >= 1000.0 {
            (format!("{:.2}", h / 1000.0), "kH/s")
        } else if running && h == 0.0 {
            ("—".to_string(), "H/s")
        } else {
            (format!("{h:.0}"), "H/s")
        };
        self.ui.hashrate.set_markup(&format!(
            "<span size='35328' weight='bold'>{value}</span><span size='13824' weight='600'> {unit}</span>"
        ));
        self.ui.hashrate.set_opacity(if running { 1.0 } else { 0.6 });
    }

    /// Refreshes everything that depends on the settings or on whether xmrig is running.
    fn refresh(&self) {
        let running = self.running();
        let s = self.settings.borrow();
        let wallet = s.wallet.trim().to_string();
        let custom = s.pool == "custom";
        drop(s);
        let pool = self.pool();
        let ui = &self.ui;

        for w in &ui.locked {
            w.set_sensitive(!running);
            w.set_opacity(if running { 0.4 } else { 1.0 });
        }

        ui.custom_box.set_visible(custom);
        ui.pool_caption.set_visible(!custom);
        ui.pool_caption.set_text(&format!("{} · TLS", pool.url));
        let pool_ok = !custom || pool_looks_valid(&pool.url);
        if custom && !pool.url.is_empty() && !pool_ok {
            set_caption(&ui.custom_caption, "Enter the pool as host:port, e.g. pool.example.com:3333.", true);
        } else if custom && !pool.tls {
            set_caption(&ui.custom_caption, "Without TLS your wallet address and shares are sent unencrypted.", false);
        } else {
            ui.custom_caption.set_visible(false);
        }

        let wallet_ok = wallet_looks_valid(&wallet);
        if wallet.is_empty() {
            let short = format!("{}…{}", &DEFAULT_WALLET[..8], &DEFAULT_WALLET[DEFAULT_WALLET.len() - 6..]);
            set_caption(&ui.wallet_caption, &format!("Empty: mining to the default address {short}"), false);
        } else if !wallet_ok {
            set_caption(&ui.wallet_caption, "That doesn't look like a Monero address (95 characters, starts with 4 or 8).", true);
        } else {
            ui.wallet_caption.set_visible(false);
        }

        let throttle = self.settings.borrow().throttle;
        ui.throttle_value.set_text(&format!("{throttle}%"));
        ui.throttle_caption.set_text(&if throttle == 100 {
            "Full speed. Turn it down to run cooler and quieter, even while mining.".to_string()
        } else {
            format!("Mining {throttle}% of the time. You can change this while mining.")
        });
        let threads = self.threads();
        ui.cores_value.set_text(&format!("{threads} of {}", cores()));

        ui.start.set_label(if running { "Stop" } else { "Start mining" });
        if running {
            ui.start.add_css_class("stop");
        } else {
            ui.start.remove_css_class("stop");
        }
        ui.start.set_sensitive(running || (wallet_ok && pool_ok));

        ui.footer.set_visible(pool.stats_page.is_some());
        ui.footer.set_label(&format!("Find your coins on {} ↗", pool.name));
    }

    fn threads(&self) -> u32 {
        self.settings.borrow().threads.clamp(1, cores())
    }

    fn start(self: &Rc<Self>) {
        if self.running() {
            return;
        }
        let Some(bin) = xmrig_path() else {
            self.set_status("The miner is missing from the app. Try rebuilding it.", StatusKind::Error);
            return;
        };
        let s = self.settings.borrow();
        let wallet = match s.wallet.trim() {
            "" => DEFAULT_WALLET.to_string(),
            w => w.to_string(),
        };
        let worker = match s.worker.trim() {
            "" => DEFAULT_WORKER.to_string(),
            w => w.to_string(),
        };
        let throttle = s.throttle;
        drop(s);
        let pool = self.pool();
        let port: u16 = 42000 + (u16::from_str_radix(&random_hex(2), 16).unwrap_or(0) % 7000);
        let token = random_hex(16);

        let mut cmd = Command::new(bin);
        cmd.args(["--no-color", "-o", &pool.url, "-u", &wallet, "-p", &worker, "-k"])
            .args(["--threads", &self.threads().to_string()])
            .args(["--http-host", "127.0.0.1", "--http-port", &port.to_string()])
            .args(["--http-access-token", &token, "--print-time", "30"]);
        if pool.tls {
            cmd.arg("--tls");
        }
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                self.set_status(&format!("Couldn't start the miner: {e}"), StatusKind::Error);
                return;
            }
        };
        let pid = child.id() as i32;

        // stdout/stderr lines, the exit, and API stats all come back through the channel
        for stream in [child.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>),
                       child.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>)].into_iter().flatten() {
            let tx = self.tx.clone();
            thread::spawn(move || {
                for line in BufReader::new(stream).lines().map_while(Result::ok) {
                    let _ = tx.send_blocking(Event::Line(line));
                }
            });
        }
        let tx = self.tx.clone();
        thread::spawn(move || {
            let code = child.wait().ok().and_then(|s| s.code());
            let _ = tx.send_blocking(Event::Exited(code));
        });
        let alive = Arc::new(AtomicBool::new(true));
        let (tx, a) = (self.tx.clone(), alive.clone());
        thread::spawn(move || {
            while a.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_secs(2));
                if let Some(json) = fetch_summary(port, &token) {
                    let hashrate = json["hashrate"]["total"][0].as_f64();
                    let good = json["results"]["shares_good"].as_u64().unwrap_or(0);
                    let uptime = json["uptime"].as_u64().unwrap_or(0);
                    let _ = tx.send_blocking(Event::Stats { hashrate, good, uptime });
                }
            }
        });

        let cookie = self.app.inhibit(
            Some(&self.ui.window),
            gtk::ApplicationInhibitFlags::IDLE | gtk::ApplicationInhibitFlags::SUSPEND,
            Some("Mining Monero"),
        );
        *self.miner.borrow_mut() = Miner {
            pid: Some(pid),
            throttler: Some(Throttler::new(pid, throttle)),
            alive: Some(alive),
            pool_name: pool.name.clone(),
            inhibit_cookie: (cookie != 0).then_some(cookie),
            ..Default::default()
        };
        self.set_status(&format!("Connecting to {}…", pool.name), StatusKind::Working);
        self.ui.subline.set_text("0 shares · 0:00:00");
        self.set_hashrate(None);
        self.refresh();
    }

    fn stop(self: &Rc<Self>) {
        let mut m = self.miner.borrow_mut();
        let Some(pid) = m.pid else { return };
        m.stopping = true;
        if let Some(mut t) = m.throttler.take() {
            t.invalidate(); // a stopped process won't see SIGINT
        }
        drop(m);
        unsafe { libc::kill(pid, libc::SIGINT) };
        let this = self.clone();
        glib::timeout_add_local_once(Duration::from_secs(3), move || {
            if this.miner.borrow().pid == Some(pid) {
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
        });
    }

    /// Used on quit so the miner isn't left running.
    fn stop_blocking(&self) {
        let mut m = self.miner.borrow_mut();
        let Some(pid) = m.pid else { return };
        m.stopping = true;
        if let Some(mut t) = m.throttler.take() {
            t.invalidate();
        }
        unsafe { libc::kill(pid, libc::SIGINT) };
        let deadline = Instant::now() + Duration::from_secs(3);
        while unsafe { libc::kill(pid, 0) } == 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
        }
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }

    fn handle(self: &Rc<Self>, event: Event) {
        match event {
            Event::Line(line) => self.handle_line(&line),
            Event::Stats { hashrate, good, uptime } => {
                if !self.running() {
                    return;
                }
                self.set_hashrate(hashrate);
                let first = {
                    let mut m = self.miner.borrow_mut();
                    let first = m.awaiting_first_hashrate && hashrate.is_some_and(|h| h > 0.0);
                    if first {
                        m.awaiting_first_hashrate = false;
                    }
                    first
                };
                if first {
                    self.set_status("Mining", StatusKind::Good);
                }
                let plural = if good == 1 { "" } else { "s" };
                self.ui.subline.set_text(&format!(
                    "{good} share{plural} · {}:{:02}:{:02}",
                    uptime / 3600, (uptime / 60) % 60, uptime % 60
                ));
            }
            Event::Exited(code) => {
                let m = std::mem::take(&mut *self.miner.borrow_mut());
                if let Some(a) = &m.alive {
                    a.store(false, Ordering::Relaxed);
                }
                if let Some(mut t) = m.throttler {
                    t.invalidate();
                }
                if let Some(c) = m.inhibit_cookie {
                    self.app.uninhibit(c);
                }
                if m.stopping {
                    self.set_status("Stopped", StatusKind::Idle);
                } else {
                    let why = m.last_error.map_or_else(
                        || format!(" (code {})", code.map_or("?".into(), |c| c.to_string())),
                        |e| format!(": {e}"),
                    );
                    self.set_status(&format!("The miner stopped unexpectedly{why}"), StatusKind::Error);
                }
                self.ui.subline.set_text("Not mining");
                self.set_hashrate(None);
                self.refresh();
            }
        }
    }

    /// Map xmrig log lines to a short status.
    fn handle_line(&self, line: &str) {
        let pool = self.miner.borrow().pool_name.clone();
        if line.contains("use pool") {
            self.set_status(&format!("Connected to {pool}"), StatusKind::Good);
        } else if line.contains("init dataset") {
            self.set_status("Getting ready to mine…", StatusKind::Working);
        } else if line.contains("READY threads") {
            self.miner.borrow_mut().awaiting_first_hashrate = true;
            self.set_status("Mining — measuring speed…", StatusKind::Working);
        } else if line.contains(" accepted (") {
            self.set_status("Share accepted by the pool", StatusKind::Good);
        } else if line.contains(" rejected (") {
            self.set_status("A share was rejected by the pool", StatusKind::Warning);
        } else if line.contains("no active pools") {
            self.set_status("Can't reach the pool, retrying…", StatusKind::Warning);
        } else if let Some(i) = ["connect error", "read error", "write error", "login error", "DNS error"]
            .iter()
            .filter_map(|p| line.find(p))
            .min()
        {
            self.miner.borrow_mut().last_error = Some(line[i..].to_string());
            self.set_status("Connection problem, retrying…", StatusKind::Warning);
        }
    }
}

fn set_caption(label: &gtk::Label, text: &str, error: bool) {
    label.set_text(text);
    label.set_visible(true);
    if error {
        label.add_css_class("error");
    } else {
        label.remove_css_class("error");
    }
}

fn caption(text: &str) -> gtk::Label {
    let l = gtk::Label::builder().label(text).xalign(0.0).wrap(true).build();
    l.add_css_class("caption");
    l
}

fn mesa_entry(placeholder: &str) -> gtk::Entry {
    gtk::Entry::builder().placeholder_text(placeholder).hexpand(true).build()
}

/// A settings section: uppercase title, optional trailing widget, then the content.
fn section(title: &str, trailing: Option<&gtk::Widget>, content: &[&gtk::Widget]) -> gtk::Box {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let t = gtk::Label::builder().label(title.to_uppercase()).xalign(0.0).hexpand(true).build();
    t.add_css_class("section-title");
    row.append(&t);
    if let Some(w) = trailing {
        row.append(w);
    }
    b.append(&row);
    for w in content {
        b.append(*w);
    }
    b
}

fn value_label() -> gtk::Label {
    let l = gtk::Label::new(None);
    l.add_css_class("value");
    l
}

// colours: (light, dark)
const PALETTE: [(&str, &str, &str); 11] = [
    ("ground", "#F3E9DA", "#1F1612"),
    ("card", "#FBF6EE", "#2B1F18"),
    ("inset", "#F1E6D5", "#241A14"),
    ("line", "#E2D1BA", "#3E2D23"),
    ("ink", "#3A2418", "#F1E3CF"),
    ("dust", "#8C6B55", "#B89C84"),
    ("clay", "#B4532A", "#C9643A"),
    ("redrock", "#8E3524", "#9C3B28"),
    ("sage", "#6E8250", "#A2B27A"),
    ("sky", "#5F8FA8", "#8DB6CC"),
    ("wheat", "#C98E2E", "#E2B25E"),
];

const CSS: &str = "
window.okminer { background: @ground; }
.okminer label { color: @ink; }
.okminer .app-title { color: @clay; font-size: 17px; font-weight: 800; letter-spacing: 0.5px; }
.okminer .header { background-image: linear-gradient(to bottom right, @clay, @redrock); border-radius: 16px; padding: 20px; }
.okminer .header label { color: #FCF5E8; }
.okminer .subline { font-size: 13px; font-weight: 500; font-feature-settings: 'tnum'; opacity: 0.8; }
.okminer .hashrate { font-feature-settings: 'tnum'; }
.okminer button.pill { background: #FCF5E8; color: @clay; border: none; box-shadow: none; border-radius: 999px;
    padding: 11px 22px; font-size: 15px; font-weight: 600; }
.okminer button.pill label { color: @clay; }
.okminer button.pill.stop label { color: @redrock; }
.okminer button.pill:hover { background: #FFFAF2; }
.okminer button.pill:disabled { opacity: 0.5; }
.okminer .status { color: @dust; font-size: 13px; font-weight: 500; }
.okminer .dot { font-size: 9px; }
.okminer .dot.idle { color: @dust; }
.okminer .dot.working { color: @sky; }
.okminer .dot.good { color: @sage; }
.okminer .dot.warning { color: @wheat; }
.okminer .dot.error { color: @redrock; }
.okminer .card { background: @card; border: 1px solid @line; border-radius: 16px; padding: 18px; }
.okminer .section-title { color: @dust; font-size: 11px; font-weight: 700; letter-spacing: 0.8px; }
.okminer .value { color: @ink; font-size: 13px; font-weight: 600; font-feature-settings: 'tnum'; }
.okminer .caption { color: @dust; font-size: 11.5px; }
.okminer .caption.error { color: @redrock; }
.okminer entry { background: @inset; border: 1px solid @line; border-radius: 8px; color: @ink; box-shadow: none;
    padding: 4px 10px; }
.okminer entry.mono { font-family: monospace; font-size: 12px; }
.okminer scale trough { background: @line; border: none; box-shadow: none; }
.okminer scale highlight { background: @clay; border: none; box-shadow: none; }
.okminer scale slider { background: #FCF5E8; border: 1px solid @line; box-shadow: none; }
.okminer checkbutton label { color: @ink; font-size: 12px; }
.okminer checkbutton check:checked { background: @clay; color: #FCF5E8; border-color: @clay; }
.okminer dropdown button { background: @inset; border: 1px solid @line; border-radius: 8px; box-shadow: none; }
.okminer button.footer-link { background: none; border: none; box-shadow: none; padding: 0 4px; }
.okminer button.footer-link label { color: @clay; font-size: 13px; font-weight: 600; text-decoration: none; }
.okminer button.footer-link:hover label { text-decoration: underline; }
";

fn prefers_dark() -> bool {
    gtk::Settings::default().is_some_and(|s| {
        s.is_gtk_application_prefer_dark_theme()
            || s.gtk_theme_name().is_some_and(|n| n.to_lowercase().contains("dark"))
    })
}

fn load_css() {
    let dark = prefers_dark();
    let colours: String = PALETTE
        .iter()
        .map(|(name, light, dk)| format!("@define-color {name} {};\n", if dark { dk } else { light }))
        .collect();
    let provider = gtk::CssProvider::new();
    provider.load_from_data(&(colours + CSS));
    gtk::style_context_add_provider_for_display(
        &gdk::Display::default().expect("no display"),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

fn build(app: &gtk::Application) {
    load_css();
    let settings = Settings::load();
    let max_cores = cores().max(2) as f64;

    // header: hashrate + start/stop
    let hashrate = gtk::Label::builder().xalign(0.0).build();
    hashrate.add_css_class("hashrate");
    let subline = gtk::Label::builder().label("Not mining").xalign(0.0).build();
    subline.add_css_class("subline");
    let left = gtk::Box::new(gtk::Orientation::Vertical, 2);
    left.set_hexpand(true);
    left.append(&hashrate);
    left.append(&subline);
    let start = gtk::Button::with_label("Start mining");
    start.add_css_class("pill");
    start.set_valign(gtk::Align::Center);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    header.add_css_class("header");
    header.append(&left);
    header.append(&start);

    let dot = gtk::Label::new(Some("●"));
    dot.add_css_class("dot");
    let status = gtk::Label::builder()
        .label("Ready to mine")
        .xalign(0.0)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .hexpand(true)
        .build();
    status.add_css_class("status");
    let status_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    status_row.set_margin_start(4);
    status_row.append(&dot);
    status_row.append(&status);

    // pool
    let pool = gtk::DropDown::from_strings(&["oklahoma.li", "Custom…"]);
    pool.set_selected(if settings.pool == "custom" { 1 } else { 0 });
    let pool_caption = caption("");
    let custom_entry = mesa_entry("host:port");
    custom_entry.add_css_class("mono");
    custom_entry.set_text(&settings.custom_pool);
    let custom_tls = gtk::CheckButton::with_label("Use TLS (encrypted connection)");
    custom_tls.set_active(settings.custom_pool_tls);
    let custom_caption = caption("");
    let custom_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    custom_box.append(&custom_entry);
    custom_box.append(&custom_tls);
    custom_box.append(&custom_caption);
    let pool_section = section("Pool", Some(pool.upcast_ref()), &[custom_box.upcast_ref(), pool_caption.upcast_ref()]);

    // wallet, worker
    let wallet = mesa_entry("Paste your Monero address");
    wallet.add_css_class("mono");
    wallet.set_text(&settings.wallet);
    let wallet_caption = caption("");
    let wallet_section = section("Wallet address", None, &[wallet.upcast_ref(), wallet_caption.upcast_ref()]);
    let worker = mesa_entry(DEFAULT_WORKER);
    worker.set_text(&settings.worker);
    let worker_section = section("Worker name", None, &[worker.upcast_ref()]);

    // cores, throttle
    let cores_value = value_label();
    let cores_scale = gtk::Scale::with_range(gtk::Orientation::Horizontal, 1.0, max_cores, 1.0);
    cores_scale.set_value(settings.threads.clamp(1, cores()) as f64);
    let cores_section = section("CPU cores", Some(cores_value.upcast_ref()), &[cores_scale.upcast_ref()]);
    let throttle_value = value_label();
    let throttle_scale = gtk::Scale::with_range(gtk::Orientation::Horizontal, 10.0, 100.0, 5.0);
    throttle_scale.set_value(settings.throttle.clamp(10, 100) as f64);
    let throttle_caption = caption("");
    let throttle_section = section(
        "CPU throttle",
        Some(throttle_value.upcast_ref()),
        &[throttle_scale.upcast_ref(), throttle_caption.upcast_ref()],
    );

    let card = gtk::Box::new(gtk::Orientation::Vertical, 16);
    card.add_css_class("card");
    for s in [&pool_section, &wallet_section, &worker_section, &cores_section, &throttle_section] {
        card.append(s);
    }

    let footer = gtk::Button::with_label("");
    footer.add_css_class("footer-link");
    footer.set_halign(gtk::Align::Start);

    let title = gtk::Label::builder().label("okminer").xalign(0.0).margin_start(4).build();
    title.add_css_class("app-title");

    let root = gtk::Box::new(gtk::Orientation::Vertical, 14);
    root.set_margin_start(20);
    root.set_margin_end(20);
    root.set_margin_top(14);
    root.set_margin_bottom(20);
    for w in [title.upcast_ref::<gtk::Widget>(), header.upcast_ref(), status_row.upcast_ref(), card.upcast_ref(), footer.upcast_ref()] {
        root.append(w);
    }

    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("okminer")
        .default_width(480)
        .resizable(false)
        .child(&root)
        .build();
    window.add_css_class("okminer");

    let (tx, rx) = async_channel::unbounded();
    let ui = Ui {
        window: window.clone(),
        hashrate,
        subline,
        start: start.clone(),
        dot,
        status,
        pool: pool.clone(),
        pool_caption,
        custom_box,
        custom_entry: custom_entry.clone(),
        custom_tls: custom_tls.clone(),
        custom_caption,
        wallet: wallet.clone(),
        wallet_caption,
        worker: worker.clone(),
        cores_value,
        cores: cores_scale.clone(),
        throttle_value,
        throttle: throttle_scale.clone(),
        throttle_caption,
        locked: vec![pool_section.upcast(), wallet_section.upcast(), worker_section.upcast(), cores_section.upcast()],
        footer: footer.clone(),
    };
    let this = Rc::new(App { app: app.clone(), ui, miner: RefCell::default(), settings: RefCell::new(settings), tx });

    let t = this.clone();
    glib::spawn_future_local(async move {
        while let Ok(event) = rx.recv().await {
            t.handle(event);
        }
    });

    // every settings change: store it, save it, refresh the UI
    let on_change = {
        let t = this.clone();
        Rc::new(move || {
            {
                let ui = &t.ui;
                let mut s = t.settings.borrow_mut();
                s.pool = if ui.pool.selected() == 1 { "custom" } else { "oklahoma" }.into();
                s.custom_pool = ui.custom_entry.text().to_string();
                s.custom_pool_tls = ui.custom_tls.is_active();
                s.wallet = ui.wallet.text().to_string();
                s.worker = ui.worker.text().to_string();
                s.threads = ui.cores.value().round() as u32;
                s.throttle = ((ui.throttle.value() / 5.0).round() * 5.0) as u32;
                s.save();
            }
            t.refresh();
        })
    };
    let f = on_change.clone();
    pool.connect_selected_notify(move |_| f());
    for entry in [&custom_entry, &wallet, &worker] {
        let f = on_change.clone();
        entry.connect_changed(move |_| f());
    }
    let f = on_change.clone();
    custom_tls.connect_toggled(move |_| f());
    let f = on_change.clone();
    cores_scale.connect_value_changed(move |_| f());
    let (f, t) = (on_change.clone(), this.clone());
    throttle_scale.connect_value_changed(move |_| {
        f();
        let duty = t.settings.borrow().throttle;
        if let Some(th) = &t.miner.borrow().throttler {
            th.set_duty(duty);
        }
    });

    let t = this.clone();
    start.connect_clicked(move |_| if t.running() { t.stop() } else { t.start() });
    window.set_default_widget(Some(&start));

    let t = this.clone();
    footer.connect_clicked(move |_| {
        let pool = t.pool();
        let Some(page) = pool.stats_page else { return };
        let wallet = match t.settings.borrow().wallet.trim() {
            "" => DEFAULT_WALLET.to_string(),
            w => w.to_string(),
        };
        gtk::show_uri(Some(&t.ui.window), &format!("{page}{wallet}"), gdk::CURRENT_TIME);
    });

    let t = this.clone();
    window.connect_close_request(move |_| {
        t.stop_blocking();
        glib::Propagation::Proceed
    });
    let t = this.clone();
    app.connect_shutdown(move |_| t.stop_blocking());

    this.set_hashrate(None);
    this.set_status("Ready to mine", StatusKind::Idle);
    this.refresh();
    window.present();
}

fn main() -> glib::ExitCode {
    let app = gtk::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    app.connect_activate(build);
    app.run()
}
