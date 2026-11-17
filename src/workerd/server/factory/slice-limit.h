// Licensed under the Apache 2.0 license found in the LICENSE file or at:
//     https://opensource.org/licenses/Apache-2.0

#pragma once

// Executor fork: a limit on each continuous stretch of JavaScript ("slice") that a Worker loaded
// through a Worker loader runs, configured by `Config.dynamicWorkerLimits` (workerd.capnp). Off
// unless the config sets it; Workers defined in the config are never limited.

#include <workerd/io/actor-cache.h>
#include <workerd/io/limit-enforcer.h>

#include <kj/mutex.h>
#include <kj/refcount.h>
#include <kj/thread.h>
#include <kj/time.h>

#include <utility>

namespace workerd::server {

// The thread that watches the slices in progress. Each slice measures the CPU time of the thread
// running it (the event loop thread) from the moment it starts; once that reaches the limit, the
// watchdog sets the slice's `fired` flag and calls v8::Isolate::TerminateExecution(), which V8
// allows from another thread. The watchdog wakes every `limit / 10` (between 1 ms and 100 ms) and
// sleeps otherwise; arming and disarming a slice only take its mutex.
class SliceWatchdog final: public kj::AtomicRefcounted {
 public:
  explicit SliceWatchdog(kj::Duration limit);
  ~SliceWatchdog() noexcept(false);
  KJ_DISALLOW_COPY_AND_MOVE(SliceWatchdog);

  kj::Duration getLimit() const {
    return limit;
  }

  struct Slice;

  // Starts watching a slice of `isolate`'s JavaScript on the calling thread. The slice ends when
  // the returned object is destroyed, which must happen on the same thread.
  kj::Own<Slice> arm(v8::Isolate* isolate) const;

  // Ends watching `slice`. Returns true if the watchdog terminated its JavaScript.
  bool disarm(Slice& slice) const;

 private:
  struct State {
    kj::Vector<Slice*> active;
    bool stop = false;
  };

  kj::Duration limit;
  kj::Duration poll;
  kj::MutexGuarded<State> state;
  kj::Maybe<kj::Own<kj::Thread>> thread;

  void run() const;
};

// The exception a slice that exceeded the limit ends with: a JavaScript Error the caller sees as
// "Worker exceeded CPU time limit.", carrying CPU_LIMIT_DETAIL_ID so that the request's outcome is
// EXCEEDED_CPU.
kj::Exception sliceLimitException();

// The per-request LimitEnforcer of a Worker loader's Worker: `inner`, with every entry into
// JavaScript limited to the watchdog's limit. After a breach the request fails with
// sliceLimitException(), its IoContext is aborted, and the Worker's isolate is aborted, so that a
// Worker loader's next load() or get() of the same name starts a fresh isolate.
kj::Own<LimitEnforcer> newSliceLimitEnforcer(
    kj::Arc<const SliceWatchdog> watchdog, kj::Own<LimitEnforcer> inner, kj::String workerName);

// The IsolateLimitEnforcer of a Worker loader's Worker: `inner`, with top-level module evaluation
// (enterStartupJs()) and dynamic imports (enterDynamicImportJs()) limited to the watchdog's limit.
// A breach is reported through the limit error the enforcer's caller passes in, and remembered:
// see startupLimitExceeded().
class SliceLimitedIsolateLimitEnforcer final: public IsolateLimitEnforcer {
 public:
  SliceLimitedIsolateLimitEnforcer(
      kj::Arc<const SliceWatchdog> watchdog, kj::Own<IsolateLimitEnforcer> inner);

  // True once a top-level evaluation or dynamic import of this isolate exceeded the limit.
  bool startupLimitExceeded() const {
    return startupExceeded;
  }

  // True, once, after a dynamic import exceeded the limit. A dynamic import runs under its own lock
  // outside the request's slices, so the request's enforcer asks after each of its slices.
  bool takeDynamicImportBreach() const {
    return std::exchange(dynamicImportExceeded, false);
  }

  v8::Isolate::CreateParams getCreateParams() override {
    return inner->getCreateParams();
  }
  void customizeIsolate(v8::Isolate* isolate) override {
    inner->customizeIsolate(isolate);
  }
  ActorCacheSharedLruOptions getActorCacheLruOptions() override {
    return inner->getActorCacheLruOptions();
  }
  kj::Own<void> enterStartupJs(
      jsg::Lock& lock, kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime) const override;
  kj::Own<void> enterStartupPython(
      jsg::Lock& lock, kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime) const override {
    return inner->enterStartupPython(lock, limitErrorOrTime);
  }
  kj::Own<void> enterDynamicImportJs(
      jsg::Lock& lock, kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime) const override;
  kj::Own<void> enterLoggingJs(
      jsg::Lock& lock, kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime) const override {
    return inner->enterLoggingJs(lock, limitErrorOrTime);
  }
  kj::Own<void> enterInspectorJs(
      jsg::Lock& lock, kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime) const override {
    return inner->enterInspectorJs(lock, limitErrorOrTime);
  }
  void completedRequest(kj::StringPtr id) const override {
    inner->completedRequest(id);
  }
  bool exitJs(jsg::Lock& lock) const override {
    return inner->exitJs(lock);
  }
  void reportMetrics(IsolateObserver& isolateMetrics) const override {
    inner->reportMetrics(isolateMetrics);
  }
  kj::Maybe<size_t> checkPbkdfIterations(jsg::Lock& js, size_t iterations) const override {
    return inner->checkPbkdfIterations(js, iterations);
  }
  kj::Maybe<uint64_t> checkScryptCost(
      jsg::Lock& js, uint32_t N, uint32_t r, uint32_t p) const override {
    return inner->checkScryptCost(js, N, r, p);
  }
  size_t getBlobSizeLimit() const override {
    return inner->getBlobSizeLimit();
  }
  bool hasExcessivelyExceededHeapLimit() const override {
    return inner->hasExcessivelyExceededHeapLimit();
  }
  const TrackedWasmInstanceList& getTrackedWasmInstances() const override {
    return inner->getTrackedWasmInstances();
  }

 private:
  kj::Arc<const SliceWatchdog> watchdog;
  kj::Own<IsolateLimitEnforcer> inner;
  mutable bool startupExceeded = false;
  mutable bool dynamicImportExceeded = false;

  kj::Own<void> enterLimited(jsg::Lock& lock,
      kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime,
      kj::Own<void> innerScope,
      bool dynamicImport) const;
};

}  // namespace workerd::server
