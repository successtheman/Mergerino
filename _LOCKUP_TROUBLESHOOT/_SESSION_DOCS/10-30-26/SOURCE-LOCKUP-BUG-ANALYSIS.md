# Mergerino 1.3.4 — GUI Lockup Investigation

**Status:** Open. No genuine lockup reproduced yet; several verified code defects identified.
**Binary under test:** `C:\Users\windoz\AppData\Local\Programs\Mergerino\mergerino.exe` (FileVersion `1.3.4`, upstream `a47a1c0`)
**Branch:** `program-lockup-bug-fix` (based on upstream `a47a1c0` "Release Mergerino 1.3.4")
**Investigation started:** 2026-10-28 · **Last updated:** 2026-10-30 01:16 CDT

---

## 1. Symptom

- Mergerino becomes unresponsive ("Not Responding"), and eventually has to be force-terminated from Task Manager.
- The lockup only appears **after the app has been running for a while** — not on start, not on immediate use.
- Original observed occurrence: session started `2026-10-28 18:22:26`, app died at `2026-10-28 23:01:23` — **4h39m of uptime**.

---

## 2. Environment

| Item | Value |
|---|---|
| OS | Windows (win32), 16 logical cores |
| App | `mergerino.exe` v1.3.4, installed at `%LOCALAPPDATA%\Programs\Mergerino\` |
| Chat logs | `%APPDATA%\Mergerino\Logs\` (chat only — **no application debug log exists**) |
| Settings | `%APPDATA%\Mergerino\Settings\settings.json`, `window-layout.json` |
| Debugger | `cdb.exe` @ `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe` (already installed) |
| ProcDump | **not installed** (and not installed per policy) |
| WER `LocalDumps` | configured, but only fires on **crash**, not hang — useless here |

### User configuration that matters

- **42 splits, and every single one is `data.type == "merged"`** (Mergerino's merged-channel feature).
  - Source mix: 20 Kick-only, 14 Twitch+Kick, 4 Twitch-only, 2 Twitch+Kick+TikTok, 2 Twitch+Kick+YouTube+TikTok.
  - 34 use the tab name as the Twitch source; 8 use explicit named overrides.
- Logging: `enabled=true`, `separatelyStoreStreamLogs=true`, `tryUseTwitchTimestamps=true`.
  - → **two** log files are written per chat message.
- 1020 log files / 37.7 MB total across 26 channel directories; no `/Users/` pseudo-channel directories.

---

## 3. What the logs proved (and disproved)

### 3.1 The app did **not** crash

Every one of the 49 log files from the lockup session ends with:

```
# Stop logging at 2026-10-28 23:01:23 CDT
```

That string is written **only** by `LoggingChannel::~LoggingChannel()`. A force-kill cannot run destructors, so the app *did* process `WM_CLOSE` and shut down through the normal destructor path.

Corroborating evidence:
- No `mergerino.exe` entry in `%LOCALAPPDATA%\CrashDumps\`.
- No `Application Error` / `Windows Error Reporting` event for mergerino.

**Conclusion:** the window became unresponsive, but the process was still able to service a close request and tear down. This points to a **stall** (or a hang during shutdown *after* logging teardown), **not** a hard deadlock at the moment of the user's force-close.

### 3.2 Chat was spammy right before the hang

Channel `dgthe99` in the final minutes:

```
[22:59:48] gfpthe99: Party1 Party1 Party1 Party1 Party1 Party1 Party1 Party1 Party1 Party1 Party1 Party1
[22:59:59] amberthe99: daddyg99Dgspin daddyg99Dgspin daddyg99Dgspin daddyg99Dgspin daddyg99Dgspin daddyg99Dgspin
[23:00:00] bombgxiv: @GFPthe99 WWWWWWWWWWWW BITTIESSSSSSSS
```

Not conclusive on its own, but relevant to the synchronous-logging hypothesis (§4.1).

---

## 4. Verified defects in the code

Everything in this section was read in the source at `F:\_githubstuff\Mergerino` and, where noted, **confirmed to be present in the shipped binary** by searching its strings (`mergerino.exe` contains `"TikTok LIVE browser session"`, `"Failed to shutdown within 1s"`, `"Failed to gracefully close all connections in time"`).

> **None of these is yet proven to be the cause of the observed lockup.** They are real defects that can produce unresponsive-window behaviour.

### 4.1 Synchronous disk I/O on the GUI thread, per message — `src/singletons/Logging.cpp:62`

```
Channel::addMessage            (src/common/Channel.cpp:236)
  -> Logging::addMessage       (src/singletons/Logging.cpp:62)   // holds a non-recursive std::mutex
     -> LoggingChannel::addMessage
        -> appendLine          (src/singletons/helper/LoggingChannel.cpp:21-28)
             fileHandle.write(line);
             fileHandle.flush();        // <-- synchronous, on the GUI thread
```

With `separatelyStoreStreamLogs=true` this is **two** `write()` + **two** `flush()` calls per chat message, both under the logging mutex, on the GUI thread. A spam flood turns this into hundreds of forced disk flushes per second on the UI thread.

**Impact:** with a slow or cloud-synced log directory this alone can wedge the GUI thread long enough for Windows to mark the window "Not Responding".

**Suggested fix:** queue log lines and flush them from a dedicated writer thread; batch the flushes.

### 4.2 GUI thread blocked for up to ~4 s in the TikTok path — `src/providers/tiktok/TikTokLiveChat.cpp:1436`

```cpp
void TikTokLiveChat::stopBrowserSession()
{
    ++this->roomStatusGeneration_;
    if (!this->browser_) { return; }

    this->browser_->socket.close();
    if (this->browser_->process &&
        this->browser_->process->state() != QProcess::NotRunning)
    {
        this->browser_->process->terminate();
        if (!this->browser_->process->waitForFinished(1500))   // (a) blocks this thread 1.5 s
        {
            this->browser_->process->kill();
            this->browser_->process->waitForFinished(1500);    // (b) blocks this thread 1.5 s
        }
    }

    this->browser_.reset();                                   // (c) -> ~WebSocketPool -> 1 s
}
```

This runs on the **GUI thread** (the object is driven by `QTimer`s and `NetworkRequest` callbacks, both GUI-thread-affine). Worst case:
- `waitForFinished(1500)` ×2 = **3 s**
- `browser_.reset()` destroys the `WebSocketPool` → `~WebSocketPool` → `tryShutdown(1000 ms)` = **+1 s**

→ **up to 4 seconds of completely frozen UI per TikTok browser-session teardown.**

Two Chrome instances were observed running for the whole session (~142 MB and ~141 MB working set each), i.e. TikTok chat is genuinely active for this configuration.

### 4.3 WebSocket pool leaks its thread and SSL context — `src/common/websockets/WebSocketPool.cpp:16`

```cpp
WebSocketPool::~WebSocketPool()
{
    if (this->impl)
    {
        if (this->impl->tryShutdown(std::chrono::milliseconds{1000}))
        {
            qCDebug(chatterinoWebsocket) << "Closed gracefully.";
        }
        else
        {
            // Note: We can't detatch the IO-thread here but have to leak the
            // pool, because the IO-thread still references the IO-context which
            // is stored in the pool (otherwise we'd have a use-after-free).
            qCWarning(chatterinoWebsocket)
                << "Failed to shutdown within 1s, leaking";
            this->impl.release();  // NOLINT
        }
    }
}
```

When shutdown exceeds 1 s the pool implementation is **deliberately leaked** — and with it the `std::thread` running `io_context::run()` (`src/common/websockets/detail/WebSocketPoolImpl.cpp:46-49`) plus the `boost::asio::ssl::context` (which holds the CA certificate store loaded by `set_default_verify_paths()`). Every subsequent `createSocket()` on that pool then builds a **brand new** impl — new thread, new SSL context, new CA-bundle load from disk.

The same "recreate the pool" pattern appears at `src/providers/tiktok/TikTokLiveChat.cpp:1533`:

```cpp
this->browser_->socketPool = std::make_unique<WebSocketPool>("TikTokLiveChat");
```

Assigning over the previous `unique_ptr` destroys the old pool (and may leak it per the code above).

### 4.4 `std::terminate` on pool destruction — `src/common/websockets/detail/WebSocketPoolImpl.cpp:61`

```cpp
WebSocketPoolImpl::~WebSocketPoolImpl()
{
    assert(this->closing);
    // After 10s, we stop and, through std::thread::~thread, std::terminate will
    // be called.
    this->tryShutdown(std::chrono::seconds{10});
}
```

`tryShutdown` returns `false` if `shutdownFlag.waitFor(timeout)` times out; the member `std::unique_ptr<std::thread> ioThread` is then destroyed while still joinable → **`std::terminate()` → `abort()`**.

### 4.5 `std::terminate` in the EventSub controller — `src/providers/twitch/eventsub/Controller.cpp:128`

```cpp
if (this->stoppedFlag.waitFor(250ms))
{
    this->thread->join();
    qCInfo(LOG) << "Controller dtor end (joined)";
    return;
}

qCWarning(LOG) << "Controller dtor end (stopped flag didn't stop)";
```

If the flag is not set within 250 ms the destructor returns **without joining**. `this->thread` is a `std::unique_ptr<std::thread>` (`Controller.hpp:162` area) and is destroyed while joinable → **`std::terminate()`**.

### 4.6 `QThread::terminate()` after a 500 ms wait — `src/singletons/StreamerMode.cpp:201`

```cpp
this->thread_.quit();
if (!this->thread_.wait(500))
{
    qCWarning(chatterinoStreamerMode)
        << "Failed waiting for thread, terminating it";
    this->thread_.terminate();
}
```

`QThread::terminate()` is documented as dangerous and must not be used on objects with mutexes — it can leave locks held forever.

### 4.7 Non-recursive mutex held while running arbitrary callbacks — `src/providers/twitch/TwitchIrcServer.cpp`

Three places take `channelMutex` (a plain `std::mutex`) and then invoke caller-supplied code **while still holding it**:

| Location | Function | What runs under the lock |
|---|---|---|
| `:1147` | `forEachChannel` | `func(chan)` — arbitrary callback |
| `:1128` | `addGlobalSystemMessage` | `chan->addMessage(...)` → `messageAppended.invoke()` → every `MergedChannel` |
| `:507`  | `onDisconnected`  | `channel->markDisconnected()` → signal emission |

`Channel::addMessage` (`src/common/Channel.cpp:248`) invokes `messageAppended` **synchronously** on the calling thread. With 42 merged channels subscribed to the same Twitch sources, any callback path that re-enters `getChannelOrEmpty` / `getOrAddChannel` / `getChannelOrEmptyByID` (all of which lock the same mutex) would self-deadlock.

**Status:** the lock-held-callback *pattern* is confirmed present. A concrete re-entrancy path has **not** been found — see §6.

---

## 5. Runtime observations

### 5.1 Instrumentation

Two watchers were built and are running against the live process:

| Script | Purpose | Elevation |
|---|---|---|
| `C:\Users\windoz\AppData\Local\Temp\opencode\mergerino-hangwatch.ps1` | Polls `Process.Responding`; after 3 consecutive failures (~6 s) captures all thread stacks via `cdb ~*k` **and** a full memory dump via `comsvcs.dll MiniDump`. Also writes a continuous health CSV. | **Required** (elevated) for the dump |
| `C:\Users\windoz\AppData\Local\Temp\opencode\mergerino-spikecatch.ps1` | Polls thread count at 250 ms; captures all thread stacks when the count exceeds a threshold. | Not required |

Output directory: `C:\Users\windoz\Desktop\mergerino-dumps\`

### 5.2 Critical gotcha — cdb symbol downloads freeze the target

**This produced a false-positive "hang" and must be avoided.**

`cdb -p <pid> -c "~*k; qd"` with the default symbol path contacts Microsoft's public symbol server. Resolving the Qt6 symbols took **~80 seconds**, during which the target process was **suspended by the debugger the whole time**. Symptoms:

- `Process.Responding` flipped to `False`.
- CPU dropped to **0 %** (classic frozen-process signature).
- The app "recovered" the instant cdb detached — i.e. it was never actually hung.
- Worse, the already-attached debugger made the *watcher's* cdb attach fail with
  `NTSTATUS 0xC0000048 — "The process that you are attempting to attach to is already being debugged"`,
  so the automated capture produced an **empty stacks file** and a **1.2 MB stub dump** instead of real data.

**Fix applied:** force a local-only symbol path.

```powershell
$env:_NT_SYMBOL_PATH = "$env:LOCALAPPDATA\Temp\opencode\symcache"
cdb.exe -p <pid> -y $env:LOCALAPPDATA\Temp\opencode\symcache -c "~*k; qd"
```

With that, attach + full `~*k` + detach completes in **0.6 seconds** and does not stall the target. This is now baked into both watcher scripts.

> Always use `qd` (quit **and detach**) with cdb. Plain `q` kills the target process.

### 5.3 Health timeline (2026-10-29 session)

Source: `mergerino-hang-20261029-230353-samples.csv` — 3945 samples, `23:03:55 → 01:16:16`, sampled every 2 s.

| Metric | Observed |
|---|---|
| `Responding == False` | **0 samples** |
| Max CPU | 147.6 % |
| Samples with CPU > 100 % | 12 |
| Private memory | 1205 MB (min) → 1827 MB (max), 1304 MB at end |
| Working set | peaked ~1820 MB, later trimmed by Windows to ~380 MB |
| Threads | 87 (min) → **655 (max)** |
| Sample gaps > 6 s | **none** |

### 5.4 Thread-count spikes — unexplained

Several times the process jumped to several hundred threads for exactly one 2-second sample:

```
23:04:33   threads 103 -> 335  (+232)   handles 1481 -> 1760  (+279)   cpu 111.5%
23:04:35   threads 335 -> 119  (-216)   handles 1760 -> 1529  (-231)
23:07:54   threads  96 -> 641  (+545)   handles 1466 -> 2080  (+614)   cpu  41.0%
23:07:56   threads 641 -> 120  (-521)   handles 2080 -> 1538  (-542)
23:11:38   threads        -> 381                              cpu 108.2%
23:13:47   threads        -> 655                              cpu  66.0%
23:16:24   threads        -> 259                              cpu 111.1%
```

Observations:
- Each new thread carries roughly one extra kernel handle, consistent with `std::thread` creation.
- The handle delta is ≈1.1× the thread delta — matching `WebSocketPoolImpl` (one `ioThread` per pool, one `boost::asio::ssl::context` per pool).
- **All spikes occurred in the first ~16 minutes after start** and never recurred afterwards, so this looks like a **warm-up transient**, not a steady-state leak.
- The `spikecatch` watcher was only armed (threshold 150) *after* this window, so no stack capture exists for these events. It remains armed for the next occurrence.

### 5.5 Memory footprint

- Private bytes settle around **1.30–1.35 GB** (peak ~1.83 GB during warm-up).
- Working set is trimmed by Windows to ~380–400 MB once idle.
- Two `chrome.exe` children of mergerino run for the whole session at **~142 MB** and **~141 MB** working set — these are Mergerino's **TikTok headless-browser** instances (`TikTokLiveChat` drives Chrome over the DevTools protocol). Together they account for roughly 280 MB of the footprint.
- Chrome process start times were confirmed to be identical to app start (`22:30:13`), i.e. **no Chrome relaunch storm** was occurring during the observed window.

### 5.6 Healthy-state thread census (baseline `~*k`, 105 threads)

| Count | Stack signature | Interpretation |
|---|---|---|
| 15 | `mergerino+0x17a5f4` → `GetQueuedCompletionStatus` | Boost ASIO `io_context::run()` workers — one per live `WebSocketPoolImpl` |
| 8 | `mergerino+0x299d93` → `WaitForSingleObjectEx` | unidentified worker pool (Qt thread-pool or similar) |
| 1 | `mergerino+0x14dde8` → `QCoreApplication::exec` | **GUI thread**, healthy and inside `PeekMessageW` |
| ~10 | `Qt6Core!QWaitCondition::wait` | `QThread`s parked on a condition variable |
| 77 | pure OS waits | idle pool threads |

---

## 6. Claims that were investigated and **retracted**

These were raised earlier in the investigation and are **not** causes. Do not re-investigate them.

| Claim | Why it was refuted |
|---|---|
| Stale `wasMinimized_` / `preMinimizeBounds_` in monitor-restore | `enableCustomFrame_` is written only in the constructor (`BaseWindow.cpp:401,407`); `frameless_` likewise (`:402`) and is never reassigned. `hasCustomWindowFrame()` (`:683-686`) is therefore constant per window, so the `handleSIZE` gate at `:1443-1444` cannot be true at minimize and false at restore. The handler performs no locking, waiting, or I/O. |
| `MergedChannel` → `getOrAddChannel` deadlock | `initializeSources()` is called **only from the `MergedChannel` constructor** (`MergedChannel.cpp:326`), never from message handling. `appendMergedMessage` (`:1103`) just clones the source message (`:1192-1243`). No path from a message back into `getOrAddChannel`. |
| Chat-log file-handle leak | `Channel::~Channel` (`Channel.cpp:121-127`) calls `closeChannel()`. No `/Users/` pseudo-channel directories exist in this configuration. |
| `MergedChannel` unbounded memory growth | `mirroredMessages_` is a `WeakMessageIndex` that prunes expired entries every 256 insertions (`WeakMessageIndex.hpp:23-41`); `recentMessageKeys_` is `BoundedUniqueSet<QString>{16384}` (`MergedChannel.hpp:147`). Both are bounded. |
| The 22:35:28 "hang" in the 10-29 session | **False positive caused by the debugger itself** — see §5.2. The app recovered the moment cdb detached. |

---

## 7. Reproduction status

| Session | Duration | Outcome |
|---|---|---|
| 2026-10-28 (original) | 4 h 39 m | Lockup observed; app force-closed. No dump captured. |
| 2026-10-29 (this session) | 2 h 07 m (still running) | **No lockup reproduced.** 0 `Responding=False` samples, 0 sampling gaps > 6 s. |

The original failure required ~4.5 h of uptime, so the current run is only ~45 % of the way to the known-bad duration.

**Current live state at time of writing:**

```
mergerino  PID 10468  uptime 121 min
  threads 106   working set 378.7 MB   private 1336.2 MB   Responding True
  watchers: mergerino-hangwatch.ps1 (elevated, PID 28400)
            mergerino-spikecatch.ps1 (PID 1568)
```

---

## 8. Recommended next steps

### 8.1 Keep the current run going

The app is still running and both watchers are armed. The most likely outcome of leaving it alone is that the watcher fires and writes a real hang dump to `C:\Users\windoz\Desktop\mergerino-dumps\`.

**Do not force-kill the app when it wedges.** The watcher needs ~6 s of confirmed unresponsiveness to fire, and `cdb`/`comsvcs` need the process to stay alive.

### 8.2 Analysis workflow once a dump exists

```powershell
# 1) Fast read - all thread stacks as text
Get-Content "C:\Users\windoz\Desktop\mergerino-dumps\mergerino-hang-*-stacks.txt"

# 2) Full dump analysis (use the local symbol path - see §5.2)
cdb.exe -y "$env:LOCALAPPDATA\Temp\opencode\symcache" `
       -z "C:\Users\windoz\Desktop\mergerino-dumps\mergerino-hang-*.dmp" `
       -c "~*k; !locks; !analyze -hang; q"
```

Interpretation guide:

| Observation | Meaning |
|---|---|
| GUI thread (thread 0) blocked in a `std::mutex` / `QMutex` / `WaitForSingleObject` | genuine deadlock → look for a lock-order inversion, likely §4.7 |
| GUI thread inside `WriteFile` / `FlushFileBuffers` | synchronous logging (§4.1) |
| GUI thread inside `QProcess::waitForFinished` | TikTok teardown (§4.2) |
| GUI thread at `QEventLoop::exec` while `Responding` is false | the event loop is blocked elsewhere, or the app is genuinely busy (CPU high) |
| CPU ≈ 0 % across the process | blocked / waiting |
| CPU pegged on one or more cores | spin / busy-loop |

### 8.3 Candidate fixes, in priority order

1. **Move chat-log writes off the GUI thread** — queue + dedicated writer thread with batched flushes. (Fixes §4.1; lowest risk, biggest payoff.)
2. **Make `TikTokLiveChat::stopBrowserSession()` non-blocking** — replace `waitForFinished` with an async finish handler, or move teardown to a worker thread. (Fixes §4.2.)
3. **Stop leaking the `WebSocketPool` impl** — extend the timeout, or make the impl own its IO thread so it can outlive the pool safely. (Fixes §4.3.)
4. **Fix the two `std::terminate` paths** — always join or detach before destroying the thread object. (Fixes §4.4, §4.5.)
5. **Replace `QThread::terminate()`** with a cooperative stop flag. (Fixes §4.6.)
6. **Snapshot-and-release the lock in `forEachChannel` / `addGlobalSystemMessage` / `onDisconnected`** — copy the channel list under the lock, then invoke callbacks with the lock released. (Fixes §4.7; needs a concrete re-entrancy path to be confirmed first.)

---

## 9. Files referenced

### Source (`F:\_githubstuff\Mergerino`, branch `program-lockup-bug-fix`)

| Path | Relevance |
|---|---|
| `src/singletons/Logging.cpp` | `:62` — GUI-thread `write()`+`flush()` under a mutex |
| `src/singletons/helper/LoggingChannel.cpp` | `:21-28` — `write()` + `flush()` per line |
| `src/common/Channel.cpp` | `:236` logger call; `:248` synchronous `messageAppended`; `:121-127` destructor |
| `src/providers/twitch/TwitchIrcServer.cpp` | `:507`, `:1128`, `:1147` — non-recursive mutex held across callbacks |
| `src/providers/twitch/eventsub/Controller.cpp` | `:128-136` — 250 ms wait, then returns without joining |
| `src/common/websockets/WebSocketPool.cpp` | `:16-34` — leak on failed shutdown |
| `src/common/websockets/detail/WebSocketPoolImpl.cpp` | `:46-49` thread creation; `:61-98` shutdown / `std::terminate` |
| `src/providers/tiktok/TikTokLiveChat.cpp` | `:1436-1457` — GUI-thread blocking teardown; `:1533` pool recreation |
| `src/singletons/StreamerMode.cpp` | `:201-206` — `QThread::terminate()` |
| `src/providers/merged/MergedChannel.cpp` | `:326`, `:851-870`, `:1103-1116`, `:1192-1243` — merged-channel message flow (refutation target) |
| `src/messages/WeakMessageIndex.hpp` | `:23-41` — bounded index (refutation target) |
| `src/widgets/BaseWindow.cpp` | `:401-407`, `:683-686`, `:1443-1444` — monitor-restore gate (refutation target) |

### Tooling

| Path | Purpose |
|---|---|
| `C:\Users\windoz\AppData\Local\Temp\opencode\mergerino-hangwatch.ps1` | Hang detector + stack/dump capture (elevated) |
| `C:\Users\windoz\AppData\Local\Temp\opencode\mergerino-spikecatch.ps1` | Thread-spike detector + stack capture |
| `C:\Users\windoz\AppData\Local\Temp\opencode\baseline-stacks.txt` | Healthy-state thread census |
| `C:\Users\windoz\AppData\Local\Temp\opencode\baseline-samples.csv` | Early health samples |
| `C:\Users\windoz\Desktop\mergerino-dumps\` | Captured stacks, dumps and health CSVs |
| `%APPDATA%\Mergerino\Logs\` | Chat logs (no app debug log) |
