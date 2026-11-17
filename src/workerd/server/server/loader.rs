// Copyright (c) 2026 Cloudflare, Inc.
// Licensed under the Apache 2.0 license found in the LICENSE file or at:
//     https://opensource.org/licenses/Apache-2.0

//! Dynamic workers: the `workerLoader` binding's namespaces, each a set of workers loaded at
//! runtime from code a worker supplies.
//!
//! A loaded worker is a [`WorkerStub`]. Its startup (fetching the source, compiling, linking)
//! runs as one shared future that begins as soon as the worker is loaded; the entrypoints and
//! classes handed out before it resolves wait on it, and a startup failure is the error every one
//! of them fails with.

use std::cell::Cell;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::rc::Weak;
use std::time::Duration;

use futures::FutureExt;
use futures::future::LocalBoxFuture;
use futures::future::Shared;
use kj_rs::KjMaybe;
use kj_rs::KjOwn;
use worker::Interface;
use workerd_capnp::config;

use crate::Result;
use crate::bridge::ffi;
use crate::channels::ActorClass;
use crate::channels::ActorClassChannel;
use crate::channels::Channel;
use crate::channels::DynamicSource;
use crate::channels::Frankenvalue;
use crate::channels::NewActor;
use crate::channels::PendingToken;
use crate::channels::RequestMetadata;
use crate::channels::SubrequestChannel;
use crate::channels::TokenUsage;
use crate::channels::WorkerInterface;
use crate::channels::attach;
use crate::config::Factory;
use crate::config::Server;
use crate::config::capnp_error;
use crate::worker::WorkerService;

/// One `workerLoader` namespace. Bindings with the same `id` share a namespace, so a worker
/// loaded under a name by one binding is the one another finds under that name.
pub struct WorkerLoaderNamespace {
    server: Weak<Server>,
    name: String,
    /// The named workers. A worker that aborts its isolate leaves the map, so the next load under
    /// its name compiles afresh. Unnamed workers are owned by their JS handles alone.
    isolates: RefCell<HashMap<String, Rc<WorkerStub>>>,
}

impl WorkerLoaderNamespace {
    /// `name` is the binding's name, for error logging.
    #[must_use]
    pub fn new(server: Weak<Server>, name: String) -> Rc<Self> {
        Rc::new(Self {
            server,
            name,
            isolates: RefCell::new(HashMap::new()),
        })
    }

    /// Loads (or, under a `name` already loaded, finds) a dynamic worker.
    pub fn load(
        self: &Rc<Self>,
        name: Option<&str>,
        source: KjOwn<DynamicSource>,
    ) -> Result<Rc<WorkerStub>> {
        let server = self
            .server
            .upgrade()
            .ok_or_else(|| kj::failed!("the server is shutting down"))?;
        let factory = server.factory();
        // An isolate's name is never keyed on nor shown to the app; it is for error logs.
        let stub = match name {
            Some(name) => {
                if let Some(stub) = self.isolates.borrow().get(name) {
                    return Ok(Rc::clone(stub));
                }
                let namespace = Rc::downgrade(self);
                let key = name.to_owned();
                let on_abort: Box<dyn Fn()> = Box::new(move || {
                    if let Some(namespace) = namespace.upgrade() {
                        namespace.isolates.borrow_mut().remove(&key);
                    }
                });
                let stub = WorkerStub::new(
                    Rc::clone(factory),
                    Weak::clone(&self.server),
                    format!("{}:{name}", self.name),
                    source,
                    Some(on_abort),
                );
                self.isolates
                    .borrow_mut()
                    .insert(name.to_owned(), Rc::clone(&stub));
                stub
            }
            None => WorkerStub::new(
                Rc::clone(factory),
                Weak::clone(&self.server),
                format!("{}:dynamic:{:032x}", self.name, rand::random::<u128>()),
                source,
                None,
            ),
        };

        // Startup runs whether or not anything calls the worker, and the task holds the stub
        // until it is done: an unnamed stub's only other owner is its JS handle, which GC may drop
        // while the source is still being fetched (the fetch re-enters the loading worker), and
        // an aborted named stub has left the map. A stub dropped before its service exists would
        // leave that service never unlinked.
        let keep = Rc::clone(&stub);
        factory.spawn_detached(async move {
            // A startup failure reaches the callers that await the stub.
            let _ = keep.startup().await;
        });
        Ok(stub)
    }

    /// Executor fork: unloads named workers that have been unused for `ttl`. The map holds one
    /// reference to each stub; callers' stubs, in-flight requests, and entrypoint and actor class
    /// channels each hold another. A request's reference ends with its response, though, while
    /// `ctx.waitUntil()` work and actors keep running in the worker, so an entry also counts as
    /// used while its worker has any of those (`WorkerService::has_pending_work`). Dropping an
    /// unused entry tears the isolate down the same way `abortIsolate()` does. Stubs that have not
    /// finished starting are left alone. Returns the number of workers unloaded.
    pub fn evict_idle(&self, now: Duration, ttl: Duration) -> usize {
        let expired: Vec<Rc<WorkerStub>> = {
            let mut isolates = self.isolates.borrow_mut();
            let mut names = Vec::new();
            for (name, stub) in isolates.iter() {
                if Rc::strong_count(stub) > 1 || !stub.is_idle() {
                    stub.idle_since.set(None);
                    continue;
                }
                match stub.idle_since.get() {
                    Some(since) => {
                        if now.saturating_sub(since) >= ttl {
                            names.push(name.clone());
                        }
                    }
                    None => stub.idle_since.set(Some(now)),
                }
            }
            names
                .iter()
                .filter_map(|name| isolates.remove(name))
                .collect()
        };
        // Dropped once the map is no longer borrowed; each stub's drop unlinks its worker on the
        // next turn of the event loop.
        expired.len()
    }

    /// Drops every loaded worker's links, as the server does its own at teardown.
    pub fn unlink(&self) {
        for stub in self.isolates.borrow().values() {
            stub.unlink();
        }
    }
}

/// A loaded dynamic worker. The runtime's `WorkerStubChannel`.
pub struct WorkerStub {
    /// Resolves with the started worker, or the startup error. Only clones are polled, so the
    /// result stays readable here (`Shared::peek`).
    startup: Shared<LocalBoxFuture<'static, Result<Rc<WorkerService>>>>,
    unlinked: Cell<bool>,
    /// Executor fork: when `evict_idle` first found the stub unused; reset whenever it is in use.
    idle_since: Cell<Option<Duration>>,
}

impl WorkerStub {
    /// `on_abort` runs (once) when the worker aborts its isolate; a named stub uses it to leave
    /// its namespace. The stub's startup compiles the worker from its source (which the factory
    /// fetches) and links it.
    fn new(
        factory: Rc<Factory>,
        server: Weak<Server>,
        isolate_name: String,
        source: KjOwn<DynamicSource>,
        on_abort: Option<Box<dyn Fn()>>,
    ) -> Rc<Self> {
        let fired = Cell::new(false);
        let abort_isolate: Box<dyn Fn()> = Box::new(move || {
            if fired.replace(true) {
                return;
            }
            if let Some(on_abort) = &on_abort {
                on_abort();
            }
        });
        let startup =
            WorkerService::new_dynamic(factory, isolate_name, source, server, abort_isolate)
                .boxed_local()
                .shared();
        Rc::new(Self {
            startup,
            unlinked: Cell::new(false),
            idle_since: Cell::new(None),
        })
    }

    /// Executor fork: whether the worker has started and has no request, `ctx.waitUntil()` work
    /// or actor in progress.
    fn is_idle(&self) -> bool {
        matches!(self.startup.peek(), Some(Ok(service)) if !service.has_pending_work())
    }

    /// Resolves once the worker has started; fails with the startup error.
    pub fn startup(&self) -> Shared<LocalBoxFuture<'static, Result<Rc<WorkerService>>>> {
        self.startup.clone()
    }

    /// The started worker, once startup has resolved.
    fn service(&self) -> Result<Rc<WorkerService>> {
        match self.startup.peek() {
            Some(started) => started.clone(),
            None => Err(kj::failed!("the dynamic worker has not started")),
        }
    }

    /// Drops the worker's links now. After this, dropping the stub does nothing more.
    pub fn unlink(&self) {
        if let Ok(service) = self.service() {
            service.unlink();
        }
        self.unlinked.set(true);
    }
}

impl Drop for WorkerStub {
    /// Unlinks the worker on the next turn of the event loop: a stub is typically dropped while
    /// another isolate is current (or by a request inside the dynamic isolate itself, through
    /// `ctx.restore()`), so its isolate cannot be entered now. A stub already unlinked has
    /// nothing left to do.
    fn drop(&mut self) {
        if self.unlinked.get() {
            return;
        }
        let Ok(service) = self.service() else {
            return;
        };
        let factory = Rc::clone(service.factory());
        factory.spawn_detached(async move { service.unlink() });
    }
}

#[expect(clippy::unnecessary_box_returns, reason = "cxx requires a Box")]
impl crate::channels::WorkerStub {
    pub(crate) fn entrypoint(
        &self,
        name: KjMaybe<&str>,
        props: KjOwn<Frankenvalue>,
    ) -> Box<SubrequestChannel> {
        SubrequestChannel::new(Rc::new(DynamicEntrypoint {
            stub: Rc::clone(&self.0),
            name: Option::<&str>::from(name).map(str::to_owned),
            props,
        }))
    }

    pub(crate) fn actor_class(
        &self,
        name: KjMaybe<&str>,
        props: KjOwn<Frankenvalue>,
    ) -> Box<ActorClassChannel> {
        ActorClassChannel::new(Rc::new(DynamicActorClass {
            stub: Rc::clone(&self.0),
            name: Option::<&str>::from(name).map(str::to_owned),
            props,
        }))
    }
}

/// Executor fork: with `Config.memory.workerLoaderIdleTtlMs` set, unloads the named dynamic
/// workers nothing has used for that long, checking every `maintenanceIntervalMs`, for as long as
/// `server` lives.
pub fn start_idle_eviction(server: &Rc<Server>, config: config::Reader<'_>) -> Result<()> {
    if !config.has_memory() {
        return Ok(());
    }
    let memory = config.get_memory().map_err(capnp_error)?;
    if memory.get_worker_loader_idle_ttl_ms() == 0 {
        return Ok(());
    }
    let ttl = Duration::from_millis(u64::from(memory.get_worker_loader_idle_ttl_ms()));
    let interval = Duration::from_millis(u64::from(memory.get_maintenance_interval_ms().max(10)));
    let factory = Rc::clone(server.factory());
    let server = Rc::downgrade(server);
    factory.spawn_detached({
        let factory = Rc::clone(&factory);
        async move {
            loop {
                factory.sleep(interval).await;
                let Some(server) = server.upgrade() else {
                    return;
                };
                let evicted = server.evict_idle_worker_loaders(factory.now(), ttl);
                if evicted > 0 {
                    tracing::info!(evicted, "executor: unloaded idle Worker loader isolates");
                }
            }
        }
    });
    Ok(())
}

pub(crate) fn dynamic_transfer_error() -> crate::Error {
    kj::failed!(
        "jsg.DOMException(DataCloneError): Entrypoints to dynamically-loaded workers cannot be \
         transferred to other Workers, because the system does not know how to reload this \
         Worker from scratch. Instead, have the parent Worker expose an entrypoint which \
         constructs the dynamic worker and forwards to it."
    )
}

/// An entrypoint of a dynamic worker. Requests made before the worker has started wait for it.
struct DynamicEntrypoint {
    stub: Rc<WorkerStub>,
    /// `None` is the default entrypoint.
    name: Option<String>,
    props: KjOwn<Frankenvalue>,
}

impl Channel for DynamicEntrypoint {
    fn start_request(&self, metadata: KjOwn<RequestMetadata>) -> Result<KjOwn<WorkerInterface>> {
        let (stub, name) = (Rc::clone(&self.stub), self.name.clone());
        let props = ffi::frankenvalue_clone(&self.props);
        // Starts the request on the started worker. The request keeps the stub alive until it
        // is done: the stub's drop unlinks the worker, which a request in flight must not see.
        let start = move || -> Result<KjOwn<WorkerInterface>> {
            let channel = stub
                .service()?
                .entrypoint(name.as_deref(), Some(props), false)
                .ok_or_else(|| match &name {
                    Some(name) => kj::failed!("jsg.Error: Worker has no such entrypoint: {name}"),
                    None => kj::failed!("jsg.Error: Worker has no default entrypoint."),
                })?;
            Ok(attach(channel.start_request(metadata)?, stub))
        };
        if self.stub.service().is_ok() {
            return start();
        }
        let startup = self.stub.startup();
        Ok(worker::PromisedInterface::new(async move {
            startup.await?;
            start()
        })
        .into_kj())
    }

    fn require_allows_transfer(&self) -> Result<()> {
        Err(dynamic_transfer_error())
    }

    fn token(&self, _usage: TokenUsage) -> Result<KjOwn<PendingToken>> {
        Err(dynamic_transfer_error())
    }
}

/// A Durable Object class of a dynamic worker. `when_ready` waits for the worker to start.
struct DynamicActorClass {
    stub: Rc<WorkerStub>,
    name: Option<String>,
    props: KjOwn<Frankenvalue>,
}

impl DynamicActorClass {
    /// The started worker's class; `when_ready` must have resolved.
    fn inner(&self) -> Result<Rc<dyn ActorClass>> {
        let service = self.stub.service().map_err(|_| {
            kj::failed!("ActorClassChannel is not ready yet; should have awaited whenReady()")
        })?;
        let props = ffi::frankenvalue_clone(&self.props);
        service
            .actor_class(self.name.as_deref(), Some(props), false)
            .ok_or_else(|| match &self.name {
                Some(name) => kj::failed!("jsg.Error: Worker has no such actor class: {name}"),
                None => kj::failed!("jsg.Error: Worker has no default actor class."),
            })
    }
}

impl ActorClass for DynamicActorClass {
    fn when_ready(&self) -> LocalBoxFuture<'_, Result<()>> {
        Box::pin(async move {
            self.stub.startup().await?;
            self.inner().map(drop)
        })
    }

    fn new_actor(&self, request: NewActor<'_>) -> Result<KjOwn<ffi::ActorHandle>> {
        self.inner()?.new_actor(request)
    }

    fn start_request(
        &self,
        metadata: KjOwn<RequestMetadata>,
        actor: &ffi::ActorHandle,
    ) -> Result<KjOwn<WorkerInterface>> {
        self.inner()?.start_request(metadata, actor)
    }

    fn run_on_hibernate<'a>(
        &'a self,
        metadata: KjOwn<RequestMetadata>,
        actor: &'a ffi::ActorHandle,
    ) -> LocalBoxFuture<'a, Result<()>> {
        Box::pin(async move { self.inner()?.run_on_hibernate(metadata, actor).await })
    }

    fn require_allows_transfer(&self) -> Result<()> {
        Err(dynamic_transfer_error())
    }

    fn token(&self, _usage: TokenUsage) -> Result<KjOwn<PendingToken>> {
        Err(dynamic_transfer_error())
    }
}
