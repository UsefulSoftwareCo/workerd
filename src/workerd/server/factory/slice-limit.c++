// Licensed under the Apache 2.0 license found in the LICENSE file or at:
//     https://opensource.org/licenses/Apache-2.0

// Executor fork: the slice limit of Worker loader Workers.
//
// An optional CPU budget for continuous JavaScript execution in Workers created through a Worker
// loader. Config-defined Workers retain their existing behavior: workerd's own LimitEnforcer and
// IsolateLimitEnforcer enforce no limits ("Single-tenant policy").
//
// This limits each continuous stretch of a loader Worker's JavaScript: one entry into JavaScript
// for a request or event (IoContext::runImpl(), microtasks included), one top-level module
// evaluation, or one dynamic import. Time a Worker spends awaiting I/O, timers or RPC is outside
// any slice, so a Worker that mostly waits is never limited. The limit is on the CPU time of the
// thread running the slice, which is the time the slice holds that thread unless the machine is
// short of CPU.
//
// JavaScript, WebAssembly loops and regular expressions stop at the limit, within the watchdog's
// polling interval. A single long native call (a sort, a large JSON.parse, structuredClone)
// cannot be interrupted, so the slice ends when that call returns.

#include "slice-limit.h"

#include <workerd/io/io-context.h>
#include <workerd/jsg/jsg.h>
#include <workerd/util/exception.h>

#include <pthread.h>

#include <atomic>
#include <time.h>

namespace workerd::server {

struct SliceWatchdog::Slice {
  Slice(const SliceWatchdog& watchdog, v8::Isolate* isolate, kj::TimePoint checkAt)
      : watchdog(watchdog),
        isolate(isolate),
        checkAt(checkAt) {}

  const SliceWatchdog& watchdog;
  v8::Isolate* isolate;
  clockid_t cpuClock = 0;
  int64_t cpuStartNs = 0;
  // When the watchdog next reads this slice's CPU time. The slice cannot have used the limit
  // before then, since CPU time never runs faster than the monotonic clock.
  kj::TimePoint checkAt;
  // Set by the watchdog, under the state mutex, when it ended the slice's JavaScript. Also read
  // without the mutex, by native code of the slice's own thread (SQLite's interrupt check).
  std::atomic<bool> fired = false;
  // The slice of this thread this one is nested in, if any.
  Slice* outer = nullptr;
  bool armed = true;

  // A slice is always disarmed before it is destroyed; this only covers unwinding past a scope.
  ~Slice() noexcept(false) {
    watchdog.disarm(*this);
  }
};

namespace {

// The innermost slice of this thread that is armed.
thread_local SliceWatchdog::Slice* currentSlice = nullptr;

int64_t readCpuNs(clockid_t clock) {
  struct timespec ts;
  KJ_SYSCALL(clock_gettime(clock, &ts));
  return static_cast<int64_t>(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

}  // namespace

SliceWatchdog::SliceWatchdog(kj::Duration limit)
    : limit(limit),
      poll(kj::min(kj::max(limit / 10, 1 * kj::MILLISECONDS), 100 * kj::MILLISECONDS)) {
  thread = kj::heap<kj::Thread>([this]() { run(); });
}

SliceWatchdog::~SliceWatchdog() noexcept(false) {
  state.lockExclusive()->stop = true;
  // Joins the thread.
  thread = kj::none;
}

kj::Own<SliceWatchdog::Slice> SliceWatchdog::arm(v8::Isolate* isolate) const {
  auto slice = kj::heap<Slice>(*this, isolate, kj::systemPreciseMonotonicClock().now() + limit);
  KJ_REQUIRE(pthread_getcpuclockid(pthread_self(), &slice->cpuClock) == 0);
  slice->cpuStartNs = readCpuNs(slice->cpuClock);
  slice->outer = currentSlice;
  currentSlice = slice.get();
  state.lockExclusive()->active.add(slice.get());
  return slice;
}

bool SliceWatchdog::disarm(Slice& slice) const {
  if (slice.armed) {
    slice.armed = false;
    // Slices end in the reverse order they start on a thread.
    if (currentSlice == &slice) currentSlice = slice.outer;
  }
  auto lock = state.lockExclusive();
  auto& active = lock->active;
  for (size_t i = 0; i < active.size(); i++) {
    if (active[i] == &slice) {
      active[i] = active.back();
      active.removeLast();
      break;
    }
  }
  return slice.fired.load(std::memory_order_relaxed);
}

void SliceWatchdog::run() const {
  auto& clock = kj::systemPreciseMonotonicClock();
  auto lock = state.lockExclusive();
  while (!lock->stop) {
    auto now = clock.now();
    for (auto slice: lock->active) {
      if (slice->fired.load(std::memory_order_relaxed)) {
        // V8 forgets a termination once no JavaScript is on the stack, so JavaScript the slice
        // enters again (the next task of a loop that runs tasks) would run on: end it again.
        slice->isolate->TerminateExecution();
        continue;
      }
      if (now < slice->checkAt) continue;
      auto used = (readCpuNs(slice->cpuClock) - slice->cpuStartNs) * kj::NANOSECONDS;
      if (used >= limit) {
        slice->fired.store(true, std::memory_order_relaxed);
        // Safe from any thread. The slice's thread is blocked on this mutex before the slice ends,
        // so the isolate is alive.
        slice->isolate->TerminateExecution();
      } else {
        slice->checkAt = now + (limit - used);
      }
    }
    lock.wait([](const State& s) { return s.stop; }, poll);
  }
}

kj::Exception sliceLimitException() {
  auto exception = JSG_KJ_EXCEPTION(OVERLOADED, Error, "Worker exceeded CPU time limit.");
  exception.setDetail(CPU_LIMIT_DETAIL_ID, kj::heapArray<kj::byte>(0));
  return exception;
}

void endCurrentSlice() {
  KJ_ASSERT(currentSlice != nullptr, "endCurrentSlice() outside a slice");
  // Raises V8's uncatchable termination at once, as abortIsolate() does: requesting it would let
  // the calling JavaScript run on until its next interrupt check.
  jsg::Lock::current().terminateExecutionNow();
}

bool currentSliceExceeded() {
  for (auto slice = currentSlice; slice != nullptr; slice = slice->outer) {
    if (slice->fired.load(std::memory_order_relaxed)) return true;
  }
  return false;
}

namespace {

class SliceLimitEnforcer final: public LimitEnforcer {
 public:
  SliceLimitEnforcer(
      kj::Arc<const SliceWatchdog> watchdog, kj::Own<LimitEnforcer> inner, kj::String workerName)
      : watchdog(kj::mv(watchdog)),
        inner(kj::mv(inner)),
        workerName(kj::mv(workerName)) {
    auto paf = kj::newPromiseAndFulfiller<void>();
    exceededPromise = paf.promise.fork();
    exceededFulfiller = kj::mv(paf.fulfiller);
  }

  kj::Own<void> enterJs(jsg::Lock& lock, IoContext& context) override {
    return kj::heap<Scope>(*this, lock, context, inner->enterJs(lock, context));
  }

  void topUpActor() override {
    inner->topUpActor();
  }
  void newSubrequest(bool isInHouse) override {
    inner->newSubrequest(isInHouse);
  }
  void newKvRequest(KvOpType op) override {
    inner->newKvRequest(op);
  }
  void newAnalyticsEngineRequest() override {
    inner->newAnalyticsEngineRequest();
  }
  kj::Promise<void> limitDrain() override {
    return inner->limitDrain();
  }
  kj::Promise<void> limitScheduled() override {
    return inner->limitScheduled();
  }
  kj::Duration getAlarmLimit() override {
    return inner->getAlarmLimit();
  }
  kj::Duration getOnHibernateLimit() override {
    return inner->getOnHibernateLimit();
  }
  void limitOnHibernateCpu() override {
    inner->limitOnHibernateCpu();
  }
  size_t getBufferingLimit() override {
    return inner->getBufferingLimit();
  }
  kj::Maybe<kj::Own<void>> tryReserveActorCallReplayMemory(size_t bytes) override {
    return inner->tryReserveActorCallReplayMemory(bytes);
  }
  kj::Maybe<EventOutcome> getLimitsExceeded() override {
    if (exceeded) return EventOutcome::EXCEEDED_CPU;
    return inner->getLimitsExceeded();
  }
  kj::Promise<void> onLimitsExceeded() override {
    return exceededPromise.addBranch().exclusiveJoin(inner->onLimitsExceeded());
  }
  void setCpuLimitNearlyExceededCallback(kj::Function<void()> cb) override {
    inner->setCpuLimitNearlyExceededCallback(kj::mv(cb));
  }
  void requireLimitsNotExceeded() override {
    if (exceeded) kj::throwFatalException(sliceLimitException());
    inner->requireLimitsNotExceeded();
  }
  void reportMetrics(RequestObserver& requestMetrics) override {
    inner->reportMetrics(requestMetrics);
  }
  kj::Duration consumeTimeElapsedForPeriodicLogging() override {
    return inner->consumeTimeElapsedForPeriodicLogging();
  }
  size_t getSqliteMemoryUsage() const override {
    return inner->getSqliteMemoryUsage();
  }

 private:
  // One entry into JavaScript. Created after the isolate lock is taken and destroyed before it is
  // released (IoContext::runImpl()).
  class Scope {
   public:
    Scope(SliceLimitEnforcer& enforcer, jsg::Lock& lock, IoContext& context, kj::Own<void> inner)
        : enforcer(enforcer),
          lock(lock),
          context(context),
          inner(kj::mv(inner)),
          slice(enforcer.watchdog->arm(lock.v8Isolate)) {
      // A breach recorded outside this request's slices (a dynamic import, or maintenance)
      // counts as this request's: end this slice before any of its JavaScript runs.
      KJ_IF_SOME(isolate, isolateEnforcer()) {
        if (isolate.takePendingBreach()) {
          pending = true;
          lock.v8Isolate->TerminateExecution();
        }
      }
    }

    ~Scope() noexcept(false) {
      auto fired = enforcer.watchdog->disarm(*slice) || pending;
      KJ_IF_SOME(isolate, isolateEnforcer()) {
        if (isolate.takePendingBreach()) fired = true;
      }
      if (fired) enforcer.breached(lock, context);
    }

   private:
    SliceLimitEnforcer& enforcer;
    jsg::Lock& lock;
    IoContext& context;
    kj::Own<void> inner;
    kj::Own<SliceWatchdog::Slice> slice;
    bool pending = false;

    kj::Maybe<const SliceLimitedIsolateLimitEnforcer&> isolateEnforcer() {
      return kj::tryDowncast<const SliceLimitedIsolateLimitEnforcer>(
          context.getWorker().getIsolate().getLimitEnforcer());
    }
  };

  kj::Arc<const SliceWatchdog> watchdog;
  kj::Own<LimitEnforcer> inner;
  kj::String workerName;
  bool exceeded = false;
  kj::ForkedPromise<void> exceededPromise = nullptr;
  kj::Own<kj::PromiseFulfiller<void>> exceededFulfiller;

  void breached(jsg::Lock& lock, IoContext& context) {
    // The JavaScript may have returned on its own just as the watchdog fired. Either way the
    // slice used the limit, and no termination may be left pending for the isolate's next
    // JavaScript: IoContext::runImpl() terminates what remains of this turn itself.
    lock.v8Isolate->CancelTerminateExecution();
    if (exceeded) return;
    exceeded = true;
    KJ_LOG(WARNING, "executor: Worker loader Worker exceeded its CPU slice limit; unloading it",
        workerName, watchdog->getLimit());
    // A Worker loader's next load() or get() of this name starts a fresh isolate. Other requests
    // in flight in this isolate run on; its globals may be half-updated.
    context.abortIsolate("Worker exceeded CPU time limit."_kj);
    exceededFulfiller->reject(sliceLimitException());
  }
};

}  // namespace

kj::Own<LimitEnforcer> newSliceLimitEnforcer(
    kj::Arc<const SliceWatchdog> watchdog, kj::Own<LimitEnforcer> inner, kj::String workerName) {
  return kj::heap<SliceLimitEnforcer>(kj::mv(watchdog), kj::mv(inner), kj::mv(workerName));
}

SliceLimitedIsolateLimitEnforcer::SliceLimitedIsolateLimitEnforcer(
    kj::Arc<const SliceWatchdog> watchdog, kj::Own<IsolateLimitEnforcer> inner)
    : watchdog(kj::mv(watchdog)),
      inner(kj::mv(inner)) {}

kj::Own<void> SliceLimitedIsolateLimitEnforcer::enterStartupJs(
    jsg::Lock& lock, kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime) const {
  return enterLimited(
      lock, limitErrorOrTime, inner->enterStartupJs(lock, limitErrorOrTime), false);
}

kj::Own<void> SliceLimitedIsolateLimitEnforcer::enterDynamicImportJs(
    jsg::Lock& lock, kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime) const {
  return enterLimited(
      lock, limitErrorOrTime, inner->enterDynamicImportJs(lock, limitErrorOrTime), true);
}

kj::Own<void> SliceLimitedIsolateLimitEnforcer::enterMaintenanceJs(jsg::Lock& lock) const {
  class Scope {
   public:
    Scope(const SliceLimitedIsolateLimitEnforcer& enforcer, jsg::Lock& lock)
        : enforcer(enforcer),
          lock(lock),
          slice(enforcer.watchdog->arm(lock.v8Isolate)) {}

    ~Scope() noexcept(false) {
      if (!enforcer.watchdog->disarm(*slice)) return;
      lock.v8Isolate->CancelTerminateExecution();
      if (!enforcer.pendingBreach) {
        KJ_LOG(WARNING,
            "executor: Worker loader Worker exceeded its CPU slice limit outside a request; its "
            "next request unloads it",
            enforcer.watchdog->getLimit());
      }
      enforcer.pendingBreach = true;
    }

   private:
    const SliceLimitedIsolateLimitEnforcer& enforcer;
    jsg::Lock& lock;
    kj::Own<SliceWatchdog::Slice> slice;
  };
  return kj::heap<Scope>(*this, lock);
}

kj::Own<void> SliceLimitedIsolateLimitEnforcer::enterLimited(jsg::Lock& lock,
    kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime,
    kj::Own<void> innerScope,
    bool dynamicImport) const {
  class Scope {
   public:
    Scope(const SliceLimitedIsolateLimitEnforcer& enforcer,
        jsg::Lock& lock,
        kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime,
        kj::Own<void> inner,
        bool dynamicImport)
        : enforcer(enforcer),
          lock(lock),
          limitErrorOrTime(limitErrorOrTime),
          inner(kj::mv(inner)),
          dynamicImport(dynamicImport),
          slice(enforcer.watchdog->arm(lock.v8Isolate)) {}

    ~Scope() noexcept(false) {
      if (!enforcer.watchdog->disarm(*slice)) return;
      lock.v8Isolate->CancelTerminateExecution();
      limitErrorOrTime = sliceLimitException();
      if (dynamicImport) {
        enforcer.pendingBreach = true;
      } else {
        enforcer.startupExceeded = true;
      }
    }

   private:
    const SliceLimitedIsolateLimitEnforcer& enforcer;
    jsg::Lock& lock;
    kj::OneOf<kj::Exception, kj::Duration>& limitErrorOrTime;
    kj::Own<void> inner;
    bool dynamicImport;
    kj::Own<SliceWatchdog::Slice> slice;
  };
  return kj::heap<Scope>(*this, lock, limitErrorOrTime, kj::mv(innerScope), dynamicImport);
}

}  // namespace workerd::server
