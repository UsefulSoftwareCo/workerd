// Licensed under the Apache 2.0 license found in the LICENSE file or at:
//     https://opensource.org/licenses/Apache-2.0

#pragma once

// Executor fork: memory maintenance, configured by `Config.memory` (workerd.capnp). Everything
// here is off unless the config enables it.

#include <workerd/io/worker.h>
#include <workerd/server/workerd.capnp.h>

#include <kj/async.h>
#include <kj/timer.h>

namespace workerd::server {

// Starts TCMalloc's background actions thread with the given release rate. Upstream workerd never
// calls MallocExtension::ProcessBackgroundActions(), so TCMalloc's background release rate has no
// effect and free pages stay cached in the page heap for the life of the process. Does nothing
// when `bytesPerSecond` is 0, and warns in builds without TCMalloc.
void startTcmallocBackgroundRelease(uint64_t bytesPerSecond);

// Watches isolates for idleness and collects their garbage; see memory-maintenance.c++.
class MemoryMaintenance final: private kj::TaskSet::ErrorHandler {
 public:
  MemoryMaintenance(kj::Timer& timer, config::MemoryOptions::Reader conf);
  ~MemoryMaintenance() noexcept(false);
  KJ_DISALLOW_COPY_AND_MOVE(MemoryMaintenance);

  // Whether `conf` enables any of the collections this class runs.
  static bool isEnabled(config::MemoryOptions::Reader conf);

  // Starts the maintenance loop. Isolates registered before or after are watched.
  void start();

  void registerIsolate(kj::StringPtr name, const Worker::Isolate& isolate);

  // Public so that helpers in memory-maintenance.c++ can name it; defined there.
  struct IsolateEntry;

 private:

  kj::Timer& timer;
  kj::Duration interval;
  kj::Duration idleGcDelay;
  config::MemoryOptions::IdleGcMode idleGcMode;
  kj::Duration idleTaskPump;
  uint64_t pressureThresholdBytes;
  kj::Duration pressureCooldown;
  kj::Duration pressureGcBudget;

  // Wait after the current pass: `pressureCooldown`, doubled after every pass that ends with
  // usage still above the threshold (up to 16 times), and reset once usage is below it.
  kj::Duration currentPressureCooldown;

  // Isolates the current memory pressure pass has yet to visit. Empty between passes.
  kj::Vector<kj::Rc<IsolateEntry>> pressureQueue;
  uint pressurePassCollected = 0;
  bool releaseMemoryAfterGc;
  kj::TimePoint nextPressureCollection;

  // Set when a collection finished since the last time free malloc memory was released.
  bool releasePending = false;

  kj::Vector<kj::Rc<IsolateEntry>> isolates;
  kj::TaskSet pumpTasks;
  kj::Maybe<kj::Promise<void>> loopTask;

  void taskFailed(kj::Exception&& exception) override;

  kj::Promise<void> loop();
  kj::Promise<void> sweep();
  kj::Promise<void> collectIdle(kj::Rc<IsolateEntry> entry);
  kj::Promise<void> pumpWhileIdle(kj::Rc<IsolateEntry> entry, kj::TimePoint until);
  kj::Promise<void> relievePressure(kj::TimePoint now);
  kj::Promise<bool> collectUnderPressure(kj::Rc<IsolateEntry> entry);
};

}  // namespace workerd::server
