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
// Optionally, it also runs a full GC in every isolate when the process's memory usage crosses
// `pressureThresholdMb`.
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
};

namespace {

// Runs the isolate's pending V8 foreground tasks, the same way IoContext does at the end of a
// request: without an IoContext, running microtasks queued by FinalizationRegistry callbacks.
void pumpForegroundTasks(jsg::Lock& js) {
  SuppressIoContextScope noIoContext;
  for (uint i = 0; i < 10000 && js.pumpMsgLoop(); ++i) {
    v8::TryCatch tryCatch(js.v8Isolate);
    js.runMicrotasks();
    if (tryCatch.HasCaught()) {
      tryCatch.Reset();
      break;
    }
  }
}

// Returns the memory charged to this process: the cgroup v2 memory.current of the process's
// cgroup when available (what a container memory limit is enforced against), otherwise the
// resident set size. Returns none when neither can be read (e.g. not on Linux).
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
      auto path = kj::str("/sys/fs/cgroup", kj::arrayPtr(start, length), "/memory.current");
      KJ_IF_SOME(current, readFile(path)) {
        return strtoull(current.cStr(), nullptr, 10);
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

MemoryMaintenance::MemoryMaintenance(kj::Timer& timer, config::MemoryOptions::Reader conf)
    : timer(timer),
      interval(kj::max(conf.getMaintenanceIntervalMs(), 10u) * kj::MILLISECONDS),
      idleGcDelay(conf.getIdleIsolateGcDelayMs() * kj::MILLISECONDS),
      idleGcMode(conf.getIdleIsolateGcMode()),
      idleTaskPump(conf.getIdleTaskPumpMs() * kj::MILLISECONDS),
      pressureThresholdBytes(conf.getPressureThresholdMb() * 1024 * 1024),
      pressureCooldown(conf.getPressureCooldownMs() * kj::MILLISECONDS),
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

  if (pressureThresholdBytes > 0 && now >= nextPressureCollection) {
    KJ_IF_SOME(usage, readMemoryUsage()) {
      if (usage > pressureThresholdBytes) {
        nextPressureCollection = now + pressureCooldown;
        co_await collectAll(usage);
      }
    }
  }
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

    isolate->runInLockScope(asyncLock, [&](jsg::Lock& js) {
      pumpForegroundTasks(js);
      if (full) {
        js.v8Isolate->LowMemoryNotification();
      } else {
        // V8 can trim caches on this notification. It starts no heap collection in this build,
        // which disables incremental marking.
        js.v8Isolate->MemoryPressureNotification(v8::MemoryPressureLevel::kModerate);
      }
      pumpForegroundTasks(js);
    });
    entry->lastLockCount = isolate->getLockSuccessCount();
  }
  entry->collected = true;
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
  KJ_DEFER(entry->pumping = false);
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
    isolate->runInLockScope(asyncLock, [&](jsg::Lock& js) { pumpForegroundTasks(js); });
    entry->lastLockCount = isolate->getLockSuccessCount();
  }
}

kj::Promise<void> MemoryMaintenance::collectAll(uint64_t usage) {
  KJ_LOG(INFO, "executor: memory usage above threshold, collecting all isolates", usage,
      pressureThresholdBytes);
  auto entries = KJ_MAP(e, isolates) { return e.addRef(); };
  for (auto& entry: entries) {
    kj::Own<const Worker::Isolate> isolate;
    KJ_IF_SOME(i, entry->ref->tryAddStrongRef()) {
      isolate = kj::mv(i);
    } else {
      continue;
    }
    auto asyncLock = co_await isolate->takeAsyncLockWithoutRequest(nullptr);
    bool wasIdle = isolate->getLockSuccessCount() == entry->lastLockCount;
    isolate->runInLockScope(asyncLock, [&](jsg::Lock& js) {
      js.v8Isolate->LowMemoryNotification();
      pumpForegroundTasks(js);
    });
    entry->lastLockCount = isolate->getLockSuccessCount();
    if (!wasIdle) {
      entry->lastActive = timer.now();
      entry->collected = false;
    }
  }
}

}  // namespace workerd::server
