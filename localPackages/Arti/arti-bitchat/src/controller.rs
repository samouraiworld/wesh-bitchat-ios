//! Native session control used by the C entry points.

use std::future::Future;
use std::io;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio::sync::oneshot;
use tokio::task::AbortHandle;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Starting,
    Running,
    Stopping,
}

struct Session<C> {
    generation: u64,
    phase: Phase,
    shutdown: Option<oneshot::Sender<()>>,
    abort: Option<AbortHandle>,
    client: Option<Arc<C>>,
}

struct State<C> {
    generation: u64,
    current: Option<Session<C>>,
    stops_in_flight: usize,
    unclean: bool,
    progress: i32,
    summary: String,
}

impl<C> State<C> {
    fn latch_closed(&mut self) {
        self.unclean = true;
        self.progress = 0;
        self.summary.clear();
        if let Some(session) = self.current.as_mut() {
            session.phase = Phase::Stopping;
        }
    }
}

pub(crate) struct Controller<C> {
    state: Mutex<State<C>>,
    changed: Condvar,
    stop_timeout: Duration,
    runtime_factory: fn() -> io::Result<Runtime>,
    #[cfg(test)]
    workers: Mutex<Vec<std::thread::JoinHandle<()>>>,
}

pub(crate) struct SessionContext<C> {
    owner: Arc<Controller<C>>,
    generation: u64,
}

impl<C> Clone for SessionContext<C> {
    fn clone(&self) -> Self {
        Self {
            owner: self.owner.clone(),
            generation: self.generation,
        }
    }
}

impl<C: Send + Sync + 'static> Controller<C> {
    pub(crate) fn new(
        stop_timeout: Duration,
        runtime_factory: fn() -> io::Result<Runtime>,
    ) -> Self {
        Self {
            state: Mutex::new(State {
                generation: 0,
                current: None,
                stops_in_flight: 0,
                unclean: false,
                progress: 0,
                summary: String::new(),
            }),
            changed: Condvar::new(),
            stop_timeout,
            runtime_factory,
            #[cfg(test)]
            workers: Mutex::new(Vec::new()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State<C>> {
        match self.state.lock() {
            Ok(state) => state,
            Err(error) => {
                let mut state = error.into_inner();
                state.latch_closed();
                self.changed.notify_all();
                state
            }
        }
    }

    fn latch_closed(&self) {
        self.lock().latch_closed();
        self.changed.notify_all();
    }

    pub(crate) fn start<F, S>(self: &Arc<Self>, run: F) -> i32
    where
        F: FnOnce(SessionContext<C>, oneshot::Receiver<()>) -> S + Send + 'static,
        S: Future<Output = ()> + Send + 'static,
    {
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let generation = {
            let mut state = self.lock();
            if state.unclean {
                return -5;
            }
            if state.current.is_some() || state.stops_in_flight != 0 {
                return -1;
            }
            let Some(generation) = state.generation.checked_add(1) else {
                state.latch_closed();
                return -5;
            };
            state.generation = generation;
            state.current = Some(Session {
                generation,
                phase: Phase::Starting,
                shutdown: Some(shutdown_tx),
                abort: None,
                client: None,
            });
            state.progress = 0;
            state.summary = "Starting...".into();
            generation
        };

        // Construction and every wait happen outside the lifecycle lock. Stop can
        // close admission even while a runtime is still being constructed.
        let runtime = match catch_unwind(self.runtime_factory) {
            Ok(Ok(runtime)) => runtime,
            _ => {
                self.latch_closed();
                return -3;
            }
        };
        let context = SessionContext {
            owner: self.clone(),
            generation,
        };
        let owner = self.clone();
        let failed_owner = self.clone();
        let worker = std::thread::Builder::new()
            .name("arti-session".into())
            .spawn(move || {
                if catch_unwind(AssertUnwindSafe(|| {
                    owner.supervise(context, runtime, run, shutdown_rx);
                }))
                .is_err()
                {
                    failed_owner.latch_closed();
                }
            });
        match worker {
            Ok(worker) => {
                #[cfg(test)]
                self.workers.lock().unwrap().push(worker);
                #[cfg(not(test))]
                drop(worker);
                0
            }
            Err(_) => {
                self.latch_closed();
                -3
            }
        }
    }

    fn supervise<F, S>(
        self: &Arc<Self>,
        context: SessionContext<C>,
        runtime: Runtime,
        run: F,
        shutdown: oneshot::Receiver<()>,
    ) where
        F: FnOnce(SessionContext<C>, oneshot::Receiver<()>) -> S + Send + 'static,
        S: Future<Output = ()> + Send + 'static,
    {
        let task_context = context.clone();
        let mut job = Some(async move { run(task_context, shutdown).await });
        let root = {
            let mut state = self.lock();
            if !state.unclean
                && state.current.as_ref().is_some_and(|session| {
                    session.generation == context.generation && session.phase == Phase::Starting
                })
            {
                let root = runtime.spawn(job.take().unwrap());
                let session = state.current.as_mut().unwrap();
                session.abort = Some(root.abort_handle());
                session.phase = Phase::Running;
                Some(root)
            } else {
                None
            }
        };
        {
            let _entered = runtime.enter();
            drop(job);
        }
        if let Some(root) = root {
            if let Err(error) = runtime.block_on(root) {
                let stopped = {
                    let state = self.lock();
                    state.unclean
                        || state.current.as_ref().is_some_and(|session| {
                            session.generation == context.generation
                                && session.phase == Phase::Stopping
                        })
                };
                if !error.is_cancelled() || !stopped {
                    self.latch_closed();
                }
            }
        }

        let client = {
            let mut state = self.lock();
            if state
                .current
                .as_ref()
                .is_some_and(|session| session.generation == context.generation)
            {
                let session = state.current.as_mut().unwrap();
                session.phase = Phase::Stopping;
                let client = session.client.take();
                state.progress = 0;
                state.summary.clear();
                client
            } else {
                None
            }
        };
        {
            let _entered = runtime.enter();
            drop(client);
        }
        // A runtime owns Arti's internal tasks as well as the root and accepted
        // handlers. Dropping it on this ordinary thread waits for all of them.
        // If that blocks, stop times out and permanently refuses clean status.
        drop(runtime);
        context.finish();
    }

    pub(crate) fn stop(&self) -> i32 {
        let deadline = Instant::now() + self.stop_timeout;
        let (generation, shutdown, abort, already_unclean) = {
            let mut state = self.lock();
            let already_unclean = state.unclean;
            let Some(session) = state.current.as_mut() else {
                return if already_unclean { -5 } else { -1 };
            };
            session.phase = Phase::Stopping;
            let generation = session.generation;
            let shutdown = session.shutdown.take();
            let abort = session.abort.clone();
            state.progress = 0;
            state.summary.clear();
            state.stops_in_flight += 1;
            (generation, shutdown, abort, already_unclean)
        };
        if let Some(shutdown) = shutdown {
            let _ = shutdown.send(());
        }
        if let Some(abort) = abort {
            abort.abort();
        }

        let mut state = self.lock();
        loop {
            if already_unclean || state.unclean {
                state.stops_in_flight -= 1;
                return -5;
            }
            if !state
                .current
                .as_ref()
                .is_some_and(|session| session.generation == generation)
            {
                state.stops_in_flight -= 1;
                return 0;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                state.latch_closed();
                state.stops_in_flight -= 1;
                self.changed.notify_all();
                return -5;
            }
            state = match self.changed.wait_timeout(state, remaining) {
                Ok((state, _)) => state,
                Err(error) => {
                    let (mut state, _) = error.into_inner();
                    state.latch_closed();
                    state
                }
            };
        }
    }

    pub(crate) fn is_running(&self) -> bool {
        let state = self.lock();
        state.unclean || state.current.is_some()
    }

    pub(crate) fn progress(&self) -> i32 {
        self.lock().progress
    }

    pub(crate) fn summary(&self) -> Result<String, ()> {
        Ok(self.lock().summary.clone())
    }

    pub(crate) fn set_summary(&self, value: &str) {
        let mut state = self.lock();
        if !state.unclean
            && state
                .current
                .as_ref()
                .is_some_and(|session| session.phase != Phase::Stopping)
        {
            state.summary = value.into();
        }
    }

    #[cfg(test)]
    fn join_tasks(&self) {
        let workers = std::mem::take(&mut *self.workers.lock().unwrap());
        for worker in workers {
            worker.join().unwrap();
        }
    }
}

impl<C: Send + Sync + 'static> SessionContext<C> {
    fn active(state: &State<C>, generation: u64) -> bool {
        !state.unclean
            && state.current.as_ref().is_some_and(|session| {
                session.generation == generation && session.phase != Phase::Stopping
            })
    }

    pub(crate) fn admit<T>(&self, operation: impl FnOnce() -> T) -> Option<T> {
        let state = self.owner.lock();
        let result = if Self::active(&state, self.generation) {
            Some(operation())
        } else {
            None
        };
        // The short synchronous bind/spawn operation and stop admission must
        // remain mutually exclusive for the entire operation.
        drop(state);
        result
    }

    pub(crate) fn publish(&self, client: Arc<C>) -> bool {
        let mut state = self.owner.lock();
        if !Self::active(&state, self.generation) {
            return false;
        }
        state.current.as_mut().unwrap().client = Some(client);
        true
    }

    pub(crate) fn set_progress(&self, progress: i32) {
        let mut state = self.owner.lock();
        if Self::active(&state, self.generation) {
            state.progress = progress;
        }
    }

    pub(crate) fn set_summary(&self, value: &str) {
        let mut state = self.owner.lock();
        if Self::active(&state, self.generation) {
            state.summary = value.into();
        }
    }

    fn finish(&self) {
        let mut state = self.owner.lock();
        if !state.unclean
            && state
                .current
                .as_ref()
                .is_some_and(|session| session.generation == self.generation)
        {
            state.current = None;
            state.progress = 0;
        }
        self.owner.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::{Controller, SessionContext};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{mpsc, Arc, Barrier};
    use std::time::Duration;
    use tokio::runtime::Builder;
    use tokio::sync::oneshot;

    struct DropMarker(Arc<AtomicBool>, Option<mpsc::Sender<()>>);

    impl Drop for DropMarker {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
            if let Some(completed) = self.1.take() {
                let _ = completed.send(());
            }
        }
    }

    fn test_runtime() -> std::io::Result<tokio::runtime::Runtime> {
        Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
    }

    fn controller_with_timeout(timeout: Duration) -> Arc<Controller<u8>> {
        Arc::new(Controller::new(timeout, test_runtime))
    }

    fn controller() -> Arc<Controller<u8>> {
        controller_with_timeout(Duration::from_secs(2))
    }

    #[test]
    fn normal_start_stop_preserves_completed_session_control() {
        let control = controller();
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = dropped.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        assert_eq!(
            control.start(move |context, shutdown| async move {
                let _marker = DropMarker(marker, None);
                entered_tx
                    .send(context.admit(|| true) == Some(true))
                    .unwrap();
                let _ = shutdown.await;
            }),
            0
        );
        let admitted = entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        let result = control.stop();
        control.join_tasks();

        assert_eq!(result, 0);
        assert!(
            admitted,
            "an active generation must admit its serving operations"
        );
        assert!(dropped.load(Ordering::SeqCst));
        assert!(!control.is_running());
    }

    #[test]
    fn stop_cannot_report_clean_while_the_root_future_is_alive() {
        let control = controller_with_timeout(Duration::ZERO);
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = dropped.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = oneshot::channel();
        assert_eq!(
            control.start(move |_, _| async move {
                let _marker = DropMarker(marker, None);
                entered_tx.send(()).unwrap();
                let _ = release_rx.await;
            }),
            0
        );
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();

        let clean = control.stop() == 0;
        let dropped_at_return = dropped.load(Ordering::SeqCst);
        let _ = release_tx.send(());
        control.join_tasks();

        assert!(
            !clean || dropped_at_return,
            "native stop reported success before the root future was dropped"
        );
    }

    struct BlockedWork {
        release: mpsc::Sender<()>,
        dropped: Arc<AtomicBool>,
        completed: mpsc::Receiver<()>,
        root_completed: mpsc::Receiver<()>,
        context: SessionContext<u8>,
    }

    fn blocked_internal_work(control: &Arc<Controller<u8>>) -> BlockedWork {
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = dropped.clone();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (completed_tx, completed_rx) = mpsc::channel();
        let (root_tx, root_rx) = mpsc::channel();
        let (context_tx, context_rx) = mpsc::channel();
        assert_eq!(
            control.start(move |context, shutdown| async move {
                let _root = DropMarker(Arc::new(AtomicBool::new(false)), Some(root_tx));
                context_tx.send(context).unwrap();
                let blocking = tokio::task::spawn_blocking(move || {
                    let _marker = DropMarker(marker, Some(completed_tx));
                    entered_tx.send(()).unwrap();
                    let _ = release_rx.recv();
                });
                // Arti's internal runtime work can outlive its caller. Completing
                // the root future alone must not count as native quiescence.
                drop(blocking);
                let _ = shutdown.await;
            }),
            0
        );
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let context = context_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        BlockedWork {
            release: release_tx,
            dropped,
            completed: completed_rx,
            root_completed: root_rx,
            context,
        }
    }

    #[test]
    fn stop_cannot_report_clean_while_internal_runtime_work_is_alive() {
        let control = controller_with_timeout(Duration::ZERO);
        let work = blocked_internal_work(&control);

        let clean = control.stop() == 0;
        let dropped_at_return = work.dropped.load(Ordering::SeqCst);
        work.root_completed
            .recv_timeout(Duration::from_secs(2))
            .unwrap();
        let blocked_after_root_completed = !work.dropped.load(Ordering::SeqCst);
        work.release.send(()).unwrap();
        work.completed.recv_timeout(Duration::from_secs(2)).unwrap();
        control.join_tasks();

        assert!(
            blocked_after_root_completed,
            "the fixture must keep internal work alive independently of the completed root"
        );
        assert!(
            !clean || dropped_at_return,
            "native stop reported success before internal runtime work ended"
        );
    }

    #[test]
    fn incomplete_teardown_blocks_a_replacement_start() {
        let control = controller_with_timeout(Duration::ZERO);
        let work = blocked_internal_work(&control);

        let stopped = control.stop();
        work.root_completed
            .recv_timeout(Duration::from_secs(2))
            .unwrap();
        let (replacement_release, replacement_wait) = oneshot::channel();
        let replacement = control.start(move |_, _| async move {
            let _ = replacement_wait.await;
        });
        work.release.send(()).unwrap();
        let _ = replacement_release.send(());
        work.completed.recv_timeout(Duration::from_secs(2)).unwrap();
        control.join_tasks();

        assert_ne!(
            stopped, 0,
            "blocked internal work cannot have a clean stop result"
        );
        assert_ne!(
            replacement, 0,
            "a new runtime was admitted after teardown had not finished"
        );
        assert!(
            control.is_running(),
            "late teardown must not clear the failure latch"
        );
        assert_eq!(control.progress(), 0);
        assert_eq!(control.summary().unwrap(), "");
        assert_ne!(
            control.start(|_, _| async {}),
            0,
            "finishing late must not admit a later restart in this process"
        );
        assert_ne!(
            control.stop(),
            0,
            "a later stop must not report the failed teardown clean"
        );
    }

    fn completed_context(control: &Arc<Controller<u8>>) -> SessionContext<u8> {
        let (context_tx, context_rx) = mpsc::channel();
        assert_eq!(
            control.start(move |context, shutdown| async move {
                context_tx.send(context).unwrap();
                let _ = shutdown.await;
            }),
            0
        );
        let context = context_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let stopped = control.stop();
        control.join_tasks();
        assert_eq!(stopped, 0);
        context
    }

    fn replacement_session(control: &Arc<Controller<u8>>) -> oneshot::Sender<()> {
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = oneshot::channel();
        assert_eq!(
            control.start(move |context, _| async move {
                context.publish(Arc::new(2));
                context.set_progress(31);
                context.set_summary("Replacement");
                entered_tx.send(()).unwrap();
                let _ = release_rx.await;
            }),
            0
        );
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        release_tx
    }

    #[test]
    fn stale_session_cannot_publish_a_client_or_overwrite_replacement_status() {
        let control = controller();
        let stale = completed_context(&control);
        let release = replacement_session(&control);

        stale.publish(Arc::new(1));
        stale.set_progress(99);
        stale.set_summary("Stale");
        let client = control
            .lock()
            .current
            .as_ref()
            .and_then(|session| session.client.as_ref().map(|value| **value));
        let progress = control.progress();
        let summary = control.summary().unwrap();
        let _ = release.send(());
        control.join_tasks();

        assert_eq!(
            (client, progress, summary.as_str()),
            (Some(2), 31, "Replacement"),
            "a stopped session overwrote the current session's client or status"
        );
    }

    #[test]
    fn stale_completion_cannot_clear_a_replacement_running_state() {
        let control = controller();
        let stale = completed_context(&control);
        let release = replacement_session(&control);

        stale.finish();
        let running = control.is_running();
        let progress = control.progress();
        let _ = release.send(());
        control.join_tasks();

        assert!(
            running,
            "completion from an old session marked its replacement stopped"
        );
        assert_eq!(progress, 31);
    }

    #[test]
    fn concurrent_start_calls_admit_exactly_one_session() {
        let control = controller();
        let ready = Arc::new(Barrier::new(3));
        let mut callers = Vec::new();
        for _ in 0..2 {
            let control = control.clone();
            let ready = ready.clone();
            callers.push(std::thread::spawn(move || {
                let (release, wait) = oneshot::channel();
                ready.wait();
                let result = control.start(move |_, _| async move {
                    let _ = wait.await;
                });
                (result, release)
            }));
        }
        ready.wait();
        let results: Vec<_> = callers
            .into_iter()
            .map(|caller| caller.join().unwrap())
            .collect();
        let stopped = control.stop();
        let codes: Vec<_> = results
            .into_iter()
            .map(|(code, release)| {
                let _ = release.send(());
                code
            })
            .collect();
        control.join_tasks();

        assert_eq!(stopped, 0);
        assert_eq!(codes.iter().filter(|&&code| code == 0).count(), 1);
        assert_eq!(codes.iter().filter(|&&code| code == -1).count(), 1);
    }

    #[test]
    fn stopped_generation_cannot_bind_or_accept_for_a_replacement() {
        let control = controller();
        let stale = completed_context(&control);
        let release = replacement_session(&control);
        let called = AtomicBool::new(false);

        let admitted = stale.admit(|| called.store(true, Ordering::SeqCst));
        let _ = release.send(());
        control.join_tasks();

        assert!(admitted.is_none());
        assert!(!called.load(Ordering::SeqCst));
    }

    #[test]
    fn stopping_closes_admission_and_ready_status_before_teardown_finishes() {
        let control = controller_with_timeout(Duration::ZERO);
        let work = blocked_internal_work(&control);
        let called = AtomicBool::new(false);

        let stopped = control.stop();
        let admitted = work.context.admit(|| called.store(true, Ordering::SeqCst));
        let published = work.context.publish(Arc::new(9));
        work.context.set_progress(100);
        work.context.set_summary("Ready");
        let running = control.is_running();
        let progress = control.progress();
        let summary = control.summary().unwrap();
        work.root_completed
            .recv_timeout(Duration::from_secs(2))
            .unwrap();
        work.release.send(()).unwrap();
        work.completed.recv_timeout(Duration::from_secs(2)).unwrap();
        control.join_tasks();

        assert_ne!(stopped, 0);
        assert!(admitted.is_none());
        assert!(!called.load(Ordering::SeqCst));
        assert!(!published);
        assert!(
            running,
            "an unconfirmed stop must remain visible to Swift as running"
        );
        assert_eq!(progress, 0);
        assert_eq!(summary, "");
    }

    #[test]
    fn worker_panic_keeps_the_process_closed_after_runtime_cleanup() {
        let control = controller();
        let (entered_tx, entered_rx) = mpsc::channel();
        assert_eq!(
            control.start(move |_, _| async move {
                entered_tx.send(()).unwrap();
                panic!("Synthetic native worker failure");
            }),
            0
        );
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        control.join_tasks();

        assert!(control.is_running());
        assert_eq!(control.progress(), 0);
        assert_eq!(control.summary().unwrap(), "");
        assert_ne!(control.start(|_, _| async {}), 0);
        assert_ne!(control.stop(), 0);
    }

    #[test]
    fn runtime_creation_failure_keeps_the_process_closed() {
        fn unavailable_runtime() -> std::io::Result<tokio::runtime::Runtime> {
            Err(std::io::Error::other("Synthetic runtime creation failure"))
        }
        let control = Arc::new(Controller::<u8>::new(Duration::ZERO, unavailable_runtime));

        assert_ne!(control.start(|_, _| async {}), 0);

        assert!(control.is_running());
        assert_eq!(control.progress(), 0);
        assert_ne!(control.start(|_, _| async {}), 0);
        assert_ne!(control.stop(), 0);
    }

    #[test]
    fn poisoned_state_cannot_report_clean_or_publish_ready() {
        let control = controller();
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut state = control.state.lock().unwrap();
            state.progress = 100;
            state.summary = "Ready".into();
            panic!("Synthetic lifecycle lock failure");
        }));

        assert!(control.is_running());
        control.set_summary("Ready");
        assert_eq!(control.progress(), 0);
        assert_eq!(control.summary().unwrap(), "");
        assert_ne!(control.start(|_, _| async {}), 0);
        assert_ne!(control.stop(), 0);
    }
}
