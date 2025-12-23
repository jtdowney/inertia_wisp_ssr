-module(inertia_wisp_ssr_poolboy_ffi).
-behaviour(gen_server).

%% poolboy worker API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% FFI exports for Gleam
-export([start_pool/4, render/3]).

%% State holds the Gleam worker reference
-record(state, {worker}).

%%% poolboy worker interface %%%

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

init([ModulePath]) ->
    case 'inertia_wisp_ssr@internal@worker':start(ModulePath) of
        {ok, Worker} ->
            {ok, #state{worker = Worker}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({render, PageData, Timeout}, _From, State) ->
    Result = 'inertia_wisp_ssr@internal@worker':call(
        State#state.worker, PageData, Timeout),
    case Result of
        {error, <<"process exited">>} ->
            {stop, normal, {error, worker_crashed}, State};
        {error, <<"timeout">>} ->
            {reply, {error, worker_timeout}, State};
        {error, Reason} when is_binary(Reason) ->
            {reply, {error, {worker_error, Reason}}, State};
        _ ->
            {reply, Result, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    'inertia_wisp_ssr@internal@worker':stop(State#state.worker),
    ok.

%%% FFI functions for Gleam %%%

start_pool(Name, ModulePath, PoolSize, MaxOverflow) ->
    PoolArgs = [
        {name, {local, Name}},
        {worker_module, ?MODULE},
        {size, PoolSize},
        {max_overflow, MaxOverflow},
        {strategy, lifo}
    ],
    WorkerArgs = [ModulePath],
    poolboy:start_link(PoolArgs, WorkerArgs).

render(PoolName, PageData, Timeout) ->
    case checkout_worker(PoolName, Timeout) of
        {error, _} = Err ->
            Err;
        {ok, Worker} ->
            try
                call_worker(Worker, PageData, Timeout)
            after
                poolboy:checkin(PoolName, Worker)
            end
    end.

checkout_worker(PoolName, Timeout) ->
    try
        {ok, poolboy:checkout(PoolName, true, Timeout)}
    catch
        exit:{timeout, _} -> {error, checkout_timeout};
        exit:{noproc, _} -> {error, pool_not_started};
        exit:_ -> {error, pool_error}
    end.

call_worker(Worker, PageData, Timeout) ->
    try
        gen_server:call(Worker, {render, PageData, Timeout}, Timeout)
    catch
        exit:{timeout, _} -> {error, render_timeout};
        exit:{noproc, _} -> {error, worker_crashed};
        exit:_ -> {error, render_error}
    end.
