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

 private:
  struct IsolateEntry;

  kj::Timer& timer;
  kj::Duration interval;
  kj::Duration idleGcDelay;
  config::MemoryOptions::IdleGcMode idleGcMode;
  kj::Duration idleTaskPump;
  uint64_t pressureThresholdBytes;
  kj::Duration pressureCooldown;
  kj::TimePoint nextPressureCollection;

  kj::Vector<kj::Rc<IsolateEntry>> isolates;
  kj::TaskSet pumpTasks;
  kj::Maybe<kj::Promise<void>> loopTask;

  void taskFailed(kj::Exception&& exception) override;

  kj::Promise<void> loop();
  kj::Promise<void> sweep();
  kj::Promise<void> collectIdle(kj::Rc<IsolateEntry> entry);
  kj::Promise<void> pumpWhileIdle(kj::Rc<IsolateEntry> entry, kj::TimePoint until);
  kj::Promise<void> collectAll(uint64_t usage);
};

}  // namespace workerd::server
