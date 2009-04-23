%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Centralized authority on where agent_fsm's are and starting them.
%% Similar in function to the {@link queue_manager}, just oriented towards
%% agents.  There can be only one `agent_manager' per node.

-module(agent_manager).
-author(micahw).
-behaviour(gen_leader).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").

-record(state, {
	agents = dict:new() :: dict()
	}).


% API exports
-export([
	start_link/1, 
	start/1, 
	stop/0, 
	start_agent/1, 
	query_agent/1, 
	find_by_skill/1,
	find_avail_agents_by_skill/1,
	get_leader/0,
	list/0
]).

% gen_leader callbacks
-export([init/1,
		elected/2,
		surrendered/3,
		handle_DOWN/3,
		handle_leader_call/4,
		handle_leader_cast/3,
		from_leader/3,
		handle_call/3,
		handle_cast/2,
		handle_info/2,
		terminate/2,
		code_change/4]).

%% API

%% @doc Starts the `agent_manger' linked to the calling process.
-spec(start_link/1 :: (Nodes :: [atom()]) -> {'ok', pid()}).
start_link(Nodes) -> 
	gen_leader:start_link(?MODULE, Nodes, [], ?MODULE, [], []).

%% @doc Starts the `agent_manager' without linking to the calling process.
-spec(start/1 :: (Nodes :: [atom()]) -> {'ok', pid()}).
start(Nodes) -> 
	gen_leader:start(?MODULE, Nodes, [], ?MODULE, [], []).
	
%% @doc stops the `agent_manager'.
-spec(stop/0 :: () -> {'ok', pid()}).
stop() -> 
	gen_leader:call(?MODULE, stop).
	
%% @doc starts a new agent_fsm for `Agent'. Returns `{ok, pid()}', where `Pid' is the new agent_fsm pid.
-spec(start_agent/1 :: (Agent :: #agent{}) -> {'ok', pid()} | {'exists', pid()}).
start_agent(#agent{login = ALogin} = Agent) -> 
	case query_agent(ALogin) of
		false -> 
			gen_leader:call(?MODULE, {start_agent, Agent});
		{true, Apid} -> 
			{exists, Apid}
	end.

%% @doc Locally find all available agents with a particular skillset that contains the subset `Skills'.  Sorted by idle time, 
%% then the length of the list of skills the agent has;  this means idle time is less important.
-spec(find_avail_agents_by_skill/1 :: (Skills :: [atom()]) -> [{string(), pid(), #agent{}}]).
find_avail_agents_by_skill(Skills) -> 
	?DEBUG("skills passed:  ~p.", [Skills]),
	AvailSkilledAgents = [{K, V, AgState} || {K, V} <-
		gen_leader:call(?MODULE, list_agents), % get all the agents
		AgState <- [agent:dump_state(V)], % dump their state
		AgState#agent.state =:= idle, % only get the idle ones
		( % check if either the call or the agent has the _all skill
			lists:member('_all', AgState#agent.skills) orelse
			lists:member('_all', Skills)
			% if there's no _all skill, make sure the agent has all the required skills
		) orelse util:list_contains_all(AgState#agent.skills, Skills)],
	AvailSkilledAgentsByIdleTime = lists:sort(fun({_K1, _V1, State1}, {_K2, _V2, State2}) -> State1#agent.lastchangetimestamp =< State2#agent.lastchangetimestamp end, AvailSkilledAgents), 
	F = fun({_K1, _V1, State1}, {_K2, _V2, State2}) -> 
		case {lists:member('_all', State1#agent.skills), lists:member('_all', State2#agent.skills)} of
			{true, false} -> 
				false;
			{false, true} -> 
				true;
			_Else -> 
				length(State1#agent.skills) =< length(State2#agent.skills)
		end
	end,
	lists:sort(F, AvailSkilledAgentsByIdleTime).

find_by_skill(Skills) ->
	[{K, V, AgState} || {K, V} <- gen_leader:call(?MODULE, list_agents), AgState <- [agent:dump_state(V)], lists:member('_all', AgState#agent.skills) orelse util:list_contains_all(AgState#agent.skills, Skills)].
	
%% @doc Get a list of agents at the node this `agent_manager' is running on.
-spec(list/0 :: () -> [any()]).
list() ->
	gen_leader:call(?MODULE, list_agents).

%% @doc Check if an agent idetified by agent record or login name string of `Login' exists
-spec(query_agent/1 ::	(Agent :: #agent{}) -> {'true', pid()} | 'false';
						(Login :: string()) -> {'true', pid()} | 'false').
query_agent(#agent{login=Login}) -> 
	query_agent(Login);
query_agent(Login) -> 
	gen_leader:leader_call(?MODULE, {exists, Login}).

%% @doc Returns `{ok, pid()}' where `pid()' is the pid of the leader process.
-spec(get_leader/0 :: () -> {'ok', pid()}).
get_leader() -> 
	gen_leader:leader_call(?MODULE, get_pid).
	
%% gen_leader callbacks
%% @hidden
init([]) ->
	?DEBUG("~p starting at ~p", [?MODULE, node()]),
	process_flag(trap_exit, true),
	{ok, #state{}}.
	
%% @hidden
elected(State, _Election) -> 
	?INFO("elected", []),
	{ok, ok, State}.
	
%% @hidden
%% TODO what about an agent started at both places?
surrendered(#state{agents = Agents} = State, _LeaderState, _Election) -> 
	?INFO("surrendered", []),
	% clean out non-local pids
	F = fun(_Login, Apid) -> 
		node() =:= node(Apid)
	end,
	Locals = dict:filter(F, Agents),
	% and tell the leader about local pids
	Notify = fun({Login, Apid}) -> 
		gen_leader:leader_cast(?MODULE, {notify, Login, Apid})
	end,
	lists:foreach(Notify, dict:to_list(Locals)),
	{ok, State#state{agents=Locals}}.
	
%% @hidden
handle_DOWN(Node, #state{agents = Agents} = State, _Election) -> 
	% clean out the pids associated w/ the dead node
	F = fun(_Login, Apid) -> 
		Node =/= node(Apid)
	end,
	Agents2 = dict:filter(F, Agents),
	{ok, State#state{agents = Agents2}}.

%% @hidden
handle_leader_call({exists, Agent}, _From, #state{agents = Agents} = State, _Election) when is_list(Agent) -> 
	?DEBUG("Trying to determine if ~p exists", [Agent]),
	case dict:find(Agent, Agents) of
		error -> 
			{reply, false, State};
		{ok, Apid} -> 
			{reply, {true, Apid}, State}
	end;
handle_leader_call(get_pid, _From, State, _Election) -> 
	{reply, {ok, self()}, State}.

%% @hidden
handle_leader_cast({notify, Agent, Apid}, #state{agents = Agents} = State, _Election) -> 
	?INFO("Notified of ~p pid ~p", [Agent, Apid]),
	case dict:find(Agent, Agents) of
		error -> 
			Agents2 = dict:store(Agent, Apid, Agents),
			{noreply, State#state{agents = Agents2}};
		_Else -> 
			{noreply, State}
	end;
handle_leader_cast({notify_down, Agent}, #state{agents = Agents} = State, _Election) ->
	?NOTICE("leader notified of ~p exiting", [Agent]),
	{noreply, State#state{agents = dict:erase(Agent, Agents)}};
handle_leader_cast(dump_election, State, Election) -> 
	?DEBUG("Dumping leader election.~nSelf:  ~p~nDump:  ~p", [self(), Election]),
	{noreply, State}.

%% @hidden
from_leader(_Msg, State, _Election) -> 
	?DEBUG("Stub from leader.", []),
	{ok, State}.

%% @hidden
handle_call(list_agents, _From, #state{agents = Agents} = State) -> 
	{reply, dict:to_list(Agents), State};
handle_call(stop, _From, State) -> 
	{stop, normal, ok, State};
handle_call({start_agent, #agent{login = ALogin} = Agent}, _From, #state{agents = Agents} = State) -> 
	% This should not be called directly!  use the wrapper start_agent/1
	?INFO("Starting new agent ~p", [Agent]),
	{ok, Apid} = agent:start_link(Agent),
	gen_leader:leader_cast(?MODULE, {notify, ALogin, Apid}),
	Agents2 = dict:store(ALogin, Apid, Agents),
	gen_server:cast(dispatch_manager, {end_avail, Apid}),
	{reply, {ok, Apid}, State#state{agents = Agents2}}.

%% @hidden
handle_cast(_Request, State) -> 
	?DEBUG("Stub handle_cast", []),
	{noreply, State}.

%% @hidden
handle_info({'EXIT', Pid, Reason}, #state{agents=Agents} = State) ->
	?NOTICE("Caught exit for ~p with reason ~p", [Pid, Reason]),
	F = fun(Key, Value) ->
		case Value =/= Pid of
			true -> true;
			false ->
				?NOTICE("notifying leader of ~p exit", [Key]),
				gen_leader:leader_cast(?MODULE, {notify_down, Key}),
				false
		end
	end,
	{noreply, State#state{agents=dict:filter(F, Agents)}};
handle_info(Msg, State) ->
	?DEBUG("Stub handle_info for ~p", [Msg]),
	{noreply, State}.

%% @hidden
terminate(Reason, _State) -> 
	?NOTICE("Terminating:  ~p", [Reason]),
	ok.

%% @hidden
code_change(_OldVsn, State, _Election, _Extra) ->
	{ok, State}.
	
-ifdef('EUNIT').

handle_call_start_test() ->
	?assertMatch({ok, _Pid}, start([node()])),
	stop().

single_node_test_() -> 
	{foreach,
		fun() ->
			Agent = #agent{login="testagent"},
			catch agent_auth:stop(),
			mnesia:stop(),
			mnesia:delete_schema([node()]),
			mnesia:create_schema([node()]),
			mnesia:start(),
			agent_auth:start(),
			start([node()]),
			Agent
		end,
		fun(_Agent) -> 
			stop()
		end,
		[
			fun(Agent) ->
				{"Start New Agent", 
					fun() -> 
						{ok, Pid} = start_agent(Agent),
						?assertMatch({ok, released}, agent:query_state(Pid))
					end
				}
			end,
			fun(Agent) ->
				{"Start Existing Agent",
					fun() -> 
						{ok, Pid} = start_agent(Agent),
						?assertMatch({exists, Pid}, start_agent(Agent))
					end
				}
			end,
			fun(Agent) ->
				{"Lookup agent by name",
					fun() -> 
						{ok, Pid} = start_agent(Agent),
						Login = Agent#agent.login,
						?assertMatch({true, Pid}, query_agent(Login))
					end
				}
			end,
			fun(_Agent) ->
				{"Look for a non-existang agent",
					fun() -> 
						?assertMatch(false, query_agent("does not exist"))
					end
				}
			end, 
			fun(_Agent) ->
				{"Find available agents with a skillset that matches but is the shortest",
					fun() ->
						Agent1 = #agent{login="Agent1"},
						Agent2 = #agent{login="Agent2", skills=[english, '_agent', '_node', coolskill, otherskill]},
						Agent3 = #agent{login="Agent3", skills=[english, '_agent', '_node', coolskill]},
						{ok, Agent1Pid} = gen_leader:call(?MODULE, {start_agent, Agent1}),
						{ok, Agent2Pid} = gen_leader:call(?MODULE, {start_agent, Agent2}),
						{ok, Agent3Pid} = gen_leader:call(?MODULE, {start_agent, Agent3}),
						agent:set_state(Agent1Pid, idle),
						agent:set_state(Agent3Pid, idle),
						?assertMatch([{"Agent3", Agent3Pid, _State}], find_avail_agents_by_skill([coolskill])),
						agent:set_state(Agent2Pid, idle),
						?assertMatch([{"Agent3", Agent3Pid, _State1}, {"Agent2", Agent2Pid, _State2}], find_avail_agents_by_skill([coolskill]))
					end
				}
			end,
			fun(_Agent) ->
				{"Find available agents with a skillset that matches but is longest idle",
					fun() ->
						Agent1 = #agent{login="Agent1"},
						Agent2 = #agent{login="Agent2", skills=[english, '_agent', '_node', coolskill]},
						Agent3 = #agent{login="Agent3", skills=[english, '_agent', '_node', coolskill]},
						{ok, Agent1Pid} = gen_leader:call(?MODULE, {start_agent, Agent1}),
						{ok, Agent2Pid} = gen_leader:call(?MODULE, {start_agent, Agent2}),
						{ok, Agent3Pid} = gen_leader:call(?MODULE, {start_agent, Agent3}),
						agent:set_state(Agent1Pid, idle),
						agent:set_state(Agent3Pid, idle),
						?assertMatch([{"Agent3", Agent3Pid, _State}], find_avail_agents_by_skill([coolskill])),
						receive after 500 -> ok end,
						agent:set_state(Agent2Pid, idle),
						?assertMatch([{"Agent3", Agent3Pid, _State1}, {"Agent2", Agent2Pid, _State2}], find_avail_agents_by_skill([coolskill]))
					end
				}
			end
		]
	}.



get_nodes() ->
	[_Name, Host] = string:tokens(atom_to_list(node()), "@"),
	{list_to_atom(lists:append("master@", Host)), list_to_atom(lists:append("slave@", Host))}.

multi_node_test_() -> 
		{
		foreach,
		fun() ->
			?CONSOLE("======multi node setup!=======", []),
			{Master, Slave} = get_nodes(),
			Agent = #agent{login="testagent"},
			Agent2 = #agent{login="testagent2"},
			slave:start(net_adm:localhost(), master, " -pa debug_ebin"), 
			slave:start(net_adm:localhost(), slave, " -pa debug_ebin"),
			mnesia:stop(),
			
			mnesia:change_config(extra_db_nodes, [Master, Slave]),
			mnesia:delete_schema([node(), Master, Slave]),
			mnesia:create_schema([node(), Master, Slave]),
			
			cover:start([Master, Slave]),
			
			rpc:call(Master, mnesia, start, []),
			rpc:call(Slave, mnesia, start, []),
			mnesia:start(),
			
			mnesia:change_table_copy_type(schema, Master, disc_copies),
			mnesia:change_table_copy_type(schema, Slave, disc_copies),

			{ok, _P3} = rpc:call(Master, agent_auth, start, []),
			{ok, _P4} = rpc:call(Slave, agent_auth, start, []),

			{ok, _P1} = rpc:call(Master, ?MODULE, start, [[Master, Slave]]),
			?CONSOLE("Master started!", []),
			{ok, _P2} = rpc:call(Slave, ?MODULE, start, [[Master, Slave]]),
			?CONSOLE("Slave started!", []),
			{Master, Slave, Agent, Agent2}
		end,
		fun({Master, Slave, _Agent, _Agent2}) -> 
			cover:stop([Master, Slave]),
			slave:stop(Master),
			slave:stop(Slave),
			ok
		end,
		[
			fun({Master, Slave, Agent, _Agent2}) ->
				{"Slave picks up added agent",
					fun() -> 
						{ok, Pid} = rpc:call(Master, ?MODULE, start_agent, [Agent]),
						?assertMatch({exists, Pid}, rpc:call(Slave, ?MODULE, start_agent, [Agent]))
					end
				}
			end,
			fun({Master, Slave, Agent, _Agent2}) ->
				{"Slave continues after master dies",
					fun() -> 
						{ok, _Pid} = rpc:call(Master, ?MODULE, start_agent, [Agent]),
						%slave:stop(Master),
						rpc:call(Master, erlang, disconnect_node, [Slave]),
						rpc:call(Slave, erlang, disconnect_node, [Master]),
						?assertMatch({ok, _NewPid}, rpc:call(Slave, ?MODULE, start_agent, [Agent]))
					end
				}
			end,
			fun({Master, Slave, _Agent, _Agent2}) ->
				{"Slave becomes master after master dies",
					fun() -> 
						%% getting the pids is important for this test
						cover:stop([Master, Slave]),
						slave:stop(Master),
						slave:stop(Slave),
						
						slave:start(net_adm:localhost(), master, " -pa debug_ebin"), 
						slave:start(net_adm:localhost(), slave, " -pa debug_ebin"),
						cover:start([Master, Slave]),

						{ok, _MasterP} = rpc:call(Master, ?MODULE, start, [[Master, Slave]]),
						{ok, SlaveP} = rpc:call(Slave, ?MODULE, start, [[Master, Slave]]),

						%% test proper begins
						rpc:call(Master, erlang, disconnect_node, [Slave]),
						cover:stop([Master]),
						slave:stop(Master),
						
						?assertMatch({ok, SlaveP}, rpc:call(Slave, ?MODULE, get_leader, []))
						
						%?assertMatch(undefined, global:whereis_name(?MODULE)),
						%?assertMatch({ok, _Pid}, rpc:call(Slave, ?MODULE, start_agent, [Agent])),
						%?assertMatch({true, _Pid}, rpc:call(Slave, ?MODULE, query_agent, [Agent])),
						
						
						%Globalwhere = global:whereis_name(?MODULE),
						%Slaveself = rpc:call(Slave, erlang, whereis, [?MODULE]),
											
						%?assertMatch(Globalwhere, Slaveself)
					end
				}
			end,
			fun({Master, Slave, Agent, Agent2}) ->
				{"Net Split with unique agents",
					fun() ->
						{ok, Apid1} = rpc:call(Master, ?MODULE, start_agent, [Agent]),
						
						?assertMatch({exists, Apid1}, rpc:call(Slave, ?MODULE, start_agent, [Agent])),
					
						rpc:call(Master, erlang, disconnect_node, [Slave]),
						rpc:call(Slave, erlang, disconnect_node, [Master]),
						
						{ok, Apid2} = rpc:call(Slave, ?MODULE, start_agent, [Agent2]),
											
						Pinged = rpc:call(Master, net_adm, ping, [Slave]),
						Pinged = rpc:call(Slave, net_adm, ping, [Master]),

						?assert(Pinged =:= pong),

						?assertMatch({true, Apid1}, rpc:call(Slave, ?MODULE, query_agent, [Agent])),
						?assertMatch({true, Apid2}, rpc:call(Master, ?MODULE, query_agent, [Agent2]))
						
					end
				}
			end,
			fun({Master, Slave, Agent, Agent2}) ->
				{"Master removes agents for a dead node",
					fun() ->
						?assertMatch({ok, _Pid}, rpc:call(Slave, ?MODULE, start_agent, [Agent])),
						?assertMatch({ok, _Pid}, rpc:call(Master, ?MODULE, start_agent, [Agent2])),
						?assertMatch({true, _Pid}, rpc:call(Master, ?MODULE, query_agent, [Agent])),
						rpc:call(Master, erlang, disconnect_node, [Slave]),
						cover:stop(Slave),
						slave:stop(Slave),
						?assertEqual(false, rpc:call(Master, ?MODULE, query_agent, [Agent])),
						?assertMatch({true, _Pid}, rpc:call(Master, ?MODULE, query_agent, [Agent2])),
						?assertMatch({ok, _Pid}, rpc:call(Master, ?MODULE, start_agent, [Agent]))
					end
				}
			end,
			fun({Master, Slave, Agent, _Agent2}) ->
				{"Master is notified of agent removal on slave",
					fun() ->
						{ok, Pid} = rpc:call(Slave, ?MODULE, start_agent, [Agent]),
						?assertMatch({true, Pid}, rpc:call(Slave, ?MODULE, query_agent, [Agent])),
						?assertMatch({true, Pid}, rpc:call(Master, ?MODULE, query_agent, [Agent])),
						exit(Pid, kill),
						timer:sleep(300),
						?assertMatch(false, rpc:call(Slave, ?MODULE, query_agent, [Agent])),
						?assertMatch(false, rpc:call(Master, ?MODULE, query_agent, [Agent]))
					end
				}
			end
		]
	}.

-endif.

