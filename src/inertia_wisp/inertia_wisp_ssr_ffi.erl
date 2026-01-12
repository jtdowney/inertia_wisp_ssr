-module(inertia_wisp_ssr_ffi).

-behaviour(gen_server).

%% poolboy worker API
-export([start_link/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
%% FFI exports for Gleam
-export([start_pool/6, stop_pool/1, render/3]).
%% FFI helpers for child process callbacks
-export([send_child_data/2, send_child_exit/2]).

-record(state,
        {child,           % Child from Gleam
         buffer,          % iolist (StringTree) buffer for partial lines
         buffer_size,     % Current buffer size in bytes
         max_buffer_size, % Maximum allowed buffer size
         pending}).       % {From, TimerRef} | undefined

start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

init([ModulePath, NodePath, MaxBufferSize]) ->
    Self = self(),
    case inertia_wisp@ssr@internal@child:start(ModulePath, NodePath, Self) of
        {ok, Child} ->
            {ok,
             #state{child = Child,
                    buffer = [],
                    buffer_size = 0,
                    max_buffer_size = MaxBufferSize,
                    pending = undefined}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({render, PageData, Timeout}, From, State) ->
    inertia_wisp@ssr@internal@child:write_request(State#state.child, PageData),
    TimerRef = erlang:send_after(Timeout, self(), render_timeout),
    {noreply, State#state{pending = {From, TimerRef}}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({child_data, Chunk}, State) ->
    ChunkSize = byte_size(Chunk),
    NewBufferSize = State#state.buffer_size + ChunkSize,
    case NewBufferSize > State#state.max_buffer_size of
        true ->
            reply_and_cancel_timer(State#state.pending, {error, buffer_overflow}),
            {stop, buffer_overflow, State};
        false ->
            case inertia_wisp@ssr@internal@child:decode_chunk(State#state.buffer, Chunk) of
                {complete, {ok, Page}, NewBuffer} ->
                    reply_and_cancel_timer(State#state.pending, {ok, Page}),
                    NewBufferSize2 = buffer_size(NewBuffer),
                    {noreply, State#state{buffer = NewBuffer, buffer_size = NewBufferSize2, pending = undefined}};
                {complete, {error, Reason}, NewBuffer} ->
                    reply_and_cancel_timer(State#state.pending, {error, {worker_error, Reason}}),
                    NewBufferSize2 = buffer_size(NewBuffer),
                    {noreply, State#state{buffer = NewBuffer, buffer_size = NewBufferSize2, pending = undefined}};
                {incomplete, NewBuffer} ->
                    {noreply, State#state{buffer = NewBuffer, buffer_size = NewBufferSize}}
            end
    end;
handle_info({child_exit, _Code}, State) ->
    reply_and_cancel_timer(State#state.pending, {error, worker_crashed}),
    {stop, child_exit, State};
handle_info(render_timeout, State) ->
    reply_and_cancel_timer(State#state.pending, {error, worker_timeout}),
    {stop, normal, State#state{pending = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    inertia_wisp@ssr@internal@child:stop(State#state.child),
    ok.

reply_and_cancel_timer({From, TimerRef}, Result) ->
    erlang:cancel_timer(TimerRef),
    gen_server:reply(From, Result);
reply_and_cancel_timer(undefined, _Result) ->
    ok.

%% Calculate buffer size - handles StringTree from Gleam (which is an iolist)
buffer_size(Buffer) ->
    iolist_size(Buffer).

%% FFI helpers called from Gleam callback closures
send_child_data(Pid, Chunk) ->
    Pid ! {child_data, Chunk},
    nil.

send_child_exit(Pid, Code) ->
    Pid ! {child_exit, Code},
    nil.

%% Pool management
start_pool(Name, ModulePath, NodePath, PoolSize, MaxOverflow, MaxBufferSize) ->
    PoolArgs =
        [{name, {local, Name}},
         {worker_module, ?MODULE},
         {size, PoolSize},
         {max_overflow, MaxOverflow},
         {strategy, lifo}],
    WorkerArgs = [ModulePath, NodePath, MaxBufferSize],
    OldTrapExit = process_flag(trap_exit, true),
    Result = poolboy:start_link(PoolArgs, WorkerArgs),
    process_flag(trap_exit, OldTrapExit),
    case Result of
        {ok, Pid} ->
            %% Flush any exit message from successful start
            receive {'EXIT', Pid, _} -> ok after 0 -> ok end,
            {ok, Pid};
        {error, _} ->
            {error, init_failed}
    end.

stop_pool(Name) ->
    poolboy:stop(Name).

render(Name, PageData, Timeout) ->
    try
        poolboy:transaction(Name,
                            fun(Worker) -> gen_server:call(Worker, {render, PageData, Timeout}, Timeout)
                            end,
                            Timeout)
    catch
        exit:{timeout, _} -> {error, worker_timeout};
        exit:{noproc, _} -> {error, pool_not_started};
        exit:Reason ->
            ReasonStr = unicode:characters_to_binary(io_lib:format("~p", [Reason])),
            {error, {worker_exit, ReasonStr}}
    end.
