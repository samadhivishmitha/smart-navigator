:- use_module(library(http/http_json)).

main :-
    open_string('{"start":"kelaniya","destination":"colombo_fort","preference":"fastest"}', Stream),
    Request = [method(post), input(Stream), content_type('application/json')],
    http_read_json_dict(Request, Data),
    writeln(Data),
    halt.
