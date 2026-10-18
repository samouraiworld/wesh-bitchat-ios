//! Bootstrap and serving orchestration shared by the native entry point and its tests.

use std::future::Future;
use tokio::sync::oneshot;

pub(crate) async fn bootstrap_then_serve<C, E, B, F, S>(
    bootstrap: B,
    mut shutdown: oneshot::Receiver<()>,
    serve: F,
) -> Result<(), E>
where
    B: Future<Output = Result<C, E>>,
    F: FnOnce(C, oneshot::Receiver<()>) -> S,
    S: Future<Output = Result<(), E>>,
{
    let client = tokio::select! {
        biased;
        _ = &mut shutdown => return Ok(()),
        result = bootstrap => result?,
    };
    // A stop can arrive while the bootstrap is producing its client. Do not
    // publish that client or bind the listener after the stop has already won.
    match shutdown.try_recv() {
        Ok(()) | Err(oneshot::error::TryRecvError::Closed) => return Ok(()),
        Err(oneshot::error::TryRecvError::Empty) => {}
    }
    serve(client, shutdown).await
}

#[cfg(test)]
mod tests {
    use super::bootstrap_then_serve;
    use std::future::pending;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::oneshot;

    struct DropMarker(Arc<AtomicBool>);

    impl Drop for DropMarker {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    #[tokio::test]
    async fn successful_bootstrap_serves_with_its_shutdown_receiver() {
        let publications = Arc::new(AtomicUsize::new(0));
        let serving = publications.clone();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();

        bootstrap_then_serve(
            async { Ok::<_, ()>(()) },
            shutdown_rx,
            move |_, shutdown| async move {
                serving.fetch_add(1, Ordering::SeqCst);
                shutdown_tx.send(()).unwrap();
                shutdown.await.unwrap();
                Ok(())
            },
        )
        .await
        .unwrap();

        assert_eq!(publications.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn stop_cancels_blocked_bootstrap_and_awaits_its_drop() {
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = dropped.clone();
        let (entered_tx, entered_rx) = oneshot::channel();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let bootstrap = async move {
            let _marker = DropMarker(marker);
            entered_tx.send(()).unwrap();
            pending::<Result<(), ()>>().await
        };
        let mut task = tokio::spawn(bootstrap_then_serve(
            bootstrap,
            shutdown_rx,
            |_, _| async { Ok(()) },
        ));
        entered_rx.await.unwrap();

        shutdown_tx.send(()).unwrap();
        let stopped = matches!(
            tokio::time::timeout(Duration::from_secs(1), &mut task).await,
            Ok(Ok(Ok(())))
        );
        let dropped_before_return = dropped.load(Ordering::SeqCst);
        if !stopped {
            task.abort();
            let _ = task.await;
        }

        assert!(stopped, "shutdown must not wait for a stalled bootstrap to finish");
        assert!(dropped_before_return, "shutdown must drop the bootstrap before reporting success");
    }

    #[tokio::test]
    async fn queued_stop_prevents_client_publication_and_listener_binding() {
        let publications = AtomicUsize::new(0);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        shutdown_tx.send(()).unwrap();

        bootstrap_then_serve(async { Ok::<_, ()>(()) }, shutdown_rx, |_, _| async {
            // The native serving closure publishes the client and binds the listener.
            publications.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .await
        .unwrap();

        assert_eq!(publications.load(Ordering::SeqCst), 0,
                   "a stopped bootstrap must never enter the native serving phase");
    }

    #[tokio::test]
    async fn stop_arriving_as_bootstrap_finishes_prevents_serving() {
        let publications = AtomicUsize::new(0);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let bootstrap = async move {
            shutdown_tx.send(()).unwrap();
            Ok::<_, ()>(())
        };

        bootstrap_then_serve(bootstrap, shutdown_rx, |_, _| async {
            publications.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .await
        .unwrap();

        assert_eq!(publications.load(Ordering::SeqCst), 0,
                   "shutdown during bootstrap completion must win before publication or binding");
    }
}
