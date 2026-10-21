//! Accepted SOCKS connection tasks owned by one native serving session.

use std::future::Future;
use tokio::task::JoinHandle;

#[derive(Default)]
pub(crate) struct ConnectionTasks {
    tasks: Vec<JoinHandle<()>>,
}

impl ConnectionTasks {
    pub(crate) fn spawn(&mut self, task: impl Future<Output = ()> + Send + 'static) {
        self.tasks.retain(|task| !task.is_finished());
        self.tasks.push(tokio::spawn(task));
    }

    pub(crate) async fn shutdown(self) {
        for task in &self.tasks {
            task.abort();
        }
        for task in self.tasks {
            let _ = task.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ConnectionTasks;
    use std::future::pending;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use tokio::sync::oneshot;

    struct DropMarker {
        dropped: Arc<AtomicBool>,
        completed: Option<oneshot::Sender<()>>,
    }

    impl Drop for DropMarker {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::SeqCst);
            if let Some(completed) = self.completed.take() {
                let _ = completed.send(());
            }
        }
    }

    #[tokio::test]
    async fn shutdown_waits_for_pending_connection_handler_to_drop() {
        let mut connections = ConnectionTasks::default();
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = dropped.clone();
        let (entered_tx, entered_rx) = oneshot::channel();
        connections.spawn(async move {
            let _marker = DropMarker { dropped: marker, completed: None };
            entered_tx.send(()).unwrap();
            pending::<()>().await;
        });
        entered_rx.await.unwrap();

        connections.shutdown().await;

        assert!(dropped.load(Ordering::SeqCst),
                "stop must reap accepted handlers before their client and runtime can be released");
    }

    #[tokio::test]
    async fn shutdown_accepts_an_already_completed_connection_handler() {
        let mut connections = ConnectionTasks::default();
        let dropped = Arc::new(AtomicBool::new(false));
        let marker = dropped.clone();
        let (completed_tx, completed_rx) = oneshot::channel();
        connections.spawn(async move {
            let _marker = DropMarker { dropped: marker, completed: Some(completed_tx) };
        });
        completed_rx.await.unwrap();

        connections.shutdown().await;

        assert!(dropped.load(Ordering::SeqCst));
    }
}
