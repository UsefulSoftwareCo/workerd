// Licensed under the Apache 2.0 license found in the LICENSE file or at:
//     https://opensource.org/licenses/Apache-2.0

// Executor fork: memory maintenance
//
// workerd is built for Cloudflare's edge, where every machine runs thousands of busy tenants.
// There, isolates are almost never idle, and V8 gets frequent chances to collect garbage and run
// its memory reducer. A small self-hosted deployment has the opposite profile: a handful of
// isolates that serve bursts of work and then sit idle for minutes or hours.
//
// V8 performs incremental marking steps and the memory reducer from foreground tasks, which
// workerd only pumps at the end of a request (see the pumpMsgLoop() loop in IoContext). And
// workerd tells V8 about memory pressure once, when the isolate is created. So once an isolate
// goes idle, nothing ever shrinks its heap again: memory only moves up, to each isolate's peak.
//
// MemoryMaintenance watches isolates for idleness (their lock count stops changing) and, once
// one has been idle for `idleIsolateGcDelayMs`, notifies V8 (moderate mode) or runs a full
// collection (full mode) and keeps pumping its foreground tasks for a while. Moderate mode can
// let V8 trim caches; it starts no heap collection in this build, which disables incremental
// marking.
// Optionally, it also runs a full GC in the isolates when the process's memory usage crosses
// `pressureThresholdMb`. Those collections run on the event loop thread and block every request
// while they run, so a pass spends at most `pressureGcBudgetMs` per sweep, skips isolates that
// have not run since they were last collected, and waits longer between passes while they do
// not bring usage back under the threshold.
//
// All of this is off unless configured in `Config.memory`.

#include "memory-maintenance.h"

#include <workerd/io/io-context.h>
#include <workerd/jsg/jsg.h>

#include <kj/io.h>

#if __linux__
#include <fcntl.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#endif

#if WD_EXECUTOR_TCMALLOC
#include "tcmalloc/malloc_extension.h"
#endif

namespace workerd::server {

struct MemoryMaintenance::IsolateEntry final: public kj::Refcounted {
  IsolateEntry(kj::String name,
      kj::Own<const Worker::Isolate::WeakIsolateRef> ref,
      uint lockCount,
      kj::TimePoint now)
      : name(kj::mv(name)),
        ref(kj::mv(ref)),
        lastLockCount(lockCount),
        lastActive(now) {}

  kj::String name;
  kj::Own<const Worker::Isolate::WeakIsolateRef> ref;

  // Lock count seen last time we looked. The isolate is idle while this stays unchanged. Our
  // own locks update it, so they don't count as activity.
  uint lastLockCount;
  kj::TimePoint lastActive;

  // True once the idle collection ran; reset when the isolate becomes active again.
  bool collected = false;

  // True while a pumpWhileIdle() task runs for this isolate.
  bool pumping = false;

  // Lock count right after this isolate's last full collection. A memory pressure pass skips
  // the isolate while the count is unchanged: nothing ran, so there is nothing new to free.
  kj::Maybe<uint> collectedAtLockCount;
};

namespace {

// Returns all free memory cached in TCMalloc's page heap to the OS. No-op without TCMalloc.
void releaseFreeMallocMemory() {
#if WD_EXECUTOR_TCMALLOC
  tcmalloc::MallocExtension::ReleaseMemoryToSystem(kj::maxValue);
#endif
}

// Runs the isolate's pending V8 foreground tasks, like IoContext does at the end of a request
// (io-context.c++): without an IoContext, running microtasks queued by FinalizationRegistry
// callbacks. That loop stops once the request's LimitEnforcer reports exceeded limits. There is
// no request here, so this checks the isolate's heap limit instead, and it also stops after
// 10000 tasks. This may run while requests of the isolate are suspended, the same as a
// FinalizationRegistry callback running at the end of another request would. When JavaScript
// execution is terminated, it stops and does not pump again.
void pumpForegroundTasks(jsg::Lock& js, const Worker::Isolate& isolate) {
  SuppressIoContextScope noIoContext;
  for (uint i = 0; i < 10000 && js.pumpMsgLoop(); ++i) {
    if (isolate.getLimitEnforcer().hasExcessivelyExceededHeapLimit()) break;
    v8::TryCatch tryCatch(js.v8Isolate);
    js.runMicrotasks();
    if (tryCatch.HasCaught()) {
      tryCatch.Reset();
      break;
    }
  }
}

// True when the isolate's last full collection happened at lock count `count`.
bool isCollectedAt(const MemoryMaintenance::IsolateEntry& entry, uint count) {
  KJ_IF_SOME(collectedAt, entry.collectedAtLockCount) {
    return collectedAt == count;
  }
  return false;
}

// Returns the memory this process is using: the working set of the process's cgroup v2 when
// available (memory.current, which a container memory limit is enforced against, minus the
// inactive file cache in memory.stat, which the kernel reclaims before it would kill anything;
// docker stats and the kubelet compute it the same way), otherwise the resident set size.
// Returns none when neither can be read (e.g. not on Linux).
kj::Maybe<uint64_t> readMemoryUsage() {
#if __linux__
  auto readFile = [](kj::StringPtr path) -> kj::Maybe<kj::String> {
    int fd = open(path.cStr(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return kj::none;
    kj::AutoCloseFd owned(fd);
    kj::FdInputStream in(owned.get());
    return in.readAllText();
  };

  KJ_IF_SOME(cgroups, readFile("/proc/self/cgroup")) {
    // cgroup v2 has a single "0::<path>" line.
    const char* text = cgroups.cStr();
    const char* line = strncmp(text, "0::", 3) == 0 ? text : strstr(text, "\n0::");
    if (line != nullptr) {
      if (*line == '\n') ++line;
      const char* start = line + 3;
      const char* end = strchr(start, '\n');
      size_t length = end == nullptr ? strlen(start) : end - start;
      auto dir = kj::str("/sys/fs/cgroup", kj::arrayPtr(start, length));
      KJ_IF_SOME(current, readFile(kj::str(dir, "/memory.current"))) {
        uint64_t usage = strtoull(current.cStr(), nullptr, 10);
        KJ_IF_SOME(stat, readFile(kj::str(dir, "/memory.stat"))) {
          const char* text = stat.cStr();
          const char* field =
              strncmp(text, "inactive_file ", 14) == 0 ? text : strstr(text, "\ninactive_file ");
          if (field != nullptr) {
            if (*field == '\n') ++field;
            uint64_t inactive = strtoull(field + 14, nullptr, 10);
            usage = inactive < usage ? usage - inactive : 0;
          }
        }
        return usage;
      }
    }
  }

  KJ_IF_SOME(statm, readFile("/proc/self/statm")) {
    unsigned long long size = 0, resident = 0;
    if (sscanf(statm.cStr(), "%llu %llu", &size, &resident) == 2) {
      return static_cast<uint64_t>(resident) * static_cast<uint64_t>(sysconf(_SC_PAGESIZE));
    }
  }
#endif
  return kj::none;
}

}  // namespace

void startTcmallocBackgroundRelease(uint64_t bytesPerSecond) {
  if (bytesPerSecond == 0) return;
#if WD_EXECUTOR_TCMALLOC
  static bool started = false;
  if (started) return;
  if (!tcmalloc::MallocExtension::NeedsProcessBackgroundActions()) {
    KJ_LOG(WARNING, "executor: TCMalloc does not need background actions here; not starting them");
    return;
  }
  started = true;
  tcmalloc::MallocExtension::SetBackgroundReleaseRate(
      static_cast<tcmalloc::MallocExtension::BytesPerSecond>(bytesPerSecond));
  kj::Thread thread([]() { tcmalloc::MallocExtension::ProcessBackgroundActions(); });
  thread.detach();
  KJ_LOG(INFO, "executor: TCMalloc background release enabled", bytesPerSecond);
#else
  KJ_LOG(WARNING,
      "executor: memory.tcmallocBackgroundReleaseBytesPerSecond is set but this build does not use "
      "TCMalloc; ignoring it");
#endif
}

MemoryMaintenance::MemoryMaintenance(kj::Timer& timer, config::MemoryOptions::Reader conf)
    : timer(timer),
      interval(kj::max(conf.getMaintenanceIntervalMs(), 10u) * kj::MILLISECONDS),
      idleGcDelay(conf.getIdleIsolateGcDelayMs() * kj::MILLISECONDS),
      idleGcMode(conf.getIdleIsolateGcMode()),
      idleTaskPump(conf.getIdleTaskPumpMs() * kj::MILLISECONDS),
      pressureThresholdBytes(conf.getPressureThresholdMb() * 1024 * 1024),
      pressureCooldown(conf.getPressureCooldownMs() * kj::MILLISECONDS),
      pressureGcBudget(conf.getPressureGcBudgetMs() * kj::MILLISECONDS),
      currentPressureCooldown(pressureCooldown),
      releaseMemoryAfterGc(conf.getReleaseMemoryAfterGc()),
      nextPressureCollection(timer.now()),
      pumpTasks(*this) {}

MemoryMaintenance::~MemoryMaintenance() noexcept(false) = default;

bool MemoryMaintenance::isEnabled(config::MemoryOptions::Reader conf) {
  return conf.getIdleIsolateGcDelayMs() > 0 || conf.getPressureThresholdMb() > 0;
}

void MemoryMaintenance::start() {
  loopTask = loop().eagerlyEvaluate(
      [](kj::Exception&& e) { KJ_LOG(ERROR, "executor: memory maintenance loop failed", e); });
}

void MemoryMaintenance::registerIsolate(kj::StringPtr name, const Worker::Isolate& isolate) {
  isolates.add(kj::rc<IsolateEntry>(
      kj::str(name), isolate.getWeakRef(), isolate.getLockSuccessCount(), timer.now()));
}

void MemoryMaintenance::taskFailed(kj::Exception&& exception) {
  KJ_LOG(ERROR, "executor: idle isolate task pump failed", exception);
}

kj::Promise<void> MemoryMaintenance::loop() {
  for (;;) {
    co_await timer.afterDelay(interval);
    co_await sweep().catch_(
        [](kj::Exception&& e) { KJ_LOG(ERROR, "executor: memory maintenance sweep failed", e); });
  }
}

kj::Promise<void> MemoryMaintenance::sweep() {
  auto now = timer.now();

  // Forget destroyed isolates, note which ones were active since the last sweep, and pick the
  // ones that have been idle long enough.
  kj::Vector<kj::Rc<IsolateEntry>> live(isolates.size());
  kj::Vector<kj::Rc<IsolateEntry>> idle;
  for (auto& entry: isolates) {
    KJ_IF_SOME(isolate, entry->ref->tryAddStrongRef()) {
      auto count = isolate->getLockSuccessCount();
      if (count != entry->lastLockCount) {
        entry->lastLockCount = count;
        entry->lastActive = now;
        entry->collected = false;
      } else if (idleGcDelay > 0 * kj::MILLISECONDS && !entry->collected &&
          now - entry->lastActive >= idleGcDelay) {
        idle.add(entry.addRef());
      }
      live.add(kj::mv(entry));
    }
  }
  isolates = kj::mv(live);

  for (auto& entry: idle) {
    co_await collectIdle(entry.addRef());
  }

  if (pressureThresholdBytes > 0) {
    co_await relievePressure(now);
  }

  // Collections free V8 heap pages directly, but native objects owned by collected JavaScript
  // objects go back to TCMalloc, which keeps them cached. Hand that memory back to the OS
  // once per sweep at most.
  if (releasePending && releaseMemoryAfterGc) {
    releaseFreeMallocMemory();
    KJ_LOG(INFO, "executor: released free malloc memory to the OS");
  }
  releasePending = false;
}

kj::Promise<void> MemoryMaintenance::collectIdle(kj::Rc<IsolateEntry> entry) {
  kj::Own<const Worker::Isolate> isolate;
  KJ_IF_SOME(i, entry->ref->tryAddStrongRef()) {
    isolate = kj::mv(i);
  } else {
    co_return;
  }

  bool full = idleGcMode == config::MemoryOptions::IdleGcMode::FULL;
  {
    auto asyncLock = co_await isolate->takeAsyncLockWithoutRequest(nullptr);
    // Something may have run while we waited for the lock. Then the isolate is not idle; the
    // next sweep notices the activity and starts the idle timer over.
    if (isolate->getLockSuccessCount() != entry->lastLockCount) co_return;

    bool stillCollected = isCollectedAt(*entry, entry->lastLockCount);
    isolate->runInLockScope(asyncLock, [&](jsg::Lock& js) {
      pumpForegroundTasks(js, *isolate);
      if (full) {
        js.v8Isolate->LowMemoryNotification();
      } else {
        // V8 can trim caches on this notification. It starts no heap collection in this build,
        // which disables incremental marking.
        js.v8Isolate->MemoryPressureNotification(v8::MemoryPressureLevel::kModerate);
      }
      pumpForegroundTasks(js, *isolate);
    });
    entry->lastLockCount = isolate->getLockSuccessCount();
    if (full || stillCollected) entry->collectedAtLockCount = entry->lastLockCount;
  }
  entry->collected = true;
  releasePending = true;
  KJ_LOG(INFO, "executor: collected idle isolate", entry->name, full ? "full" : "moderate");

  if (idleTaskPump > 0 * kj::MILLISECONDS && !entry->pumping) {
    entry->pumping = true;
    auto until = timer.now() + idleTaskPump;
    pumpTasks.add(pumpWhileIdle(kj::mv(entry), until));
  }
}

// Keeps running an idle isolate's foreground tasks until `until`, or until the isolate does
// something on its own. Tasks V8 posts after a notification or a collection come with short
// delays first and longer ones later, so pump quickly at first, then fall back to the
// maintenance interval.
kj::Promise<void> MemoryMaintenance::pumpWhileIdle(
    kj::Rc<IsolateEntry> entry, kj::TimePoint until) {
  KJ_DEFER({
    entry->pumping = false;
    // Tasks run during the pumping can free memory too, so release afterwards as well.
    releasePending = true;
  });
  auto burstEnd = timer.now() + 2 * kj::SECONDS;
  while (timer.now() < until) {
    co_await timer.afterDelay(timer.now() < burstEnd ? 20 * kj::MILLISECONDS : interval);

    kj::Own<const Worker::Isolate> isolate;
    KJ_IF_SOME(i, entry->ref->tryAddStrongRef()) {
      isolate = kj::mv(i);
    } else {
      co_return;
    }
    if (isolate->getLockSuccessCount() != entry->lastLockCount) co_return;

    auto asyncLock = co_await isolate->takeAsyncLockWithoutRequest(nullptr);
    if (isolate->getLockSuccessCount() != entry->lastLockCount) co_return;
    bool stillCollected = isCollectedAt(*entry, entry->lastLockCount);
    isolate->runInLockScope(asyncLock, [&](jsg::Lock& js) { pumpForegroundTasks(js, *isolate); });
    entry->lastLockCount = isolate->getLockSuccessCount();
    // Our own lock is not activity: a full collection before it still covers the isolate.
    if (stillCollected) entry->collectedAtLockCount = entry->lastLockCount;
  }
}

// One step of the memory pressure handling, run once per sweep. Starts a pass over all isolates
// when usage is above the threshold and the cooldown has passed, then collects isolates from the
// pass until `pressureGcBudget` is spent; the rest wait for the next sweep, so requests get the
// event loop in between. When a pass has visited every isolate, the next one waits for the
// cooldown, which doubles while the passes leave usage above the threshold.
kj::Promise<void> MemoryMaintenance::relievePressure(kj::TimePoint now) {
  if (pressureQueue.empty()) {
    if (now < nextPressureCollection) co_return;
    KJ_IF_SOME(usage, readMemoryUsage()) {
      if (usage <= pressureThresholdBytes) {
        currentPressureCooldown = pressureCooldown;
        co_return;
      }
      KJ_LOG(INFO, "executor: memory usage above threshold, collecting isolates", usage,
          pressureThresholdBytes);
      pressureQueue = KJ_MAP(e, isolates) { return e.addRef(); };
      pressurePassCollected = 0;
    } else {
      co_return;
    }
  }

  auto& clock = kj::systemPreciseMonotonicClock();
  auto start = clock.now();
  size_t visited = 0;
  while (visited < pressureQueue.size()) {
    if (pressureGcBudget > 0 * kj::MILLISECONDS && visited > 0 &&
        clock.now() - start >= pressureGcBudget) {
      break;
    }
    auto entry = pressureQueue[visited++].addRef();
    if (co_await collectUnderPressure(kj::mv(entry))) ++pressurePassCollected;
  }
  pressureQueue = KJ_MAP(e, pressureQueue.slice(visited, pressureQueue.size())) {
    return e.addRef();
  };
  if (!pressureQueue.empty()) co_return;

  // The pass is over.
  bool relieved = true;
  uint64_t usage = 0;
  KJ_IF_SOME(u, readMemoryUsage()) {
    usage = u;
    relieved = usage <= pressureThresholdBytes;
  }
  if (relieved) {
    currentPressureCooldown = pressureCooldown;
  } else {
    currentPressureCooldown = kj::min(currentPressureCooldown * 2, pressureCooldown * 16);
  }
  nextPressureCollection = timer.now() + currentPressureCooldown;
  uint collected = pressurePassCollected;
  kj::Duration nextPassIn = currentPressureCooldown;
  KJ_LOG(INFO, "executor: memory pressure pass done", collected, usage, nextPassIn);
}

// Runs a full GC in one isolate for the memory pressure pass. Returns false when the isolate is
// gone or has not run since its last full collection.
kj::Promise<bool> MemoryMaintenance::collectUnderPressure(kj::Rc<IsolateEntry> entry) {
  kj::Own<const Worker::Isolate> isolate;
  KJ_IF_SOME(i, entry->ref->tryAddStrongRef()) {
    isolate = kj::mv(i);
  } else {
    co_return false;
  }
  if (isCollectedAt(*entry, isolate->getLockSuccessCount())) co_return false;

  auto asyncLock = co_await isolate->takeAsyncLockWithoutRequest(nullptr);
  bool wasIdle = isolate->getLockSuccessCount() == entry->lastLockCount;
  isolate->runInLockScope(asyncLock, [&](jsg::Lock& js) {
    js.v8Isolate->LowMemoryNotification();
    pumpForegroundTasks(js, *isolate);
  });
  entry->lastLockCount = isolate->getLockSuccessCount();
  entry->collectedAtLockCount = entry->lastLockCount;
  releasePending = true;
  if (!wasIdle) {
    entry->lastActive = timer.now();
    entry->collected = false;
  }
  co_return true;
}

}  // namespace workerd::server
