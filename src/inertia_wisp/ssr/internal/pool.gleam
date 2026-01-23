import gleam/bool
import gleam/deque.{type Deque}
import gleam/dict.{type Dict}
import gleam/erlang/process.{
  type Down, type Monitor, type Name, type Pid, type Subject, ProcessDown,
}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/json.{type Json}
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import inertia_wisp/ssr/internal/listener
import inertia_wisp/ssr/internal/protocol.{type Page}
import inertia_wisp/ssr/internal/worker.{
  type Worker, type WorkerError, RenderFailed, Timeout as WorkerTimeout,
}
import logging

const max_retry_attempts = 5

pub type PoolError {
  Timeout
  NotStarted
  InitFailed
  Worker(WorkerError)
}

pub type PoolName =
  Name(PoolMessage)

type PoolConfig {
  PoolConfig(
    size: Int,
    module_path: String,
    node_path: Option(String),
    start_timeout: Duration,
  )
}

pub type PoolMessage {
  Checkout(reply_to: Subject(Result(Worker, PoolError)), request_id: Reference)
  Checkin(worker: Worker)
  CancelWaiting(request_id: Reference)
  WorkerDown(worker: Worker)
  MonitorDown(Down)
  StopPool(reply_to: Subject(Nil))
  RetryWorkerStart(attempts: Int)
  WorkerReady(worker: Worker, worker_id: Int)
  WorkerStartFailed(attempts: Int)
}

type WaitingRequest {
  WaitingRequest(
    request_id: Reference,
    reply_to: Subject(Result(Worker, PoolError)),
  )
}

type PoolState {
  PoolState(
    all_workers: List(Worker),
    assigned_workers: Dict(Reference, Worker),
    available: List(Worker),
    client_monitors: Dict(Monitor, Worker),
    config: PoolConfig,
    initializing_count: Int,
    listener: Subject(listener.ListenerMessage),
    listener_port: Int,
    monitors: Dict(Monitor, Worker),
    next_worker_id: Int,
    pool_subject: Subject(PoolMessage),
    stopping: Bool,
    waiting: Deque(WaitingRequest),
    worker_ids: Dict(Subject(worker.WorkerRequest), Int),
  )
}

pub fn start(
  name: PoolName,
  module_path: String,
  node_path: Option(String),
  pool_size: Int,
) -> Result(Pid, PoolError) {
  let pool_config =
    PoolConfig(
      size: pool_size,
      module_path:,
      node_path:,
      start_timeout: duration.seconds(10),
    )

  start_actor(name, pool_config)
  |> result.map(fn(started) { started.pid })
  |> result.map_error(fn(_) { InitFailed })
}

/// Stop a pool and wait for it to terminate.
/// This is primarily for tests — in production, use a supervisor which
/// handles shutdown automatically.
pub fn stop(pool_name: PoolName) -> Nil {
  case process.named(pool_name) {
    Error(_) -> Nil
    Ok(_) -> {
      let subject = process.named_subject(pool_name)
      let reply_subject = process.new_subject()
      process.send(subject, StopPool(reply_subject))
      let _ = process.receive(reply_subject, 5000)
      Nil
    }
  }
}

pub fn render(
  pool_name: PoolName,
  page_data: Json,
  timeout: Duration,
) -> Result(Page, PoolError) {
  use _ <- result.try(
    process.named(pool_name)
    |> result.replace_error(NotStarted),
  )

  let frame = protocol.encode_request(page_data)
  let pool_subject = process.named_subject(pool_name)
  let start = timestamp.system_time()
  use worker <- worker_transaction(pool_subject, timeout)

  let now = timestamp.system_time()
  let elapsed = timestamp.difference(start, now)
  let remaining = duration.difference(elapsed, timeout)

  case duration.compare(remaining, duration.milliseconds(1)) {
    order.Lt -> Error(Timeout)
    _ -> worker.render_fn(frame, remaining) |> result.map_error(Worker)
  }
}

fn start_actor(
  name: PoolName,
  config: PoolConfig,
) -> Result(actor.Started(Subject(PoolMessage)), actor.StartError) {
  let initialise = fn(subject: Subject(PoolMessage)) {
    use listener_info <- result.try(
      listener.start()
      |> result.replace_error("listener_init_failed"),
    )

    let assert Ok(listener_pid) = process.subject_owner(listener_info.subject)
    let _ = process.link(listener_pid)

    use state <- result.map(
      create_initial_workers(config, subject, listener_info)
      |> result.replace_error("worker_init_failed"),
    )

    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(MonitorDown)

    actor.initialised(state)
    |> actor.selecting(selector)
    |> actor.returning(subject)
  }

  actor.new_with_initialiser(60_000, initialise)
  |> actor.on_message(handle_pool_message)
  |> actor.named(name)
  |> actor.start
}

fn create_initial_workers(
  config: PoolConfig,
  pool_subject: Subject(PoolMessage),
  listener_info: listener.ListenerInfo,
) -> Result(PoolState, WorkerError) {
  let empty_state =
    PoolState(
      all_workers: [],
      assigned_workers: dict.new(),
      available: [],
      client_monitors: dict.new(),
      config:,
      initializing_count: 0,
      listener: listener_info.subject,
      listener_port: listener_info.port,
      monitors: dict.new(),
      next_worker_id: 1,
      pool_subject:,
      stopping: False,
      waiting: deque.new(),
      worker_ids: dict.new(),
    )

  list.range(1, config.size)
  |> list.try_fold(empty_state, fn(state, _) {
    let worker_id = state.next_worker_id
    case start_worker_with_config(state, worker_id) {
      Ok(worker) -> Ok(do_register_worker(state, worker, worker_id))
      Error(err) -> {
        list.each(state.all_workers, fn(w) {
          process.send(w.pool_subject, worker.WorkerShutdown)
        })
        Error(err)
      }
    }
  })
}

fn start_worker_with_config(
  state: PoolState,
  worker_id: Int,
) -> Result(Worker, WorkerError) {
  let worker_config =
    worker.WorkerConfig(
      module_path: state.config.module_path,
      node_path: state.config.node_path,
      start_timeout: state.config.start_timeout,
      listener: state.listener,
      listener_port: state.listener_port,
    )
  worker.start_worker(worker_config, worker_id)
}

fn spawn_worker_start(state: PoolState, worker_id: Int, attempts: Int) -> Nil {
  let pool_subject = state.pool_subject
  let worker_config =
    worker.WorkerConfig(
      module_path: state.config.module_path,
      node_path: state.config.node_path,
      start_timeout: state.config.start_timeout,
      listener: state.listener,
      listener_port: state.listener_port,
    )

  let _ =
    process.spawn_unlinked(fn() {
      case worker.start_worker(worker_config, worker_id) {
        Error(_) -> process.send(pool_subject, WorkerStartFailed(attempts))
        Ok(w) -> process.send(pool_subject, WorkerReady(w, worker_id))
      }
    })
  Nil
}

fn checkout(
  pool_subject: Subject(PoolMessage),
  timeout: Duration,
) -> Result(Worker, PoolError) {
  let reply_subject = process.new_subject()
  let request_id = reference.new()
  process.send(pool_subject, Checkout(reply_subject, request_id))

  let timeout_ms = duration.to_milliseconds(timeout)
  case process.receive(reply_subject, timeout_ms) {
    Error(_) -> {
      process.send(pool_subject, CancelWaiting(request_id))
      Error(Timeout)
    }
    Ok(result) -> result
  }
}

fn worker_transaction(
  pool_subject: Subject(PoolMessage),
  timeout: Duration,
  callback: fn(Worker) -> Result(a, PoolError),
) -> Result(a, PoolError) {
  use worker <- result.try(checkout(pool_subject, timeout))
  let result = callback(worker)
  case result {
    Error(Worker(RenderFailed(_))) ->
      process.send(pool_subject, Checkin(worker))
    Error(Worker(WorkerTimeout)) ->
      process.send(worker.pool_subject, worker.WorkerShutdown)
    Error(Timeout) -> process.send(pool_subject, Checkin(worker))
    Error(_) -> Nil
    Ok(_) -> process.send(pool_subject, Checkin(worker))
  }
  result
}

fn handle_pool_message(
  state: PoolState,
  msg: PoolMessage,
) -> actor.Next(PoolState, PoolMessage) {
  case msg {
    Checkout(reply_to, request_id) ->
      handle_checkout(state, reply_to, request_id)
    Checkin(worker) -> handle_checkin(state, worker)
    CancelWaiting(request_id) -> handle_cancel_waiting(state, request_id)
    WorkerDown(worker) -> handle_worker_down(state, worker)
    MonitorDown(down) -> handle_monitor_down(state, down)
    StopPool(reply_to) -> handle_stop(state, reply_to)
    RetryWorkerStart(attempts) -> handle_retry_worker_start(state, attempts)
    WorkerReady(worker, worker_id) ->
      handle_worker_ready(state, worker, worker_id)
    WorkerStartFailed(attempts) -> handle_worker_start_failed(state, attempts)
  }
}

fn handle_checkout(
  state: PoolState,
  reply_to: Subject(Result(Worker, PoolError)),
  request_id: Reference,
) -> actor.Next(PoolState, PoolMessage) {
  use <- bool.lazy_guard(state.stopping, fn() {
    process.send(reply_to, Error(NotStarted))
    actor.continue(state)
  })

  case state.available {
    [worker, ..remaining] -> {
      process.send(reply_to, Ok(worker))
      let state = monitor_client(state, reply_to, worker)
      actor.continue(PoolState(..state, available: remaining))
    }
    [] -> queue_waiting(state, reply_to, request_id)
  }
}

fn queue_waiting(
  state: PoolState,
  reply_to: Subject(Result(Worker, PoolError)),
  request_id: Reference,
) -> actor.Next(PoolState, PoolMessage) {
  let request = WaitingRequest(request_id:, reply_to:)
  let new_waiting = deque.push_back(state.waiting, request)
  actor.continue(PoolState(..state, waiting: new_waiting))
}

fn handle_checkin(
  state: PoolState,
  worker: Worker,
) -> actor.Next(PoolState, PoolMessage) {
  let state =
    state
    |> demonitor_client_for_worker(worker)
    |> remove_assignment_for_worker(worker)
  use <- bool.lazy_guard(state.stopping, fn() {
    process.send(worker.pool_subject, worker.WorkerShutdown)
    actor.continue(state)
  })

  assign_worker_to_waiting(state, worker)
}

fn assign_worker_to_waiting(
  state: PoolState,
  worker: Worker,
) -> actor.Next(PoolState, PoolMessage) {
  case deque.pop_front(state.waiting) {
    Ok(#(waiting_request, remaining_waiting)) -> {
      process.send(waiting_request.reply_to, Ok(worker))
      let state = monitor_client(state, waiting_request.reply_to, worker)
      let assigned_workers =
        dict.insert(state.assigned_workers, waiting_request.request_id, worker)
      actor.continue(
        PoolState(..state, waiting: remaining_waiting, assigned_workers:),
      )
    }
    Error(Nil) -> {
      let available = [worker, ..state.available]
      actor.continue(PoolState(..state, available:))
    }
  }
}

fn handle_cancel_waiting(
  state: PoolState,
  request_id: Reference,
) -> actor.Next(PoolState, PoolMessage) {
  let new_waiting =
    state.waiting
    |> deque.to_list
    |> list.filter(fn(req) { req.request_id != request_id })
    |> deque.from_list

  case dict.get(state.assigned_workers, request_id) {
    Error(Nil) -> actor.continue(PoolState(..state, waiting: new_waiting))
    Ok(worker) -> {
      let state = demonitor_client_for_worker(state, worker)
      let assigned_workers = dict.delete(state.assigned_workers, request_id)
      let state = PoolState(..state, waiting: new_waiting, assigned_workers:)
      assign_worker_to_waiting(state, worker)
    }
  }
}

fn do_register_worker(
  state: PoolState,
  worker: Worker,
  worker_id: Int,
) -> PoolState {
  let state = register_worker_for_assignment(state, worker, worker_id)
  PoolState(..state, available: [worker, ..state.available])
}

fn register_worker_for_assignment(
  state: PoolState,
  worker: Worker,
  worker_id: Int,
) -> PoolState {
  let assert Ok(pid) = process.subject_owner(worker.pool_subject)
  let monitor = process.monitor(pid)
  PoolState(
    ..state,
    all_workers: [worker, ..state.all_workers],
    monitors: dict.insert(state.monitors, monitor, worker),
    worker_ids: dict.insert(state.worker_ids, worker.pool_subject, worker_id),
    next_worker_id: state.next_worker_id + 1,
  )
}

fn monitor_client(
  state: PoolState,
  reply_to: Subject(Result(Worker, PoolError)),
  worker: Worker,
) -> PoolState {
  case process.subject_owner(reply_to) {
    Ok(client_pid) -> {
      let monitor = process.monitor(client_pid)
      PoolState(
        ..state,
        client_monitors: dict.insert(state.client_monitors, monitor, worker),
      )
    }
    Error(Nil) -> PoolState(..state, available: [worker, ..state.available])
  }
}

fn demonitor_client_for_worker(state: PoolState, worker: Worker) -> PoolState {
  let found =
    state.client_monitors
    |> dict.to_list
    |> list.find(fn(entry) {
      let #(_, w) = entry
      w.pool_subject == worker.pool_subject
    })

  case found {
    Error(Nil) -> state
    Ok(#(monitor, _)) -> {
      let _ = process.demonitor_process(monitor)
      PoolState(
        ..state,
        client_monitors: dict.delete(state.client_monitors, monitor),
      )
    }
  }
}

fn remove_assignment_for_worker(state: PoolState, worker: Worker) -> PoolState {
  let assigned_workers =
    state.assigned_workers
    |> dict.to_list
    |> list.filter(fn(entry) {
      let #(_, w) = entry
      w.pool_subject != worker.pool_subject
    })
    |> dict.from_list
  PoolState(..state, assigned_workers:)
}

fn handle_monitor_down(
  state: PoolState,
  down: Down,
) -> actor.Next(PoolState, PoolMessage) {
  case down {
    ProcessDown(monitor:, ..) -> {
      case dict.get(state.monitors, monitor) {
        Ok(worker) -> {
          let new_monitors = dict.delete(state.monitors, monitor)
          handle_worker_down(PoolState(..state, monitors: new_monitors), worker)
        }
        Error(Nil) -> {
          case dict.get(state.client_monitors, monitor) {
            Ok(worker) -> {
              process.send(worker.pool_subject, worker.WorkerShutdown)
              let new_client_monitors =
                dict.delete(state.client_monitors, monitor)
              actor.continue(
                PoolState(..state, client_monitors: new_client_monitors),
              )
            }
            Error(Nil) -> actor.continue(state)
          }
        }
      }
    }
    _ -> actor.continue(state)
  }
}

fn handle_worker_down(
  state: PoolState,
  worker: Worker,
) -> actor.Next(PoolState, PoolMessage) {
  let _ = logging.log(logging.Warning, "Node.js worker died")

  let old_worker_id = dict.get(state.worker_ids, worker.pool_subject)
  use <- bool.lazy_guard(when: result.is_error(old_worker_id), return: fn() {
    actor.continue(state)
  })

  let assert Ok(id) = old_worker_id
  process.send(state.listener, listener.UnregisterWorker(id))

  let is_alive = fn(w: Worker) { w.pool_subject != worker.pool_subject }
  let base_state =
    state
    |> demonitor_client_for_worker(worker)
    |> remove_assignment_for_worker(worker)
    |> fn(s) {
      PoolState(
        ..s,
        available: list.filter(s.available, is_alive),
        all_workers: list.filter(s.all_workers, is_alive),
        worker_ids: dict.delete(s.worker_ids, worker.pool_subject),
      )
    }

  use <- bool.lazy_guard(when: state.stopping, return: fn() {
    actor.continue(base_state)
  })

  let new_worker_id = base_state.next_worker_id
  let _ = spawn_worker_start(base_state, new_worker_id, 1)
  actor.continue(
    PoolState(
      ..base_state,
      next_worker_id: new_worker_id + 1,
      initializing_count: base_state.initializing_count + 1,
    ),
  )
}

fn schedule_retry(pool_subject: Subject(PoolMessage), attempts: Int) -> Nil {
  let delay_ms =
    int.bitwise_shift_left(1, attempts - 1)
    |> int.multiply(100)

  let _ = process.send_after(pool_subject, delay_ms, RetryWorkerStart(attempts))
  Nil
}

fn handle_retry_worker_start(
  state: PoolState,
  attempts: Int,
) -> actor.Next(PoolState, PoolMessage) {
  use <- bool.lazy_guard(when: state.stopping, return: fn() {
    actor.continue(state)
  })

  case attempts < max_retry_attempts {
    True -> {
      let worker_id = state.next_worker_id
      let _ = spawn_worker_start(state, worker_id, attempts + 1)
      actor.continue(
        PoolState(
          ..state,
          next_worker_id: worker_id + 1,
          initializing_count: state.initializing_count + 1,
        ),
      )
    }
    False -> {
      let _ =
        logging.log(
          logging.Error,
          "Max retries exceeded, pool continues with reduced capacity",
        )
      actor.continue(state)
    }
  }
}

fn handle_worker_ready(
  state: PoolState,
  worker: Worker,
  worker_id: Int,
) -> actor.Next(PoolState, PoolMessage) {
  use <- bool.lazy_guard(when: state.stopping, return: fn() {
    process.send(worker.pool_subject, worker.WorkerShutdown)
    let state =
      PoolState(..state, initializing_count: state.initializing_count - 1)
    actor.continue(state)
  })

  let state = register_worker_for_assignment(state, worker, worker_id)
  let state =
    PoolState(..state, initializing_count: state.initializing_count - 1)
  assign_worker_to_waiting(state, worker)
}

fn handle_worker_start_failed(
  state: PoolState,
  attempts: Int,
) -> actor.Next(PoolState, PoolMessage) {
  let state =
    PoolState(..state, initializing_count: state.initializing_count - 1)

  use <- bool.lazy_guard(when: state.stopping, return: fn() {
    actor.continue(state)
  })

  let _ = schedule_retry(state.pool_subject, attempts)
  actor.continue(state)
}

fn handle_stop(
  state: PoolState,
  reply_to: Subject(Nil),
) -> actor.Next(PoolState, PoolMessage) {
  state.client_monitors
  |> dict.keys
  |> list.each(process.demonitor_process)

  state.waiting
  |> deque.to_list
  |> list.each(fn(req) { process.send(req.reply_to, Error(NotStarted)) })

  list.each(state.all_workers, fn(worker) {
    process.send(worker.pool_subject, worker.WorkerShutdown)
  })

  let _ = case process.subject_owner(state.listener) {
    Ok(listener_pid) -> process.kill(listener_pid)
    Error(Nil) -> Nil
  }

  process.send(reply_to, Nil)
  actor.stop()
}
