-module(inertia_wisp_ssr_test_ffi).

-export([suppress_logger/0]).

suppress_logger() ->
    logger:set_handler_config(default, level, none),
    nil.
