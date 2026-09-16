:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_files)).
:- use_module(library(www_browser)).

:- consult('backend/smart_route_api.pl').

:- dynamic server_started/0.

:- http_handler(root(.), frontend_files, [prefix]).
:- http_handler(root(assests), http_reply_from_files('assests', []), [prefix]).

start :-
    ensure_server,
    www_open_url('http://localhost:8080/').

start_server :-
    ensure_server,
    thread_get_message(_).

ensure_server :-
    server_started,
    !.
ensure_server :-
    server_port(Port),
    http_server(http_dispatch, [port(Port), bind_address('0.0.0.0')]),
    assertz(server_started).

server_port(Port) :-
    getenv('PORT', PortText),
    catch(( atom(PortText) -> atom_number(PortText, Port) ; number_string(Port, PortText) ), _, fail),
    !.
server_port(8080).

% Skip API requests here so /api/* are handled by the backend handlers.
frontend_files(Request) :-
    memberchk(path(Path), Request),
    ( sub_atom(Path, 0, 4, _, '/api') ; sub_atom(Path, 0, 3, _, 'api') ),
    !,
    fail.

frontend_files(Request) :-
    memberchk(path('/'), Request),
    !,
    http_reply_file('frontend/route_finder_ui.html', [], Request).
frontend_files(Request) :-
    http_reply_from_files('frontend', [], Request).
