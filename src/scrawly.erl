%% scrawly.erl — BEAM bootstrap for Scrawly (LiveView mode).
%% Called by the iOS/Android native launcher via -eval 'scrawly:start().'.
%% Starts the OTP ecosystem, then starts Phoenix + MobScreen via MobApp.
-module(scrawly).
-export([start/0]).

start() ->
    step(1, fun() -> application:start(compiler) end),
    step(2, fun() -> application:start(elixir)   end),
    step(3, fun() -> application:start(logger)   end),
    step(4, fun() -> mob_nif:platform()          end),
    step(5, fun() -> 'Elixir.Scrawly.MobApp':start() end),
    timer:sleep(infinity).

step(N, Fun) ->
    mob_nif:log("step " ++ integer_to_list(N) ++ " starting"),
    Result = (catch Fun()),
    mob_nif:log("step " ++ integer_to_list(N) ++ " => " ++
                lists:flatten(io_lib:format("~p", [Result]))).
