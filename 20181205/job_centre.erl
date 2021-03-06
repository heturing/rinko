-module(job_centre).

-behaviour(gen_server).
-record(state, {next_job_number, queued_jobs, executing_jobs, done_jobs}).
-export([start_link/0, init/1, handle_call/3, add_job/1, work_wanted/0, fire_worker/1, job_done/1, statistics/0,handle_info/2]).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
  true.

init([]) ->
  QueuedJobs = dict:new(),
  ExecutingJobs = dict:new(),
  DoneJobs = dict:new(),
  NextJobNumber = 1,
  {ok, #state{next_job_number=NextJobNumber, queued_jobs=QueuedJobs, executing_jobs=ExecutingJobs, done_jobs=DoneJobs}}.

add_job(F) ->
  gen_server:call(?MODULE, {add_job, F}).

work_wanted() ->
  gen_server:call(?MODULE, {work_wanted}).

job_done(JobNumber) ->
  gen_server:call(?MODULE, {job_done, JobNumber}).

statistics() ->
  gen_server:call(?MODULE, {statistics}).

get_job(JobNumber, Jobs) ->
  lists:last(dict:fetch(JobNumber, Jobs)).

move_job(JobNumber, FromBag, ToBag) ->
  Job = get_job(JobNumber, FromBag),
  NewFromBag = dict:erase(JobNumber, FromBag),
  NewToBag = dict:append(JobNumber, Job, ToBag),
  {NewFromBag, NewToBag}.

fire_worker(Pid) ->
    gen_server:call(?MODULE, {fire_worker, Pid}).

fetch_values([], _, Values) -> Values;

fetch_values([H|T], Dict, Values) ->
  V = dict:fetch(H, Dict),
  fetch_values(T, Dict, lists:append(Values, V)).

check_lazy_worker(Pid, JobTime) ->
  HurryTimeMS = (JobTime - 1) * 1000,
  FireTimeMS = 2000,
  receive
    {_, ended} ->
      ok
    after HurryTimeMS ->
      seq_trace:set_token(label,0),
      seq_trace:set_token('receive',true),
      Pid ! {self(), hurry_up},
      %io:format("Please hurry up, ~p!~n", [Pid]),
      receive
        {_, ended} ->
          ok
        after FireTimeMS ->
	  case ex22_5:is_alarmed(Pid) of
	      [true] ->
                  exit(Pid, youre_fired),
		  ex22_5:delete_worker(Pid);
	      [false] ->
	          io:format("Cannot fire the worker ~p, because you have not alarmed him.~n", [Pid]);
	      Any ->
	          io:format("received Any ~p~n",[Any])
	  end
      end
  end.

handle_call({add_job, F}, _From, State) ->
  #state{next_job_number=NextJobNumber, queued_jobs=QueuedJobs} = State,
  NewQueuedJobs = dict:append(NextJobNumber, F, QueuedJobs),
  NewState = State#state{next_job_number=NextJobNumber+1, queued_jobs=NewQueuedJobs},
  {reply, NextJobNumber, NewState};

handle_call({work_wanted}, {Pid,_Ref}, State) ->
   ex22_5:add_worker(Pid),
   Ref = erlang:monitor(process,Pid),
   #state{queued_jobs=QueuedJobs, executing_jobs=ExecutingJobs} = State,
   JobIDs = dict:fetch_keys(QueuedJobs),
   case length(JobIDs) of
     0 -> {reply, no, State};
     _ ->
      JobNumber = lists:min(JobIDs),
      Job = get_job(JobNumber, QueuedJobs),
      JobTime = 10,
      CheckerPid = spawn(fun() -> check_lazy_worker(Pid, JobTime) end),
      NewQueuedJobs = dict:erase(JobNumber,QueuedJobs),
      NewExecutingJobs = dict:append(JobNumber, {Job, Pid, Ref, CheckerPid}, ExecutingJobs),
      NewState = State#state{queued_jobs=NewQueuedJobs, executing_jobs=NewExecutingJobs},
      {reply, {JobNumber, JobTime, Job}, NewState}
  end;

handle_call({job_done, JobNumber}, _From, State) ->
  #state{executing_jobs=ExecutingJobs, done_jobs=DoneJobs} = State,
  case dict:is_key(JobNumber, ExecutingJobs) of
    true ->
        {Job, _, _, CheckerPid} = lists:last(dict:fetch(JobNumber, ExecutingJobs)),
        CheckerPid ! {self(), ended},
        NewExecutingJobs = dict:erase(JobNumber,ExecutingJobs),
        NewDoneJobs = dict:append(JobNumber, Job, DoneJobs),
        NewState = State#state{executing_jobs=NewExecutingJobs, done_jobs=NewDoneJobs},
      {reply, ok, NewState};
    false ->
      {reply, no_job, State}
  end;

handle_call({fire_worker, Pid}, _From, State) ->
    ex22_5:show_all(),
    case ex22_5:is_alarmed(Pid) of
        [true] ->
            exit(Pid, youre_fired),
	    ex22_5:delete_worker(Pid),
	    {reply, exited, State};
	[false] ->
	    io:format("Cannot fire the worker ~p, because you have not alarmed him.~n", [Pid]),
	    {reply, not_exited, State};
	Any ->
	    io:format("received Any ~p~n",[Any]),
	    {reply, Any, State}
    end;

handle_call({statistics}, _From, State) ->
  #state{queued_jobs=QueuedJobs, executing_jobs=ExecutingJobs, done_jobs=DoneJobs} = State,
  Jobs_in_Q = fetch_values(dict:fetch_keys(QueuedJobs),QueuedJobs,[]),
  Jobs_in_E = fetch_values(dict:fetch_keys(ExecutingJobs),ExecutingJobs,[]),
  Jobs_in_D = fetch_values(dict:fetch_keys(DoneJobs),DoneJobs,[]),
  {reply, {{queue,Jobs_in_Q},{progress,Jobs_in_E},{done,Jobs_in_D}}, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
  #state{queued_jobs=QueuedJobs, executing_jobs=ExecutingJobs} = State,
  {JobNumber, Job} = lists:last([{X, Y} || {X, [{Y, _, Z, _}]} <- dict:to_list(ExecutingJobs), Z == Ref]),
  io:format("Worker died ~p~n",[Ref]),
  NewExecutingJobs = dict:erase(JobNumber, ExecutingJobs),
  NewQueuedJobs = dict:append(JobNumber,Job,QueuedJobs),
  NewState = State#state{queued_jobs=NewQueuedJobs, executing_jobs=NewExecutingJobs},
  {noreply, NewState};
handle_info(_Info, State) ->
  {noreply, State}.
